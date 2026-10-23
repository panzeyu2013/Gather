// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Delete.swift
// DeliveryRepo 拆分（纯移动）：删除（孤儿 / 终态 CAS）。
//
// 方法体与拆分前逐字一致；跨文件 private 成员仅提升为 internal。

import Foundation
import GatherProtocol

extension DeliveryRepo {
    /// 删除孤儿交付：单事务、revision CAS，且执行删除时仍无会话关联。
    ///
    /// 返回 false 只表示「状态已漂移」（并发改写/被重新链接），调用方重读列表即可，
    /// 不得当作成功；真正删不掉时抛 writeNotPersisted 回滚子行删除。
    @discardableResult
    public func deleteOrphanDelivery(xmpPath: String, revision: Int64) throws -> Bool {
        let path = try normalizedPath(xmpPath)
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
        return try connection.transaction {
            guard let current = try get(path), current.revision == revision else { return false }
            let links = try connection.prepare("""
                SELECT COUNT(*) FROM delivery_sessions WHERE delivery_id = ?
                """).get([.int(current.id)])?[0].intValue ?? 0
            guard links == 0 else { return false }
            _ = try connection.prepare("DELETE FROM delivery_items WHERE delivery_id = ?")
                .run([.int(current.id)])
            let removed = try connection.prepare("""
                DELETE FROM deliveries WHERE id = ? AND revision = ?
                """).run([.int(current.id), .int(revision)])
            guard removed == 1 else {
                // 事务内已校验仍删不掉：宁可抛错回滚子行删除，也不留半删状态。
                throw DeliveryRepoError.writeNotPersisted("delivery#\(current.id)")
            }
            return true
        }
    }

    // MARK: - 终态删除（cleanup / finalize 共用）

    /// 删除已确认交付的结果。cleanup 的 replay 与 finalize 的 dropWithoutRestore
    /// 都需要「先 CAS 校验、再物理删子行」的同一条纪律，差异只在文件阶段
    /// （cleanup 恢复备份，finalize 丢弃备份），因此 DB 段收敛到这里。
    public enum DeliveryDeleteOutcome: String, Sendable, Equatable {
        /// 行已删除。
        case deleted
        /// 行本来就不存在（重放幂等）。
        case alreadyGone
        /// xmp_path 仍在但 id 已变（删除后重建：新输入必须保留）。
        case idChanged
        /// revision 已推进（新输入必须保留）。
        case revisionChanged
        /// 状态不再是 synced，或还有未确认的关联会话。
        case stateChanged
    }

    /// 单事务删除一条 synced 交付：delivery_items → delivery_sessions → deliveries。
    ///
    /// 守卫（全部在同一事务内读取，避免文件阶段 await 期间的状态漂移）：
    /// - id 与 revision 必须与调用方快照一致；
    /// - status 必须是 synced；
    /// - 所有关联会话都必须已确认（linkSession 会把 confirmed_at 重置为 ''，
    ///   不能替别的会话删行）。
    ///
    /// 删不掉时返回 outcome（不是错误）：replay 需要区分「幂等完成」与
    /// 「新输入保留」。显式删子行而不是依赖 CASCADE，与 cleanup 的既有顺序一致。
    @discardableResult
    public func deleteSyncedDelivery(
        xmpPath: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        let path = try normalizedPath(xmpPath)
        guard deliveryId > 0 else {
            throw DeliveryRepoError.invalidArgument("deliveryId 必须为正: \(deliveryId)")
        }
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
        return try connection.transaction {
            try deleteSyncedDeliveryInTransaction(
                path: path, deliveryId: deliveryId, revision: revision)
        }
    }

    /// 事务内变体（WP2b）：调用方已持有 connection.transaction 时使用。
    ///
    /// DeliveryDBPhase 用它把「删除 deliveries/items/links」与
    /// DeliveryIntentRepo.finishInTransaction 放进同一事务：任一步失败整体回滚，
    /// 不再出现「行已删、intent 未收尾」的崩溃窗口。
    @discardableResult
    public func deleteSyncedDeliveryInTransaction(
        xmpPath: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        let path = try normalizedPath(xmpPath)
        try Self.validateDeleteArguments(deliveryId: deliveryId, revision: revision)
        return try deleteSyncedDeliveryBody(
            path: path, deliveryId: deliveryId, revision: revision)
    }

    /// 事务内变体（已归一化 path 的内部实现；供公开包装复用）。
    @discardableResult
    private func deleteSyncedDeliveryInTransaction(
        path: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        try deleteSyncedDeliveryBody(
            path: path, deliveryId: deliveryId, revision: revision)
    }

    private static func validateDeleteArguments(deliveryId: Int64, revision: Int64) throws {
        guard deliveryId > 0 else {
            throw DeliveryRepoError.invalidArgument("deliveryId 必须为正: \(deliveryId)")
        }
        guard revision >= 0 else {
            throw DeliveryRepoError.invalidArgument("revision 不能为负: \(revision)")
        }
    }

    private func deleteSyncedDeliveryBody(
        path: String,
        deliveryId: Int64,
        revision: Int64
    ) throws -> DeliveryDeleteOutcome {
        guard let current = try get(path) else { return .alreadyGone }
        guard current.id == deliveryId else { return .idChanged }
        guard current.revision == revision else { return .revisionChanged }
        guard current.typedStatus == .synced else { return .stateChanged }
        let unconfirmedLinks = try connection.prepare("""
            SELECT COUNT(*) FROM delivery_sessions
            WHERE delivery_id = ? AND confirmed_at = ''
            """).get([.int(deliveryId)])?[0].intValue ?? 0
        guard unconfirmedLinks == 0 else { return .stateChanged }
        _ = try connection.prepare("DELETE FROM delivery_items WHERE delivery_id = ?")
            .run([.int(deliveryId)])
        _ = try connection.prepare("DELETE FROM delivery_sessions WHERE delivery_id = ?")
            .run([.int(deliveryId)])
        let removed = try connection.prepare("""
            DELETE FROM deliveries
            WHERE id = ? AND revision = ? AND status = ?
            """).run([
                .int(deliveryId),
                .int(revision),
                .text(DeliveryStatus.synced.rawValue),
            ])
        guard removed == 1 else {
            // 事务内已校验仍删不掉：宁可抛错回滚子行删除，也不留半删状态。
            throw DeliveryRepoError.writeNotPersisted("delivery#\(deliveryId)")
        }
        return .deleted
    }
}
