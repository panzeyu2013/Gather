// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryCleanupFlow+Finalize.swift
// 源：DeliveryCleanupFlow.swift（HEAD 3fbf997）；纯拆分（finalize + 备份清理），
// 控制流/错误码/计数逐字未改（P1-1 后置备份清理仅 finalize 调用）。
// 访问级：共享错误映射为 internal（记账见 DeliveryCleanupFlow.swift 头部）。
//
// P1 下一波 §3.1.3（本文件改造）：finalize 变成 **module 作用域**的收尾。
// - 只删本模块的 synced item；
// - 该交付上仍有其它模块 item（任意状态）→ 保留交付行与备份，记 retained，
//   留给最后一个模块收尾（谁最后结束谁清理，不会出现无主备份）；
// - 已无其它 item → 走原有前滚（prepare → 删备份 → CAS 删行 → finish），逐字不变；
// - 本模块仍有未确认 item → skip 并报 XMP_CONFIRM_INCOMPLETE（"先确认再结束"）。
// 共享交付的语义与 cleanup 的 retainForeign 对齐，但**绝不 restore**（只 drop）。
//
// GC/保留期（§3.1.4）复用同一个逐交付步骤 finalizeStep：不另写删除逻辑。

import Foundation
import GatherPersistence
import GatherProtocol

extension DeliveryCleanupFlow {
    // MARK: - finalize

    /// 结束会话：只处理 synced 交付；**保留 XMP 原样**，删除 items/links/delivery
    /// 与备份文件（刻意不 restore）。reload-ack 门禁由 Coordinator 在进入本流程前检查。
    ///
    /// P1-1 顺序：verify（不碰盘）→ advance(fileDone) → DB 删除事务 → 删备份。
    /// DB CAS/事务失败时交付行、备份、intent 都在，错误进 summary，下一次
    /// finalize/replay 可重试；备份删除失败时行已删，只上报孤儿备份。
    ///
    /// §3.1.3：候选只要求"本模块 item 全部 synced"；同一文件上其它模块的 item
    /// 不再阻止"删自己的 item"，但会阻止删行/备份（retained 分支）。
    func finalize(
        sessionId: String,
        module: DeliveryModule
    ) async throws -> DeliveryFinalizeSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        let startedAtMs = DeliveryTrace.nowMs()
        let candidates = try summaryQuery.syncedCandidates(sessionId: sessionId, module: module)
        let backlog = try intents.pending()
        var activeIntents = Set(backlog.all.map(\.xmpPath))
        var totals = FinalizeStepOutcome()

        for candidate in candidates {
            let step = try await finalizeStep(
                candidate, sessionId: sessionId, module: module, blockedByIntent: activeIntents)
            if let prepared = step.preparedIntentPath {
                activeIntents.insert(prepared)
            }
            totals.merge(step)
        }

        // WP7b：批次汇总只带计数与整体耗时，不输出路径/会话明文。
        DeliveryTrace.log(
            DeliveryTrace.text(
                id: DeliveryTrace.sessionToken(sessionId), revision: 0, phase: "summary"),
            "event=done op=finalize phase=summary module=\(module.rawValue) "
                + "deleted=\(totals.deleted) retained=\(totals.retained) "
                + "skipped=\(totals.skipped) errors=\(totals.errors.count) "
                + "duration_ms=\(DeliveryTrace.elapsedMs(since: startedAtMs))",
            level: .info)
        emitStateChanged(sessionId)
        return totals.summary
    }

    /// GC/保留期专用：按交付行结束**一条**已确认交付（不按会话过滤）。
    ///
    /// 与 finalize(sessionId:module:) 的差别只有两处：
    /// - 候选由调用方（MetadataRetentionService）按保留期选出；
    /// - module 传 nil = 整条交付（仍有未 synced item 时 DB 段门禁 fail-closed 拒绝，
    ///   行与备份原样保留）。
    /// 文件/DB 段与 finalize 逐字相同：同一条 intent 前滚，不另写删除逻辑。
    ///
    /// - Parameter sessionId: 关联会话（只用于 photoPath 解析；空串表示"没有会话上下文"，
    ///   此时解析器必须退回 delivery.photoPath —— 生产默认解析器正是如此）。
    func finalizeDeliveryRow(
        _ candidate: DeliveryRow,
        sessionId: String
    ) async -> DeliveryFinalizeSummary {
        let blockedByIntent: Set<String>
        do {
            blockedByIntent = Set(try intents.pending().all.map(\.xmpPath))
        } catch {
            return DeliveryFinalizeSummary(
                deletedCount: 0,
                skippedCount: 0,
                errors: [Self.failure("XMP_FINALIZE_PREPARE_FAILED", candidate.xmpPath, error)],
                retainedCount: 0
            )
        }
        do {
            let step = try await finalizeStep(
                candidate, sessionId: sessionId, module: nil, blockedByIntent: blockedByIntent)
            return step.summary
        } catch {
            return DeliveryFinalizeSummary(
                deletedCount: 0,
                skippedCount: 0,
                errors: [Self.failure("XMP_FINALIZE_DB_FAILED", candidate.xmpPath, error)],
                retainedCount: 0
            )
        }
    }

    // MARK: - 单条交付（finalize 批次与 GC 共用的唯一删除步骤）

    /// 单个交付的 finalize 步骤（不改任何批次状态；调用方累计计数）。
    ///
    /// 抛出只来自交付行读取（SQL）；其余失败一律进 step.errors，
    /// 与既有 finalize"单交付失败不拖垮整批"的纪律一致。
    private func finalizeStep(
        _ candidate: DeliveryRow,
        sessionId: String,
        module: DeliveryModule?,
        blockedByIntent: Set<String>
    ) async throws -> FinalizeStepOutcome {
        if blockedByIntent.contains(candidate.xmpPath) {
            var step = FinalizeStepOutcome()
            step.skipped = 1
            step.errors.append("XMP_FINALIZE_INTENT_PENDING: \(candidate.xmpPath)")
            return step
        }
        // 候选查询与文件阶段之间状态可能漂移：重新读一次再 prepare。
        guard let current = try deliveryRepo.get(candidate.xmpPath),
              current.id == candidate.id,
              DeliveryStateMachine.isCleanupCandidate(current.typedStatus)
        else {
            var step = FinalizeStepOutcome()
            step.skipped = 1
            return step
        }
        // §3.1.3：module 作用域的收尾规则（GC 传 nil 时跳过，直接整条结束）。
        if let module, let scope = finalizeModuleScope(current, module: module) {
            return scope
        }
        let resolvedPhotoPath: String
        do {
            resolvedPhotoPath = try resolvePhotoPath(sessionId, current)
        } catch {
            var step = FinalizeStepOutcome()
            step.skipped = 1
            step.errors.append(Self.failure("XMP_FINALIZE_PATH_FAILED", current.xmpPath, error))
            return step
        }
        let payload = DeliveryCleanupPayload(
            delivery: current,
            photoPath: resolvedPhotoPath,
            action: .finalize
        )
        // P2：错误 reason 里可能带 xmp/backup/photo 绝对路径；trace 只用
        // pathToken（basename#hash），完整路径仍保留在 summary.errors 供定位。
        let traceContext = [current.xmpPath, payload.photoPath, payload.backupPath]
        // WP7b：本交付本次尝试的关联标识（prepare 时的 id/revision 快照）。
        let traceFile = DeliveryTrace.text(
            deliveryId: current.id, revision: current.revision, phase: "file")
        let traceDB = DeliveryTrace.text(
            deliveryId: current.id, revision: current.revision, phase: "db")
        let traceIntent = DeliveryTrace.text(
            deliveryId: current.id, revision: current.revision, phase: "intent")
        // P2：备份清理是 finalize 的独立后置段（DB 提交之后），trace 段必须与
        // phase=backup 一致；不能再借用 /db（否则按段 grep 会把尾段误读成 DB）。
        let traceBackup = DeliveryTrace.text(
            deliveryId: current.id, revision: current.revision, phase: "backup")
        let intentId: Int64
        do {
            intentId = try intents.prepare(
                kind: .cleanup,
                xmpPath: current.xmpPath,
                payload: payload.json
            )
        } catch {
            DeliveryTrace.log(
                traceIntent,
                "event=failed op=finalize phase=intent outcome=prepare-failed "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.errors.append(
                Self.failure("XMP_FINALIZE_PREPARE_FAILED", current.xmpPath, error))
            return step
        }

        // P0-1 + TOCTOU：finalize 只删备份，但备份路径可能已被新一轮写入
        // 复用；verify（锁内 revision/status）→ 删备份 → 事后复核整体在
        // XMPFileLock 内，与 WritebackService 写盘共用同一实例。
        DeliveryTrace.log(
            traceFile,
            "event=start op=finalize phase=file xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                + "intent=\(intentId) action=\(payload.action.rawValue)",
            level: .info)
        let phase = await filePhase.run(xmpPath: current.xmpPath, payload: payload)
        switch phase {
        case .completed:
            DeliveryTrace.log(
                traceFile,
                "event=done op=finalize phase=file xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "intent=\(intentId) outcome=completed",
                level: .info)
            break
        case .guardFailed(let reason):
            DeliveryTrace.log(
                traceFile,
                "event=failed op=finalize phase=file outcome=guard-failed "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.errors.append(
                "XMP_FINALIZE_GUARD_FAILED: \(current.xmpPath) reason=\(reason)")
            return step
        case .fileFailed(let reason):
            // prepared 留在库里：下次 replay 重删备份（删除是幂等的）。
            DeliveryTrace.log(
                traceFile,
                "event=failed op=finalize phase=file outcome=file-failed "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.errors.append(
                "XMP_FINALIZE_FILE_FAILED: \(current.xmpPath) reason=\(reason)")
            return step
        case .invalidated(let reason):
            DeliveryTrace.log(
                traceFile,
                "event=failed op=finalize phase=file outcome=invalidated "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.skipped = 1
            step.errors.append(
                "XMP_FINALIZE_FILE_RACED: \(current.xmpPath) reason=\(reason)")
            do {
                try intents.finish(id: intentId, error: "XMP_FINALIZE_FILE_RACED: \(reason)")
            } catch {
                step.errors.append(
                    Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
            }
            return step
        case .skipped(let verdict):
            switch verdict {
            case .changed(let reason):
                DeliveryTrace.log(
                    traceFile,
                    "event=skipped op=finalize phase=file outcome=changed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                var step = FinalizeStepOutcome()
                step.skipped = 1
                step.errors.append("XMP_FINALIZE_ABANDONED: \(current.xmpPath) reason=\(reason)")
                do {
                    try intents.finish(
                        id: intentId, error: "XMP_FINALIZE_ABANDONED: \(reason)")
                } catch {
                    step.errors.append(
                        Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
                return step
            case .conflict(let reason):
                // finalize 不做指纹比对；conflict 分支不可达（仅清理编译器穷举）。
                DeliveryTrace.log(
                    traceFile,
                    "event=skipped op=finalize phase=file outcome=conflict "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                var step = FinalizeStepOutcome()
                step.skipped = 1
                step.errors.append("XMP_FINALIZE_ABANDONED: \(current.xmpPath) reason=\(reason)")
                do {
                    try intents.finish(
                        id: intentId, error: "XMP_FINALIZE_ABANDONED: \(reason)")
                } catch {
                    step.errors.append(
                        Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
                return step
            case .invalidBackup(let reason):
                // P2-12：备份路径不可信时 finalize 必须保留行与备份；
                // 与 cleanup 一样以终态 intent 收尾，避免无限重试。
                DeliveryTrace.log(
                    traceFile,
                    "event=skipped op=finalize phase=file outcome=invalid-backup "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                var step = FinalizeStepOutcome()
                step.skipped = 1
                step.errors.append(
                    "XMP_FINALIZE_BACKUP_PATH_INVALID: \(current.xmpPath) reason=\(reason)")
                do {
                    try intents.finish(
                        id: intentId,
                        error: "XMP_FINALIZE_BACKUP_PATH_INVALID: \(reason)")
                } catch {
                    step.errors.append(
                        Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
                return step
            case .alreadyGone:
                DeliveryTrace.log(
                    traceFile,
                    "event=skipped op=finalize phase=file outcome=already-gone "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath))",
                    level: .info)
                var step = FinalizeStepOutcome()
                step.skipped = 1
                do { try intents.finish(id: intentId) }
                catch {
                    step.errors.append(
                        Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
                return step
            case .proceed:
                break
            }
        }
        do {
            _ = try intents.advance(id: intentId, to: .fileDone)
        } catch {
            DeliveryTrace.log(
                traceIntent,
                "event=failed op=finalize phase=intent outcome=advance-failed "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) intent=\(intentId) "
                    + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.errors.append(
                Self.failure("XMP_FINALIZE_ADVANCE_FAILED", current.xmpPath, error))
            return step
        }

        // DB 删除 + intent.finish 同一事务（DeliveryDBPhase 的唯一事务）。
        DeliveryTrace.log(
            traceDB,
            "event=start op=finalize phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                + "intent=\(intentId) action=\(payload.action.rawValue)",
            level: .info)
        let outcome: FinalizeDBOutcome
        do {
            outcome = try dbPhase.applyFinalize(
                intentId: intentId,
                xmpPath: current.xmpPath,
                payload: payload
            )
        } catch let error as DeliveryDBPhaseError {
            DeliveryTrace.log(
                traceDB,
                "event=failed op=finalize phase=db outcome=db-failed "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(cause(of: error), paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.errors.append(
                Self.failure(code(for: error, action: .finalize), current.xmpPath, cause(of: error)))
            return step
        } catch {
            DeliveryTrace.log(
                traceDB,
                "event=failed op=finalize phase=db outcome=db-failed "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.errors.append(Self.failure("XMP_FINALIZE_DB_FAILED", current.xmpPath, error))
            return step
        }
        var step = FinalizeStepOutcome()
        switch outcome {
        case .deleted:
            DeliveryTrace.log(
                traceDB,
                "event=done op=finalize phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "outcome=\(outcome.reason)",
                level: .info)
            step.deleted = 1
            // P1-1：DB 删除事务已提交，备份删除是唯一的后置步骤（幂等）。
            if let failure = await removeFinalizeBackup(
                xmpPath: current.xmpPath,
                backupPath: payload.backupPath,
                trace: traceBackup
            ) {
                step.errors.append(failure)
            } else {
                // A3：备份已清（或本就不存在）才删 applied intent；失败留给 replay。
                try? intents.finish(id: intentId, error: nil)
            }
        case .alreadyGone:
            DeliveryTrace.log(
                traceDB,
                "event=done op=finalize phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "outcome=\(outcome.reason)",
                level: .info)
            step.skipped = 1
            // 行已不在（并发删除/重放）：备份归属已确认，同样按后置步骤清理。
            if let failure = await removeFinalizeBackup(
                xmpPath: current.xmpPath,
                backupPath: payload.backupPath,
                trace: traceBackup
            ) {
                step.errors.append(failure)
            } else {
                try? intents.finish(id: intentId, error: nil)
            }
        case .incompleteItems(let blockerModule, let blockerStatus):
            // P2-2：DB 段门禁拒绝。交付行/备份/其它模块 item 全部保留；
            // intent 已标终态错误，错误必须让调用方看见（不是静默 skip）。
            //
            // §3.1.3：走到这里说明本模块 item 已全部 synced（否则上面的 module
            // 作用域门禁更早返回），剩余的未 synced item 属于其它模块 —— 新的
            // module 收尾规则本应在 DB 段之前 retain，因此本分支只在 GC（module=nil）
            // 或竞态下出现，仍按 fail-closed 报错。
            DeliveryTrace.log(
                traceDB,
                "event=skipped op=finalize phase=db outcome=incomplete-items "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "module=\(blockerModule) status=\(blockerStatus)",
                level: .warn)
            step.skipped = 1
            step.errors.append(
                "XMP_FINALIZE_INCOMPLETE_ITEMS: \(current.xmpPath) "
                    + "module=\(blockerModule) status=\(blockerStatus)")
        case .idChanged, .revisionChanged, .stateChanged:
            DeliveryTrace.log(
                traceDB,
                "event=skipped op=finalize phase=db outcome=\(outcome.reason) "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) reason=db-guard-rejected",
                level: .warn)
            step.skipped = 1
            // CAS 拒绝：交付行与新输入都保留，备份**必须原样保留**
            // （P1-1：绝不能留下指向已删文件的 backup_path）。错误必须可见。
            step.errors.append(
                "XMP_FINALIZE_SKIPPED: \(current.xmpPath) reason=\(outcome.reason)")
        }
        // 新建过 intent 的路径交给调用方登记（同批后续候选不会重复 prepare）。
        step.preparedIntentPath = current.xmpPath
        return step
    }

    // MARK: - module 作用域收尾（§3.1.3）

    /// 判断该交付是否只能"删自己的 item"：返回非 nil 表示本步骤已结束（不进入前滚）。
    ///
    /// 顺序：
    /// 1. 本模块仍有非 synced item → 跳过并报 XMP_CONFIRM_INCOMPLETE（先确认再结束）；
    /// 2. 仍有其它模块 item（任意状态）→ 只删本模块 synced item，保留行/备份，
    ///    记 retained（留给最后一个模块收尾）；
    /// 3. 只有本模块 item → 返回 nil，走原有整条前滚。
    private func finalizeModuleScope(
        _ current: DeliveryRow,
        module: DeliveryModule
    ) -> FinalizeStepOutcome? {
        let items: [DeliveryItemRow]
        do {
            items = try deliveryRepo.items(deliveryId: current.id)
        } catch {
            var step = FinalizeStepOutcome()
            step.skipped = 1
            step.errors.append(
                Self.failure("XMP_FINALIZE_DB_FAILED", current.xmpPath, error))
            return step
        }
        let ownModule = items.filter { $0.module == module.rawValue }
        let foreignModules = items.filter { $0.module != module.rawValue }
        if let blocker = ownModule.first(where: { $0.typedStatus != .synced }) {
            // 不新增错误码：与 confirm 同一门禁码（用户的下一步动作就是"先确认"）。
            DeliveryTrace.log(
                DeliveryTrace.text(
                    deliveryId: current.id, revision: current.revision, phase: "db"),
                "event=skipped op=finalize phase=db outcome=confirm-incomplete "
                    + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "module=\(module.rawValue) status=\(blocker.status)",
                level: .warn)
            var step = FinalizeStepOutcome()
            step.skipped = 1
            step.errors.append(
                "XMP_CONFIRM_INCOMPLETE: \(current.xmpPath) "
                    + "module=\(module.rawValue) status=\(blocker.status)")
            return step
        }
        guard !foreignModules.isEmpty else { return nil }
        // 共享文件：只删本模块的 synced item（单事务、幂等），行与备份保留。
        do {
            _ = try writer.deleteItems(
                xmpPath: current.xmpPath, module: module, statuses: [.synced])
        } catch {
            var step = FinalizeStepOutcome()
            step.skipped = 1
            step.errors.append(
                Self.failure("XMP_FINALIZE_DB_FAILED", current.xmpPath, error))
            return step
        }
        let foreignNames = Set(foreignModules.map(\.module)).sorted()
        DeliveryTrace.log(
            DeliveryTrace.text(
                deliveryId: current.id, revision: current.revision, phase: "db"),
            "event=done op=finalize phase=db outcome=retained-foreign-items "
                + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                + "module=\(module.rawValue) foreign=\(foreignNames.joined(separator: ","))",
            level: .info)
        var step = FinalizeStepOutcome()
        step.retained = 1
        return step
    }

    // MARK: - P1-1：DB 成功后的备份清理

    /// 交付行删除成功之后才删备份（finalize 的唯一删除点，幂等）。
    ///
    /// 返回非 nil 表示清理没完成（新交付复用该路径 / IO 失败）：交付行已删，
    /// 不回滚；错误并入 summary 让调用方看见，绝不把清理失败伪装成成功。
    /// DB CAS/事务失败的分支不调用本方法（备份保留，下一次 finalize/replay 重试）。
    private func removeFinalizeBackup(
        xmpPath: String,
        backupPath: String,
        trace: String
    ) async -> String? {
        let removal = await filePhase.removeFinalizeBackup(
            xmpPath: xmpPath, backupPath: backupPath)
        switch removal {
        case .removed:
            DeliveryTrace.log(
                trace,
                "event=done op=finalize phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) outcome=removed",
                level: .info)
            return nil
        case .absent:
            DeliveryTrace.log(
                trace,
                "event=done op=finalize phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) outcome=absent",
                level: .info)
            return nil
        case .retained(let reason):
            DeliveryTrace.log(
                trace,
                "event=skipped op=finalize phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) "
                    + "outcome=retained "
                    + "reason=\(DeliveryTrace.reason(reason, paths: [xmpPath, backupPath]))",
                level: .warn)
            return "XMP_FINALIZE_BACKUP_RETAINED: \(xmpPath) reason=\(reason)"
        case .failed(let reason):
            DeliveryTrace.log(
                trace,
                "event=failed op=finalize phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) "
                    + "reason=\(DeliveryTrace.reason(reason, paths: [xmpPath, backupPath]))",
                level: .warn)
            return "XMP_FINALIZE_BACKUP_CLEANUP_FAILED: \(xmpPath) reason=\(reason)"
        }
    }
}

/// 单个交付的 finalize 结果（批次与 GC 单条共用）。
///
/// 只做计数聚合：delivered 与 skipped 互斥；retained 表示"只删了本模块 item，
/// 交付行与备份保留"，它不是失败（errors 为空），但用户仍需看到"还没结束"。
struct FinalizeStepOutcome {
    var deleted = 0
    var retained = 0
    var skipped = 0
    var errors: [String] = []
    /// 本步骤 prepare 过 intent 的路径（批次内后续候选不得重复 prepare）。
    var preparedIntentPath: String?

    var summary: DeliveryFinalizeSummary {
        DeliveryFinalizeSummary(
            deletedCount: deleted,
            skippedCount: skipped,
            errors: errors,
            retainedCount: retained
        )
    }

    mutating func merge(_ other: FinalizeStepOutcome) {
        deleted += other.deleted
        retained += other.retained
        skipped += other.skipped
        errors.append(contentsOf: other.errors)
        // preparedIntentPath 不合并：由调用方逐条登记（见 finalize 的循环）。
    }
}
