// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/CullingHistoryRepo.swift
// TS 源: desktop/src/main/db/repositories/culling-history.repo.ts
// 类型说明：CullingHistoryEntry/CullingHistoryOperation 复用 Protocol/Culling.swift 的定义。
//
// ── 栈序唯一规则（undo/redo 只有这一条规则，读取方与仓库必须一致）──────
// culling_history 是单栈 + undone 标记：
//   * undo 目标 = MAX(id) WHERE undone = 0（最新未撤销操作）
//   * redo 目标 = MIN(id) WHERE undone = 1（最早被撤销的操作；撤销是自新向旧走的，
//     因此重做栈顶就是「被撤销集合里 id 最小」的那条）
// setUndone 用同一规则做顺序守卫（undo → CULLING_UNDO_NOT_LATEST；
// redo → CULLING_REDO_OUT_OF_ORDER）。任何读取方都必须用 stackTops() 或同规则推导，
// 不得用「列表里第一个 undone」（列表是 id DESC，first(undone) = MAX(undone) ≠ redo 栈顶）。
import Foundation
import GatherProtocol

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

/// 撤销/重做栈顶（见文件头注）。nil = 对应方向没有可应用的操作。
public struct CullingHistoryStackTops: Equatable, Sendable {
    public let undoId: Int?
    public let redoId: Int?

    public init(undoId: Int?, redoId: Int?) {
        self.undoId = undoId
        self.redoId = redoId
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

    /// 翻转 undone 标记；目标必须是当前栈顶（规则见文件头注），否则抛
    /// CULLING_UNDO_NOT_LATEST / CULLING_REDO_OUT_OF_ORDER（TS 逐字）。
    public func setUndone(sessionId: String, operationId: Int, undone: Bool) throws {
        let boundary = try connection.prepare("""
            SELECT \(undone ? "MAX" : "MIN")(id) AS id
            FROM culling_history WHERE session_id = ? AND undone = ?
          """).get([.text(sessionId), .int(undone ? 0 : 1)])
        let boundaryId = boundary?[0].intValue
        if boundaryId != Int64(operationId) {
            throw PersistenceError(code: undone ? .CULLING_UNDO_NOT_LATEST : .CULLING_REDO_OUT_OF_ORDER)
        }
        let changed = try connection.prepare("""
            UPDATE culling_history SET undone = ?
            WHERE id = ? AND session_id = ? AND undone = ?
          """).run([.int(undone ? 1 : 0), .int(Int64(operationId)), .text(sessionId), .int(undone ? 0 : 1)])
        if changed != 1 { throw PersistenceError(code: .CULLING_HISTORY_STALE) }
    }

    /// 撤销/重做栈顶（单查询；规则见文件头注）。
    public func stackTops(sessionId: String) throws -> CullingHistoryStackTops {
        let row = try connection.prepare("""
            SELECT MAX(CASE WHEN undone = 0 THEN id END) AS undo_id,
                   MIN(CASE WHEN undone = 1 THEN id END) AS redo_id
            FROM culling_history WHERE session_id = ?
          """).get([.text(sessionId)])
        let undoId = row?[0].intValue
        let redoId = row?[1].intValue
        return CullingHistoryStackTops(
            undoId: undoId.map(Int.init),
            redoId: redoId.map(Int.init)
        )
    }

    public func get(sessionId: String, operationId: Int) throws -> CullingHistoryOperation? {
        guard let row = try connection.prepare("""
            SELECT id, session_id, operation_json, undone, created_at
            FROM culling_history WHERE id = ? AND session_id = ?
          """).get([.int(Int64(operationId)), .text(sessionId)]) else { return nil }
        return try makeOperation(CullingHistoryRow(row: row))
    }

    /// 历史栈窗口（id DESC）。limit 由调用方给定，仓库内 clamp 到 500；
    /// 这是仓库可见的完整窗口，调用方（服务层）负责把栈顶补进窗口。
    public func list(sessionId: String, limit: Int = 100) throws -> [CullingHistoryOperation] {
        let clamped = Swift.min(Swift.max(1, limit), Self.maxWindow)
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

    /// 仓库可见的最大窗口（list clamp 上限）。
    public static let maxWindow = 500

    /// 删除「条目涉及任一给定照片」的历史操作（reset 使用：决策行与其历史必须同时
    /// 清空，否则 undo 会以 CULLING_HISTORY_DIVERGED 失败、redo 栈指向不存在的状态）。
    /// 损坏的 operation_json 无法判定涉及照片，保留（reset 后首次 undo 会报分歧错误，
    /// 比静默删除不可解析的历史更保守）。返回删除条数。
    @discardableResult
    public func deleteOperationsTouching(sessionId: String, photoIds: Set<String>) throws -> Int {
        if photoIds.isEmpty { return 0 }
        let rows = try connection.prepare("""
            SELECT id, operation_json FROM culling_history WHERE session_id = ?
          """).query([.text(sessionId)])
        var doomed: [Int64] = []
        for row in rows {
            guard let json = row[1].textValue,
                  let entries = try? JSONDecoder().decode(
                      [CullingHistoryEntry].self, from: Data(json.utf8)) else { continue }
            if entries.contains(where: { photoIds.contains($0.photoId) }) {
                doomed.append(row[0].intValue ?? 0)
            }
        }
        guard !doomed.isEmpty else { return 0 }
        try connection.transaction {
            for id in doomed {
                _ = try connection.prepare(
                    "DELETE FROM culling_history WHERE id = ? AND session_id = ?"
                ).run([.int(id), .text(sessionId)])
            }
        }
        return doomed.count
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
            throw PersistenceError(
                code: .CULLING_HISTORY_CORRUPT,
                detail: "operationId=\(row.id) \(error)"
            )
        }
    }
}