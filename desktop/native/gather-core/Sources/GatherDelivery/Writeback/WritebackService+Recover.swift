// desktop/native/gather-core/Sources/GatherDelivery/Writeback/WritebackService+Recover.swift
// 拆分（final-sweep-code P1-1 / 纯移动）：WritebackService 按角色拆分——写租约与崩溃归位。
// 源：HEAD ab7752e 的 Writeback/WritebackService.swift；仅调整跨文件访问级与文件头注释。
import Foundation
import GatherPersistence
import GatherProtocol

extension WritebackService {
    // MARK: - 交付写租约 trace（P2）

    /// 写租约事件：`trace=delivery:<id>/rev:<revision>/lease` + op/phase/reason。
    ///
    /// 只在租约冲突/丢失/条件更新未命中时 warn：这是写回最难排障、也最容易
    /// 在多写者下静默失败的路径。reason 只用错误码或脱敏后的错误文本，
    /// xmpPath 只以 basename#hash 出现（不泄漏绝对路径）。
    func logLeaseEvent(
        xmpPath: String,
        delivery: DeliveryRow?,
        revision: Int64?,
        op: String,
        reason: String
    ) {
        let fallback: DeliveryRow?
        do {
            fallback = try deliveryRepo.get(xmpPath)
        } catch {
            fallback = nil
        }
        let identity = delivery ?? fallback
        guard let identity else { return }
        DeliveryTrace.log(
            DeliveryTrace.text(
                deliveryId: identity.id,
                revision: revision ?? identity.revision,
                phase: "lease"),
            "event=failed op=\(op) phase=lease xmp=\(DeliveryTrace.pathToken(xmpPath)) "
                + "reason=\(DeliveryTrace.reason(reason, paths: [xmpPath]))",
            level: .warn)
    }

    /// 仅把「租约被他人持有 / 租约已丢失」的错误码抽出来；其它错误不进租约 trace。
    static func leaseFailureReason(_ error: Error) -> String? {
        guard let repoError = error as? DeliveryRepoError else { return nil }
        switch repoError {
        case .leaseHeld, .leaseLost: return repoError.code
        default: return nil
        }
    }

    // MARK: - 写租约与崩溃归位（P1-2）
    /// execute 的逐交付租约入口（P1-2）：pending/failed/conflict → writing；
    /// written/synced（仍有新的 pending item）→ 新输入重开后再抢租约；
    /// writing → claim（同 owner 续租 / 过期抢占 / 未过期拒绝），不再无条件复用；
    /// cleaned（审计终态）或 CAS 失配返回 nil，由调用方把本交付的项标 failed。
    func beginDeliveryWrite(xmpPath: String) throws -> DeliveryRow? {
        guard let current = try deliveryRepo.get(xmpPath) else { return nil }
        switch current.typedStatus {
        case .some(.writing):
            // 崩溃遗留或并发写者：只有本 owner 续租、或旧 heartbeat 过期才能接管。
            return try stateWriter.claimWriting(
                xmpPath: xmpPath, revision: current.revision, leaseOwner: leaseOwner)
        case .some(.pending), .some(.failed), .some(.conflict):
            // 必须走 claim：读与写之间若被并发写者抢成 writing，markWriting 会
            // 无条件覆盖对方租约；claim 会按 owner/heartbeat 拒绝或续租。
            return try stateWriter.claimWriting(
                xmpPath: xmpPath, revision: current.revision,
                leaseOwner: leaseOwner, heartbeatAt: nowISOString())
        case .some(.written), .some(.synced):
            guard let reopened = try stateWriter.mergeInput(
                xmpPath: xmpPath,
                photoPath: current.photoPath,
                expectedRevision: current.revision,
                newRevision: current.revision + 1,
                baseFingerprint: current.baseFingerprint,
                baseValues: current.baseValues
            ) else {
                return nil
            }
            return try stateWriter.claimWriting(
                xmpPath: xmpPath, revision: reopened.revision,
                leaseOwner: leaseOwner, heartbeatAt: nowISOString())
        case .some(.cleaned), .none:
            return nil
        }
    }

    /// 崩溃归位（P1-2）：把本会话/模块下停在 writing 的交付收敛掉。
    ///
    /// 文件阶段在 execute Phase 1 完成、markItem(written) 在 Phase 2 才落库，因此：
    /// - 已有 written item：文件已写完（markItem 只在写盘成功后调用），只需补
    ///   markWritten（指纹/基线按当前盘上内容补齐，备份沿用交付行）；
    /// - 没有任何 written item：崩溃发生在写盘前/写盘中，归 failed 并记明确错误，
    ///   下一次重试可从 failed 重新抢租约，而不是永久卡在 writing。
    ///
    /// 只有本 owner 能续租或抢到过期租约才动行；他人未过期的租约留给持有者：
    /// 真正有输入项时由 beginDeliveryWrite 逐项显式失败，恢复扫描不误报并发写者。
    func recoverInterruptedWrites(
        sessionId: String,
        entries: [DeliveryWritebackEntry]
    ) async -> LeaseRecoveryResult {
        var result = LeaseRecoveryResult()
        var byPath: [String: [DeliveryWritebackEntry]] = [:]
        for entry in entries where entry.delivery.typedStatus == .writing {
            byPath[entry.delivery.xmpPath, default: []].append(entry)
        }
        for path in byPath.keys.sorted() {
            guard let group = byPath[path], let stale = group.first?.delivery else { continue }
            let claimed: DeliveryRow?
            do {
                claimed = try stateWriter.claimWriting(
                    xmpPath: path, revision: stale.revision, leaseOwner: leaseOwner)
            } catch {
                // 他人持有效租约（或行已不在 writing）：留给持有者/下一次执行。
                if let leaseReason = Self.leaseFailureReason(error) {
                    logLeaseEvent(
                        xmpPath: path,
                        delivery: stale,
                        revision: stale.revision,
                        op: "writeback-recover",
                        reason: leaseReason)
                }
                continue
            }
            guard let row = claimed else {
                logLeaseEvent(
                    xmpPath: path,
                    delivery: stale,
                    revision: stale.revision,
                    op: "writeback-recover",
                    reason: "DELIVERY_WRITE_CAS_FAILED")
                result.errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                continue
            }
            if group.contains(where: { $0.item.typedStatus == .written }) {
                var baseValues = stale.baseValues
                let photoId = group.first?.item.photoId ?? ""
                let photoPath = recoveryPhotoPath(
                    sessionId: sessionId, delivery: stale, photoId: photoId)
                if !photoPath.isEmpty {
                    do {
                        baseValues = try await xmp.readAttributes(photoPath: photoPath).asJSONValue
                    } catch {
                        result.errors.append("DELIVERY_BASE_VALUES_FAILED: \(path): \(error)")
                    }
                }
                var fingerprint = stale.baseFingerprint
                do {
                    let fresh = try await MetadataFingerprint.contentFingerprint(path)
                    if !fresh.isEmpty { fingerprint = fresh }
                } catch {
                    result.errors.append("DELIVERY_FINGERPRINT_FAILED: \(path): \(error)")
                }
                do {
                    // 归位前还有两次 await 读盘：先续租，租约被接管就停止收敛。
                    guard try stateWriter.renewWriting(
                        xmpPath: path, revision: row.revision, leaseOwner: leaseOwner)
                    else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_LEASE_LOST")
                        result.errors.append("DELIVERY_LEASE_LOST: \(path)")
                        continue
                    }
                    if try stateWriter.markWrittenAndClearReloadAcks(
                        xmpPath: path, revision: row.revision,
                        leaseOwner: leaseOwner,
                        baseFingerprint: fingerprint, baseValues: baseValues,
                        backupPath: stale.backupPath,
                        timestamp: nowISOString()) != nil {
                        result.written += 1
                    } else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        result.errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: leaseReason)
                    }
                    result.errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            } else {
                do {
                    guard try stateWriter.renewWriting(
                        xmpPath: path, revision: row.revision, leaseOwner: leaseOwner)
                    else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_LEASE_LOST")
                        result.errors.append("DELIVERY_LEASE_LOST: \(path)")
                        continue
                    }
                    if try stateWriter.markFailed(
                        xmpPath: path, revision: row.revision,
                        errorMessage: Self.interruptedWriteMessage,
                        leaseOwner: leaseOwner) != nil {
                        result.failed += 1
                        result.errors.append("DELIVERY_WRITE_INTERRUPTED: \(path)")
                    } else {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: "DELIVERY_WRITE_CAS_FAILED")
                        result.errors.append("DELIVERY_WRITE_CAS_FAILED: \(path)")
                    }
                } catch {
                    if let leaseReason = Self.leaseFailureReason(error) {
                        logLeaseEvent(
                            xmpPath: path,
                            delivery: row,
                            revision: row.revision,
                            op: "writeback-recover",
                            reason: leaseReason)
                    }
                    result.errors.append("DELIVERY_WRITE_FAILED: \(path): \(error)")
                }
            }
        }
        return result
    }

    /// 归位时解析写盘路径（优先资产解析，其次交付行/侧车推导）；空白路径表示无法回读。
    private func recoveryPhotoPath(
        sessionId: String,
        delivery: DeliveryRow,
        photoId: String
    ) -> String {
        if !photoId.isEmpty, let assetResolver,
           let resolved = try? assetResolver.resolve(sessionId: sessionId, photoId: photoId) {
            return resolved.filepath
        }
        if !delivery.photoPath.isEmpty { return delivery.photoPath }
        return Self.photoPathFromSidecar(delivery.xmpPath)
    }

    /// 归位为 failed 时的稳定错误串（UI/日志按前缀识别「崩溃后归位」）。
    private static let interruptedWriteMessage =
        "WRITEBACK_INTERRUPTED: write lease expired before the delivery completed"
}
