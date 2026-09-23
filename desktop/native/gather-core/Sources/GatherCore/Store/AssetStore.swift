// Store/AssetStore.swift
// R1：asset_files / asset_members / asset_link_candidates / session_assets 的访问入口
// （取代 Database/Repositories/AssetRepo.swift；本轮先落只读查询面，
//  backfill/relink/reconcile 变更面随后并入同一 Store）。
import Foundation

public struct AssetFileRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let volumeId: String
    public let fileIdentity: String
    public let normalizedPath: String
    public let filename: String
    public let fileExtension: String
    public let mediaType: String
    public let fileSize: Int64
    public let fileMtimeMs: Double
    public let checksum: String
    public let onlineStatus: String
    public let lastSeenAt: String
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, filename, checksum
        case volumeId = "volume_id"
        case fileIdentity = "file_identity"
        case normalizedPath = "normalized_path"
        case fileExtension = "extension"
        case mediaType = "media_type"
        case fileSize = "file_size"
        case fileMtimeMs = "file_mtime_ms"
        case onlineStatus = "online_status"
        case lastSeenAt = "last_seen_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public protocol AssetStore: Sendable {
    /// 批量照片的 asset_members 角色映射（photo.id → member_role；未关联为 "unknown"）。
    func memberRoles(sessionId: String, photoIds: [String]) async throws -> [String: String]
    func listCandidates(sessionId: String?) async throws -> [AssetLinkCandidateData]
    func listVolumes() async throws -> [AssetVolumeData]
    func assetFile(id: String) async throws -> AssetFileRecord?

    // MARK: 变更面（relink / 候选 / 对账）

    func relinkRoot(oldRoot: String, newRoot: String) async throws -> AssetRelinkRootResult
    func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        fileIdentity: String
    ) async throws -> AssetRelinkFileResult?
    func acceptCandidate(_ candidateId: String) async throws
    func rejectCandidate(_ candidateId: String) async throws
    func reconcileRawJpegLinks(sessionId: String) async throws -> Int64

    // MARK: 回填

    func backfillSession(_ sessionId: String) async throws -> AssetBackfillResult
}

public struct AssetBackfillResult: Equatable, Sendable {
    public let migrated: Int64
    public let offline: Int64
    public let candidates: Int64

    public init(migrated: Int64, offline: Int64, candidates: Int64) {
        self.migrated = migrated
        self.offline = offline
        self.candidates = candidates
    }
}

public struct PhotoBackfillRecord: Decodable, Equatable, Sendable {
    public let migrationRowid: Int64
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case id, filepath, filename, checksum, status
        case migrationRowid = "migration_rowid"
        case sessionId = "session_id"
    }
}

struct AssetRawJpegFile: Equatable, Sendable {
    let id: String
    let filename: String
    let normalizedPath: String
    let fileExtension: String
}

public enum AssetStoreError: Error, Equatable, CustomStringConvertible, Sendable {
    case candidateNotFound
    case fileNotLinked
    case relinkXMPBusy
    case relinkOutboxConflict
    case relinkXMPConflict

    public var description: String {
        switch self {
        case .candidateNotFound: return "ASSET_LINK_CANDIDATE_NOT_FOUND"
        case .fileNotLinked: return "ASSET_FILE_NOT_LINKED"
        case .relinkXMPBusy: return "ASSET_RELINK_XMP_BUSY"
        case .relinkOutboxConflict: return "ASSET_RELINK_OUTBOX_CONFLICT"
        case .relinkXMPConflict: return "ASSET_RELINK_XMP_CONFLICT"
        }
    }
}

public struct AssetRelinkRootResult: Equatable, Sendable {
    public let relocatedFiles: Int
    /// 需要通知 MetadataSyncCoordinator 的新 XMP 路径（旧实现用可变 sink 回调）。
    public let relocatedOutboxPaths: [String]

    public init(relocatedFiles: Int, relocatedOutboxPaths: [String]) {
        self.relocatedFiles = relocatedFiles
        self.relocatedOutboxPaths = relocatedOutboxPaths
    }
}

public struct AssetRelinkFileResult: Equatable, Sendable {
    public let fileId: String
    public let photoIds: [String]
    public let relocatedOutboxPath: String?

    public init(fileId: String, photoIds: [String], relocatedOutboxPath: String?) {
        self.fileId = fileId
        self.photoIds = photoIds
        self.relocatedOutboxPath = relocatedOutboxPath
    }
}

struct AssetFileRef: Equatable, Sendable {
    let id: String
    let normalizedPath: String
}

struct AssetCandidateLite: Equatable, Sendable {
    let leftFileId: String
    let rightFileId: String
    let status: String
}

struct AssetSidecarState: Equatable, Sendable {
    let rating: Int64?
    let label: String?
    let keywords: String
    let fingerprint: String
}

public extension AssetStore {
    func listCandidates() async throws -> [AssetLinkCandidateData] {
        try await listCandidates(sessionId: nil)
    }
}

public struct SQLiteAssetStore: AssetStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func memberRoles(sessionId: String, photoIds: [String]) async throws -> [String: String] {
        guard !photoIds.isEmpty else { return [:] }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query(
            """
            SELECT p.id AS photo_id, am.member_role
            FROM photos p
            LEFT JOIN asset_members am ON am.file_id = p.asset_file_id
            WHERE p.session_id = ? AND p.id IN (\(placeholders))
            """,
            [.text(sessionId)] + photoIds.map { .text($0) }
        )
        var roles: [String: String] = [:]
        for row in rows {
            guard let photoId = row.text("photo_id") else { continue }
            roles[photoId] = row.text("member_role") ?? "unknown"
        }
        return roles
    }

    public func listCandidates(sessionId: String? = nil) async throws -> [AssetLinkCandidateData] {
        let sessionClause = sessionId == nil ? "" : """
            AND EXISTS (
                SELECT 1
                FROM asset_members am
                JOIN session_assets sa ON sa.asset_id = am.asset_id
                WHERE am.file_id IN (c.left_file_id, c.right_file_id)
                  AND sa.session_id = ?
              )
            """
        let values: [SQLiteValue] = sessionId.map { [.text($0)] } ?? []
        let rows = try await database.query(
            """
            SELECT c.id, c.left_file_id, c.right_file_id, c.confidence,
              c.evidence_json, c.status, lf.normalized_path AS left_path,
              rf.normalized_path AS right_path
            FROM asset_link_candidates c
            JOIN asset_files lf ON lf.id = c.left_file_id
            JOIN asset_files rf ON rf.id = c.right_file_id
            WHERE c.relation_type = 'raw_jpeg' \(sessionClause)
            ORDER BY
              CASE c.status WHEN 'pending' THEN 0 WHEN 'accepted' THEN 1 ELSE 2 END,
              c.updated_at DESC
            """,
            values
        )
        return try rows.map { row in
            let evidenceJSON = row.text("evidence_json") ?? "{}"
            let parsed = (try? JSONValue.parse(evidenceJSON)) ?? JSONValue.object([:])
            let evidence: [String: JSONValue]
            if case .object(let dict) = parsed {
                evidence = dict
            } else {
                evidence = [:]
            }
            return AssetLinkCandidateData(
                id: row.text("id") ?? "",
                leftFileId: row.text("left_file_id") ?? "",
                rightFileId: row.text("right_file_id") ?? "",
                leftPath: row.text("left_path") ?? "",
                rightPath: row.text("right_path") ?? "",
                confidence: row.double("confidence") ?? 0,
                status: AssetLinkCandidateStatus(rawValue: row.text("status") ?? "") ?? .pending,
                evidence: evidence
            )
        }
    }

    public func listVolumes() async throws -> [AssetVolumeData] {
        let rows = try await database.query(
            """
            SELECT volume_id, normalized_path, online_status
            FROM asset_files ORDER BY volume_id, normalized_path
            """
        )
        var volumes: [String: AssetVolumeData] = [:]
        for row in rows {
            let volumeId = row.text("volume_id") ?? ""
            let normalizedPath = row.text("normalized_path") ?? ""
            let root: String
            if normalizedPath.hasPrefix("/Volumes/") {
                let components = normalizedPath.split(separator: "/")
                root = "/" + components.prefix(2).joined(separator: "/")
            } else {
                root = TSPath.root(normalizedPath)
            }
            var volume = volumes[volumeId] ?? AssetVolumeData(
                volumeId: volumeId,
                roots: [],
                onlineFiles: 0,
                offlineFiles: 0
            )
            if !volume.roots.contains(root) { volume.roots.append(root) }
            if row.text("online_status") == "online" {
                volume.onlineFiles += 1
            } else {
                volume.offlineFiles += 1
            }
            volumes[volumeId] = volume
        }
        return Array(volumes.values)
    }

    public func assetFile(id: String) async throws -> AssetFileRecord? {
        try await database.queryOne("SELECT * FROM asset_files WHERE id = ?", [.text(id)])?
            .decode(AssetFileRecord.self)
    }
}

// MARK: - 变更面实现

public extension SQLiteAssetStore {
    func relinkRoot(oldRoot: String, newRoot: String) async throws -> AssetRelinkRootResult {
        let resolvedOld = TSPath.resolve(oldRoot)
        let resolvedNew = TSPath.resolve(newRoot)
        let escaped = resolvedOld.map { character -> String in
            if character == "\\" || character == "%" || character == "_" { return "\\\(character)" }
            return String(character)
        }.joined()
        let rows = try await database.query(
            """
            SELECT id, normalized_path FROM asset_files
            WHERE normalized_path = ? OR normalized_path LIKE ? ESCAPE '\\'
            """,
            [.text(resolvedOld), .text("\(escaped)\(TSPath.separator)%")]
        )

        var changes: [(id: String, oldPath: String, newPath: String, volumeId: String, fileIdentity: String)] = []
        for row in rows {
            let id = row.text("id") ?? ""
            let normalizedPath = row.text("normalized_path") ?? ""
            let relativePath = TSPath.relative(resolvedOld, to: normalizedPath)
            if relativePath.hasPrefix("..") || TSPath.isAbsolute(relativePath) { continue }
            let newPath = TSPath.join([resolvedNew, relativePath])
            guard let info = tsStat(newPath), info.isFile else { continue }
            changes.append((
                id: id,
                oldPath: normalizedPath,
                newPath: newPath,
                volumeId: "dev:\(info.dev)",
                fileIdentity: String(info.ino)
            ))
        }

        let timestamp = nowISOString()
        let relocated = try await database.transaction { db -> [String] in
            var relocatedPaths: [String] = []
            var affectedSessions: [String] = []
            if !changes.isEmpty {
                let placeholders = changes.map { _ in "?" }.joined(separator: ",")
                affectedSessions = try db.query(
                    "SELECT DISTINCT session_id FROM photos WHERE asset_file_id IN (\(placeholders))",
                    changes.map { .text($0.id) }
                ).compactMap { $0.text("session_id") }
            }
            for change in changes {
                if let relocatedPath = try Self.relocateMetadataState(
                    db,
                    oldPhotoPath: change.oldPath,
                    newPhotoPath: change.newPath,
                    timestamp: timestamp
                ) {
                    relocatedPaths.append(relocatedPath)
                }
                try db.run(
                    """
                    UPDATE asset_files
                    SET volume_id = ?, file_identity = ?, normalized_path = ?, filename = ?,
                        online_status = 'online', last_seen_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                    [
                        .text(change.volumeId), .text(change.fileIdentity), .text(change.newPath),
                        .text(TSPath.basename(change.newPath)), .text(timestamp), .text(timestamp),
                        .text(change.id),
                    ]
                )
                try db.run(
                    """
                    UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
                    WHERE asset_file_id = ?
                    """,
                    [
                        .text(change.newPath), .text(TSPath.basename(change.newPath)),
                        .text(timestamp), .text(change.id),
                    ]
                )
                try Self.relocateSidecarBinding(
                    db,
                    oldPhotoPath: change.oldPath,
                    newPhotoPath: change.newPath,
                    timestamp: timestamp
                )
            }
            for sessionId in affectedSessions {
                let sourcePath = try db.queryOne("SELECT source_path FROM sessions WHERE id = ?", [.text(sessionId)])?
                    .text("source_path") ?? ""
                if !sourcePath.isEmpty {
                    let resolvedSourcePath = TSPath.resolve(sourcePath)
                    let relativeSourcePath = TSPath.relative(resolvedOld, to: resolvedSourcePath)
                    if relativeSourcePath == "" ||
                        (!relativeSourcePath.hasPrefix("..") && !TSPath.isAbsolute(relativeSourcePath)) {
                        try db.run(
                            "UPDATE sessions SET source_path = ?, updated_at = ? WHERE id = ?",
                            [.text(TSPath.join([resolvedNew, relativeSourcePath])), .text(timestamp), .text(sessionId)]
                        )
                    }
                }
                try db.run("DELETE FROM similarity_results WHERE session_id = ?", [.text(sessionId)])
                try db.run(
                    "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
                    [.text(sessionId)]
                )
                try db.run(
                    "UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?",
                    [.text(timestamp), .text(sessionId)]
                )
            }
            return relocatedPaths
        }
        return AssetRelinkRootResult(relocatedFiles: changes.count, relocatedOutboxPaths: relocated)
    }

    func relinkMovedFile(
        newPath: String,
        checksum: String,
        fileSize: Int64,
        fileMtimeMs: Double,
        fileIdentity: String = ""
    ) async throws -> AssetRelinkFileResult? {
        let resolvedPath = TSPath.resolve(newPath)
        guard let info = tsStat(resolvedPath) else { return nil }
        let volumeId = "dev:\(info.dev)"

        var identityMatch: AssetFileRef?
        if !fileIdentity.isEmpty {
            identityMatch = try await database.queryOne(
                """
                SELECT id, normalized_path FROM asset_files
                WHERE volume_id = ? AND file_identity = ? AND normalized_path <> ?
                LIMIT 1
                """,
                [.text(volumeId), .text(fileIdentity), .text(resolvedPath)]
            ).map { AssetFileRef(id: $0.text("id") ?? "", normalizedPath: $0.text("normalized_path") ?? "") }
        }
        if checksum.isEmpty && identityMatch == nil { return nil }

        var checksumMatches: [AssetFileRef] = []
        if !checksum.isEmpty {
            let rows = try await database.query(
                """
                SELECT id, normalized_path FROM asset_files
                WHERE checksum = ? AND file_size = ? AND normalized_path <> ?
                ORDER BY id
                """,
                [.text(checksum), .int(fileSize), .text(resolvedPath)]
            )
            checksumMatches = rows
                .map { AssetFileRef(id: $0.text("id") ?? "", normalizedPath: $0.text("normalized_path") ?? "") }
                .filter { !tsExists($0.normalizedPath) }
            if checksumMatches.count > 2 { checksumMatches = Array(checksumMatches.prefix(2)) }
        }
        guard let match = identityMatch ?? (checksumMatches.count == 1 ? checksumMatches[0] : nil) else {
            return nil
        }

        let timestamp = nowISOString()
        let relocated = try await database.transaction { db -> String? in
            let relocatedPath = try Self.relocateMetadataState(
                db,
                oldPhotoPath: match.normalizedPath,
                newPhotoPath: resolvedPath,
                timestamp: timestamp
            )
            try db.run(
                """
                UPDATE asset_files
                SET volume_id = ?, file_identity = ?, normalized_path = ?, filename = ?, extension = ?,
                    file_size = ?, file_mtime_ms = ?, online_status = 'online',
                    last_seen_at = ?, updated_at = ?
                WHERE id = ?
                """,
                [
                    .text(volumeId), .text(fileIdentity), .text(resolvedPath),
                    .text(TSPath.basename(resolvedPath)), .text(TSPath.extname(resolvedPath).lowercased()),
                    .int(fileSize), .real(fileMtimeMs), .text(timestamp), .text(timestamp),
                    .text(match.id),
                ]
            )
            try db.run(
                """
                UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
                WHERE asset_file_id = ?
                """,
                [.text(resolvedPath), .text(TSPath.basename(resolvedPath)), .text(timestamp), .text(match.id)]
            )
            try Self.relocateSidecarBinding(
                db,
                oldPhotoPath: match.normalizedPath,
                newPhotoPath: resolvedPath,
                timestamp: timestamp
            )
            return relocatedPath
        }
        let photoIds = try await database.query(
            "SELECT id FROM photos WHERE asset_file_id = ? ORDER BY id",
            [.text(match.id)]
        ).compactMap { $0.text("id") }
        return AssetRelinkFileResult(fileId: match.id, photoIds: photoIds, relocatedOutboxPath: relocated)
    }

    func acceptCandidate(_ candidateId: String) async throws {
        guard let candidate = try await Self.candidate(database, candidateId) else {
            throw AssetStoreError.candidateNotFound
        }
        try await database.transaction { db in
            try Self.mergeFileAssets(db, primaryFileId: candidate.leftFileId, secondaryFileId: candidate.rightFileId)
            try db.run(
                "UPDATE asset_link_candidates SET status = 'accepted', updated_at = ? WHERE id = ?",
                [.text(nowISOString()), .text(candidateId)]
            )
        }
    }

    func rejectCandidate(_ candidateId: String) async throws {
        guard let candidate = try await Self.candidate(database, candidateId) else {
            throw AssetStoreError.candidateNotFound
        }
        try await database.transaction { db in
            if candidate.status == "accepted" {
                try Self.splitFileAsset(db, fileId: candidate.rightFileId)
            }
            try db.run(
                "UPDATE asset_link_candidates SET status = 'rejected', updated_at = ? WHERE id = ?",
                [.text(nowISOString()), .text(candidateId)]
            )
        }
    }

    /// 完全证据（同目录/同基名 + 拍摄时间差 ≤2s + 同机型 + 双方各仅一个候选）才自动合并。
    func reconcileRawJpegLinks(sessionId: String) async throws -> Int64 {
        let candidates = try await database.query(
            """
            SELECT c.id, c.left_file_id, c.right_file_id, c.status,
              lpmc.date_taken AS left_date, rpmc.date_taken AS right_date,
              lpmc.camera_model AS left_camera, rpmc.camera_model AS right_camera,
              (
                SELECT COUNT(*) FROM asset_link_candidates related
                WHERE related.relation_type = 'raw_jpeg' AND related.status = 'pending'
                  AND (related.left_file_id = c.left_file_id OR related.right_file_id = c.left_file_id)
              ) AS left_candidate_count,
              (
                SELECT COUNT(*) FROM asset_link_candidates related
                WHERE related.relation_type = 'raw_jpeg' AND related.status = 'pending'
                  AND (related.left_file_id = c.right_file_id OR related.right_file_id = c.right_file_id)
              ) AS right_candidate_count
            FROM asset_link_candidates c
            JOIN asset_files lf ON lf.id = c.left_file_id
            JOIN asset_files rf ON rf.id = c.right_file_id
            LEFT JOIN photos lp ON lp.asset_file_id = lf.id AND lp.session_id = ?
            LEFT JOIN photos rp ON rp.asset_file_id = rf.id AND rp.session_id = ?
            LEFT JOIN photo_metadata_cache lpmc ON lpmc.photo_id = lp.id
            LEFT JOIN photo_metadata_cache rpmc ON rpmc.photo_id = rp.id
            WHERE c.relation_type = 'raw_jpeg' AND c.status = 'pending'
            GROUP BY c.id
            """,
            [.text(sessionId), .text(sessionId)]
        )
        return try await database.transaction { db -> Int64 in
            var merged: Int64 = 0
            for candidate in candidates {
                let leftDate = candidate.text("left_date")
                let rightDate = candidate.text("right_date")
                let leftTime = leftDate.flatMap { tsDateParse($0) } ?? .nan
                let rightTime = rightDate.flatMap { tsDateParse($0) } ?? .nan
                let leftCamera = (candidate.text("left_camera") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let rightCamera = (candidate.text("right_camera") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fullyEvidenced =
                    leftTime.isFinite &&
                    rightTime.isFinite &&
                    abs(leftTime - rightTime) <= 2_000 &&
                    !leftCamera.isEmpty && !rightCamera.isEmpty &&
                    leftCamera.compare(rightCamera, options: .caseInsensitive) == .orderedSame &&
                    (candidate.int("left_candidate_count") ?? 0) == 1 &&
                    (candidate.int("right_candidate_count") ?? 0) == 1
                if !fullyEvidenced { continue }
                try Self.mergeFileAssets(
                    db,
                    primaryFileId: candidate.text("left_file_id") ?? "",
                    secondaryFileId: candidate.text("right_file_id") ?? ""
                )
                let evidence = JSONValue.object([
                    "sameDirectory": JSONValue.bool(true),
                    "sameBasename": JSONValue.bool(true),
                    "captureTimeDeltaMs": JSONValue.int(Int64(abs(leftTime - rightTime))),
                    "cameraModel": JSONValue.string(leftCamera),
                    "automatic": JSONValue.bool(true),
                    "reversible": JSONValue.bool(true),
                ])
                try db.run(
                    """
                    UPDATE asset_link_candidates
                    SET confidence = 1, evidence_json = ?, status = 'accepted', updated_at = ?
                    WHERE id = ? AND status = 'pending'
                    """,
                    [
                        .text(try JSONValue.stringify(evidence)),
                        .text(nowISOString()),
                        .text(candidate.text("id") ?? ""),
                    ]
                )
                merged += 1
            }
            if merged > 0 {
                try db.run(
                    """
                    UPDATE asset_backfill_state
                    SET automatic_merges = automatic_merges + ?, updated_at = ?
                    WHERE session_id = ?
                    """,
                    [.int(merged), .text(nowISOString()), .text(sessionId)]
                )
            }
            return merged
        }
    }

    // MARK: 私有：事务内辅助

    internal static func candidate(_ database: SQLiteDatabase, _ candidateId: String) async throws -> AssetCandidateLite? {
        try await database.queryOne(
            "SELECT left_file_id, right_file_id, status FROM asset_link_candidates WHERE id = ?",
            [.text(candidateId)]
        ).map {
            AssetCandidateLite(
                leftFileId: $0.text("left_file_id") ?? "",
                rightFileId: $0.text("right_file_id") ?? "",
                status: $0.text("status") ?? ""
            )
        }
    }

    /// 把 metadata_outbox / writeback_items / metadata_keyword_origins 从旧照片路径迁到新路径。
    internal static func relocateMetadataState(
        _ db: isolated SQLiteDatabase,
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws -> String? {
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        if oldXmp == newXmp { return nil }
        let oldOutbox = try db.queryOne("SELECT status FROM metadata_outbox WHERE xmp_path = ?", [.text(oldXmp)])
        if oldOutbox?.text("status") == "writing" {
            throw AssetStoreError.relinkXMPBusy
        }
        if oldOutbox != nil {
            let targetExists = try db.queryOne("SELECT 1 FROM metadata_outbox WHERE xmp_path = ?", [.text(newXmp)])
            if targetExists != nil {
                throw AssetStoreError.relinkOutboxConflict
            }
            try db.run(
                """
                INSERT INTO metadata_outbox (
                  xmp_path, owner_session_id, created_by_session_id, photo_path,
                  patch_json, dirty_fields, revision, persisted_revision,
                  base_fingerprint, base_values_json, backup_path, status,
                  attempt_count, error_message, updated_at
                )
                SELECT ?, owner_session_id, created_by_session_id, ?,
                  patch_json, dirty_fields, revision, persisted_revision,
                  base_fingerprint, base_values_json, backup_path,
                  CASE WHEN status IN ('pending', 'failed') THEN 'pending' ELSE status END,
                  CASE WHEN status IN ('pending', 'failed') THEN 0 ELSE attempt_count END,
                  CASE WHEN status IN ('pending', 'failed') THEN '' ELSE error_message END,
                  ?
                FROM metadata_outbox WHERE xmp_path = ?
                """,
                [.text(newXmp), .text(newPhotoPath), .text(timestamp), .text(oldXmp)]
            )
            try db.run(
                """
                INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
                SELECT ?, session_id, confirmed_at, linked_at
                FROM metadata_outbox_sessions WHERE xmp_path = ?
                """,
                [.text(newXmp), .text(oldXmp)]
            )
            try db.run(
                "UPDATE writeback_items SET photo_path = ?, xmp_path = ? WHERE xmp_path = ?",
                [.text(newPhotoPath), .text(newXmp), .text(oldXmp)]
            )
            try relocateKeywordOrigins(db, oldXmp: oldXmp, newXmp: newXmp, timestamp: timestamp)
            try db.run("DELETE FROM metadata_keyword_origins WHERE xmp_path = ?", [.text(oldXmp)])
            try db.run("DELETE FROM metadata_outbox WHERE xmp_path = ?", [.text(oldXmp)])
            return newXmp
        }
        try db.run(
            "UPDATE writeback_items SET photo_path = ?, xmp_path = ? WHERE xmp_path = ?",
            [.text(newPhotoPath), .text(newXmp), .text(oldXmp)]
        )
        try relocateKeywordOrigins(db, oldXmp: oldXmp, newXmp: newXmp, timestamp: timestamp)
        try db.run("DELETE FROM metadata_keyword_origins WHERE xmp_path = ?", [.text(oldXmp)])
        return nil
    }

    internal static func relocateKeywordOrigins(
        _ db: isolated SQLiteDatabase,
        oldXmp: String,
        newXmp: String,
        timestamp: String
    ) throws {
        try db.run(
            """
            INSERT INTO metadata_keyword_origins (
              xmp_path, source, keyword, active, created_at, updated_at
            )
            SELECT ?, source, keyword, active, created_at, ?
            FROM metadata_keyword_origins WHERE xmp_path = ?
            ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
              active = MAX(active, excluded.active),
              updated_at = excluded.updated_at
            """,
            [.text(newXmp), .text(timestamp), .text(oldXmp)]
        )
    }

    internal static func relocateSidecarBinding(
        _ db: isolated SQLiteDatabase,
        oldPhotoPath: String,
        newPhotoPath: String,
        timestamp: String
    ) throws {
        let oldXmp = TSPath.xmpSidecarPath(oldPhotoPath)
        let newXmp = TSPath.xmpSidecarPath(newPhotoPath)
        let normalizedOld = TSPath.normalize(oldXmp)
        let normalizedNew = TSPath.normalize(newXmp)
        if normalizedOld == normalizedNew { return }
        guard let oldBindingId = try db.queryOne(
            "SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?",
            [.text(normalizedOld)]
        )?.text("id") else { return }
        let targetBindingId = try db.queryOne(
            "SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?",
            [.text(normalizedNew)]
        )?.text("id")
        if targetBindingId == nil {
            try db.run(
                """
                UPDATE sidecar_bindings
                SET xmp_path = ?, normalized_xmp_path = ?, updated_at = ?
                WHERE id = ?
                """,
                [.text(newXmp), .text(normalizedNew), .text(timestamp), .text(oldBindingId)]
            )
            return
        }
        let targetId = targetBindingId ?? ""
        let oldState = try sidecarState(db, bindingId: oldBindingId)
        let targetState = try sidecarState(db, bindingId: targetId)
        if let oldState, let targetState,
           oldState.rating != targetState.rating ||
           oldState.label != targetState.label ||
           oldState.keywords != targetState.keywords ||
           oldState.fingerprint != targetState.fingerprint {
            throw AssetStoreError.relinkXMPConflict
        }
        if let oldState, targetState == nil {
            try db.run(
                """
                INSERT INTO sidecar_metadata_state (
                  sidecar_binding_id, rating, label, keywords, fingerprint, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(targetId),
                    sqlValue(oldState.rating),
                    sqlValue(oldState.label),
                    .text(oldState.keywords),
                    .text(oldState.fingerprint),
                    .text(timestamp),
                ]
            )
        }
        try db.run(
            """
            INSERT OR IGNORE INTO sidecar_binding_files (sidecar_binding_id, file_id)
            SELECT ?, file_id FROM sidecar_binding_files WHERE sidecar_binding_id = ?
            """,
            [.text(targetId), .text(oldBindingId)]
        )
        try db.run("DELETE FROM sidecar_bindings WHERE id = ?", [.text(oldBindingId)])
    }

    private static func sidecarState(_ db: isolated SQLiteDatabase, bindingId: String) throws -> AssetSidecarState? {
        try db.queryOne(
            """
            SELECT rating, label, keywords, fingerprint
            FROM sidecar_metadata_state WHERE sidecar_binding_id = ?
            """,
            [.text(bindingId)]
        ).map {
            AssetSidecarState(
                rating: $0.int("rating"),
                label: $0.text("label"),
                keywords: $0.text("keywords") ?? "",
                fingerprint: $0.text("fingerprint") ?? ""
            )
        }
    }

    /// 合并两个文件的资产（调用方保证外层事务）。
    internal static func mergeFileAssets(
        _ db: isolated SQLiteDatabase,
        primaryFileId: String,
        secondaryFileId: String
    ) throws {
        let primary = try db.queryOne("SELECT asset_id FROM asset_members WHERE file_id = ?", [.text(primaryFileId)])?
            .text("asset_id")
        let secondary = try db.queryOne("SELECT asset_id FROM asset_members WHERE file_id = ?", [.text(secondaryFileId)])?
            .text("asset_id")
        guard let primary, let secondary, primary != secondary else { return }

        let timestamp = nowISOString()
        let secondarySessions = try db.query(
            "SELECT session_id, display_file_id, import_order, added_at FROM session_assets WHERE asset_id = ?",
            [.text(secondary)]
        )
        try db.run(
            "UPDATE asset_members SET asset_id = ?, is_primary = 0, binding_source = ? WHERE asset_id = ?",
            [.text(primary), .text("auto_raw_jpeg"), .text(secondary)]
        )
        for membership in secondarySessions {
            try db.run(
                """
                INSERT INTO session_assets
                  (session_id, asset_id, display_file_id, import_order, added_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id, asset_id) DO UPDATE SET
                  import_order = MIN(import_order, excluded.import_order)
                """,
                [
                    .text(membership.text("session_id") ?? ""),
                    .text(primary),
                    .text(membership.text("display_file_id") ?? secondaryFileId),
                    .int(membership.int("import_order") ?? 0),
                    .text(membership.text("added_at") ?? ""),
                ]
            )
        }
        try db.run(
            "UPDATE photos SET asset_id = ?, updated_at = ? WHERE asset_id = ?",
            [.text(primary), .text(timestamp), .text(secondary)]
        )
        try db.run("DELETE FROM session_assets WHERE asset_id = ?", [.text(secondary)])
        try db.run("DELETE FROM assets WHERE id = ?", [.text(secondary)])
    }

    internal static func splitFileAsset(_ db: isolated SQLiteDatabase, fileId: String) throws {
        guard let membership = try db.queryOne(
            "SELECT asset_id FROM asset_members WHERE file_id = ?",
            [.text(fileId)]
        )?.text("asset_id") else {
            throw AssetStoreError.fileNotLinked
        }
        let siblingCount = try db.scalarInt(
            "SELECT COUNT(*) AS count FROM asset_members WHERE asset_id = ?",
            [.text(membership)]
        ) ?? 0
        if siblingCount <= 1 { return }

        let timestamp = nowISOString()
        let assetId = newUUIDString()
        try db.run(
            "INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            [.text(assetId), .text(""), .text("active"), .text(timestamp), .text(timestamp)]
        )
        try db.run(
            """
            UPDATE asset_members
            SET asset_id = ?, is_primary = 1, binding_source = 'manual_split'
            WHERE file_id = ?
            """,
            [.text(assetId), .text(fileId)]
        )
        let sessions = try db.query(
            "SELECT DISTINCT session_id FROM photos WHERE asset_file_id = ?",
            [.text(fileId)]
        ).compactMap { $0.text("session_id") }
        try db.run(
            "UPDATE photos SET asset_id = ?, updated_at = ? WHERE asset_file_id = ?",
            [.text(assetId), .text(timestamp), .text(fileId)]
        )
        for sessionId in sessions {
            try db.run(
                """
                INSERT OR IGNORE INTO session_assets
                  (session_id, asset_id, display_file_id, import_order, added_at)
                VALUES (?, ?, ?, 0, ?)
                """,
                [.text(sessionId), .text(assetId), .text(fileId), .text(timestamp)]
            )
            try db.run(
                """
                DELETE FROM session_assets
                WHERE session_id = ? AND asset_id = ?
                  AND NOT EXISTS (
                    SELECT 1 FROM photos WHERE session_id = ? AND asset_id = ?
                  )
                """,
                [.text(sessionId), .text(membership), .text(sessionId), .text(membership)]
            )
        }
    }
}

// MARK: - 回填实现

public extension SQLiteAssetStore {
    /// 增量回填：逐批（250）扫描未关联照片，写回 asset_files/asset_members/
    /// session_assets/sidecar_bindings，末尾生成 RAW/JPEG 候选并收敛状态。
    func backfillSession(_ sessionId: String) async throws -> AssetBackfillResult {
        var migrated: Int64 = 0
        var offline: Int64 = 0
        let total = try await database.scalarInt(
            "SELECT COUNT(*) AS count FROM photos WHERE session_id = ?",
            [.text(sessionId)]
        ) ?? 0
        var cursor = try await database.scalarInt(
            "SELECT last_photo_rowid FROM asset_backfill_state WHERE session_id = ?",
            [.text(sessionId)]
        ) ?? 0
        try await database.run(
            """
            INSERT INTO asset_backfill_state (session_id, last_photo_rowid, total_photos, status, updated_at)
            VALUES (?, ?, ?, 'running', ?)
            ON CONFLICT(session_id) DO UPDATE SET
              total_photos = excluded.total_photos,
              status = 'running',
              updated_at = excluded.updated_at
            """,
            [.text(sessionId), .int(cursor), .int(total), .text(nowISOString())]
        )

        do {
            while true {
                let photos = try await database.query(
                    """
                    SELECT rowid AS migration_rowid, *
                    FROM photos
                    WHERE session_id = ? AND rowid > ?
                      AND (asset_id IS NULL OR asset_file_id IS NULL)
                    ORDER BY rowid
                    LIMIT 250
                    """,
                    [.text(sessionId), .int(cursor)]
                ).map { try $0.decode(PhotoBackfillRecord.self) }
                if photos.isEmpty && cursor > 0 {
                    let remaining = try await database.scalarInt(
                        """
                        SELECT COUNT(*) AS count FROM photos
                        WHERE session_id = ? AND (asset_id IS NULL OR asset_file_id IS NULL)
                        """,
                        [.text(sessionId)]
                    ) ?? 0
                    if remaining > 0 {
                        cursor = 0
                        continue
                    }
                }
                if photos.isEmpty { break }
                let batch = try await database.transaction { db -> (migrated: Int64, offline: Int64, cursor: Int64) in
                    var batchMigrated: Int64 = 0
                    var batchOffline: Int64 = 0
                    var batchCursor = cursor
                    for photo in photos {
                        let result = try Self.ensurePhoto(db, sessionId: sessionId, photo: photo)
                        batchMigrated += result.migrated
                        batchOffline += result.offline
                        batchCursor = photo.migrationRowid
                    }
                    try db.run(
                        """
                        UPDATE asset_backfill_state
                        SET last_photo_rowid = ?, migrated_photos = migrated_photos + ?,
                            offline_files = offline_files + ?, updated_at = ?
                        WHERE session_id = ?
                        """,
                        [
                            .int(batchCursor), .int(batchMigrated), .int(batchOffline),
                            .text(nowISOString()), .text(sessionId),
                        ]
                    )
                    return (batchMigrated, batchOffline, batchCursor)
                }
                migrated += batch.migrated
                offline += batch.offline
                cursor = batch.cursor
            }
        } catch {
            _ = try? await database.run(
                "UPDATE asset_backfill_state SET status = 'failed', updated_at = ? WHERE session_id = ?",
                [.text(nowISOString()), .text(sessionId)]
            )
            throw error
        }

        let candidates = try await createRawJpegCandidates(sessionId)
        try await database.run(
            """
            UPDATE asset_backfill_state
            SET candidate_links = candidate_links + ?, status = 'completed', updated_at = ?
            WHERE session_id = ?
            """,
            [.int(candidates), .text(nowISOString()), .text(sessionId)]
        )
        return AssetBackfillResult(migrated: migrated, offline: offline, candidates: candidates)
    }

    // MARK: 私有：RAW/JPEG 候选

    internal func createRawJpegCandidates(_ sessionId: String) async throws -> Int64 {
        let files = try await database.query(
            """
            SELECT DISTINCT af.id, af.filename, af.normalized_path, af.extension
            FROM asset_files af
            JOIN asset_members am ON am.file_id = af.id
            JOIN session_assets sa ON sa.asset_id = am.asset_id
            WHERE sa.session_id = ?
              AND af.extension IN ('.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw',
                                   '.jpg', '.jpeg')
            """,
            [.text(sessionId)]
        ).map {
            AssetRawJpegFile(
                id: $0.text("id") ?? "",
                filename: $0.text("filename") ?? "",
                normalizedPath: $0.text("normalized_path") ?? "",
                fileExtension: $0.text("extension") ?? ""
            )
        }
        var seen = Set<String>()
        let fileIds = files.compactMap { file -> String? in
            guard !seen.contains(file.id) else { return nil }
            seen.insert(file.id)
            return file.id
        }
        var existingPairs = Set<String>()
        for chunk in fileIds.chunked(by: 500) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT left_file_id, right_file_id FROM asset_link_candidates
                WHERE left_file_id IN (\(placeholders)) OR right_file_id IN (\(placeholders))
                """,
                chunk.map { .text($0) } + chunk.map { .text($0) }
            )
            for row in rows {
                let left = row.text("left_file_id") ?? ""
                let right = row.text("right_file_id") ?? ""
                existingPairs.insert("\(left)\u{0}\(right)")
                existingPairs.insert("\(right)\u{0}\(left)")
            }
        }

        var candidatesByStem: [String: (raws: [AssetRawJpegFile], jpegs: [AssetRawJpegFile])] = [:]
        for file in files {
            let directory = TSPath.dirname(file.normalizedPath).lowercased()
            let stem = TSPath.stem(file.filename).lowercased()
            let key = "\(directory)\u{0}\(stem)"
            var group = candidatesByStem[key] ?? (raws: [], jpegs: [])
            if Self.mediaType(file.fileExtension) == "raw" {
                group.raws.append(file)
            } else if [".jpg", ".jpeg"].contains(file.fileExtension) {
                group.jpegs.append(file)
            }
            candidatesByStem[key] = group
        }

        var created: Int64 = 0
        try await database.transaction { db in
            for (groupKey, group) in candidatesByStem {
                let stem = String(groupKey.split(separator: "\u{0}", maxSplits: 1).last ?? "")
                for raw in group.raws {
                    for jpeg in group.jpegs {
                        if existingPairs.contains("\(raw.id)\u{0}\(jpeg.id)") { continue }
                        let timestamp = nowISOString()
                        let unambiguous = group.raws.count == 1 && group.jpegs.count == 1
                        let evidence = JSONValue.object([
                            "basename": JSONValue.string(stem),
                            "sameDirectory": JSONValue.bool(true),
                            "sameSession": JSONValue.bool(true),
                            "unambiguous": .bool(unambiguous),
                            "requiresManualConfirmation": JSONValue.bool(true),
                        ])
                        try db.run(
                            """
                            INSERT INTO asset_link_candidates
                              (id, left_file_id, right_file_id, relation_type, confidence,
                               evidence_json, status, created_at, updated_at)
                            VALUES (?, ?, ?, 'raw_jpeg', ?, ?, 'pending', ?, ?)
                            """,
                            [
                                .text(newUUIDString()),
                                .text(raw.id),
                                .text(jpeg.id),
                                .real(unambiguous ? 0.85 : 0.7),
                                .text(try JSONValue.stringify(evidence)),
                                .text(timestamp),
                                .text(timestamp),
                            ]
                        )
                        created += 1
                    }
                }
            }
        }
        return created
    }

    // MARK: 私有：单照片回填

    internal static func ensurePhoto(
        _ db: isolated SQLiteDatabase,
        sessionId: String,
        photo: PhotoBackfillRecord
    ) throws -> (migrated: Int64, offline: Int64) {
        let absolute = TSPath.resolve(photo.filepath)
        let normalizedPath = TSPath.normalize(absolute)
        let extensionWithDot = TSPath.extname(absolute).lowercased()
        var fileSize: Int64 = 0
        var mtimeMs: Double = 0
        var deviceId: Int64?
        var fileIdentity = ""
        var onlineStatus = "online"
        if let info = tsStat(absolute) {
            fileSize = info.size
            mtimeMs = info.mtimeMs
            deviceId = info.dev
            fileIdentity = String(info.ino)
        } else {
            onlineStatus = "offline"
        }
        let timestamp = nowISOString()
        let volumeId: String
        if let deviceId {
            volumeId = "dev:\(deviceId)"
        } else if let rootStat = tsStat(TSPath.root(absolute)) {
            volumeId = "dev:\(rootStat.dev)"
        } else {
            volumeId = "path:\(TSPath.root(absolute))"
        }

        var file: AssetFileRef?
        if !fileIdentity.isEmpty {
            file = try db.queryOne(
                """
                SELECT id, normalized_path FROM asset_files
                WHERE volume_id = ? AND file_identity = ?
                ORDER BY updated_at DESC LIMIT 1
                """,
                [.text(volumeId), .text(fileIdentity)]
            ).map { AssetFileRef(id: $0.text("id") ?? "", normalizedPath: $0.text("normalized_path") ?? "") }
        }
        if file == nil {
            file = try db.queryOne(
                "SELECT id, normalized_path FROM asset_files WHERE normalized_path = ? ORDER BY updated_at DESC LIMIT 1",
                [.text(normalizedPath)]
            ).map { AssetFileRef(id: $0.text("id") ?? "", normalizedPath: $0.text("normalized_path") ?? "") }
        }

        let fileId: String
        if let file {
            let previousPath = file.normalizedPath
            try db.run(
                """
                UPDATE asset_files
                SET volume_id = ?, file_identity = CASE WHEN ? != '' THEN ? ELSE file_identity END,
                    normalized_path = ?, filename = ?, extension = ?,
                    file_size = ?, file_mtime_ms = ?,
                    checksum = CASE WHEN ? != '' THEN ? ELSE checksum END, online_status = ?,
                    last_seen_at = ?, updated_at = ?
                WHERE id = ?
                """,
                [
                    .text(volumeId),
                    .text(fileIdentity), .text(fileIdentity),
                    .text(normalizedPath),
                    .text(TSPath.basename(absolute)),
                    .text(extensionWithDot),
                    .int(fileSize),
                    .real(mtimeMs),
                    .text(photo.checksum), .text(photo.checksum),
                    .text(onlineStatus),
                    .text(timestamp),
                    .text(timestamp),
                    .text(file.id),
                ]
            )
            if !previousPath.isEmpty && previousPath != normalizedPath && !tsExists(previousPath) {
                try db.run(
                    """
                    UPDATE photos SET filepath = ?, filename = ?, status = 'pending', updated_at = ?
                    WHERE asset_file_id = ?
                    """,
                    [
                        .text(normalizedPath), .text(TSPath.basename(normalizedPath)),
                        .text(timestamp), .text(file.id),
                    ]
                )
            }
            fileId = file.id
        } else {
            let newFileId = newUUIDString()
            try db.run(
                """
                INSERT INTO asset_files (
                  id, volume_id, file_identity, normalized_path, filename, extension, media_type,
                  file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(newFileId), .text(volumeId), .text(fileIdentity), .text(normalizedPath),
                    .text(TSPath.basename(absolute)), .text(extensionWithDot),
                    .text(mediaType(extensionWithDot)),
                    .int(fileSize), .real(mtimeMs), .text(photo.checksum), .text(onlineStatus),
                    .text(timestamp), .text(timestamp), .text(timestamp),
                ]
            )
            fileId = newFileId
        }

        var membership = try db.queryOne("SELECT asset_id FROM asset_members WHERE file_id = ?", [.text(fileId)])?
            .text("asset_id")
        if membership == nil {
            let assetId = newUUIDString()
            try db.run(
                "INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(assetId), .text(""),
                    .text(onlineStatus == "online" ? "active" : "offline_unverified"),
                    .text(timestamp), .text(timestamp),
                ]
            )
            try db.run(
                "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES (?, ?, ?, 1, ?)",
                [.text(assetId), .text(fileId), .text(memberRole(extensionWithDot)), .text("backfill")]
            )
            membership = assetId
        }

        let importOrder: Int64
        if photo.migrationRowid != 0 {
            importOrder = photo.migrationRowid
        } else {
            importOrder = try db.scalarInt("SELECT rowid FROM photos WHERE id = ?", [.text(photo.id)]) ?? 0
        }
        try db.run(
            """
            INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(session_id, asset_id) DO UPDATE SET display_file_id = excluded.display_file_id
            """,
            [
                .text(sessionId), .text(membership ?? ""), .text(fileId),
                .int(importOrder), .text(timestamp),
            ]
        )
        try db.run(
            "UPDATE assets SET status = ?, updated_at = ? WHERE id = ?",
            [
                .text(onlineStatus == "online" ? "active" : "offline_unverified"),
                .text(timestamp), .text(membership ?? ""),
            ]
        )
        try db.run(
            "UPDATE photos SET asset_id = ?, asset_file_id = ? WHERE id = ?",
            [.text(membership ?? ""), .text(fileId), .text(photo.id)]
        )

        let sidecarPath = TSPath.xmpSidecarPath(absolute)
        let normalizedXmp = TSPath.normalize(sidecarPath)
        try db.run(
            """
            INSERT INTO sidecar_bindings (id, xmp_path, normalized_xmp_path, binding_rule, created_at, updated_at)
            VALUES (?, ?, ?, 'same_basename', ?, ?)
            ON CONFLICT(normalized_xmp_path) DO UPDATE SET updated_at = excluded.updated_at
            """,
            [
                .text(newUUIDString()), .text(sidecarPath), .text(normalizedXmp),
                .text(timestamp), .text(timestamp),
            ]
        )
        let bindingId = try db.queryOne(
            "SELECT id FROM sidecar_bindings WHERE normalized_xmp_path = ?",
            [.text(normalizedXmp)]
        )?.text("id") ?? ""
        try db.run(
            "INSERT OR IGNORE INTO sidecar_binding_files (sidecar_binding_id, file_id) VALUES (?, ?)",
            [.text(bindingId), .text(fileId)]
        )

        return (migrated: 1, offline: onlineStatus == "online" ? 0 : 1)
    }

    // MARK: 私有：扩展名分类

    internal static func mediaType(_ extensionWithDot: String) -> String {
        if [".jpg", ".jpeg", ".heic", ".heif", ".png", ".webp"].contains(extensionWithDot) { return "image" }
        if [".nef", ".arw", ".cr2", ".cr3", ".dng", ".raf", ".orf", ".rw2", ".pef", ".srw"].contains(extensionWithDot) { return "raw" }
        if [".tif", ".tiff", ".psd"].contains(extensionWithDot) { return "image" }
        return "unknown"
    }

    internal static func memberRole(_ extensionWithDot: String) -> String {
        if mediaType(extensionWithDot) == "raw" { return "raw" }
        if [".jpg", ".jpeg", ".heic", ".heif"].contains(extensionWithDot) { return "camera_jpeg" }
        if [".tif", ".tiff"].contains(extensionWithDot) { return "rendered_tiff" }
        return "unknown"
    }
}
