// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryCleanupFlow+Cleanup.swift
// 源：DeliveryCleanupFlow.swift（HEAD 3fbf997）；纯拆分（cleanup），控制流/错误码/计数逐字未改。
// 访问级：共享错误映射为 internal（记账见 DeliveryCleanupFlow.swift 头部）。

import Foundation
import GatherPersistence

extension DeliveryCleanupFlow {
    // MARK: - cleanup

    /// 清理本会话在本模块下已确认（synced）的交付。
    ///
    /// 已有未完成 intent 的交付会被跳过（由 replay() 统一重试，避免重复 prepare）。
    func cleanup(
        sessionId: String,
        module: DeliveryModule
    ) async throws -> DeliveryCleanupSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryCoordinatorError.invalidArgument("sessionId 不能为空")
        }
        let startedAtMs = DeliveryTrace.nowMs()
        let candidates = try summaryQuery.cleanupCandidates(sessionId: sessionId, module: module)
        let backlog = try intents.pending()
        var activeIntents = Set(backlog.all.map(\.xmpPath))

        var deletedCount = 0
        var conflictedCount = 0
        var skippedCount = 0
        var errors: [String] = []
        var conflictedXmpPaths: [String] = []

        for candidate in candidates {
            if activeIntents.contains(candidate.xmpPath) {
                skippedCount += 1
                errors.append("XMP_CLEANUP_INTENT_PENDING: \(candidate.xmpPath)")
                continue
            }
            // 重新读一次，避免候选查询与文件阶段之间状态漂移。
            guard let current = try deliveryRepo.get(candidate.xmpPath),
                  current.id == candidate.id,
                  DeliveryStateMachine.isCleanupCandidate(current.typedStatus)
            else {
                skippedCount += 1
                continue
            }

            // P1-8：删除前检查该交付的**所有**模块 item（文件级交付可能同时有
            // culling/metadata/... 的输入）。必须在 prepare/文件阶段之前：确认
            // 不能删时不得 restore/remove sidecar，也不得建 intent。
            let itemGate: CleanupItemGate
            do {
                itemGate = try dbPhase.cleanupItemGate(
                    deliveryId: current.id, module: module)
            } catch {
                skippedCount += 1
                errors.append(Self.failure("XMP_CLEANUP_ITEM_GATE_FAILED", current.xmpPath, error))
                continue
            }
            switch itemGate {
            case .incomplete(let blockerModule, let status):
                skippedCount += 1
                errors.append(
                    "XMP_CLEANUP_INCOMPLETE_ITEMS: \(current.xmpPath) "
                        + "module=\(blockerModule) status=\(status)")
                continue
            case .retainForeign(let modules):
                // 本模块 item 已全部 synced，但同一文件上还有其它模块的 synced item：
                // 只清本模块 item，交付保留给其它模块收尾；绝不恢复/删除文件。
                do {
                    let removed = try writer.deleteItems(
                        xmpPath: current.xmpPath, module: module, statuses: [.synced])
                    skippedCount += 1
                    errors.append(
                        "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: \(current.xmpPath) "
                            + "modules=\(modules.joined(separator: ",")) "
                            + "ownItemsRemoved=\(removed)")
                } catch {
                    skippedCount += 1
                    errors.append(
                        Self.failure("XMP_CLEANUP_ITEM_CLEANUP_FAILED", current.xmpPath, error))
                }
                continue
            case .proceed:
                break
            }

            // 外部修改：盘上内容已不是我们写入的基线 → conflict，不恢复、不删行。
            if !current.baseFingerprint.isEmpty {
                let currentFingerprint: String
                do {
                    currentFingerprint = try await filePhase.contentFingerprint(current.xmpPath)
                } catch {
                    skippedCount += 1
                    errors.append(Self.failure("XMP_FINGERPRINT_FAILED", current.xmpPath, error))
                    continue
                }
                if currentFingerprint != current.baseFingerprint {
                    do {
                        let updated = try writer.markConflict(
                            xmpPath: current.xmpPath,
                            revision: current.revision,
                            errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT",
                            leaseOwner: ""
                        )
                        if updated != nil {
                            conflictedCount += 1
                            conflictedXmpPaths.append(current.xmpPath)
                        } else {
                            skippedCount += 1
                        }
                    } catch {
                        skippedCount += 1
                        errors.append(Self.failure("XMP_CLEANUP_CONFLICT_FAILED", current.xmpPath, error))
                    }
                    continue
                }
            }

            let resolvedPhotoPath: String
            do {
                resolvedPhotoPath = try resolvePhotoPath(sessionId, current)
            } catch {
                skippedCount += 1
                errors.append(Self.failure("XMP_CLEANUP_PATH_FAILED", current.xmpPath, error))
                continue
            }

            let payload = DeliveryCleanupPayload(
                delivery: current, photoPath: resolvedPhotoPath, module: module)
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
                    "event=failed op=cleanup phase=intent outcome=prepare-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                    level: .warn)
                errors.append(Self.failure("XMP_CLEANUP_PREPARE_FAILED", current.xmpPath, error))
                continue
            }
            activeIntents.insert(current.xmpPath)

            // P0-1 + TOCTOU：verify → restore/remove → 事后再 verify 整体在
            // XMPFileLock 内（与 WritebackService 同一实例）。prepare 之后新输入
            // 可能已把 revision+1 / status 改回 pending；锁内重读后仍不一致则
            // 绝不碰文件，直接放弃本次清理（intent 标终态 + 错误可见）。
            DeliveryTrace.log(
                traceFile,
                "event=start op=cleanup phase=file xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "intent=\(intentId) action=\(payload.action.rawValue)",
                level: .info)
            let phase = await filePhase.run(xmpPath: current.xmpPath, payload: payload)
            switch phase {
            case .completed:
                DeliveryTrace.log(
                    traceFile,
                    "event=done op=cleanup phase=file xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "intent=\(intentId) outcome=completed",
                    level: .info)
                break
            case .guardFailed(let reason):
                // 指纹读取失败：prepared 留库，下次 replay 重试。
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=cleanup phase=file outcome=guard-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                errors.append("XMP_CLEANUP_GUARD_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .fileFailed(let reason):
                // prepared 留在库里：下次 replay() 重做文件（restore 幂等）。
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=cleanup phase=file outcome=file-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                errors.append("XMP_CLEANUP_FILE_FAILED: \(current.xmpPath) reason=\(reason)")
                continue
            case .invalidated(let reason):
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=cleanup phase=file outcome=invalidated "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                    level: .warn)
                // restore/remove 的 await 期间出现新输入：文件可能已被旧备份覆盖，
                // 不得静默走 DB 删除；放弃 intent 并显式上报（DB 保留新输入）。
                skippedCount += 1
                errors.append("XMP_CLEANUP_FILE_RACED: \(current.xmpPath) reason=\(reason)")
                do {
                    try intents.finish(
                        id: intentId, error: "XMP_CLEANUP_FILE_RACED: \(reason)")
                } catch {
                    errors.append(
                        Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                }
                continue
            case .skipped(let verdict):
                switch verdict {
                case .changed(let reason):
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=cleanup phase=file outcome=changed "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                            + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                        level: .warn)
                    skippedCount += 1
                    errors.append("XMP_CLEANUP_ABANDONED: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intents.finish(
                            id: intentId, error: "XMP_CLEANUP_ABANDONED: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .conflict(let reason):
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=cleanup phase=file outcome=conflict "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                            + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                        level: .warn)
                    do {
                        if try writer.markConflict(
                            xmpPath: current.xmpPath,
                            revision: current.revision,
                            errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT",
                            leaseOwner: ""
                        ) != nil {
                            conflictedCount += 1
                            conflictedXmpPaths.append(current.xmpPath)
                        } else {
                            skippedCount += 1
                            errors.append(
                                "XMP_CLEANUP_GUARD_CONFLICT_CAS_FAILED: \(current.xmpPath) reason=\(reason)")
                        }
                    } catch {
                        skippedCount += 1
                        errors.append(
                            Self.failure("XMP_CLEANUP_CONFLICT_FAILED", current.xmpPath, error))
                    }
                    do {
                        try intents.finish(
                            id: intentId,
                            error: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .invalidBackup(let reason):
                    // P2-12：backup_path 未通过受控目录/前缀/常规文件校验。fail-closed：
                    // 不 restore/remove，也不留 prepared intent（重试不会自愈）。
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=cleanup phase=file outcome=invalid-backup "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                            + "reason=\(DeliveryTrace.reason(reason, paths: traceContext))",
                        level: .warn)
                    skippedCount += 1
                    errors.append(
                        "XMP_CLEANUP_BACKUP_PATH_INVALID: \(current.xmpPath) reason=\(reason)")
                    do {
                        try intents.finish(
                            id: intentId,
                            error: "XMP_CLEANUP_BACKUP_PATH_INVALID: \(reason)")
                    } catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .alreadyGone:
                    // 行已被并发删除：无法确认盘上内容归属，不碰文件，幂等收尾。
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=cleanup phase=file outcome=already-gone "
                            + "xmp=\(DeliveryTrace.pathToken(current.xmpPath))",
                        level: .info)
                    skippedCount += 1
                    do { try intents.finish(id: intentId) }
                    catch {
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", current.xmpPath, error))
                    }
                    continue
                case .proceed:
                    // 不可达：filePhase.run 已把 proceed 转成 .completed。
                    continue
                }
            }

            do {
                _ = try intents.advance(id: intentId, to: .fileDone)
            } catch {
                // 文件已做、相位没推进：prepared 回放会再恢复一次（幂等），不会跳过文件。
                DeliveryTrace.log(
                    traceIntent,
                    "event=failed op=cleanup phase=intent outcome=advance-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) intent=\(intentId) "
                        + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                    level: .warn)
                errors.append(Self.failure("XMP_CLEANUP_ADVANCE_FAILED", current.xmpPath, error))
                continue
            }

            // DB 删除 + intent.finish 同一事务（DeliveryDBPhase 的唯一事务）。
            DeliveryTrace.log(
                traceDB,
                "event=start op=cleanup phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                    + "intent=\(intentId) action=\(payload.action.rawValue)",
                level: .info)
            let outcome: CleanupDBOutcome
            do {
                outcome = try dbPhase.applyCleanup(
                    intentId: intentId,
                    xmpPath: current.xmpPath,
                    payload: payload
                )
            } catch let error as DeliveryDBPhaseError {
                DeliveryTrace.log(
                    traceDB,
                    "event=failed op=cleanup phase=db outcome=db-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(cause(of: error), paths: traceContext))",
                    level: .warn)
                errors.append(Self.failure(code(for: error, action: .cleanup), current.xmpPath, cause(of: error)))
                continue
            } catch {
                DeliveryTrace.log(
                    traceDB,
                    "event=failed op=cleanup phase=db outcome=db-failed "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "reason=\(DeliveryTrace.reason(error, paths: traceContext))",
                    level: .warn)
                errors.append(Self.failure("XMP_CLEANUP_DB_FAILED", current.xmpPath, error))
                continue
            }

            switch outcome {
            case .deleted:
                DeliveryTrace.log(
                    traceDB,
                    "event=done op=cleanup phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "outcome=\(outcome.reason)",
                    level: .info)
                deletedCount += 1
            case .alreadyGone:
                DeliveryTrace.log(
                    traceDB,
                    "event=done op=cleanup phase=db xmp=\(DeliveryTrace.pathToken(current.xmpPath)) "
                        + "outcome=\(outcome.reason)",
                    level: .info)
                skippedCount += 1
            case .foreignItemsPending(let blockerModule, let status):
                // 文件阶段期间/回放时出现其它模块的未完成 item：DB 段已拒绝删除。
                // 文件可能已恢复，必须让调用方看见原因，不能静默当成功。
                DeliveryTrace.log(
                    traceDB,
                    "event=skipped op=cleanup phase=db outcome=foreign-items-pending "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) module=\(blockerModule) status=\(status)",
                    level: .warn)
                skippedCount += 1
                errors.append(
                    "XMP_CLEANUP_INCOMPLETE_ITEMS: \(current.xmpPath) "
                        + "module=\(blockerModule) status=\(status)")
            case .foreignItemsRetained(let modules):
                // DB 段已清本模块 item 并保留交付（其它模块 synced item 仍在）。
                DeliveryTrace.log(
                    traceDB,
                    "event=skipped op=cleanup phase=db outcome=foreign-items-retained "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) modules=\(modules.joined(separator: ","))",
                    level: .info)
                skippedCount += 1
                errors.append(
                    "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: \(current.xmpPath) "
                        + "modules=\(modules.joined(separator: ","))")
            case .revisionChanged, .rowReplaced, .stateChanged:
                DeliveryTrace.log(
                    traceDB,
                    "event=skipped op=cleanup phase=db outcome=\(outcome.reason) "
                        + "xmp=\(DeliveryTrace.pathToken(current.xmpPath)) reason=db-guard-rejected",
                    level: .warn)
                skippedCount += 1
                // 文件阶段已经执行而 DB 守卫拒绝：必须让调用方看见
                // 「文件可能已旧、新输入仍保留」，不能只记 skipped。
                errors.append("XMP_CLEANUP_SKIPPED: \(current.xmpPath) reason=\(outcome.reason)")
            }
        }

        // WP7b：批次汇总只带计数与整体耗时，不输出路径/会话明文。
        DeliveryTrace.log(
            DeliveryTrace.text(
                id: DeliveryTrace.sessionToken(sessionId), revision: 0, phase: "summary"),
            "event=done op=cleanup phase=summary module=\(module.rawValue) "
                + "deleted=\(deletedCount) conflicted=\(conflictedCount) "
                + "skipped=\(skippedCount) errors=\(errors.count) "
                + "duration_ms=\(DeliveryTrace.elapsedMs(since: startedAtMs))",
            level: .info)
        emitStateChanged(sessionId)
        return DeliveryCleanupSummary(
            deletedCount: deletedCount,
            conflictedCount: conflictedCount,
            skippedCount: skippedCount,
            errors: errors,
            conflictedXmpPaths: conflictedXmpPaths
        )
    }
}
