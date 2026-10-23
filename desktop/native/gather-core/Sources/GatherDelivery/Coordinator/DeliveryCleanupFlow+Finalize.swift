// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryCleanupFlow+Finalize.swift
// 源：DeliveryCleanupFlow.swift（HEAD 3fbf997）；纯拆分（finalize + 备份清理），
// 控制流/错误码/计数逐字未改（P1-1 后置备份清理仅 finalize 调用）。
// 访问级：共享错误映射为 internal（记账见 DeliveryCleanupFlow.swift 头部）。

import Foundation
import GatherPersistence

extension DeliveryCleanupFlow {
    // MARK: - finalize

    /// 结束会话：只处理 synced 交付；**保留 XMP 原样**，删除 items/links/delivery
    /// 与备份文件（刻意不 restore）。reload-ack 门禁由 Coordinator 在进入本流程前检查。
    ///
    /// P1-1 顺序：verify（不碰盘）→ advance(fileDone) → DB 删除事务 → 删备份。
    /// DB CAS/事务失败时交付行、备份、intent 都在，错误进 summary，下一次
    /// finalize/replay 可重试；备份删除失败时行已删，只上报孤儿备份。
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
        var deletedCount = 0
        var skippedCount = 0
        var errors: [String] = []

        for candidate in candidates {
            if activeIntents.contains(candidate.xmpPath) {
                skippedCount += 1
                errors.append("XMP_FINALIZE_INTENT_PENDING: \(candidate.xmpPath)")
                continue
            }
            // 候选查询与文件阶段之间状态可能漂移：重新读一次再 prepare。
            guard let current = try deliveryRepo.get(candidate.xmpPath),
                  current.id == candidate.id,
                  DeliveryStateMachine.isCleanupCandidate(current.typedStatus)
            else {
                skippedCount += 1
                continue
            }
            let resolvedPhotoPath: String
            do {
                resolvedPhotoPath = try resolvePhotoPath(sessionId, current)
            } catch {
                skippedCount += 1
                errors.append(Self.failure("XMP_FINALIZE_PATH_FAILED", current.xmpPath, error))
                continue
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
                errors.append(Self.failure("XMP_FINALIZE_PREPARE_FAILED", current.xmpPath, error))
                continue
            }
            activeIntents.insert(current.xmpPath)

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
                errors.append("XMP_FINALIZE_GUARD_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .fileFailed(let reason):
                // prepared 留在库里：下次 replay 重删备份（删除是幂等的）。
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=finalize phase=file outcome=file-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                errors.append("XMP_FINALIZE_FILE_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .invalidated(let reason):
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=finalize phase=file outcome=invalidated "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                skippedCount += 1
                errors.append("XMP_FINALIZE_FILE_RACED: \(current.xmpPath) reason=\(reason)")
                do {
                    try intents.finish(
                        id: intentId, error: "XMP_FINALIZE_FILE_RACED: \(reason)")
                } catch {
                    errors.append(
                        Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                }
                continue
            case .skipped(let verdict):
                switch verdict {
                case .changed(let reason):
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=finalize phase=file outcome=changed "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                            + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                        level: .warn)
                    skippedCount += 1
                    errors.append("XMP_FINALIZE_ABANDONED: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intents.finish(
                            id: intentId, error: "XMP_FINALIZE_ABANDONED: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .conflict(let reason):
                    // finalize 不做指纹比对；conflict 分支不可达（仅清理编译器穷举）。
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=finalize phase=file outcome=conflict "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                            + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                        level: .warn)
                    skippedCount += 1
                    errors.append("XMP_FINALIZE_ABANDONED: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intents.finish(
                            id: intentId, error: "XMP_FINALIZE_ABANDONED: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .invalidBackup(let reason):
                    // P2-12：备份路径不可信时 finalize 必须保留行与备份；
                    // 与 cleanup 一样以终态 intent 收尾，避免无限重试。
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=finalize phase=file outcome=invalid-backup "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                            + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                        level: .warn)
                    skippedCount += 1
                    errors.append(
                        "XMP_FINALIZE_BACKUP_PATH_INVALID: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intents.finish(
                            id: intentId,
                            error: "XMP_FINALIZE_BACKUP_PATH_INVALID: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .alreadyGone:
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=finalize phase=file outcome=already-gone "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath))",
                        level: .info)
                    skippedCount += 1
                    do { try intents.finish(id: intentId) }
                    catch {
                        errors.append(
                            Self.failure("XMP_FINALIZE_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .proceed:
                    continue
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
                errors.append(Self.failure("XMP_FINALIZE_ADVANCE_FAILED", current.xmpPath, error))
                continue
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
                errors.append(Self.failure(code(for: error, action: .finalize), current.xmpPath, cause(of: error)))
                continue
            } catch {
                DeliveryTrace.log(
                    traceDB,
                    "event=failed op=finalize phase=db outcome=db-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                    level: .warn)
                errors.append(Self.failure("XMP_FINALIZE_DB_FAILED", current.xmpPath, error))
                continue
            }
            switch outcome {
            case .deleted:
                DeliveryTrace.log(
                    traceDB,
                    "event=done op=finalize phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "outcome=\(outcome.reason)",
                    level: .info)
                deletedCount += 1
                // P1-1：DB 删除事务已提交，备份删除是唯一的后置步骤（幂等）。
                if let failure = await removeFinalizeBackup(
                    xmpPath: current.xmpPath,
                    backupPath: payload.backupPath,
                    trace: traceBackup
                ) {
                    errors.append(failure)
                }
            case .alreadyGone:
                DeliveryTrace.log(
                    traceDB,
                    "event=done op=finalize phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "outcome=\(outcome.reason)",
                    level: .info)
                skippedCount += 1
                // 行已不在（并发删除/重放）：备份归属已确认，同样按后置步骤清理。
                if let failure = await removeFinalizeBackup(
                    xmpPath: current.xmpPath,
                    backupPath: payload.backupPath,
                    trace: traceBackup
                ) {
                    errors.append(failure)
                }
            case .incompleteItems(let blockerModule, let blockerStatus):
                // P2-2：DB 段门禁拒绝。交付行/备份/其它模块 item 全部保留；
                // intent 已标终态错误，错误必须让调用方看见（不是静默 skip）。
                DeliveryTrace.log(
                    traceDB,
                    "event=skipped op=finalize phase=db outcome=incomplete-items "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "module=\(blockerModule) status=\(blockerStatus)",
                    level: .warn)
                skippedCount += 1
                errors.append(
                    "XMP_FINALIZE_INCOMPLETE_ITEMS: \(current.xmpPath) "
                        + "module=\(blockerModule) status=\(blockerStatus)")
            case .idChanged, .revisionChanged, .stateChanged:
                DeliveryTrace.log(
                    traceDB,
                    "event=skipped op=finalize phase=db outcome=\(outcome.reason) "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) reason=db-guard-rejected",
                    level: .warn)
                skippedCount += 1
                // CAS 拒绝：交付行与新输入都保留，备份**必须原样保留**
                // （P1-1：绝不能留下指向已删文件的 backup_path）。错误必须可见。
                errors.append(
                    "XMP_FINALIZE_SKIPPED: \(current.xmpPath) reason=\(outcome.reason)")
            }
        }

        // WP7b：批次汇总只带计数与整体耗时，不输出路径/会话明文。
        DeliveryTrace.log(
            DeliveryTrace.text(
                id: DeliveryTrace.sessionToken(sessionId), revision: 0, phase: "summary"),
            "event=done op=finalize phase=summary module=\(module.rawValue) "
                + "deleted=\(deletedCount) skipped=\(skippedCount) errors=\(errors.count) "
                + "duration_ms=\(DeliveryTrace.elapsedMs(since: startedAtMs))",
            level: .info)
        emitStateChanged(sessionId)
        return DeliveryFinalizeSummary(
            deletedCount: deletedCount,
            skippedCount: skippedCount,
            errors: errors
        )
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
