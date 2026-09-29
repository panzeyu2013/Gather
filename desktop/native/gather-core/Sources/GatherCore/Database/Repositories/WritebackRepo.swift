// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/WritebackRepo.swift
// TS 源: desktop/src/main/db/repositories/writeback.repo.ts
import Foundation

/// writeback_items 表行（字段按 TS 接口顺序；init 按表列序位置读取）。
public struct WritebackItemRow: Equatable, Sendable {
    public let id: Int64
    public let photoId: String
    public let photoPath: String
    public let sessionId: String
    public let module: String
    public let keywords: String
    public let attributesJson: String
    public let xmpPath: String
    public let backupPath: String
    public let xmpStatus: String
    public let errorMessage: String
    public let attemptCount: Int
    public let lastAttemptAt: String

    // 表列序: id(0), photo_id(1), session_id(2), module(3), keywords(4),
    // attributes_json(5), photo_path(6), xmp_path(7), backup_path(8),
    // xmp_status(9), error_message(10), attempt_count(11), last_attempt_at(12),
    // created_at(13)
    init(row: DBRow) throws {
        guard row.count >= 13 else { throw DBError.message("WritebackItemRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        photoId = row[1].textValue ?? ""
        photoPath = row[6].textValue ?? ""
        sessionId = row[2].textValue ?? ""
        module = row[3].textValue ?? ""
        keywords = row[4].textValue ?? ""
        attributesJson = row[5].textValue ?? ""
        xmpPath = row[7].textValue ?? ""
        backupPath = row[8].textValue ?? ""
        xmpStatus = row[9].textValue ?? ""
        errorMessage = row[10].textValue ?? ""
        attemptCount = Int(row[11].intValue ?? 0)
        lastAttemptAt = row[12].textValue ?? ""
    }
}

/// saveItems 的单条输入（TS: WritebackItemInput）。
public struct WritebackItemInput {
    public let photoId: String
    public let photoPath: String
    public let module: String
    public let keywords: [String]
    public let attributes: [String: Any]?
    public let xmpPath: String
    public let backupPath: String

    public init(photoId: String, photoPath: String, module: String, keywords: [String], attributes: [String: Any]? = nil, xmpPath: String, backupPath: String) {
        self.photoId = photoId
        self.photoPath = photoPath
        self.module = module
        self.keywords = keywords
        self.attributes = attributes
        self.xmpPath = xmpPath
        self.backupPath = backupPath
    }
}

public final class WritebackRepo: Sendable {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 先删掉该 (session, module) 下 pending/failed 的旧行，再批量插入。
    public func saveItems(sessionId: String, module: String, items: [WritebackItemInput]) throws {
        let now = nowISOString()
        try connection.transaction {
            _ = try connection.prepare(
                "DELETE FROM writeback_items WHERE session_id = ? AND module = ? AND xmp_status IN ('pending', 'failed')"
            ).run([.text(sessionId), .text(module)])

            let insertStmt = try connection.prepare(
                "INSERT INTO writeback_items (photo_id, photo_path, session_id, module, keywords, attributes_json, xmp_path, backup_path, xmp_status, error_message, last_attempt_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?)"
            )
            for item in items {
                _ = try insertStmt.run([
                    .text(item.photoId),
                    .text(item.photoPath),
                    .text(sessionId),
                    .text(module),
                    .text(jsonString(item.keywords)),
                    .text(jsonString(item.attributes ?? [:])),
                    .text(item.xmpPath),
                    .text(item.backupPath),
                    .text(now),
                ])
            }
        }
    }

    public func getItems(sessionId: String, module: String? = nil, status: String? = nil) throws -> [WritebackItemRow] {
        var sql = "SELECT * FROM writeback_items WHERE session_id = ?"
        var params: [DBValue?] = [.text(sessionId)]

        if let module, !module.isEmpty {
            sql += " AND module = ?"
            params.append(.text(module))
        }
        if let status, !status.isEmpty {
            sql += " AND xmp_status = ?"
            params.append(.text(status))
        }

        sql += " ORDER BY id ASC"
        let rows = try connection.prepare(sql).query(params)
        return try rows.map { try WritebackItemRow(row: $0) }
    }

    public func updateStatus(itemId: Int64, status: String, error: String? = nil) throws {
        let now = nowISOString()
        _ = try connection.prepare(
            "UPDATE writeback_items SET xmp_status = ?, error_message = ?, attempt_count = attempt_count + 1, last_attempt_at = ? WHERE id = ?"
        ).run([.text(status), .text(error ?? ""), .text(now), .int(itemId)])
    }

    public func getFailedCount(sessionId: String, module: String? = nil) throws -> Int {
        var sql = "SELECT COUNT(*) as count FROM writeback_items WHERE session_id = ? AND xmp_status = ?"
        var params: [DBValue?] = [.text(sessionId), .text("failed")]
        if let module, !module.isEmpty {
            sql += " AND module = ?"
            params.append(.text(module))
        }
        let row = try connection.prepare(sql).get(params)
        return Int(row?[0].intValue ?? 0)
    }

    /// 只删除指定 (session, module) 下状态为 synced 且 id 在列表中的行
    /// （按 400 分块，与 TS 一致）。
    public func deleteItemsByIds(sessionId: String, module: String, ids: [Int64]) throws {
        var doomed: [Int64] = []
        let selectStmt = try connection.prepare(
            "SELECT id FROM writeback_items WHERE session_id = ? AND module = ? AND xmp_status = 'synced' AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
        )
        for chunkStart in stride(from: 0, to: ids.count, by: 400) {
            let chunk = ids[chunkStart..<min(chunkStart + 400, ids.count)]
            let rows = try selectStmt.query([.text(sessionId), .text(module)] + chunk.map { .int($0) })
            doomed.append(contentsOf: rows.compactMap { $0[0].intValue })
        }
        for chunkStart in stride(from: 0, to: doomed.count, by: 400) {
            let chunk = doomed[chunkStart..<min(chunkStart + 400, doomed.count)]
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare("DELETE FROM writeback_items WHERE id IN (\(placeholders))")
                .run(chunk.map { .int($0) })
        }
    }

    public func updateKeywords(itemId: Int64, keywords: [String]) throws {
        _ = try connection.prepare("UPDATE writeback_items SET keywords = ? WHERE id = ?")
            .run([.text(jsonString(keywords)), .int(itemId)])
    }

    public func updateAttributesMany(items: [(id: Int64, attributes: [String: Any])]) throws {
        let statement = try connection.prepare("UPDATE writeback_items SET attributes_json = ? WHERE id = ?")
        try connection.transaction {
            for item in items {
                _ = try statement.run([.text(jsonString(item.attributes)), .int(item.id)])
            }
        }
    }

    public func updateKeywordsMany(items: [(id: Int64, keywords: [String])]) throws {
        let statement = try connection.prepare("UPDATE writeback_items SET keywords = ? WHERE id = ?")
        try connection.transaction {
            for item in items {
                _ = try statement.run([.text(jsonString(item.keywords)), .int(item.id)])
            }
        }
    }

    public func markWrittenAsSynced(sessionId: String, module: String) throws {
        _ = try connection.prepare(
            "UPDATE writeback_items SET xmp_status = 'synced' WHERE session_id = ? AND module = ? AND xmp_status = 'written'"
        ).run([.text(sessionId), .text(module)])
    }

    /// 返回删除行数（TS: run(...).changes）。
    @discardableResult
    public func discardPendingByXmpPath(xmpPath: String) throws -> Int {
        try connection.prepare(
            "DELETE FROM writeback_items WHERE xmp_path = ? AND xmp_status IN ('pending', 'failed')"
        ).run([.text(xmpPath)])
    }
}

/// TS: JSON.stringify(keywords) —— JSONEncoder 输出 key 顺序与 TS 一致
/// （字符串数组无 key，直接原样数组文本）。
private func jsonString(_ keywords: [String]) -> String {
    guard let data = try? JSONEncoder().encode(keywords) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
}

/// TS: JSON.stringify(attributes)（Record<string, unknown>）。
private func jsonString(_ attributes: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: attributes) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}


