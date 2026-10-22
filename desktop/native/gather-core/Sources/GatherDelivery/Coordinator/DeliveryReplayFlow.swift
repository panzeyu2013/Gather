// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryReplayFlow.swift
// WP2b：启动回放（自 DeliveryCoordinator.swift 抽出，语义逐字保留）。
//
// 相位语义（draft §5.5 三条硬规则）：
//   prepared：重做文件 + 重做 DB；
//   fileDone：只补 DB，绝不重放文件；
//   applied ：replayAll() 启动时直接删除 intent 行。
// deliveries 删除带 revision 守卫：期间有新输入（revision 变了）就不删，intent 标
// applied + error（新输入必须保留）。
//
// 与迁移前的结构差异只有一处：DB 删除与 intent 收尾由 DeliveryDBPhase 在**同一
// 事务**内完成；错误码（XMP_CLEANUP_DB_FAILED / _FINISH_FAILED / XMP_FINALIZE_*）
// 与计数（applied/skipped/failed）保持原样。

import Foundation
import GatherPersistence

/// 进程内 replay 抢占（P2-4）：同一 intent 同时只允许一个回放者。
///
/// 与 XMPFileLock 同一边界（进程内）；跨进程并发仍不在承诺内。纯内存、无 Schema
/// 变更：抢不到的回放者直接跳过本 intent（对方会推进/收尾），不再产生虚假失败。
private final class DeliveryReplayClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed: Set<Int64> = []

    func claim(_ id: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed.insert(id).inserted
    }

    func release(_ id: Int64) {
        lock.lock()
        claimed.remove(id)
        lock.unlock()
    }
}

struct DeliveryReplayFlow: Sendable {
    let intents: DeliveryIntentStore
    let writer: DeliveryStateWriter
    let filePhase: DeliveryFilePhase
    let dbPhase: DeliveryDBPhase

    /// 抢占状态必须按 flow/coordinator 隔离；用 static 会把不同数据库里相同的
    /// intent.id（各库都从 1 开始）误判为同一回放，测试并行时直接互相跳过。
    private let claims: DeliveryReplayClaims

    init(
        intents: DeliveryIntentStore,
        writer: DeliveryStateWriter,
        filePhase: DeliveryFilePhase,
        dbPhase: DeliveryDBPhase
    ) {
        self.intents = intents
        self.writer = writer
        self.filePhase = filePhase
        self.dbPhase = dbPhase
        self.claims = DeliveryReplayClaims()
    }

    /// 启动回放（幂等）：先删除 applied 终态，再按相位处理 prepared/fileDone。
    ///
    /// 单条失败不抛出：保留 intent（prepared/fileDone）等待下次重试，错误进 summary。
    func replay() async throws -> DeliveryReplaySummary {
        let backlog: DeliveryIntentBacklog
        do {
            backlog = try intents.replayAll()
        } catch {
            throw DeliveryCoordinatorError.invalidArgument("读取回放待办失败: \(error)")
        }

        var appliedCount = 0
        var skippedCount = 0
        var failedCount = 0
        var errors: [String] = []

        // P2-15：启动回放是清理崩溃残留临时文件的自然时点；只扫有未完成 intent
        // 的 xmpPath，只删 24h 前的 .tmp-/.restore- 常规文件（不碰备份）。
        for path in Set(backlog.all.map(\.xmpPath)).sorted() {
            _ = DeliveryTemporaryFiles.sweep(xmpPath: path)
        }

        /// 汇总一次「DB 段 + intent 收尾」的结果（可重试失败 / 闭环 / 跳过）。
        ///
        /// P1-1：DB 已删行但备份清理没完成（孤儿备份/路径被新交付复用）时，
        /// applied 仍为 true，但 notice 必须并入 errors，不能静默丢弃。
        func record(_ result: DeliveryDBFinishOutcome) {
            if let retryable = result.retryableError {
                failedCount += 1
                errors.append(retryable)
                return
            }
            if result.applied {
                appliedCount += 1
            } else {
                skippedCount += 1
            }
            if let notice = result.notice { errors.append(notice) }
        }

        for intent in backlog.prepared {
            guard intent.typedKind == .cleanup else {
                failedCount += 1
                errors.append("XMP_CLEANUP_UNSUPPORTED_INTENT: #\(intent.id) kind=\(intent.kind)")
                continue
            }
            guard let payload = DeliveryCleanupPayload(intent: intent) else {
                do {
                    try intents.finish(id: intent.id, error: "XMP_CLEANUP_INVALID_PAYLOAD")
                    skippedCount += 1
                } catch {
                    failedCount += 1
                    errors.append(Self.failure("XMP_CLEANUP_INVALID_PAYLOAD", intent.xmpPath, error))
                }
                continue
            }
            // P2-4：同一 intent 只允许一个回放者。抢不到说明另一回放正在进行，
            // 直接跳过（不再产生 rowNotFound 虚假失败）。
            guard claims.claim(intent.id) else {
                skippedCount += 1
                errors.append("XMP_CLEANUP_REPLAY_CLAIMED: #\(intent.id)")
                continue
            }
            defer { claims.release(intent.id) }
            // P0-1 + TOCTOU：prepared 回放的 verify → 文件 → 事后 verify
            // 同样整体在 XMPFileLock 内；新输入已推进 revision 时绝不重做文件
            //（旧备份会覆盖新内容），直接放弃 intent 并上报。
            // WP7b：trace 的 id/revision 取自 intent payload（prepare 快照）。
            let traceFile = DeliveryTrace.text(
                deliveryId: payload.deliveryId, revision: payload.revision, phase: "file")
            DeliveryTrace.log(
                traceFile,
                "event=start op=replay phase=file xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                    + "intent=\(intent.id) action=\(payload.action.rawValue)",
                level: .info)
            let phase = await filePhase.run(xmpPath: intent.xmpPath, payload: payload)
            switch phase {
            case .completed:
                DeliveryTrace.log(
                    traceFile,
                    "event=done op=replay phase=file xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                        + "intent=\(intent.id) outcome=completed",
                    level: .info)
                break
            case .guardFailed(let reason):
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=replay phase=file outcome=guard-failed "
                        + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(reason)",
                    level: .warn)
                failedCount += 1
                errors.append("XMP_CLEANUP_GUARD_FAILED: \(intent.xmpPath) reason=\(reason)")
                continue
            case .fileFailed(let reason):
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=replay phase=file outcome=file-failed "
                        + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(reason)",
                    level: .warn)
                failedCount += 1
                errors.append("XMP_CLEANUP_FILE_FAILED: \(intent.xmpPath) reason=\(reason)")
                continue
            case .invalidated(let reason):
                DeliveryTrace.log(
                    traceFile,
                    "event=failed op=replay phase=file outcome=invalidated "
                        + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(reason)",
                    level: .warn)
                do {
                    try intents.finish(
                        id: intent.id, error: "XMP_CLEANUP_FILE_RACED: \(reason)")
                    skippedCount += 1
                    errors.append(
                        "XMP_CLEANUP_FILE_RACED: \(intent.xmpPath) reason=\(reason)")
                } catch {
                    failedCount += 1
                    errors.append(
                        Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
                }
                continue
            case .skipped(let verdict):
                switch verdict {
                case .changed(let reason):
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=replay phase=file outcome=changed "
                            + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(reason)",
                        level: .warn)
                    do {
                        try intents.finish(
                            id: intent.id, error: "XMP_CLEANUP_ABANDONED: \(reason)")
                        skippedCount += 1
                        errors.append(
                            "XMP_CLEANUP_ABANDONED: \(intent.xmpPath) reason=\(reason)")
                    } catch {
                        failedCount += 1
                        errors.append(Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
                    }
                    continue
                case .conflict(let reason):
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=replay phase=file outcome=conflict "
                            + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(reason)",
                        level: .warn)
                    do {
                        // P2：markConflict 也带 owner CAS。CAS 失配（另一写者持有
                        // 租约）时保留 intent，交给持有者/下次 replay，不假报已收尾。
                        guard try writer.markConflict(
                            xmpPath: intent.xmpPath,
                            revision: payload.revision,
                            errorMessage: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT") != nil else {
                            failedCount += 1
                            errors.append(
                                "XMP_CLEANUP_GUARD_CONFLICT_CAS_FAILED: \(intent.xmpPath)")
                            continue
                        }
                        try intents.finish(
                            id: intent.id,
                            error: "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT: \(reason)")
                        skippedCount += 1
                        errors.append(
                            "XMP_CLEANUP_ABORTED_EXTERNAL_EDIT: \(intent.xmpPath) reason=\(reason)")
                    } catch {
                        failedCount += 1
                        errors.append(Self.failure("XMP_CLEANUP_CONFLICT_FAILED", intent.xmpPath, error))
                    }
                    continue
                case .invalidBackup(let reason):
                    // P2-12：回放同样 fail-closed；以终态 intent 收尾，避免无限重试。
                    let code = payload.action == .finalize
                        ? "XMP_FINALIZE_BACKUP_PATH_INVALID"
                        : "XMP_CLEANUP_BACKUP_PATH_INVALID"
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=replay phase=file outcome=invalid-backup "
                            + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(reason)",
                        level: .warn)
                    do {
                        try intents.finish(id: intent.id, error: "\(code): \(reason)")
                        skippedCount += 1
                        errors.append("\(code): \(intent.xmpPath) reason=\(reason)")
                    } catch {
                        failedCount += 1
                        errors.append(
                            Self.failure("XMP_CLEANUP_FINISH_FAILED", intent.xmpPath, error))
                    }
                    continue
                case .alreadyGone:
                    // 行已被并发删除：不碰文件，DB 段按 alreadyGone 幂等收尾。
                    DeliveryTrace.log(
                        traceFile,
                        "event=skipped op=replay phase=file outcome=already-gone "
                            + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath))",
                        level: .info)
                    record(await applyDBAndFinish(intent: intent, payload: payload))
                    continue
                case .proceed:
                    continue
                }
            }
            do {
                _ = try intents.advance(id: intent.id, to: .fileDone)
            } catch {
                DeliveryTrace.log(
                    DeliveryTrace.text(
                        deliveryId: payload.deliveryId,
                        revision: payload.revision,
                        phase: "intent"),
                    "event=failed op=replay phase=intent outcome=advance-failed "
                        + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) intent=\(intent.id) reason=\(error)",
                    level: .warn)
                failedCount += 1
                errors.append(Self.failure("XMP_CLEANUP_ADVANCE_FAILED", intent.xmpPath, error))
                continue
            }
            record(await applyDBAndFinish(intent: intent, payload: payload))
        }

        for intent in backlog.fileDone {
            guard intent.typedKind == .cleanup else {
                failedCount += 1
                errors.append("XMP_CLEANUP_UNSUPPORTED_INTENT: #\(intent.id) kind=\(intent.kind)")
                continue
            }
            guard let payload = DeliveryCleanupPayload(intent: intent) else {
                do {
                    try intents.finish(id: intent.id, error: "XMP_CLEANUP_INVALID_PAYLOAD")
                    skippedCount += 1
                } catch {
                    failedCount += 1
                    errors.append(Self.failure("XMP_CLEANUP_INVALID_PAYLOAD", intent.xmpPath, error))
                }
                continue
            }
            guard claims.claim(intent.id) else {
                skippedCount += 1
                errors.append("XMP_CLEANUP_REPLAY_CLAIMED: #\(intent.id)")
                continue
            }
            defer { claims.release(intent.id) }
            // 文件已是目标状态：这里绝不调用文件阶段（finalize 的备份清理是 DB
            // 段成功后的后置步骤，不属于文件阶段重放）。
            record(await applyDBAndFinish(intent: intent, payload: payload))
        }

        return DeliveryReplaySummary(
            appliedCount: appliedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            errors: errors
        )
    }

    // MARK: - DB 段 + intent 收尾

    /// DB 段 + intent 收尾（按 payload.action 分派到 cleanup/finalize）。
    ///
    /// finalize 在 DB 事务提交后会 await 一次幂等的备份清理（P1-1），
    /// 因此这里必须是 async；cleanup 分支不碰文件。
    private func applyDBAndFinish(
        intent: DeliveryIntentRow,
        payload: DeliveryCleanupPayload
    ) async -> DeliveryDBFinishOutcome {
        switch payload.action {
        case .cleanup:
            return applyCleanupDBAndFinish(intent: intent, payload: payload)
        case .finalize:
            return await applyFinalizeDBAndFinish(intent: intent, payload: payload)
        }
    }

    private func applyCleanupDBAndFinish(
        intent: DeliveryIntentRow,
        payload: DeliveryCleanupPayload
    ) -> DeliveryDBFinishOutcome {
        let trace = DeliveryTrace.text(
            deliveryId: payload.deliveryId, revision: payload.revision, phase: "db")
        DeliveryTrace.log(
            trace,
            "event=start op=replay phase=db xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                + "intent=\(intent.id) action=cleanup",
            level: .info)
        let outcome: CleanupDBOutcome
        do {
            outcome = try dbPhase.applyCleanup(
                intentId: intent.id, xmpPath: intent.xmpPath, payload: payload)
        } catch let error as DeliveryDBPhaseError {
            let code: String
            let cause: Error
            switch error {
            case .database(let value): code = "XMP_CLEANUP_DB_FAILED"; cause = value
            case .finish(let value): code = "XMP_CLEANUP_FINISH_FAILED"; cause = value
            }
            let message = Self.failure(code, intent.xmpPath, cause)
            DeliveryTrace.log(
                trace,
                "event=failed op=replay phase=db outcome=db-failed "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(cause)",
                level: .warn)
            return .retry(message)
        } catch {
            let message = Self.failure("XMP_CLEANUP_DB_FAILED", intent.xmpPath, error)
            DeliveryTrace.log(
                trace,
                "event=failed op=replay phase=db outcome=db-failed "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(error)",
                level: .warn)
            return .retry(message)
        }
        switch outcome {
        case .deleted, .alreadyGone:
            DeliveryTrace.log(
                trace,
                "event=done op=replay phase=db xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                    + "outcome=\(outcome.reason)",
                level: .info)
            return .closed()
        case .foreignItemsPending(let blockerModule, let status):
            DeliveryTrace.log(
                trace,
                "event=skipped op=replay phase=db outcome=foreign-items-pending "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) module=\(blockerModule) status=\(status)",
                level: .warn)
            return .skipped(
                "XMP_CLEANUP_INCOMPLETE_ITEMS: \(intent.xmpPath) "
                    + "module=\(blockerModule) status=\(status)")
        case .foreignItemsRetained(let modules):
            DeliveryTrace.log(
                trace,
                "event=skipped op=replay phase=db outcome=foreign-items-retained "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) modules=\(modules.joined(separator: ","))",
                level: .info)
            return .skipped(
                "XMP_CLEANUP_RETAINED_FOREIGN_ITEMS: \(intent.xmpPath) "
                    + "modules=\(modules.joined(separator: ","))")
        case .revisionChanged, .rowReplaced, .stateChanged:
            DeliveryTrace.log(
                trace,
                "event=skipped op=replay phase=db outcome=\(outcome.reason) "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=db-guard-rejected",
                level: .warn)
            return .skipped(
                "XMP_CLEANUP_SKIPPED: \(intent.xmpPath) reason=\(outcome.reason)")
        }
    }

    /// finalize 的 DB 段：与 cleanup 同一删除 helper，差异只在错误码。
    ///
    /// P1-1：只有 DB 返回 .deleted / .alreadyGone（事务已提交）后才删备份；
    /// CAS 拒绝（idChanged/revisionChanged/stateChanged）时交付行与新输入都在，
    /// 备份原样保留。备份清理是幂等后置步骤，重复重放安全。
    private func applyFinalizeDBAndFinish(
        intent: DeliveryIntentRow,
        payload: DeliveryCleanupPayload
    ) async -> DeliveryDBFinishOutcome {
        let trace = DeliveryTrace.text(
            deliveryId: payload.deliveryId, revision: payload.revision, phase: "db")
        DeliveryTrace.log(
            trace,
            "event=start op=replay phase=db xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                + "intent=\(intent.id) action=finalize",
            level: .info)
        let outcome: FinalizeDBOutcome
        do {
            outcome = try dbPhase.applyFinalize(
                intentId: intent.id, xmpPath: intent.xmpPath, payload: payload)
        } catch let error as DeliveryDBPhaseError {
            let code: String
            let cause: Error
            switch error {
            case .database(let value): code = "XMP_FINALIZE_DB_FAILED"; cause = value
            case .finish(let value): code = "XMP_FINALIZE_FINISH_FAILED"; cause = value
            }
            let message = Self.failure(code, intent.xmpPath, cause)
            DeliveryTrace.log(
                trace,
                "event=failed op=replay phase=db outcome=db-failed "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(cause)",
                level: .warn)
            return .retry(message)
        } catch {
            let message = Self.failure("XMP_FINALIZE_DB_FAILED", intent.xmpPath, error)
            DeliveryTrace.log(
                trace,
                "event=failed op=replay phase=db outcome=db-failed "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=\(error)",
                level: .warn)
            return .retry(message)
        }
        switch outcome {
        case .deleted, .alreadyGone:
            DeliveryTrace.log(
                trace,
                "event=done op=replay phase=db xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                    + "outcome=\(outcome.reason)",
                level: .info)
            // P1-1：DB 事务已提交，才清理备份（prepared/fileDone 两条重放路径共用）。
            let notice = await removeFinalizeBackup(
                trace: trace,
                xmpPath: intent.xmpPath,
                backupPath: payload.backupPath
            )
            return DeliveryDBFinishOutcome(
                applied: true, retryableError: nil, notice: notice)
        case .incompleteItems(let module, let status):
            DeliveryTrace.log(
                trace,
                "event=skipped op=replay phase=db outcome=incomplete-items "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) "
                    + "module=\(module) status=\(status)",
                level: .warn)
            return .skipped(
                "XMP_FINALIZE_INCOMPLETE_ITEMS: \(intent.xmpPath) "
                    + "module=\(module) status=\(status)")
        case .idChanged, .revisionChanged, .stateChanged:
            DeliveryTrace.log(
                trace,
                "event=skipped op=replay phase=db outcome=\(outcome.reason) "
                    + "xmp=\(DeliveryTrace.pathToken(intent.xmpPath)) reason=db-guard-rejected",
                level: .warn)
            return .skipped(
                "XMP_FINALIZE_SKIPPED: \(intent.xmpPath) reason=\(outcome.reason)")
        }
    }

    /// P1-1：DB 删除成功后的备份清理（与 DeliveryCleanupFlow.finalize 同一幂等点）。
    ///
    /// 返回非 nil 表示清理没完成：行已删、applied 仍为 true，notice 并入 errors。
    private func removeFinalizeBackup(
        trace: String,
        xmpPath: String,
        backupPath: String
    ) async -> String? {
        let removal = await filePhase.removeFinalizeBackup(
            xmpPath: xmpPath, backupPath: backupPath)
        switch removal {
        case .removed:
            DeliveryTrace.log(
                trace,
                "event=done op=replay phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) outcome=removed",
                level: .info)
            return nil
        case .absent:
            DeliveryTrace.log(
                trace,
                "event=done op=replay phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) outcome=absent",
                level: .info)
            return nil
        case .retained(let reason):
            DeliveryTrace.log(
                trace,
                "event=skipped op=replay phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) "
                    + "outcome=retained reason=\(reason)",
                level: .warn)
            return "XMP_FINALIZE_BACKUP_RETAINED: \(xmpPath) reason=\(reason)"
        case .failed(let reason):
            DeliveryTrace.log(
                trace,
                "event=failed op=replay phase=backup xmp=\(DeliveryTrace.pathToken(xmpPath)) reason=\(reason)",
                level: .warn)
            return "XMP_FINALIZE_BACKUP_CLEANUP_FAILED: \(xmpPath) reason=\(reason)"
        }
    }

    private static func failure(_ code: String, _ xmpPath: String, _ error: Error) -> String {
        "\(code): \(xmpPath) reason=\(String(describing: error))"
    }
}

/// DB 段 + intent 收尾的结果。
/// - retryableError 非空：intent 被保留，下次 replay 重试；
/// - applied：DB 行已删除（或本来就不存在）且 intent 已闭环；
/// - notice：intent 已标终态但 DB 守卫拒绝（新输入保留），错误必须可见。
struct DeliveryDBFinishOutcome {
    let applied: Bool
    let retryableError: String?
    let notice: String?

    static func retry(_ message: String) -> DeliveryDBFinishOutcome {
        DeliveryDBFinishOutcome(applied: false, retryableError: message, notice: nil)
    }

    static func closed() -> DeliveryDBFinishOutcome {
        DeliveryDBFinishOutcome(applied: true, retryableError: nil, notice: nil)
    }

    static func skipped(_ message: String) -> DeliveryDBFinishOutcome {
        DeliveryDBFinishOutcome(applied: false, retryableError: nil, notice: message)
    }
}
