// Store/PhotoStore.swift
// R1：photos 的唯一访问入口（取代 Database/Repositories/PhotoRepo.swift）。
import Foundation

public struct PhotoRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let checksumFileSize: Int
    public let checksumFileMtimeMs: Double
    public let status: String
    public let metadata: String
    public let result: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, filepath, filename, checksum, status, metadata, result, width, height
        case sessionId = "session_id"
        case checksumFileSize = "checksum_file_size"
        case checksumFileMtimeMs = "checksum_file_mtime_ms"
        case assetId = "asset_id"
        case assetFileId = "asset_file_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 轻投影：不含 metadata/result。
public struct PhotoProjection: Decodable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let checksumFileSize: Int
    public let checksumFileMtimeMs: Double
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, filepath, filename, checksum, status, width, height
        case sessionId = "session_id"
        case checksumFileSize = "checksum_file_size"
        case checksumFileMtimeMs = "checksum_file_mtime_ms"
        case assetId = "asset_id"
        case assetFileId = "asset_file_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 键集分页行。键行解码使尾部重列（metadata/result/checksum 三件套）
/// 在查询未选中时自然为 nil，无需旧 PhotoPageRow 的位置长度判断。
public struct PhotoPage: Decodable, Equatable, Sendable {
    public let rowid: Int64
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let checksum: String?
    public let createdAt: String
    public let updatedAt: String
    public let metadata: String?
    public let result: String?
    public let checksumFileSize: Int?
    public let checksumFileMtimeMs: Double?

    enum CodingKeys: String, CodingKey {
        case rowid, id, filepath, filename, status, width, height, checksum, metadata, result
        case sessionId = "session_id"
        case assetId = "asset_id"
        case assetFileId = "asset_file_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case checksumFileSize = "checksum_file_size"
        case checksumFileMtimeMs = "checksum_file_mtime_ms"
    }
}

public struct PhotoAddInput: Sendable {
    public let filepath: String
    public let width: Int
    public let height: Int

    public init(filepath: String, width: Int, height: Int) {
        self.filepath = filepath
        self.width = width
        self.height = height
    }
}

public struct PhotoAddResult: Equatable, Sendable {
    public let added: Int
    public let skipped: Int
    public let ids: [String]

    public init(added: Int, skipped: Int, ids: [String]) {
        self.added = added
        self.skipped = skipped
        self.ids = ids
    }
}

public protocol PhotoStore: Sendable {
    func getBySession(sessionId: String) async throws -> [PhotoRecord]
    func getBySessionProjection(sessionId: String) async throws -> [PhotoProjection]
    func getBySessionPage(sessionId: String, afterRowId: Int64?, limit: Int) async throws -> [PhotoPage]
    func countBySession(sessionId: String) async throws -> Int
    func getAssetPage(sessionId: String, afterFirstRowid: Int64?, limit: Int) async throws -> (rows: [PhotoPage], cursor: Int64?)
    func countAssetsBySession(sessionId: String) async throws -> Int
    func containsFilepath(filepath: String) async throws -> Bool
    /// W2c：会话照片 → asset_file_id 映射（跳过 NULL；空串保留，与旧内联查询一致）。
    func assetFileIdsByPhoto(sessionId: String) async throws -> [String: String]
    func addPhotos(sessionId: String, inputs: [PhotoAddInput], source: String) async throws -> PhotoAddResult
    func deleteBySession(sessionId: String) async throws
    func updateIndexedFile(photoId: String, width: Int, height: Int, changed: Bool) async throws
    func updateChecksum(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double) async throws
    func markMissing(photoIds: [String]) async throws
}

public extension PhotoStore {
    func getBySessionPage(sessionId: String) async throws -> [PhotoPage] {
        try await getBySessionPage(sessionId: sessionId, afterRowId: nil, limit: 200)
    }

    func getAssetPage(sessionId: String) async throws -> (rows: [PhotoPage], cursor: Int64?) {
        try await getAssetPage(sessionId: sessionId, afterFirstRowid: nil, limit: 200)
    }
}

public struct SQLitePhotoStore: PhotoStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func getBySession(sessionId: String) async throws -> [PhotoRecord] {
        try await database.query("SELECT * FROM photos WHERE session_id = ? ORDER BY rowid", [.text(sessionId)])
            .map { try $0.decode(PhotoRecord.self) }
    }

    public func getBySessionProjection(sessionId: String) async throws -> [PhotoProjection] {
        try await database.query(
            """
            SELECT id, session_id, filepath, filename, checksum, checksum_file_size,
                   checksum_file_mtime_ms, status, asset_id, asset_file_id, width, height,
                   created_at, updated_at
            FROM photos WHERE session_id = ? ORDER BY rowid
            """,
            [.text(sessionId)]
        ).map { try $0.decode(PhotoProjection.self) }
    }

    public func getBySessionPage(sessionId: String, afterRowId: Int64?, limit: Int = 200) async throws -> [PhotoPage] {
        let rows: [SQLiteRow]
        if let afterRowId {
            rows = try await database.query(
                "SELECT \(PhotoFormats.pageColumns) FROM photos p WHERE p.session_id = ? AND p.rowid > ? ORDER BY p.rowid LIMIT ?",
                [.text(sessionId), .int(afterRowId), .int(Int64(limit))]
            )
        } else {
            rows = try await database.query(
                "SELECT \(PhotoFormats.pageColumns) FROM photos p WHERE p.session_id = ? ORDER BY p.rowid LIMIT ?",
                [.text(sessionId), .int(Int64(limit))]
            )
        }
        return try rows.map { try $0.decode(PhotoPage.self) }
    }

    public func countBySession(sessionId: String) async throws -> Int {
        Int(try await database.scalarInt("SELECT COUNT(*) AS count FROM photos WHERE session_id = ?", [.text(sessionId)]) ?? 0)
    }

    /// 按逻辑资产分组分页（RAW/JPEG 变体同页）。两分支 UNION 走
    /// idx_photos_asset_group 覆盖索引，避免表达式分组全表扫描。
    public func getAssetPage(
        sessionId: String,
        afterFirstRowid: Int64? = nil,
        limit: Int = 200
    ) async throws -> (rows: [PhotoPage], cursor: Int64?) {
        let groups = try await database.query(
            """
            SELECT gid, MIN(first_rowid) AS first_rowid FROM (
              SELECT asset_id AS gid, MIN(rowid) AS first_rowid
                FROM photos WHERE session_id = ? AND asset_id IS NOT NULL
                GROUP BY asset_id
              UNION ALL
              SELECT id AS gid, rowid AS first_rowid
                FROM photos WHERE session_id = ? AND asset_id IS NULL
            )
            GROUP BY gid
            HAVING MIN(first_rowid) > ?
            ORDER BY MIN(first_rowid)
            LIMIT ?
            """,
            [.text(sessionId), .text(sessionId), .int(afterFirstRowid ?? 0), .int(Int64(limit))]
        )
        if groups.isEmpty { return ([], nil) }

        let gids = groups.map { (gid: $0.text("gid") ?? "", firstRowid: $0.int("first_rowid") ?? 0) }
        var rows: [PhotoPage] = []
        for chunkStart in stride(from: 0, to: gids.count, by: 800) {
            let chunk = gids[chunkStart..<min(chunkStart + 800, gids.count)].map { $0.gid }
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let chunkRows = try await database.query(
                """
                SELECT \(PhotoFormats.pageColumns) FROM photos p
                WHERE p.session_id = ? AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (\(placeholders))
                ORDER BY p.rowid
                """,
                [.text(sessionId)] + chunk.map { .text($0) }
            )
            rows.append(contentsOf: try chunkRows.map { try $0.decode(PhotoPage.self) })
        }
        return (rows, gids[gids.count - 1].firstRowid)
    }

    public func countAssetsBySession(sessionId: String) async throws -> Int {
        Int(try await database.scalarInt(
            """
            SELECT COUNT(*) AS count FROM (
              SELECT COALESCE(NULLIF(asset_id, ''), id) AS gid FROM photos WHERE session_id = ? GROUP BY gid
            )
            """,
            [.text(sessionId)]
        ) ?? 0)
    }

    public func containsFilepath(filepath: String) async throws -> Bool {
        try await database.queryOne("SELECT 1 FROM photos WHERE filepath = ? LIMIT 1", [.text(filepath)]) != nil
    }

    /// W2c：原 SimilarityService.reuseSimilarityHashes 开头内联查询的 Store 化。
    public func assetFileIdsByPhoto(sessionId: String) async throws -> [String: String] {
        let rows = try await database.query(
            "SELECT id, asset_file_id FROM photos WHERE session_id = ? AND asset_file_id IS NOT NULL",
            [.text(sessionId)]
        )
        var assetFileByPhoto: [String: String] = [:]
        for row in rows {
            guard let id = row.text("id"), let assetFileId = row.text("asset_file_id") else { continue }
            assetFileByPhoto[id] = assetFileId
        }
        return assetFileByPhoto
    }

    public func addPhotos(sessionId: String, inputs: [PhotoAddInput], source: String) async throws -> PhotoAddResult {
        let now = nowISOString()
        return try await database.transaction { db in
            var added = 0
            var skipped = 0
            var ids: [String] = []
            for input in inputs {
                let exists = try db.queryOne(
                    "SELECT 1 FROM photos WHERE session_id = ? AND filepath = ? LIMIT 1",
                    [.text(sessionId), .text(input.filepath)]
                ) != nil
                if exists {
                    skipped += 1
                    ids.append("")
                    continue
                }
                let filename = input.filepath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
                    ?? input.filepath
                let id = newUUIDString()
                let changes = try db.run(
                    """
                    INSERT OR IGNORE INTO photos
                      (id, session_id, filepath, filename, checksum, status, metadata, result,
                       width, height, created_at, updated_at)
                    VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?, ?, ?)
                    """,
                    [
                        .text(id), .text(sessionId), .text(input.filepath), .text(filename),
                        .int(Int64(input.width)), .int(Int64(input.height)), .text(now), .text(now),
                    ]
                )
                if changes > 0 {
                    added += 1
                    ids.append(id)
                } else {
                    skipped += 1
                    ids.append("")
                }
            }
            return PhotoAddResult(added: added, skipped: skipped, ids: ids)
        }
    }

    public func deleteBySession(sessionId: String) async throws {
        try await database.run("DELETE FROM photos WHERE session_id = ?", [.text(sessionId)])
    }

    public func updateIndexedFile(photoId: String, width: Int, height: Int, changed: Bool) async throws {
        let flag = Int64(changed ? 1 : 0)
        try await database.run(
            """
            UPDATE photos SET width = ?, height = ?, status = 'pending',
              checksum = CASE WHEN ? THEN '' ELSE checksum END,
              checksum_file_size = CASE WHEN ? THEN 0 ELSE checksum_file_size END,
              checksum_file_mtime_ms = CASE WHEN ? THEN 0 ELSE checksum_file_mtime_ms END,
              updated_at = ?
            WHERE id = ?
            """,
            [.int(Int64(width)), .int(Int64(height)), .int(flag), .int(flag), .int(flag), .text(nowISOString()), .text(photoId)]
        )
    }

    public func updateChecksum(photoId: String, checksum: String, fileSize: Int, fileMtimeMs: Double) async throws {
        try await database.run(
            "UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?, updated_at = ? WHERE id = ?",
            [.text(checksum), .int(Int64(fileSize)), .real(fileMtimeMs), .text(nowISOString()), .text(photoId)]
        )
    }

    public func markMissing(photoIds: [String]) async throws {
        guard !photoIds.isEmpty else { return }
        try await database.transaction { db in
            let now = nowISOString()
            for id in photoIds {
                try db.run("UPDATE photos SET status = 'missing', updated_at = ? WHERE id = ?", [.text(now), .text(id)])
            }
        }
    }
}
