// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryFilePhase.swift
// WP2b：cleanup / finalize / replay 的**唯一文件阶段**（自 DeliveryCoordinator.swift 抽出）。
//
// 顺序固定且整体持 XMPFileLock：
//   verify（锁内重读 revision/status/指纹）→ restore/remove → 事后 verify。
// 为什么必须在同一次取锁内完成：拆成两次取锁会重新打开
// 「验证通过 → 另一写者落盘 → 旧备份覆盖」的 TOCTOU 窗口。
//
// P1-1：finalize 的文件阶段**不再删除备份**（旧实现先删备份、后做 DB CAS，
// CAS 一旦拒绝，delivery 行保留却带着指向已删文件的 backup_path，后续 cleanup
// 永久 XMP_BACKUP_MISSING）。finalize 的删除点只有一个：
// removeFinalizeBackup(...)，由调用方在 DB 删除事务成功之后调用，幂等且失败不抛。
//
// 失败不抛出：用 LockedFilePhaseOutcome 保留旧错误码语义，intent 留在 prepared；
// 只有「文件已执行但事后发现新输入」才返回 .invalidated（调用方必须显式上报）。

import Foundation
import GatherPersistence

/// 文件阶段前的守卫结论（P0-1）。
///
/// 只有 .proceed 允许碰文件；其余分支都不得 restore/remove：
/// - .changed：交付行已被新输入/重写推进（revision/status/base_fingerprint 不一致）；
/// - .conflict：行快照一致但盘上内容已不是基线（外部修改）；
/// - .alreadyGone：行已被并发删除，无法确认盘上内容归属。
enum DeliveryFilePhaseVerdict: Equatable {
    case proceed
    case alreadyGone
    case changed(reason: String)
    case conflict(reason: String)
}

/// 锁内文件阶段的整体结果（P0-1 + TOCTOU 收口）。
///
/// 守卫、restore/remove 与事后复核必须在**同一次** XMPFileLock.run 内完成：
/// 分成两次取锁会重新打开“验证通过 → 另一写者落盘 → 旧备份覆盖”的窗口。
/// - .completed：verify 放行且文件阶段（含事后复核）成功；
/// - .skipped：verify 判定不得碰文件（changed/conflict/alreadyGone）；
/// - .invalidated：文件已执行，但事后复核发现新输入（等价于 filePhaseInvalidated）；
/// - .guardFailed / .fileFailed：保留旧错误码语义的失败（intent 留在 prepared）。
enum LockedFilePhaseOutcome: Sendable, Equatable {
    case completed
    case skipped(DeliveryFilePhaseVerdict)
    case invalidated(reason: String)
    case guardFailed(reason: String)
    case fileFailed(reason: String)
}

struct DeliveryFilePhase: Sendable {
    private let deliveryRepo: DeliveryRepo
    private let files: any DeliveryFilePort
    /// 与 WritebackService 共享的按 xmpPath 文件锁（P0-1 收口）。
    private let fileLock: XMPFileLock
    private let fingerprint: DeliveryFingerprintProvider

    init(
        deliveryRepo: DeliveryRepo,
        files: any DeliveryFilePort,
        fileLock: XMPFileLock,
        fingerprint: @escaping DeliveryFingerprintProvider
    ) {
        self.deliveryRepo = deliveryRepo
        self.files = files
        self.fileLock = fileLock
        self.fingerprint = fingerprint
    }

    /// 在 XMPFileLock 内执行 cleanup/finalize 的完整文件阶段（唯一入口）。
    ///
    /// 顺序固定：verify（锁内重读 revision/status/指纹）→ restore/remove →
    /// verifyAfterMutation（锁内重读，检测 restore 期间的新输入）。
    func run(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async -> LockedFilePhaseOutcome {
        do {
            return try await fileLock.run(path: xmpPath) {
                let verdict: DeliveryFilePhaseVerdict
                do {
                    verdict = try await self.verify(xmpPath: xmpPath, payload: payload)
                } catch {
                    return .guardFailed(reason: String(describing: error))
                }
                guard case .proceed = verdict else { return .skipped(verdict) }
                do {
                    switch payload.action {
                    case .cleanup:
                        try await self.performCleanup(xmpPath: xmpPath, payload: payload)
                    case .finalize:
                        // P1-1：finalize 的文件阶段只做 verify，绝不碰盘。
                        // 备份删除在 DB 删除事务成功之后由 removeFinalizeBackup 完成；
                        // 这里若提前删，DB CAS 拒绝就会留下悬空 backup_path。
                        break
                    }
                    return .completed
                } catch let error as DeliveryCoordinatorError {
                    if case .filePhaseInvalidated(_, let reason) = error {
                        return .invalidated(reason: reason)
                    }
                    return .fileFailed(reason: String(describing: error))
                } catch {
                    return .fileFailed(reason: String(describing: error))
                }
            }
        } catch {
            // 只有取锁/排队被取消才会走到这里：文件未执行，intent 保持 prepared。
            return .guardFailed(reason: String(describing: error))
        }
    }

    /// cleanup 预检的外部修改指纹（与文件阶段守卫同一 provider）。
    func contentFingerprint(_ xmpPath: String) async throws -> String {
        try await fingerprint(xmpPath)
    }

    /// 文件阶段前的快照复核（P0-1 的唯一守卫入口）。
    ///
    /// 只有完全一致才返回 .proceed：
    /// 1. 重读交付行，比对 id/revision/status（+ payload 记录的 base_fingerprint）；
    /// 2. cleanup 还要比对盘上指纹（finalize 只删备份，绝不碰 XMP）；
    /// 3. 指纹读取是 await 窗口——窗口内可能又出现新输入，因此**再读一次**行，
    ///    不一致一律不碰文件（这也是回归测试的确定性注入点）。
    ///
    /// 指纹读取失败直接抛出：调用方保留 intent、下次 replay 重试。
    func verify(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async throws -> DeliveryFilePhaseVerdict {
        guard let before = try deliveryRepo.get(xmpPath) else { return .alreadyGone }
        if let reason = Self.snapshotMismatch(before, payload: payload) {
            return .changed(reason: reason)
        }
        // finalize 不触碰 XMP：只做 revision/status 守卫，不读指纹。
        guard payload.action == .cleanup else { return .proceed }
        let expected = payload.baseFingerprint.isEmpty
            ? before.baseFingerprint
            : payload.baseFingerprint
        // 没有基线（旧行/懒备份）时无法检测外部修改，只剩同步快照守卫。
        guard !expected.isEmpty else { return .proceed }
        let onDisk = try await fingerprint(xmpPath)
        // await 期间新输入/重写：revision/status/基线任一变化都不得碰文件。
        guard let after = try deliveryRepo.get(xmpPath) else { return .alreadyGone }
        if let reason = Self.snapshotMismatch(after, payload: payload) {
            return .changed(reason: reason)
        }
        if after.baseFingerprint != before.baseFingerprint {
            return .changed(reason: "base-fingerprint-changed")
        }
        guard onDisk == expected else {
            return .conflict(reason: "fingerprint-mismatch")
        }
        return .proceed
    }

    /// 交付行与 intent 快照的不一致原因；nil 表示快照一致。
    static func snapshotMismatch(
        _ row: DeliveryRow,
        payload: DeliveryCleanupPayload
    ) -> String? {
        if row.id != payload.deliveryId { return "delivery-id-changed" }
        if row.revision != payload.revision { return "revision-changed" }
        if row.status != payload.status { return "status-changed(\(row.status))" }
        if !payload.baseFingerprint.isEmpty, row.baseFingerprint != payload.baseFingerprint {
            return "base-fingerprint-changed"
        }
        return nil
    }

    /// 文件阶段执行后再次复核：restore/remove 的 await 期间若出现新输入，
    /// 旧备份可能已覆盖新内容。此时抛 .filePhaseInvalidated 让调用方显式上报
    /// 并放弃 intent（绝不静默走 DB 删除）。
    func verifyAfterMutation(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) throws {
        guard let current = try deliveryRepo.get(xmpPath) else { return }
        if let reason = Self.snapshotMismatch(current, payload: payload) {
            throw DeliveryCoordinatorError.filePhaseInvalidated(
                xmpPath: xmpPath, reason: reason)
        }
    }

    /// 把备份内容恢复回侧车；无备份时删除本次写入的侧车（旧 cleanup 语义）。
    /// 两种形态都幂等：恢复是覆盖写，删除前先看存在性。
    private func performCleanup(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async throws {
        if payload.backupPath.isEmpty {
            if files.fileExists(xmpPath) {
                try await files.removeFile(xmpPath)
            }
        } else {
            guard files.fileExists(payload.backupPath) else {
                throw DeliveryCoordinatorError.backupMissing(xmpPath: xmpPath)
            }
            try await files.restore(
                photoPath: payload.photoPath,
                backupPath: payload.backupPath
            )
        }
        try verifyAfterMutation(xmpPath: xmpPath, payload: payload)
    }

    // MARK: - finalize 的 DB 后置步骤（P1-1）

    /// 交付行删除成功**之后**才删除备份（finalize 的唯一删除点）。
    ///
    /// 为什么必须在这里而不是文件阶段：旧顺序「删备份 → DB CAS」在 CAS 拒绝/
    /// 事务回滚时会把交付行留在库里、却让 backup_path 指向已删文件；该行之后
    /// cleanup 走 backupMissing 永久失败，原始 XMP 也再不可恢复。现在删除只在
    /// DB 段返回 .deleted / .alreadyGone 之后发生，失败也只是一份孤儿备份。
    ///
    /// 幂等与归属守卫（整体持 XMPFileLock，与写盘互斥）：
    /// - 备份已不存在 → .absent（重放/重复重试安全）；
    /// - 同 xmpPath 上又出现新交付 → .retained（备份路径可能被新一轮写入复用，
    ///   宁可留孤儿文件，也不删新备份）；
    /// - 删除失败 → .failed（行已删，不回滚，由调用方并入 errors）。
    func removeFinalizeBackup(
        xmpPath: String,
        backupPath: String
    ) async -> FinalizeBackupRemovalOutcome {
        guard !backupPath.isEmpty else { return .absent }
        do {
            return try await fileLock.run(path: xmpPath) {
                if let row = try self.deliveryRepo.get(xmpPath) {
                    return .retained(
                        reason: "delivery-reappeared(id=\(row.id),revision=\(row.revision))")
                }
                guard self.files.fileExists(backupPath) else { return .absent }
                do {
                    try await self.files.removeFile(backupPath)
                    return .removed
                } catch {
                    return .failed(reason: String(describing: error))
                }
            }
        } catch {
            // 取锁失败/取消或行读取失败：不抛出，交调用方上报。
            return .failed(reason: String(describing: error))
        }
    }
}

/// finalize 的备份清理结论（P1-1：DB 成功后的后置步骤）。
enum FinalizeBackupRemovalOutcome: Sendable, Equatable {
    /// 备份已删除。
    case removed
    /// 备份本来就不存在（幂等重放/重复重试）。
    case absent
    /// 该 xmpPath 上已有新交付：备份可能被新一轮写入复用，保留不删。
    case retained(reason: String)
    /// 删除失败（权限/IO/取锁取消）：交付行已删，只上报，不回滚。
    case failed(reason: String)
}
