// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliverySummaryQuery.swift
// Cut 2 / S4：delivery 的会话级派生读模型（draft §5.4 / D-021）。
//
// 边界：
// 1. **只读**：本文件不写任何行（D-021 禁止回写 sessions.writeback_status）。
//    会话级交付状态由 deliveries / delivery_items 聚合派生，供 DeliveryCoordinator
//    的门禁与 UI 读取。
// 2. **显式列 + 参数绑定**：聚合查询只读 status 与 COUNT，行映射读取的是本文件自己
//    SELECT 的两列（不是 SELECT *），不依赖表的物理列序。
// 3. **module 过滤口径**：delivery_items 没有 session_id，必须经 photos.session_id
//    关联；module 非空时只统计「该会话内确有该模块 item」的交付，避免别的模块的
//    pending/failed 阻塞本模块 confirm。
// 4. cleanup/finalize 候选只选 **synced** 交付，且要求该会话在该模块下至少有一条
//    synced item（两者只在文件阶段不同：cleanup 恢复备份，finalize 丢弃备份）。
// 5. metadataSummary 是 syncStatus/flush/retry 的旧 MetadataSyncSummary 投影：
//    按交付去重计数（不把 delivery 与 item 数量相加），item 的 pending/failed
//    会把交付展示态升级。

import Foundation
import GatherProtocol

/// 会话级交付状态的派生值（不落库）。
public enum DeliverySessionState: String, Sendable, Equatable, CaseIterable {
    /// 作用域内没有交付行。
    case idle
    /// 有未落盘输入。
    case pending
    /// 有写租约未完成。
    case writing
    /// 文件已写、等待关联会话确认。
    case written
    /// 全部已确认。
    case synced
    /// 有写失败。
    case failed
    /// 有外部修改冲突。
    case conflict
    /// 软清理终态（当前物理删除不会产生；保留枚举与 UI 兼容）。
    case cleaned

    /// 兼容旧 `sessions.writeback_status` 读点的映射（D-021）。
    /// pending/writing/written 都表示「还没收口」→ running；failed/conflict → partial。
    public var writebackStatus: WritebackStatus {
        switch self {
        case .idle: return .idle
        case .pending, .writing, .written: return .running
        case .synced: return .done
        case .failed, .conflict: return .partial
        case .cleaned: return .cleaned
        }
    }
}

/// 会话（可再按 module 收窄）的交付聚合：两种状态计数 + 派生状态。
public struct DeliverySessionSummary: Sendable, Equatable {
    public let deliveryCounts: [DeliveryStatus: Int]
    public let itemCounts: [DeliveryItemStatus: Int]

    public init(
        deliveryCounts: [DeliveryStatus: Int],
        itemCounts: [DeliveryItemStatus: Int]
    ) {
        self.deliveryCounts = deliveryCounts
        self.itemCounts = itemCounts
    }

    public var isEmpty: Bool { deliveryCounts.isEmpty && itemCounts.isEmpty }

    private func deliveryCount(_ status: DeliveryStatus) -> Int {
        deliveryCounts[status] ?? 0
    }

    private func itemCount(_ status: DeliveryItemStatus) -> Int {
        itemCounts[status] ?? 0
    }

    /// 严重度从高到低：conflict > failed > writing > pending > written > cleaned > synced。
    /// cleaned 是软删审计态，优先于「全部已确认」；物理删除后没有行 → idle。
    public var state: DeliverySessionState {
        if deliveryCount(.conflict) > 0 { return .conflict }
        if deliveryCount(.failed) > 0 || itemCount(.failed) > 0 { return .failed }
        if deliveryCount(.writing) > 0 { return .writing }
        if deliveryCount(.pending) > 0 || itemCount(.pending) > 0 { return .pending }
        if deliveryCount(.written) > 0 { return .written }
        if deliveryCount(.cleaned) > 0 { return .cleaned }
        if deliveryCount(.synced) > 0 { return .synced }
        return .idle
    }

    public var writebackStatus: WritebackStatus { state.writebackStatus }

    /// confirm 门禁的阻断项（稳定顺序，可直接进错误描述/测试）。
    /// 只列 pending/writing/failed/conflict；written 是可确认态，不是阻断。
    public var blockers: [String] {
        var result: [String] = []
        for status in [DeliveryStatus.pending, .writing, .failed, .conflict] {
            let value = deliveryCount(status)
            if value > 0 { result.append("delivery:\(status.rawValue)=\(value)") }
        }
        for status in [DeliveryItemStatus.pending, .failed] {
            let value = itemCount(status)
            if value > 0 { result.append("item:\(status.rawValue)=\(value)") }
        }
        return result
    }

    public var isConfirmable: Bool { blockers.isEmpty }
}

/// delivery 的会话级聚合查询（只读；DeliveryCoordinator 与后续 UI 共用）。
public struct DeliverySummaryQuery: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 会话级聚合。module 非空时只统计该会话在该模块下真实存在的交付/item。
    public func summary(sessionId: String, module: DeliveryModule? = nil) throws -> DeliverySessionSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        return DeliverySessionSummary(
            deliveryCounts: try deliveryCounts(sessionId: sessionId, module: module),
            itemCounts: try itemCounts(sessionId: sessionId, module: module)
        )
    }

    /// synced 交付候选：cleanup（恢复备份后删行）与 finalize（保留 XMP、丢备份后删行）
    /// 共用同一套「可删除」判定，差异只在文件阶段，因此候选查询只有一份。
    /// 返回完整 DeliveryRow（显式列），调用方必须按 revision 重新做 CAS 删除。
    public func syncedCandidates(sessionId: String, module: DeliveryModule) throws -> [DeliveryRow] {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        // 交付行显式列必须带 d. 前缀：delivery_sessions 也有 created_at，
        // 不加限定会被 SQLite 判为 ambiguous column name。
        let selectList = DeliveryRow.columnNames.map { "d." + $0 }.joined(separator: ", ")
        let rows = try connection.prepare("""
            SELECT \(selectList)
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE ds.session_id = ?
              AND d.status = ?
              -- 只有「所有关联会话都已确认」的交付才能删：linkSession 重链会把
              -- confirmed_at 重置为 ''，此时必须等重新确认，不能替别的会话删行。
              AND NOT EXISTS (
                SELECT 1 FROM delivery_sessions pending
                WHERE pending.delivery_id = d.id AND pending.confirmed_at = ''
              )
              AND EXISTS (
                SELECT 1
                FROM delivery_items di
                JOIN photos p ON p.id = di.photo_id
                WHERE di.delivery_id = d.id
                  AND di.module = ?
                  AND p.session_id = ?
                  AND di.status = ?
              )
              -- 同一 (delivery, session, module) 下不允许残留未确认 item。
              AND NOT EXISTS (
                SELECT 1
                FROM delivery_items di2
                JOIN photos p2 ON p2.id = di2.photo_id
                WHERE di2.delivery_id = d.id
                  AND di2.module = ?
                  AND p2.session_id = ?
                  AND di2.status <> ?
              )
            ORDER BY d.id ASC
            """).query([
                .text(sessionId),
                .text(DeliveryStatus.synced.rawValue),
                .text(module.rawValue),
                .text(sessionId),
                .text(DeliveryItemStatus.synced.rawValue),
                .text(module.rawValue),
                .text(sessionId),
                .text(DeliveryItemStatus.synced.rawValue),
            ])
        return try rows.map { try DeliveryRow(columns: DeliveryRow.columnNames, row: $0) }
    }

    /// 旧名保留（S4 的调用点/测试只关心「cleanup 候选」；实现已上移为 syncedCandidates）。
    public func cleanupCandidates(sessionId: String, module: DeliveryModule) throws -> [DeliveryRow] {
        try syncedCandidates(sessionId: sessionId, module: module)
    }

    // MARK: - 旧 MetadataSyncSummary 投影（S5c-2b-1）

    /// 把本会话（可再按 module 收窄）的交付聚合映射成旧 `MetadataSyncSummary`。
    ///
    /// 口径（与旧 outbox 摘要对齐，每交付一行 = 每个 sidecar 一行）：
    /// 1. 计数按**交付**去重，绝不把 delivery 与 delivery_items 的数量相加
    ///    （同一张照片的 rating/label 与 keyword 可能落在不同 item，相加会虚高）；
    /// 2. item 的未完成态（pending/failed）会把交付的展示态升级：交付已 written
    ///    但仍有失败 item 时，`failed > 0`，UI/confirm 门禁都能看见；
    /// 3. 严重度顺序 conflict > failed > writing > pending > written > synced
    ///    （与 DeliverySessionSummary.state 同一套优先级）；
    /// 4. `items` 一行一交付，revision/attemptCount/updatedAt 直接取交付行
    ///    （`persisted_revision` 的语义在 V1 就是当前 revision，draft §5.3 偏离 4）。
    public func metadataSummary(
        sessionId: String,
        module: DeliveryModule? = nil
    ) throws -> MetadataSyncSummary {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        var sql = """
            SELECT d.xmp_path, d.status, d.revision, d.attempt_count,
                   d.error_message, d.updated_at,
                   COALESCE(items.failed_count, 0) AS failed_items,
                   COALESCE(items.pending_count, 0) AS pending_items
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            LEFT JOIN (
              SELECT delivery_id,
                     SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
                     SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending_count
              FROM delivery_items
              GROUP BY delivery_id
            ) items ON items.delivery_id = d.id
            WHERE ds.session_id = ?
            """
        var values: [DBValue?] = [.text(sessionId)]
        if let module {
            sql += """

              AND EXISTS (
                SELECT 1
                FROM delivery_items di
                JOIN photos p ON p.id = di.photo_id
                WHERE di.delivery_id = d.id
                  AND di.module = ?
                  AND p.session_id = ?
              )
            """
            values.append(.text(module.rawValue))
            values.append(.text(sessionId))
        }
        sql += " ORDER BY d.id ASC"

        var pending = 0
        var writing = 0
        var written = 0
        var failed = 0
        var conflict = 0
        var synced = 0
        var items: [MetadataSyncItem] = []

        for row in try connection.prepare(sql).query(values) {
            let xmpPath = row[0].textValue ?? ""
            let rawStatus = row[1].textValue ?? ""
            guard let deliveryStatus = DeliveryStatus(rawValue: rawStatus) else {
                throw DeliveryRepoError.invalidArgument("未知 delivery.status: " + rawStatus)
            }
            let revision = Int(row[2].intValue ?? 0)
            let attemptCount = Int(row[3].intValue ?? 0)
            let errorMessage = row[4].textValue ?? ""
            let updatedAt = row[5].textValue ?? ""
            let failedItems = Int(row[6].intValue ?? 0)
            let pendingItems = Int(row[7].intValue ?? 0)

            let status: MetadataSyncStatus = switch deliveryStatus {
            case .conflict: .conflict
            case .failed: .failed
            case .writing: .writing
            case .pending: .pending
            case .written:
                failedItems > 0 ? .failed : (pendingItems > 0 ? .pending : .written)
            case .synced:
                failedItems > 0 ? .failed : (pendingItems > 0 ? .pending : .synced)
            case .cleaned: .cleaned
            }

            switch status {
            case .pending: pending += 1
            case .writing: writing += 1
            case .written: written += 1
            case .failed: failed += 1
            case .conflict: conflict += 1
            case .synced: synced += 1
            case .clean, .cleaned:
                // clean 不是 V1 状态；cleaned 是审计终态，旧摘要没有对应计数桶。
                break
            }
            items.append(MetadataSyncItem(
                xmpPath: xmpPath,
                revision: revision,
                persistedRevision: revision,
                status: status,
                attemptCount: attemptCount,
                errorMessage: errorMessage,
                updatedAt: updatedAt
            ))
        }

        return MetadataSyncSummary(
            sessionId: sessionId,
            pending: pending,
            writing: writing,
            written: written,
            failed: failed,
            conflict: conflict,
            synced: synced,
            items: items
        )
    }

    // MARK: - 聚合 SQL

    private func deliveryCounts(
        sessionId: String,
        module: DeliveryModule?
    ) throws -> [DeliveryStatus: Int] {
        var sql = """
            SELECT d.status AS status, COUNT(DISTINCT d.id) AS row_count
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE ds.session_id = ?
            """
        var values: [DBValue?] = [.text(sessionId)]
        if let module {
            sql += """

                  AND EXISTS (
                    SELECT 1
                    FROM delivery_items di
                    JOIN photos p ON p.id = di.photo_id
                    WHERE di.delivery_id = d.id
                      AND di.module = ?
                      AND p.session_id = ?
                  )
                """
            values.append(.text(module.rawValue))
            values.append(.text(sessionId))
        }
        sql += " GROUP BY d.status"

        var counts: [DeliveryStatus: Int] = [:]
        for row in try connection.prepare(sql).query(values) {
            guard let raw = row[0].textValue else {
                throw DeliveryRepoError.invalidArgument("delivery.status 读回为空")
            }
            guard let status = DeliveryStatus(rawValue: raw) else {
                throw DeliveryRepoError.invalidArgument("未知 delivery.status: \(raw)")
            }
            counts[status, default: 0] += Int(row[1].intValue ?? 0)
        }
        return counts
    }

    /// WP3b-1（WorkspaceStatus 下沉）：本会话某模块是否存在已落盘 item。
    public func hasWrittenBackItem(sessionId: String, module: DeliveryModule) throws -> Bool {
        try connection.prepare("""
            SELECT 1
            FROM delivery_items di
            JOIN photos p ON p.id = di.photo_id
            WHERE p.session_id = ? AND di.module = ?
              AND di.status IN ('written', 'synced')
            LIMIT 1
          """).get([.text(sessionId), .text(module.rawValue)]) != nil
    }

    private func itemCounts(
        sessionId: String,
        module: DeliveryModule?
    ) throws -> [DeliveryItemStatus: Int] {
        var sql = """
            SELECT di.status AS status, COUNT(*) AS row_count
            FROM delivery_items di
            JOIN photos p ON p.id = di.photo_id
            WHERE p.session_id = ?
            """
        var values: [DBValue?] = [.text(sessionId)]
        if let module {
            sql += " AND di.module = ?"
            values.append(.text(module.rawValue))
        }
        sql += " GROUP BY di.status"

        var counts: [DeliveryItemStatus: Int] = [:]
        for row in try connection.prepare(sql).query(values) {
            guard let raw = row[0].textValue else {
                throw DeliveryRepoError.invalidArgument("delivery_items.status 读回为空")
            }
            guard let status = DeliveryItemStatus(rawValue: raw) else {
                throw DeliveryRepoError.invalidArgument("未知 delivery_items.status: \(raw)")
            }
            counts[status, default: 0] += Int(row[1].intValue ?? 0)
        }
        return counts
    }
}
