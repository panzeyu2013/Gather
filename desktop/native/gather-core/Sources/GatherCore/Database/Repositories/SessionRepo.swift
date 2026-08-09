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

    public func get(id: String) throws -> SessionRow? {
        guard let row = try connection.prepare("SELECT * FROM sessions WHERE id = ?").get([.text(id)]) else {
            return nil
        }
        return try SessionRow(row: row)
    }

    public func create(name: String, source: String, sourcePath: String = "", truncatedImport: Bool = false) throws -> SessionRow {
        let id = newUUID()
        let now = nowISO()
        _ = try connection.prepare(
            "INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, truncated_import, photo_count, failed_writeback_count, created_at, updated_at) VALUES (?, ?, 'draft', 'idle', 'idle', ?, ?, ?, 0, 0, ?, ?)"
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
        let rows = try connection.prepare("SELECT * FROM sessions ORDER BY updated_at DESC").query()
        return try rows.map { try SessionRow(row: $0) }
    }

    @discardableResult
    public func updateName(id: String, name: String) throws -> Bool {
        let changes = try connection.prepare("UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?")
            .run([.text(name), .text(nowISO()), .text(id)])
        return changes > 0
    }

    @discardableResult
    public func updateSourcePath(id: String, sourcePath: String) throws -> Bool {
        let changes = try connection.prepare("UPDATE sessions SET source_path = ?, updated_at = ? WHERE id = ?")
            .run([.text(sourcePath), .text(nowISO()), .text(id)])
        return changes > 0
    }

    public func updateStatus(id: String, status: String) throws {
        _ = try connection.prepare("UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISO()), .text(id)])
    }

    public func updatePhotoCount(id: String, count: Int) throws {
        _ = try connection.prepare("UPDATE sessions SET photo_count = ?, updated_at = ? WHERE id = ?")
            .run([.int(Int64(count)), .text(nowISO()), .text(id)])
    }

    public func updateAnalysisStatus(id: String, status: String) throws {
        _ = try connection.prepare("UPDATE sessions SET analysis_status = ?, updated_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISO()), .text(id)])
    }

    public func updateWritebackStatus(id: String, status: String) throws {
        _ = try connection.prepare("UPDATE sessions SET writeback_status = ?, updated_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISO()), .text(id)])
    }

    public func updateFailedWritebackCount(id: String, count: Int) throws {
        _ = try connection.prepare("UPDATE sessions SET failed_writeback_count = ?, updated_at = ? WHERE id = ?")
            .run([.int(Int64(count)), .text(nowISO()), .text(id)])
    }

    public func getReloadAckedAt(sessionId: String) throws -> String? {
        let row = try connection.prepare("SELECT reload_acked_at FROM sessions WHERE id = ?").get([.text(sessionId)])
        return row?[0].textValue
    }

    @discardableResult
    public func setReloadAckedAt(sessionId: String, iso: String) throws -> Bool {
        let changes = try connection.prepare("UPDATE sessions SET reload_acked_at = ?, updated_at = ? WHERE id = ?")
            .run([.text(iso), .text(nowISO()), .text(sessionId)])
        return changes > 0
    }

    public func getIndexSeq(id: String) throws -> Int {
        let row = try connection.prepare("SELECT index_seq FROM sessions WHERE id = ?").get([.text(id)])
        return Int(row?[0].intValue ?? 0)
    }

    public func bumpIndexSeq(id: String) throws -> Int {
        try connection.transaction {
            _ = try connection.prepare("UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?")
                .run([.text(nowISO()), .text(id)])
            let row = try connection.prepare("SELECT index_seq FROM sessions WHERE id = ?").get([.text(id)])
            return Int(row?[0].intValue ?? 0)
        }
    }
}

/// TS: crypto.randomUUID()（小写，与 Node 输出一致）。
private func newUUID() -> String {
    UUID().uuidString.lowercased()
}

/// TS: new Date().toISOString()（毫秒级小数秒 + Z）。
private func nowISO() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}
