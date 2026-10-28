// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/DeliveryRepo+Read.swift
// DeliveryRepo 拆分（纯移动）：读取与列表。
//
// 方法体与拆分前逐字一致；跨文件 private 成员仅提升为 internal。

import Foundation
import GatherProtocol

extension DeliveryRepo {
    /// 按 xmp_path 批量读取交付行（一次 IN 查询替代逐行 get 的 N+1）。
    ///
    /// 键为归一化路径；不存在的路径不出现在返回值里（调用方自行判定缺失）。
    /// 分块 400 与旧 WritebackRepo 的批量口径一致，避免超过 SQLite 变量上限。
    public func getMany(xmpPaths: [String]) throws -> [String: DeliveryRow] {
        var map: [String: DeliveryRow] = [:]
        let paths = Array(Set(xmpPaths.map { TSPath.normalize($0) })).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return map }
        for chunkStart in stride(from: 0, to: paths.count, by: 400) {
            let chunk = paths[chunkStart..<min(chunkStart + 400, paths.count)]
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT \(DeliveryRow.selectList) FROM deliveries
                WHERE xmp_path IN (\(placeholders))
                """).query(chunk.map { DBValue.text($0) })
            for row in rows {
                let delivery = try DeliveryRow(columns: DeliveryRow.columnNames, row: row)
                map[delivery.xmpPath] = delivery
            }
        }
        return map
    }

    /// 会话视角的 item 列表：delivery_items 本身不带 session_id，必须经 photos.session_id 关联。
    public func listItems(
        sessionId: String,
        module: DeliveryModule? = nil,
        status: DeliveryItemStatus? = nil
    ) throws -> [DeliveryItemRow] {
        var sql = """
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            JOIN photos p ON p.id = di.photo_id
            WHERE p.session_id = ?
            """
        var values: [DBValue?] = [.text(sessionId)]
        if let module {
            sql += " AND di.module = ?"
            values.append(.text(module.rawValue))
        }
        if let status {
            sql += " AND di.status = ?"
            values.append(.text(status.rawValue))
        }
        sql += " ORDER BY di.id ASC"
        let rows = try connection.prepare(sql).query(values)
        return try rows.map { try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: $0) }
    }

    /// 按主键读取单条交付项（execute / persist 的行映射入口）。
    public func item(id: Int64) throws -> DeliveryItemRow? {
        try itemRow(id: id)
    }

    // MARK: - 手动元数据队列（S5c-2b-3b-2b-2）

    /// 按 (xmp_path, photo, module) 读取单条交付项。
    ///
    /// 手动 rating/label/keywords 的队列要做「读取现有 item → 合并字段 → 写回」，
    /// 读入口必须与 UNIQUE(delivery_id, photo_id, module) 同一口径，不能借
    /// listItems 全表扫（会话内 N+1）。
    public func item(
        xmpPath: String,
        photoId: String,
        module: DeliveryModule
    ) throws -> DeliveryItemRow? {
        guard let delivery = try get(xmpPath) else { return nil }
        return try itemRow(deliveryId: delivery.id, photoId: photoId, module: module)
    }

    /// 按 (xmp_path, module) 读取该 sidecar 的交付项（不区分首张照片）。
    /// K0 delta 的 item 身份必须按 sidecar 而不是照片：同一 sidecar 换首张（JPEG→RAW）
    /// 不能生成第二条 item，否则 cumulative added/removed 会丢失。
    public func item(xmpPath: String, module: DeliveryModule) throws -> DeliveryItemRow? {
        guard let delivery = try get(xmpPath) else { return nil }
        let row = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.delivery_id = ? AND di.module = ?
            ORDER BY di.id ASC
            LIMIT 1
            """).get([.int(delivery.id), .text(module.rawValue)])
        guard let row else { return nil }
        return try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: row)
    }

    /// 某交付下的全部交付项（按 id 升序 = 入队顺序；conflicts 投影用）。
    public func items(deliveryId: Int64) throws -> [DeliveryItemRow] {
        let rows = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.delivery_id = ?
            ORDER BY di.id ASC
            """).query([.int(deliveryId)])
        return try rows.map { try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: $0) }
    }

    func itemRow(
        deliveryId: Int64,
        photoId: String,
        module: DeliveryModule
    ) throws -> DeliveryItemRow? {
        guard let row = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.delivery_id = ? AND di.photo_id = ? AND di.module = ?
            """).get([.int(deliveryId), .text(photoId), .text(module.rawValue)]) else {
            return nil
        }
        return try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: row)
    }

    func itemRow(id: Int64) throws -> DeliveryItemRow? {
        guard let row = try connection.prepare("""
            SELECT \(DeliveryItemRow.selectList)
            FROM delivery_items di
            JOIN deliveries d ON d.id = di.delivery_id
            WHERE di.id = ?
            """).get([.int(id)]) else {
            return nil
        }
        return try DeliveryItemRow(columns: DeliveryItemRow.columnNames, row: row)
    }

    // MARK: - 冲突 / 孤儿（S5c-2b-3b-2b-2：旧 outbox 查询的交付等价物）

    /// 会话视角的 conflict 交付（旧 metadata_outbox 的 status='conflict' 行等价物）。
    ///
    /// 冲突是**交付级**事实（一个 sidecar 文件一个状态），按 delivery_sessions 反查会话，
    /// 与旧 getBySession(sessionId).filter(status == conflict) 同一口径。
    public func conflictDeliveries(sessionId: String) throws -> [DeliveryRow] {
        guard !sessionId.isEmpty else {
            throw DeliveryRepoError.invalidArgument("sessionId 不能为空")
        }
        // 交付行显式列必须带 d. 前缀：delivery_sessions 也有 created_at/updated_at。
        let selectList = DeliveryRow.columnNames.map { "d." + $0 }.joined(separator: ", ")
        let rows = try connection.prepare("""
            SELECT \(selectList)
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE ds.session_id = ? AND d.status = ?
            ORDER BY d.updated_at DESC, d.id ASC
            """).query([.text(sessionId), .text(DeliveryStatus.conflict.rawValue)])
        return try rows.map { try DeliveryRow(columns: DeliveryRow.columnNames, row: $0) }
    }

    /// 孤儿交付：没有任何 delivery_sessions 关联（旧 getOrphans 的同一判据）。
    ///
    /// 这类行不再有会话能确认/清理，只能由 metadata.orphans 处置（keep/restore/retry）。
    public func orphanDeliveries() throws -> [DeliveryRow] {
        let rows = try connection.prepare("""
            SELECT \(DeliveryRow.selectList) FROM deliveries
            WHERE NOT EXISTS (
              SELECT 1 FROM delivery_sessions ds WHERE ds.delivery_id = deliveries.id
            )
            ORDER BY updated_at DESC, id ASC
            """).query()
        return try rows.map { try DeliveryRow(columns: DeliveryRow.columnNames, row: $0) }
    }

    /// 旧 MetadataSyncSummary 投影（LiveMetadataAPI.resolveConflict 的返回形状）。
    /// 与 DeliveryCoordinator.metadataSummary 共用 DeliverySummaryQuery 的唯一口径。
    public func metadataSummary(
        sessionId: String,
        module: DeliveryModule? = nil
    ) throws -> MetadataSyncSummary {
        try DeliverySummaryQuery(connection: connection)
            .metadataSummary(sessionId: sessionId, module: module)
    }
}
