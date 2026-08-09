// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/CullingHistoryRepo.swift
// TS 源: desktop/src/main/db/repositories/culling-history.repo.ts
// 类型说明：CullingHistoryEntry/CullingHistoryOperation 复用 Protocol/Culling.swift 的定义。

import Foundation

/// culling_history 表行（列序与 SELECT 一致）。
public struct CullingHistoryRow {
    public let id: Int64
    public let sessionId: String
    public let operationJSON: String
    public let undone: Bool
    public let createdAt: String

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        sessionId = row[1].textValue ?? ""
        operationJSON = row[2].textValue ?? ""
        undone = (row[3].intValue ?? 0) != 0
        createdAt = row[4].textValue ?? ""
    }
}

/// culling_history 仓库（TS CullingHistoryRepository）。
public final class CullingHistoryRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    public func append(sessionId: String, entries: [CullingHistoryEntry]) throws -> CullingHistoryOperation {
        let createdAt = nowISOString()
        let id: Int64 = try connection.transaction {
            _ = try connection.prepare(
                "DELETE FROM culling_history WHERE session_id = ? AND undone = 1"
            ).run([.text(sessionId)])
            let operationJSON = try JSONEncoder().encode(entries)
            _ = try connection.prepare("""
                INSERT INTO culling_history (session_id, operation_json, undone, created_at)
                VALUES (?, ?, 0, ?)
              """).run([
                .text(sessionId),
                .text(String(data: operationJSON, encoding: .utf8) ?? "[]"),
                .text(createdAt),
            ])
            return connection.lastInsertRowid
        }
        return CullingHistoryOperation(id: Int(id), sessionId: sessionId, entries: entries, undone: false, createdAt: createdAt)
    }

    public func setUndone(sessionId: String, operationId: Int, undone: Bool) throws {
        let boundary = try connection.prepare("""
            SELECT \(undone ? "MAX" : "MIN")(id) AS id
            FROM culling_history WHERE session_id = ? AND undone = ?
          """).get([.text(sessionId), .int(undone ? 0 : 1)])
        let boundaryId = boundary?[0].intValue
        if boundaryId != Int64(operationId) {
            throw DBError.message(undone ? "CULLING_UNDO_NOT_LATEST" : "CULLING_REDO_OUT_OF_ORDER")
        }
        let changed = try connection.prepare("""
            UPDATE culling_history SET undone = ?
            WHERE id = ? AND session_id = ? AND undone = ?
          """).run([.int(undone ? 1 : 0), .int(Int64(operationId)), .text(sessionId), .int(undone ? 0 : 1)])
        if changed != 1 { throw DBError.message("CULLING_HISTORY_STALE") }
    }

    public func get(sessionId: String, operationId: Int) throws -> CullingHistoryOperation? {
        guard let row = try connection.prepare("""
            SELECT id, session_id, operation_json, undone, created_at
            FROM culling_history WHERE id = ? AND session_id = ?
          """).get([.int(Int64(operationId)), .text(sessionId)]) else { return nil }
        return try makeOperation(CullingHistoryRow(row: row))
    }

    public func list(sessionId: String, limit: Int = 100) throws -> [CullingHistoryOperation] {
        let clamped = Swift.min(Swift.max(1, limit), 500)
        let rows = try connection.prepare("""
            SELECT id, session_id, operation_json, undone, created_at
            FROM culling_history WHERE session_id = ? ORDER BY id DESC LIMIT ?
          """).query([.text(sessionId), .int(Int64(clamped))])
        var result: [CullingHistoryOperation] = []
        for row in rows {
            if let operation = try? makeOperation(CullingHistoryRow(row: row)) {
                result.append(operation)
            }
        }
        return result
    }

    private func makeOperation(_ row: CullingHistoryRow) throws -> CullingHistoryOperation {
        do {
            let entries = try JSONDecoder().decode(
                [CullingHistoryEntry].self,
                from: Data(row.operationJSON.utf8)
            )
            return CullingHistoryOperation(
                id: Int(row.id),
                sessionId: row.sessionId,
                entries: entries,
                undone: row.undone,
                createdAt: row.createdAt
            )
        } catch {
            throw DBError.message("CULLING_HISTORY_CORRUPT")
        }
    }
}
