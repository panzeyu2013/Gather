// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/MetadataLifecycleRepo.swift
// P1 下一波：metadata/template 交付生命周期与保留期 GC 的只读/删除查询。
//
// 分层约定：Application 的 MetadataDeliveryService / MetadataRetentionService 只做编排，
// SQL 全部收在这里（cleanup ratchet 的 services_prepare 指标保持 0 增长）。
// 所有查询显式列 + 参数绑定；删除走单事务，避免半删。

import Foundation
import GatherProtocol

public struct MetadataLifecycleRow: Sendable, Equatable {
    public let id: Int64
    public let xmpPath: String
    public let photoPath: String
    public let backupPath: String
    public let sessionId: String
    public let status: String
    public let updatedAt: String

    public init(
        id: Int64,
        xmpPath: String,
        photoPath: String = "",
        backupPath: String = "",
        sessionId: String = "",
        status: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.xmpPath = xmpPath
        self.photoPath = photoPath
        self.backupPath = backupPath
        self.sessionId = sessionId
        self.status = status
        self.updatedAt = updatedAt
    }
}

/// 交付状态投影的一行（一个交付 × 一个模块；调用方按 xmpPath 聚合）。
public struct MetadataLifecycleProjection: Sendable, Equatable {
    public let xmpPath: String
    public let status: String
    public let updatedAt: String
    public let backupPath: String
    public let module: String
    public let failedItems: Int
    public let pendingItems: Int

    public init(
        xmpPath: String,
        status: String,
        updatedAt: String,
        backupPath: String,
        module: String,
        failedItems: Int,
        pendingItems: Int
    ) {
        self.xmpPath = xmpPath
        self.status = status
        self.updatedAt = updatedAt
        self.backupPath = backupPath
        self.module = module
        self.failedItems = failedItems
        self.pendingItems = pendingItems
    }
}

public final class MetadataLifecycleRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    // MARK: - 保留期 / 收编候选

    /// 仅有 metadata/template item、状态 written、无未完成 intent 的交付（供存量收编）。
    public func adoptionCandidates(limit: Int) throws -> [MetadataLifecycleRow] {
        try connection.prepare("""
            SELECT d.id, d.xmp_path, d.photo_path, ds.session_id
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE d.status = 'written'
              AND NOT EXISTS (
                SELECT 1 FROM delivery_intents i
                WHERE i.xmp_path = d.xmp_path AND i.phase <> 'applied'
              )
              AND EXISTS (
                SELECT 1 FROM delivery_items di
                WHERE di.delivery_id = d.id AND di.module = 'metadata'
              )
              AND NOT EXISTS (
                SELECT 1 FROM delivery_items other
                WHERE other.delivery_id = d.id
                  AND other.module NOT IN ('metadata', 'template')
              )
            ORDER BY d.updated_at ASC
            LIMIT ?
            """).query([.int(Int64(max(0, limit)))]).compactMap { row in
                guard let id = row[0].intValue,
                      let xmpPath = row[1].textValue, !xmpPath.isEmpty,
                      let sessionId = row[3].textValue, !sessionId.isEmpty else { return nil }
                return MetadataLifecycleRow(
                    id: id, xmpPath: xmpPath, photoPath: row[2].textValue ?? "",
                    sessionId: sessionId)
            }
    }

    /// 已确认、超过保留期、无未完成 intent 的交付。
    public func expiredCandidates(cutoff: String, limit: Int) throws -> [MetadataLifecycleRow] {
        try connection.prepare("""
            SELECT d.id, d.xmp_path, d.backup_path
            FROM deliveries d
            WHERE d.status = 'synced'
              AND d.updated_at < ?
              AND NOT EXISTS (
                SELECT 1 FROM delivery_intents i
                WHERE i.xmp_path = d.xmp_path AND i.phase <> 'applied'
              )
              AND EXISTS (
                SELECT 1 FROM delivery_items di
                WHERE di.delivery_id = d.id
                  AND di.module IN ('metadata', 'template')
              )
            ORDER BY d.updated_at ASC
            LIMIT ?
            """).query([.text(cutoff), .int(Int64(max(0, limit)))]).compactMap { row in
                guard let id = row[0].intValue,
                      let xmpPath = row[1].textValue, !xmpPath.isEmpty else { return nil }
                return MetadataLifecycleRow(
                    id: id, xmpPath: xmpPath, backupPath: row[2].textValue ?? "")
            }
    }

    /// 没有任何 item、且超过最小年龄的孤儿交付行。
    public func emptyCandidates(cutoff: String, limit: Int) throws -> [MetadataLifecycleRow] {
        try connection.prepare("""
            SELECT d.id, d.xmp_path, d.backup_path
            FROM deliveries d
            WHERE d.updated_at < ?
              AND NOT EXISTS (
                SELECT 1 FROM delivery_items di WHERE di.delivery_id = d.id
              )
            ORDER BY d.updated_at ASC
            LIMIT ?
            """).query([.text(cutoff), .int(Int64(max(0, limit)))]).compactMap { row in
                guard let id = row[0].intValue,
                      let xmpPath = row[1].textValue, !xmpPath.isEmpty else { return nil }
                return MetadataLifecycleRow(
                    id: id, xmpPath: xmpPath, backupPath: row[2].textValue ?? "")
            }
    }

    /// 非 writing、无租约、无未完成 intent、带 metadata/template item 的交付
    /// （文件是否真的消失由 Application 侧判断：卷离线不能当删除）。
    public func vanishedCandidates(limit: Int) throws -> [MetadataLifecycleRow] {
        try connection.prepare("""
            SELECT d.id, d.xmp_path, d.backup_path
            FROM deliveries d
            WHERE d.status <> 'writing'
              AND d.lease_owner = ''
              AND NOT EXISTS (
                SELECT 1 FROM delivery_intents i
                WHERE i.xmp_path = d.xmp_path AND i.phase <> 'applied'
              )
              AND EXISTS (
                SELECT 1 FROM delivery_items di
                WHERE di.delivery_id = d.id
                  AND di.module IN ('metadata', 'template')
              )
            ORDER BY d.updated_at ASC
            LIMIT ?
            """).query([.int(Int64(max(0, limit)))]).compactMap { row in
                guard let id = row[0].intValue,
                      let xmpPath = row[1].textValue, !xmpPath.isEmpty else { return nil }
                return MetadataLifecycleRow(
                    id: id, xmpPath: xmpPath, backupPath: row[2].textValue ?? "")
            }
    }

    // MARK: - 备份引用 / 会话

    /// 会话 source_path（孤儿备份扫描根）。
    public func orphanRoots() throws -> [String] {
        try connection.prepare("""
            SELECT DISTINCT source_path FROM sessions WHERE source_path <> ''
            """).query().compactMap { $0[0].textValue }.filter { !$0.isEmpty }
    }

    /// 仍被 deliveries.backup_path 引用的备份（规范化路径）。
    public func referencedBackupPaths() throws -> Set<String> {
        Set(try connection.prepare("""
            SELECT backup_path FROM deliveries WHERE backup_path <> ''
            """).query().compactMap { row -> String? in
                guard let path = row[0].textValue, !path.isEmpty else { return nil }
                return TSPath.normalize(path)
            })
    }

    /// 交付关联的会话 + reload-ack 状态（C1 未重载时保留备份）。
    public func linkedSessions(deliveryId: Int64) throws -> [(id: String, acked: Bool)] {
        try connection.prepare("""
            SELECT ds.session_id, s.reload_acked_at
            FROM delivery_sessions ds
            JOIN sessions s ON s.id = ds.session_id
            WHERE ds.delivery_id = ?
            ORDER BY ds.session_id ASC
            """).query([.int(deliveryId)]).compactMap { row in
                guard let sessionId = row[0].textValue, !sessionId.isEmpty else { return nil }
                let acked = !(row[1].textValue ?? "").isEmpty
                return (sessionId, acked)
            }
    }

    // MARK: - 删除（单事务）

    /// 事务内重新确认"仍然没有 item"再删行（与 upsert 竞态安全）。
    public func deleteRowIfEmpty(id: Int64, xmpPath: String) throws -> Bool {
        try connection.transaction {
            guard try rowExists(id: id, xmpPath: xmpPath) else { return false }
            let items = try connection.prepare("""
                SELECT COUNT(*) FROM delivery_items WHERE delivery_id = ?
                """).get([.int(id)])?[0].intValue ?? 0
            guard items == 0 else { return false }
            return try deleteRowInTransaction(id: id)
        }
    }

    /// 删除一条已由调用方确认"文件已消失"的行（事务内只做 id/xmpPath 复核）。
    public func deleteVanishedRow(id: Int64, xmpPath: String) throws -> Bool {
        try connection.transaction {
            guard try rowExists(id: id, xmpPath: xmpPath) else { return false }
            return try deleteRowInTransaction(id: id)
        }
    }

    private func rowExists(id: Int64, xmpPath: String) throws -> Bool {
        let count = try connection.prepare("""
            SELECT COUNT(*) FROM deliveries WHERE id = ? AND xmp_path = ?
            """).get([.int(id), .text(xmpPath)])?[0].intValue ?? 0
        return count == 1
    }

    private func deleteRowInTransaction(id: Int64) throws -> Bool {
        _ = try connection.prepare("DELETE FROM delivery_items WHERE delivery_id = ?")
            .run([.int(id)])
        _ = try connection.prepare("DELETE FROM delivery_sessions WHERE delivery_id = ?")
            .run([.int(id)])
        let removed = try connection.prepare("DELETE FROM deliveries WHERE id = ?")
            .run([.int(id)])
        return removed == 1
    }

    // MARK: - 状态投影 / 备份统计

    /// 本会话里带 metadata/template item 的交付（按模块展开；调用方去重聚合）。
    public func projections(sessionId: String) throws -> [MetadataLifecycleProjection] {
        try connection.prepare("""
            SELECT d.xmp_path, d.status, d.updated_at, di.module,
                   COALESCE(items.failed_count, 0) AS failed_items,
                   COALESCE(items.pending_count, 0) AS pending_items,
                   d.backup_path
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            JOIN delivery_items di ON di.delivery_id = d.id
            JOIN photos p ON p.id = di.photo_id
            LEFT JOIN (
              SELECT delivery_id,
                     SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
                     SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending_count
              FROM delivery_items
              GROUP BY delivery_id
            ) items ON items.delivery_id = d.id
            WHERE ds.session_id = ?
              AND di.module IN ('metadata', 'template')
              AND p.session_id = ?
            ORDER BY d.id ASC
            """).query([.text(sessionId), .text(sessionId)]).compactMap { row in
                guard let xmpPath = row[0].textValue, !xmpPath.isEmpty else { return nil }
                return MetadataLifecycleProjection(
                    xmpPath: xmpPath,
                    status: row[1].textValue ?? "",
                    updatedAt: row[2].textValue ?? "",
                    backupPath: row[6].textValue ?? "",
                    module: row[3].textValue ?? "",
                    failedItems: Int(row[4].intValue ?? 0),
                    pendingItems: Int(row[5].intValue ?? 0))
            }
    }

    /// deliveries.backup_path（非空）；sessionId == nil = 全库。
    public func backupPaths(sessionId: String?) throws -> [String] {
        var sql = "SELECT d.backup_path FROM deliveries d"
        var values: [DBValue?] = []
        if let sessionId {
            sql += """

              JOIN delivery_sessions ds ON ds.delivery_id = d.id
              WHERE ds.session_id = ? AND d.backup_path <> ''
              """
            values.append(.text(sessionId))
        } else {
            sql += " WHERE d.backup_path <> ''"
        }
        sql += " ORDER BY d.id ASC"
        return try connection.prepare(sql).query(values).compactMap { row -> String? in
            guard let path = row[0].textValue, !path.isEmpty else { return nil }
            return path
        }
    }
}
