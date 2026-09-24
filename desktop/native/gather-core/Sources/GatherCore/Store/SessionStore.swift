// Store/SessionStore.swift
// R1：sessions / session_assets 的唯一访问入口（取代 旧 SessionRepo）。
import Foundation

public struct SessionRecord: Decodable, Equatable, Sendable {
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

    public init(
        id: String,
        name: String,
        status: String,
        analysisStatus: String,
        writebackStatus: String,
        importSource: String,
        sourcePath: String,
        truncatedImport: Int,
        reloadAckedAt: String?,
        indexSeq: Int,
        photoCount: Int,
        failedWritebackCount: Int,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.analysisStatus = analysisStatus
        self.writebackStatus = writebackStatus
        self.importSource = importSource
        self.sourcePath = sourcePath
        self.truncatedImport = truncatedImport
        self.reloadAckedAt = reloadAckedAt
        self.indexSeq = indexSeq
        self.photoCount = photoCount
        self.failedWritebackCount = failedWritebackCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case analysisStatus = "analysis_status"
        case writebackStatus = "writeback_status"
        case importSource = "import_source"
        case sourcePath = "source_path"
        case truncatedImport = "truncated_import"
        case reloadAckedAt = "reload_acked_at"
        case indexSeq = "index_seq"
        case photoCount = "photo_count"
        case failedWritebackCount = "failed_writeback_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public protocol SessionStore: Sendable {
    func get(id: String) async throws -> SessionRecord?
    func create(name: String, source: String, sourcePath: String, truncatedImport: Bool) async throws -> SessionRecord
    func list() async throws -> [SessionRecord]
    func delete(id: String) async throws -> Bool
    func deleteMany(ids: [String]) async throws -> Int
    func deleteSimilarityData(sessionId: String) async throws
    func updateName(id: String, name: String) async throws -> Bool
    func updateSourcePath(id: String, sourcePath: String) async throws -> Bool
    func updateStatus(id: String, status: String) async throws
    func updatePhotoCount(id: String, count: Int) async throws
    func updateAnalysisStatus(id: String, status: String) async throws
    func updateWritebackStatus(id: String, status: String) async throws
    func updateFailedWritebackCount(id: String, count: Int) async throws
    func reloadAckedAt(sessionId: String) async throws -> String?
    func setReloadAckedAt(sessionId: String, iso: String) async throws -> Bool
    /// W4-1c：按 XMP 路径批量清除 reload 确认（单事务，返回实际清除的会话行数；空参 0）。
    func clearReloadAckedAtForXmpPaths(_ paths: [String]) async throws -> Int
    func indexSeq(id: String) async throws -> Int
    func bumpIndexSeq(id: String) async throws -> Int
}

public extension SessionStore {
    func create(name: String, source: String) async throws -> SessionRecord {
        try await create(name: name, source: source, sourcePath: "", truncatedImport: false)
    }

    /// W4-1c：非 SQLite 实现（如测试包装器）无持久层可清，默认空操作。
    /// 真实持久化实现必须重写（SQLiteSessionStore 已提供单事务实现）。
    func clearReloadAckedAtForXmpPaths(_ paths: [String]) async throws -> Int {
        0
    }
}

public struct SQLiteSessionStore: SessionStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func get(id: String) async throws -> SessionRecord? {
        try await database.queryOne("SELECT * FROM sessions WHERE id = ?", [.text(id)])?
            .decode(SessionRecord.self)
    }

    public func create(
        name: String,
        source: String,
        sourcePath: String = "",
        truncatedImport: Bool = false
    ) async throws -> SessionRecord {
        let id = newUUIDString()
        let now = nowISOString()
        try await database.run(
            """
            INSERT INTO sessions
              (id, name, status, analysis_status, writeback_status, import_source, source_path,
               truncated_import, photo_count, failed_writeback_count, created_at, updated_at)
            VALUES (?, ?, 'draft', 'idle', 'idle', ?, ?, ?, 0, 0, ?, ?)
            """,
            [.text(id), .text(name), .text(source), .text(sourcePath), .int(truncatedImport ? 1 : 0), .text(now), .text(now)]
        )
        guard let record = try await get(id: id) else {
            throw SQLiteFailure(phase: .other, code: 0, extended: 0, message: "session row missing after insert: \(id)")
        }
        return record
    }

    public func list() async throws -> [SessionRecord] {
        try await database.query("SELECT * FROM sessions ORDER BY updated_at DESC")
            .map { try $0.decode(SessionRecord.self) }
    }

    public func delete(id: String) async throws -> Bool {
        try await database.run("DELETE FROM sessions WHERE id = ?", [.text(id)]) > 0
    }

    public func deleteMany(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        try await database.transaction { db in
            for id in ids {
                try db.run("DELETE FROM sessions WHERE id = ?", [.text(id)])
            }
        }
        return ids.count
    }

    public func deleteSimilarityData(sessionId: String) async throws {
        try await database.transaction { db in
            try db.run("DELETE FROM similarity_results WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM similarity_hashes WHERE session_id = ?", [.text(sessionId)])
        }
    }

    public func updateName(id: String, name: String) async throws -> Bool {
        try await database.run(
            "UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?",
            [.text(name), .text(nowISOString()), .text(id)]
        ) > 0
    }

    public func updateSourcePath(id: String, sourcePath: String) async throws -> Bool {
        try await database.run(
            "UPDATE sessions SET source_path = ?, updated_at = ? WHERE id = ?",
            [.text(sourcePath), .text(nowISOString()), .text(id)]
        ) > 0
    }

    public func updateStatus(id: String, status: String) async throws {
        try await database.run(
            "UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?",
            [.text(status), .text(nowISOString()), .text(id)]
        )
    }

    public func updatePhotoCount(id: String, count: Int) async throws {
        try await database.run(
            "UPDATE sessions SET photo_count = ?, updated_at = ? WHERE id = ?",
            [.int(Int64(count)), .text(nowISOString()), .text(id)]
        )
    }

    public func updateAnalysisStatus(id: String, status: String) async throws {
        try await database.run(
            "UPDATE sessions SET analysis_status = ?, updated_at = ? WHERE id = ?",
            [.text(status), .text(nowISOString()), .text(id)]
        )
    }

    public func updateWritebackStatus(id: String, status: String) async throws {
        try await database.run(
            "UPDATE sessions SET writeback_status = ?, updated_at = ? WHERE id = ?",
            [.text(status), .text(nowISOString()), .text(id)]
        )
    }

    public func updateFailedWritebackCount(id: String, count: Int) async throws {
        try await database.run(
            "UPDATE sessions SET failed_writeback_count = ?, updated_at = ? WHERE id = ?",
            [.int(Int64(count)), .text(nowISOString()), .text(id)]
        )
    }

    public func reloadAckedAt(sessionId: String) async throws -> String? {
        try await database.queryOne("SELECT reload_acked_at FROM sessions WHERE id = ?", [.text(sessionId)])?
            .text("reload_acked_at")
    }

    public func setReloadAckedAt(sessionId: String, iso: String) async throws -> Bool {
        try await database.run(
            "UPDATE sessions SET reload_acked_at = ?, updated_at = ? WHERE id = ?",
            [.text(iso), .text(nowISOString()), .text(sessionId)]
        ) > 0
    }

    /// W4-1c：metadata_outbox_sessions → sessions 批量清 reload_acked_at。
    /// 单事务内按 800 分块（SQLite 变量上限），只清实际有值的行，
    /// 返回清除行数（重复调用第二次为 0）。
    public func clearReloadAckedAtForXmpPaths(_ paths: [String]) async throws -> Int {
        guard !paths.isEmpty else { return 0 }
        let now = nowISOString()
        return try await database.transaction { db in
            var cleared = 0
            for chunk in paths.chunked(by: 800) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                cleared += try db.run(
                    """
                    UPDATE sessions SET reload_acked_at = NULL, updated_at = ?
                    WHERE reload_acked_at IS NOT NULL
                      AND id IN (
                        SELECT os.session_id FROM metadata_outbox_sessions os
                        WHERE os.xmp_path IN (\(placeholders))
                      )
                    """,
                    [.text(now)] + chunk.map { .text($0) }
                )
            }
            return cleared
        }
    }

    public func indexSeq(id: String) async throws -> Int {
        Int(try await database.scalarInt("SELECT index_seq FROM sessions WHERE id = ?", [.text(id)]) ?? 0)
    }

    public func bumpIndexSeq(id: String) async throws -> Int {
        try await database.transaction { db in
            try db.run(
                "UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?",
                [.text(nowISOString()), .text(id)]
            )
            return Int(try db.scalarInt("SELECT index_seq FROM sessions WHERE id = ?", [.text(id)]) ?? 0)
        }
    }
}
