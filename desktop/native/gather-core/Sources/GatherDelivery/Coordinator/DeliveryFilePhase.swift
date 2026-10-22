// desktop/native/gather-core/Sources/GatherDelivery/Coordinator/DeliveryFilePhase.swift
// WP2b：cleanup / finalize / replay 的**唯一文件阶段**（自 DeliveryCoordinator.swift 抽出）。
//
// 顺序固定且整体持 XMPFileLock：
//   verify（锁内重读 revision/status/指纹）→ restore/remove → 事后 verify。
// 为什么必须在同一次取锁内完成：拆成两次取锁会重新打开
// 「验证通过 → 另一写者落盘 → 旧备份覆盖」的 TOCTOU 窗口。
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
                        try await self.performFinalize(xmpPath: xmpPath, payload: payload)
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

    /// finalize 的文件阶段：只删备份，绝不触碰 XMP（dropWithoutRestore）。
    /// 删除后同样复核快照：备份路径可能已被新一轮写入复用，不能静默删掉新备份。
    private func performFinalize(
        xmpPath: String,
        payload: DeliveryCleanupPayload
    ) async throws {
        guard !payload.backupPath.isEmpty else { return }
        guard files.fileExists(payload.backupPath) else { return }
        try await files.removeFile(payload.backupPath)
        try verifyAfterMutation(xmpPath: xmpPath, payload: payload)
    }
}
