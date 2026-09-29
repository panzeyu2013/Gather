// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/SessionRepo.swift
// TS 源: desktop/src/main/db/repositories/session.repo.ts
import Foundation

/// sessions 表行（列序与表定义一致）。
public struct SessionRow: Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let analysisStatus: String
    public let writebackStatus: String
    public let importSource: String
    public let sourcePath: String
    public let truncatedImport: Int
    public let reloadAckedAt: String?
    public let indexSeq: Int
    public let photoCount: Int
    public let failedWritebackCount: Int
    public let createdAt: String
    public let updatedAt: String

    init(row: DBRow) throws {
        guard row.count >= 14 else { throw DBError.message("SessionRow 列数不足: \(row.count)") }
        id = row[0].textValue ?? ""
        name = row[1].textValue ?? ""
        status = row[2].textValue ?? ""
        analysisStatus = row[3].textValue ?? ""
        writebackStatus = row[4].textValue ?? ""
        importSource = row[5].textValue ?? ""
        sourcePath = row[6].textValue ?? ""
        truncatedImport = Int(row[7].intValue ?? 0)
        reloadAckedAt = row[8].textValue
        indexSeq = Int(row[9].intValue ?? 0)
        photoCount = Int(row[10].intValue ?? 0)
        failedWritebackCount = Int(row[11].intValue ?? 0)
        createdAt = row[12].textValue ?? ""
        updatedAt = row[13].textValue ?? ""
    }
}

public final class SessionRepo {
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 会话行的显式投影：analysis_status 已删列，分析状态**派生**自
    /// analysis_jobs（方案 A：job 表是唯一真相源，无"读列再回退"的双读）。
    /// running = 存在 queued/running/cancelling/interrupted；否则最近终态
    /// succeeded→done / failed→failed / cancelled→cancelled；无行 → idle。
    static let projectionSQL = """
        SELECT id, name, status,
          CASE
            WHEN EXISTS (
              SELECT 1 FROM analysis_jobs j
              WHERE j.scope_id = sessions.id
                AND j.status IN ('queued', 'running', 'cancelling', 'interrupted')
            ) THEN 'running'
            ELSE COALESCE((
              SELECT CASE j2.status
                       WHEN 'succeeded' THEN 'done'
                       WHEN 'failed' THEN 'failed'
                       WHEN 'cancelled' THEN 'cancelled'
                       ELSE 'idle' END
              FROM analysis_jobs j2
              WHERE j2.scope_id = sessions.id
              ORDER BY j2.updated_at DESC, j2.rowid DESC
              LIMIT 1
            ), 'idle')
          END AS analysis_status,
          writeback_status, import_source, source_path, truncated_import,
          reload_acked_at, index_seq, photo_count, failed_writeback_count,
          created_at, updated_at
        FROM sessions
        """

    public func get(id: String) throws -> SessionRow? {
        guard let row = try connection.prepare("\(Self.projectionSQL) WHERE id = ?").get([.text(id)]) else {
            return nil
        }
        return try SessionRow(row: row)
    }

    public func create(name: String, source: String, sourcePath: String = "", truncatedImport: Bool = false) throws -> SessionRow {
        let id = newUUIDString()
        let now = nowISOString()
        _ = try connection.prepare(
            "INSERT INTO sessions (id, name, status, writeback_status, import_source, source_path, truncated_import, photo_count, failed_writeback_count, created_at, updated_at) VALUES (?, ?, 'draft', 'idle', ?, ?, ?, 0, 0, ?, ?)"
        ).run([.text(id), .text(name), .text(source), .text(sourcePath), .int(truncatedImport ? 1 : 0), .text(now), .text(now)])
        return try get(id: id)!
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        let changes = try connection.prepare("DELETE FROM sessions WHERE id = ?").run([.text(id)])
        return changes > 0
    }

    public func deleteMany(ids: [String]) throws -> Int {
        let deleteStmt = try connection.prepare("DELETE FROM sessions WHERE id = ?")
        try connection.transaction {
            for sid in ids {
                _ = try deleteStmt.run([.text(sid)])
            }
        }
        return ids.count
    }

    public func deleteSimilarityDataBySession(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM similarity_results WHERE session_id = ?").run([.text(sessionId)])
        _ = try connection.prepare("DELETE FROM similarity_hashes WHERE session_id = ?").run([.text(sessionId)])
    }

    public func list() throws -> [SessionRow] {
        // 排序语义（显式决策）："分析也是会话活动" —— 取最近一次分析 job 的
        // updated_at 与会话自身 updated_at 的较大者，保住"分析完成把会话顶到
        // 最前"（delete updateAnalysisStatus 曾顺带写 sessions.updated_at 的
        // 副作用不能再悄悄丢失）。同刻按 rowid 兜底，顺序确定。
        let rows = try connection.prepare("""
            \(Self.projectionSQL)
            ORDER BY COALESCE(
              NULLIF((SELECT MAX(j.updated_at) FROM analysis_jobs j WHERE j.scope_id = sessions.id), ''),
              updated_at
            ) DESC, rowid DESC
            """).query()
        return try rows.map { try SessionRow(row: $0) }
    }

    @discardableResult
    public func updateName(id: String, name: String) throws -> Bool {
        let changes = try connection.prepare("UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?")
            .run([.text(name), .text(nowISOString()), .text(id)])
        return changes > 0
    }

    public func updateStatus(id: String, status: String) throws {
        _ = try connection.prepare("UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISOString()), .text(id)])
    }

    public func updatePhotoCount(id: String, count: Int) throws {
        _ = try connection.prepare("UPDATE sessions SET photo_count = ?, updated_at = ? WHERE id = ?")
            .run([.int(Int64(count)), .text(nowISOString()), .text(id)])
    }

    public func updateWritebackStatus(id: String, status: String) throws {
        _ = try connection.prepare("UPDATE sessions SET writeback_status = ?, updated_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISOString()), .text(id)])
    }

    public func updateFailedWritebackCount(id: String, count: Int) throws {
        _ = try connection.prepare("UPDATE sessions SET failed_writeback_count = ?, updated_at = ? WHERE id = ?")
            .run([.int(Int64(count)), .text(nowISOString()), .text(id)])
    }

    @discardableResult
    public func setReloadAckedAt(sessionId: String, iso: String) throws -> Bool {
        let changes = try connection.prepare("UPDATE sessions SET reload_acked_at = ?, updated_at = ? WHERE id = ?")
            .run([.text(iso), .text(nowISOString()), .text(sessionId)])
        return changes > 0
    }

    public func getIndexSeq(id: String) throws -> Int {
        let row = try connection.prepare("SELECT index_seq FROM sessions WHERE id = ?").get([.text(id)])
        return Int(row?[0].intValue ?? 0)
    }

    public func bumpIndexSeq(id: String) throws -> Int {
        try connection.transaction {
            _ = try connection.prepare("UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?")
                .run([.text(nowISOString()), .text(id)])
            let row = try connection.prepare("SELECT index_seq FROM sessions WHERE id = ?").get([.text(id)])
            return Int(row?[0].intValue ?? 0)
        }
    }
}


