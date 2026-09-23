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
