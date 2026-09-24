// Store/DuplicateStore.swift
// R1：photos 校验列 / similarity_hashes / duplicate_groups / duplicate_group_members
// 的唯一访问入口（从 Services/DuplicateService.swift 抽出 SQL；聚类与评分留在服务层）。
import Foundation

public enum DuplicateStoreError: Error, Equatable, Sendable {
    case groupNotFound(Int)
    case memberNotFound(Int)
}

public struct DuplicatePhotoRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let filepath: String
    public let checksum: String
    public let checksumFileSize: Int64
    public let checksumFileMtimeMs: Double

    enum CodingKeys: String, CodingKey {
        case id, filepath, checksum
        case checksumFileSize = "checksum_file_size"
        case checksumFileMtimeMs = "checksum_file_mtime_ms"
    }
}

public struct DuplicateVisualHashRecord: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int64
    public let fileMtimeMs: Double
}

public struct DuplicateHashPair: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
}

public struct DuplicateExactGroupInput: Equatable, Sendable {
    public let checksum: String
    public let photoIds: [String]

    public init(checksum: String, photoIds: [String]) {
        self.checksum = checksum
        self.photoIds = photoIds
    }
}

public struct DuplicateVisualGroupInput: Equatable, Sendable {
    public let hashHex: String
    public let photoIds: [String]

    public init(hashHex: String, photoIds: [String]) {
        self.hashHex = hashHex
        self.photoIds = photoIds
    }
}

public struct DuplicateFileInfo: Equatable, Sendable {
    public let size: Int64
    public let mtimeISO: String

    public init(size: Int64, mtimeISO: String) {
        self.size = size
        self.mtimeISO = mtimeISO
    }
}

public struct DuplicateChecksumUpdate: Equatable, Sendable {
    public let photoId: String
    public let checksum: String
    public let fileSize: Int64
    public let fileMtimeMs: Double

    public init(photoId: String, checksum: String, fileSize: Int64, fileMtimeMs: Double) {
        self.photoId = photoId
        self.checksum = checksum
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

public struct DuplicateHashUpsert: Equatable, Sendable {
    public let photoId: String
    public let hashHex: String
    public let fileSize: Int64
    public let fileMtimeMs: Double

    public init(photoId: String, hashHex: String, fileSize: Int64, fileMtimeMs: Double) {
        self.photoId = photoId
        self.hashHex = hashHex
        self.fileSize = fileSize
        self.fileMtimeMs = fileMtimeMs
    }
}

public struct DuplicateGroupRecord: Decodable, Equatable, Sendable {
    public let id: Int
    public let sessionId: String
    public let groupType: String
    public let checksum: String?
    public let hashHex: String?
    public let memberCount: Int
    public let resolution: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, checksum, resolution
        case sessionId = "session_id"
        case groupType = "group_type"
        case hashHex = "hash_hex"
        case memberCount = "member_count"
        case createdAt = "created_at"
    }
}

public struct DuplicateGroupMemberRecord: Decodable, Equatable, Sendable {
    public let id: Int
    public let groupId: Int
    public let photoId: String
    public let sessionId: String
    public let isKept: Bool
    public let fileSize: Int64?
    public let fileMtime: String?
    public let resolution: String?

    enum CodingKeys: String, CodingKey {
        case id, resolution
        case groupId = "group_id"
        case photoId = "photo_id"
        case sessionId = "session_id"
        case isKept = "is_kept"
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
    }
}

/// W2c：duplicate_group_members JOIN photos 的行（现有 members* 不含
/// filepath/filename，无法装配 DuplicateGroupMember DTO）。
public struct DuplicateGroupMemberPhotoRecord: Decodable, Equatable, Sendable {
    public let id: Int
    public let groupId: Int
    public let photoId: String
    public let sessionId: String
    public let isKept: Bool
    public let fileSize: Int64?
    public let fileMtime: String?
    public let resolution: String?
    public let filepath: String
    public let filename: String

    enum CodingKeys: String, CodingKey {
        case id, resolution, filepath, filename
        case groupId = "group_id"
        case photoId = "photo_id"
        case sessionId = "session_id"
        case isKept = "is_kept"
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
    }
}

public protocol DuplicateStore: Sendable {
    func photos(sessionId: String) async throws -> [DuplicatePhotoRecord]
    func visualHashes(sessionId: String) async throws -> [DuplicateVisualHashRecord]
    func writeScanResults(
        sessionId: String,
        checksums: [DuplicateChecksumUpdate],
        visualHashes: [DuplicateHashUpsert]
    ) async throws
    func exactDuplicateGroups(sessionId: String) async throws -> [DuplicateExactGroupInput]
    func hashesForClustering(sessionId: String) async throws -> [DuplicateHashPair]
    func rebuildGroups(
        sessionId: String,
        exact: [DuplicateExactGroupInput],
        visual: [DuplicateVisualGroupInput],
        fileInfo: [String: DuplicateFileInfo],
        createdAt: String
    ) async throws -> (exact: [Int], visual: [Int])
    func groups(sessionId: String) async throws -> [DuplicateGroupRecord]
    /// W2c：按 id 批量读组（ORDER BY id）；空参数/无匹配返回 []。
    func groups(ids: [Int]) async throws -> [DuplicateGroupRecord]
    func members(groupIds: [Int]) async throws -> [Int: [DuplicateGroupMemberRecord]]
    /// W2c：按组批量读成员（JOIN photos 取 filepath/filename，ORDER BY dgm.id）；
    /// 空参数返回 [:]。
    func membersWithPhoto(groupIds: [Int]) async throws -> [Int: [DuplicateGroupMemberPhotoRecord]]
    func members(groupId: Int) async throws -> [DuplicateGroupMemberRecord]
    func applyResolution(groupId: Int, resolution: String, keptMemberIds: Set<Int>) async throws
    func resolveMember(memberId: Int, isKept: Bool) async throws -> String
    func recomputePhotoStatuses(_ photoIds: [String]) async throws
}

public struct SQLiteDuplicateStore: DuplicateStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func photos(sessionId: String) async throws -> [DuplicatePhotoRecord] {
        try await database.query(
            """
            SELECT id, filepath, checksum, checksum_file_size, checksum_file_mtime_ms
            FROM photos WHERE session_id IN (?)
            """,
            [.text(sessionId)]
        ).map { try $0.decode(DuplicatePhotoRecord.self) }
    }

    public func visualHashes(sessionId: String) async throws -> [DuplicateVisualHashRecord] {
        try await database.query(
            """
            SELECT photo_id, hash_hex, file_size, file_mtime_ms
            FROM similarity_hashes WHERE session_id IN (?)
            """,
            [.text(sessionId)]
        ).map {
            DuplicateVisualHashRecord(
                photoId: $0.text("photo_id") ?? "",
                hashHex: $0.text("hash_hex") ?? "",
                fileSize: $0.int("file_size") ?? 0,
                fileMtimeMs: $0.double("file_mtime_ms") ?? 0
            )
        }
    }

    /// checksum 回写 + similarity_hashes UPSERT（单事务）。
    public func writeScanResults(
        sessionId: String,
        checksums: [DuplicateChecksumUpdate],
        visualHashes: [DuplicateHashUpsert]
    ) async throws {
        try await database.transaction { db in
            for update in checksums {
                try db.run(
                    """
                    UPDATE photos
                    SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
                    WHERE id = ?
                    """,
                    [.text(update.checksum), .int(update.fileSize), .real(update.fileMtimeMs), .text(update.photoId)]
                )
            }
            for hash in visualHashes {
                try db.run(
                    """
                    INSERT INTO similarity_hashes
                      (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(session_id, photo_id) DO UPDATE SET
                      hash_hex = excluded.hash_hex,
                      file_size = excluded.file_size,
                      file_mtime_ms = excluded.file_mtime_ms
                    """,
                    [.text(sessionId), .text(hash.photoId), .text(hash.hashHex), .int(hash.fileSize), .real(hash.fileMtimeMs)]
                )
            }
        }
    }

    /// 精确重复分组（按 checksum）；分组在 Swift 侧聚合，避免 GROUP_CONCAT 截断。
    public func exactDuplicateGroups(sessionId: String) async throws -> [DuplicateExactGroupInput] {
        let rows = try await database.query(
            """
            SELECT checksum, id FROM photos
            WHERE session_id IN (?) AND checksum != ''
            ORDER BY checksum, id
            """,
            [.text(sessionId)]
        )
        var groups: [DuplicateExactGroupInput] = []
        var currentChecksum: String?
        var currentIds: [String] = []
        for row in rows {
            let checksum = row.text("checksum") ?? ""
            if checksum != currentChecksum {
                if let currentChecksum, currentIds.count > 1 {
                    groups.append(DuplicateExactGroupInput(checksum: currentChecksum, photoIds: currentIds))
                }
                currentChecksum = checksum
                currentIds = []
            }
            currentIds.append(row.text("id") ?? "")
        }
        if let currentChecksum, currentIds.count > 1 {
            groups.append(DuplicateExactGroupInput(checksum: currentChecksum, photoIds: currentIds))
        }
        return groups
    }

    public func hashesForClustering(sessionId: String) async throws -> [DuplicateHashPair] {
        try await database.query(
            """
            SELECT sh.photo_id, sh.hash_hex
            FROM similarity_hashes sh
            JOIN photos p ON p.id = sh.photo_id
            WHERE p.session_id IN (?)
            ORDER BY sh.photo_id
            """,
            [.text(sessionId)]
        ).map { DuplicateHashPair(photoId: $0.text("photo_id") ?? "", hashHex: $0.text("hash_hex") ?? "") }
    }

    /// 重建分组：removed → ready 复位、旧组整删、按输入重插（单事务，幂等）。
    public func rebuildGroups(
        sessionId: String,
        exact: [DuplicateExactGroupInput],
        visual: [DuplicateVisualGroupInput],
        fileInfo: [String: DuplicateFileInfo],
        createdAt: String
    ) async throws -> (exact: [Int], visual: [Int]) {
        try await database.transaction { db in
            try db.run(
                """
                UPDATE photos
                SET status = 'ready'
                WHERE id IN (
                  SELECT photo_id FROM duplicate_group_members WHERE session_id IN (?)
                )
                AND status = 'removed'
                """,
                [.text(sessionId)]
            )
            try db.run("DELETE FROM duplicate_group_members WHERE session_id IN (?)", [.text(sessionId)])
            try db.run("DELETE FROM duplicate_groups WHERE session_id IN (?)", [.text(sessionId)])

            var exactGroupIds: [Int] = []
            for group in exact {
                try db.run(
                    """
                    INSERT INTO duplicate_groups
                      (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at)
                    VALUES (?, 'exact', ?, NULL, ?, NULL, ?)
                    """,
                    [.text(sessionId), .text(group.checksum), .int(Int64(group.photoIds.count)), .text(createdAt)]
                )
                let groupId = Int(db.lastInsertRowID)
                exactGroupIds.append(groupId)
                try Self.insertMembers(
                    db, groupId: groupId, sessionId: sessionId,
                    photoIds: group.photoIds, fileInfo: fileInfo
                )
            }

            var visualGroupIds: [Int] = []
            for group in visual {
                try db.run(
                    """
                    INSERT INTO duplicate_groups
                      (session_id, group_type, checksum, hash_hex, member_count, resolution, created_at)
                    VALUES (?, 'visual', NULL, ?, ?, NULL, ?)
                    """,
                    [.text(sessionId), .text(group.hashHex), .int(Int64(group.photoIds.count)), .text(createdAt)]
                )
                let groupId = Int(db.lastInsertRowID)
                visualGroupIds.append(groupId)
                try Self.insertMembers(
                    db, groupId: groupId, sessionId: sessionId,
                    photoIds: group.photoIds, fileInfo: fileInfo
                )
            }
            return (exactGroupIds, visualGroupIds)
        }
    }

    public func groups(sessionId: String) async throws -> [DuplicateGroupRecord] {
        try await database.query(
            "SELECT * FROM duplicate_groups WHERE session_id = ? ORDER BY group_type, id",
            [.text(sessionId)]
        ).map { try $0.decode(DuplicateGroupRecord.self) }
    }

    /// 组行批量读（按 id 升序；跨块拼接后统一排序去重）。
    public func groups(ids: [Int]) async throws -> [DuplicateGroupRecord] {
        guard !ids.isEmpty else { return [] }
        var records: [DuplicateGroupRecord] = []
        var seen = Set<Int>()
        for chunk in ids.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                "SELECT * FROM duplicate_groups WHERE id IN (\(placeholders)) ORDER BY id",
                chunk.map { .int(Int64($0)) }
            )
            for row in rows {
                let record = try row.decode(DuplicateGroupRecord.self)
                if seen.insert(record.id).inserted {
                    records.append(record)
                }
            }
        }
        return records.sorted { $0.id < $1.id }
    }

    /// 成员行 + photos.filepath/filename（按 dgm.id 升序；每组成员独立排序）。
    public func membersWithPhoto(groupIds: [Int]) async throws -> [Int: [DuplicateGroupMemberPhotoRecord]] {
        guard !groupIds.isEmpty else { return [:] }
        var result: [Int: [DuplicateGroupMemberPhotoRecord]] = [:]
        for chunk in groupIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT dgm.*, p.filepath, p.filename
                FROM duplicate_group_members dgm
                JOIN photos p ON p.id = dgm.photo_id
                WHERE dgm.group_id IN (\(placeholders))
                ORDER BY dgm.id
                """,
                chunk.map { .int(Int64($0)) }
            )
            for row in rows {
                let member = try row.decode(DuplicateGroupMemberPhotoRecord.self)
                result[member.groupId, default: []].append(member)
            }
        }
        for (groupId, members) in result {
            var seen = Set<Int>()
            result[groupId] = members
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.id < $1.id }
        }
        return result
    }

    public func members(groupIds: [Int]) async throws -> [Int: [DuplicateGroupMemberRecord]] {
        guard !groupIds.isEmpty else { return [:] }
        var result: [Int: [DuplicateGroupMemberRecord]] = [:]
        for chunk in groupIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                "SELECT * FROM duplicate_group_members WHERE group_id IN (\(placeholders)) ORDER BY id",
                chunk.map { .int(Int64($0)) }
            )
            for row in rows {
                let member = try row.decode(DuplicateGroupMemberRecord.self)
                result[member.groupId, default: []].append(member)
            }
        }
        return result
    }

    public func members(groupId: Int) async throws -> [DuplicateGroupMemberRecord] {
        try await database.query(
            "SELECT * FROM duplicate_group_members WHERE group_id = ? ORDER BY id",
            [.int(Int64(groupId))]
        ).map { try $0.decode(DuplicateGroupMemberRecord.self) }
    }

    /// 组决议落库：组 resolution + 成员 is_kept/resolution + 照片状态重算（单事务）。
    public func applyResolution(groupId: Int, resolution: String, keptMemberIds: Set<Int>) async throws {
        try await database.transaction { db in
            let members = try db.query(
                "SELECT id, photo_id FROM duplicate_group_members WHERE group_id = ?",
                [.int(Int64(groupId))]
            )
            if members.isEmpty { throw DuplicateStoreError.groupNotFound(groupId) }
            try db.run(
                "UPDATE duplicate_groups SET resolution = ? WHERE id = ?",
                [.text(resolution), .int(Int64(groupId))]
            )
            for member in members {
                let memberId = Int(member.int("id") ?? 0)
                try db.run(
                    "UPDATE duplicate_group_members SET is_kept = ?, resolution = ? WHERE id = ?",
                    [
                        .int(keptMemberIds.contains(memberId) ? 1 : 0),
                        .text(resolution), .int(Int64(memberId)),
                    ]
                )
            }
            try Self.recomputePhotoStatuses(db, members.compactMap { $0.text("photo_id") })
        }
    }

    /// 单成员保留/移除；resolution 仅在未定时写入。返回成员对应 photoId。
    public func resolveMember(memberId: Int, isKept: Bool) async throws -> String {
        try await database.transaction { db -> String in
            try db.run(
                """
                UPDATE duplicate_group_members
                SET is_kept = ?, resolution = COALESCE(resolution, ?)
                WHERE id = ?
                """,
                [
                    .int(isKept ? 1 : 0),
                    .text(isKept ? "keep_all" : "keep_one"),
                    .int(Int64(memberId)),
                ]
            )
            guard let photoId = try db.queryOne(
                "SELECT photo_id FROM duplicate_group_members WHERE id = ?",
                [.int(Int64(memberId))]
            )?.text("photo_id") else {
                throw DuplicateStoreError.memberNotFound(memberId)
            }
            try Self.recomputePhotoStatuses(db, [photoId])
            return photoId
        }
    }

    public func recomputePhotoStatuses(_ photoIds: [String]) async throws {
        try await database.transaction { db in
            try Self.recomputePhotoStatuses(db, photoIds)
        }
    }

    // MARK: 私有

    private static func insertMembers(
        _ db: isolated SQLiteDatabase,
        groupId: Int,
        sessionId: String,
        photoIds: [String],
        fileInfo: [String: DuplicateFileInfo]
    ) throws {
        for photoId in photoIds {
            let info = fileInfo[photoId]
            try db.run(
                """
                INSERT INTO duplicate_group_members
                  (group_id, photo_id, session_id, is_kept, file_size, file_mtime)
                VALUES (?, ?, ?, 1, ?, ?)
                """,
                [
                    .int(Int64(groupId)), .text(photoId), .text(sessionId),
                    info.map { SQLiteValue.int($0.size) } ?? .null,
                    info.map { SQLiteValue.text($0.mtimeISO) } ?? .null,
                ]
            )
        }
    }

    /// 任一 is_kept=0 成员 → 'removed'，否则 'ready'。
    internal static func recomputePhotoStatuses(
        _ db: isolated SQLiteDatabase,
        _ photoIds: [String]
    ) throws {
        guard !photoIds.isEmpty else { return }
        var seen = Set<String>()
        let uniqueIds = photoIds.filter { seen.insert($0).inserted }
        let placeholders = uniqueIds.map { _ in "?" }.joined(separator: ",")
        try db.run(
            """
            UPDATE photos
            SET status = CASE
              WHEN EXISTS (
                SELECT 1 FROM duplicate_group_members dgm
                WHERE dgm.photo_id = photos.id AND dgm.is_kept = 0
              ) THEN 'removed'
              ELSE 'ready'
            END
            WHERE id IN (\(placeholders))
            """,
            uniqueIds.map { .text($0) }
        )
    }
}
