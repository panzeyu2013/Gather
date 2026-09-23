// Store/NavigationStore.swift
// R1：navigation_groups / 拍摄行查询的唯一入口（从 Services/NavigationService.swift
// 抽出内联 SQL；分组、lead 选择、指纹与 explanation 仍在服务层）。
import Foundation

public struct NavigationGroupRecord: Decodable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let groupType: String
    public let photoIdsJSON: String
    public let leadPhotoId: String?
    public let explanation: String
    public let inputFingerprint: String
    public let source: String
    public let createdAt: String
    public let updatedAt: String

    public var photoIds: [String] {
        SQLiteNavigationStore.parsePhotoIDs(photoIdsJSON) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, explanation, source
        case sessionId = "session_id"
        case groupType = "group_type"
        case photoIdsJSON = "photo_ids_json"
        case leadPhotoId = "lead_photo_id"
        case inputFingerprint = "input_fingerprint"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// 待写入的分组（服务层的 NavigationGroup → Store 边界类型）。
public struct NavigationGroupInsert: Equatable, Sendable {
    public let id: String
    public let groupType: String
    public let photoIdsJSON: String
    public let leadPhotoId: String?
    public let explanation: String
    public let source: String
    public let fingerprint: String

    public init(
        id: String,
        groupType: String,
        photoIdsJSON: String,
        leadPhotoId: String?,
        explanation: String,
        source: String,
        fingerprint: String
    ) {
        self.id = id
        self.groupType = groupType
        self.photoIdsJSON = photoIdsJSON
        self.leadPhotoId = leadPhotoId
        self.explanation = explanation
        self.source = source
        self.fingerprint = fingerprint
    }
}

/// 拍摄行（未解析 quality JSON，解析留在服务层）。
public struct NavigationCaptureRow: Equatable, Sendable {
    public let id: String
    public let filepath: String
    public let filename: String
    public let capturedAt: String
    public let cameraModel: String
    public let hashHex: String
    public let rating: Double
    public let assetFileId: String?
    public let qualityJSON: String?

    public init(
        id: String,
        filepath: String,
        filename: String,
        capturedAt: String,
        cameraModel: String,
        hashHex: String,
        rating: Double,
        assetFileId: String?,
        qualityJSON: String?
    ) {
        self.id = id
        self.filepath = filepath
        self.filename = filename
        self.capturedAt = capturedAt
        self.cameraModel = cameraModel
        self.hashHex = hashHex
        self.rating = rating
        self.assetFileId = assetFileId
        self.qualityJSON = qualityJSON
    }
}

public protocol NavigationStore: Sendable {
    func groups(sessionId: String) async throws -> [NavigationGroupRecord]
    func manualGroups(sessionId: String) async throws -> [NavigationGroupRecord]
    func cachedFingerprint(sessionId: String) async throws -> String?
    func insertGroup(sessionId: String, group: NavigationGroupInsert) async throws
    func deleteGroup(sessionId: String, id: String) async throws
    func deleteGroups(sessionId: String, ids: [String]) async throws
    func deleteAutomaticGroups(sessionId: String) async throws
    func replaceAutomaticGroups(
        sessionId: String,
        groups: [NavigationGroupInsert],
        fingerprint: String
    ) async throws
    func captureRows(sessionId: String) async throws -> [NavigationCaptureRow]
}

public struct SQLiteNavigationStore: NavigationStore {
    /// TS: IN chunk 800（quality 查询）。
    private static let qualityChunkSize = 800

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func groups(sessionId: String) async throws -> [NavigationGroupRecord] {
        try await database.query(
            """
            SELECT id, session_id, group_type, photo_ids_json, lead_photo_id, explanation,
                   input_fingerprint, source, created_at, updated_at
            FROM navigation_groups WHERE session_id = ?
            ORDER BY group_type, created_at, id
            """,
            [.text(sessionId)]
        ).map { try $0.decode(NavigationGroupRecord.self) }
    }

    public func manualGroups(sessionId: String) async throws -> [NavigationGroupRecord] {
        try await database.query(
            """
            SELECT id, session_id, group_type, photo_ids_json, lead_photo_id, explanation,
                   input_fingerprint, source, created_at, updated_at
            FROM navigation_groups WHERE session_id = ? AND source = 'manual'
            """,
            [.text(sessionId)]
        ).map { try $0.decode(NavigationGroupRecord.self) }
    }

    public func cachedFingerprint(sessionId: String) async throws -> String? {
        try await database.queryOne(
            """
            SELECT input_fingerprint FROM navigation_groups
            WHERE session_id = ? AND source = 'automatic' LIMIT 1
            """,
            [.text(sessionId)]
        )?.text("input_fingerprint")
    }

    public func insertGroup(sessionId: String, group: NavigationGroupInsert) async throws {
        try await database.transaction { db in
            try Self.insertGroup(db, sessionId: sessionId, group: group)
        }
    }

    public func deleteGroup(sessionId: String, id: String) async throws {
        try await database.run(
            "DELETE FROM navigation_groups WHERE id = ? AND session_id = ?",
            [.text(id), .text(sessionId)]
        )
    }

    public func deleteGroups(sessionId: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try await database.run(
            "DELETE FROM navigation_groups WHERE session_id = ? AND id IN (\(placeholders))",
            [.text(sessionId)] + ids.map { .text($0) }
        )
    }

    public func deleteAutomaticGroups(sessionId: String) async throws {
        try await database.run(
            "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
            [.text(sessionId)]
        )
    }

    public func replaceAutomaticGroups(
        sessionId: String,
        groups: [NavigationGroupInsert],
        fingerprint: String
    ) async throws {
        try await database.transaction { db in
            try db.run(
                "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
                [.text(sessionId)]
            )
            for group in groups {
                var group = group
                if group.fingerprint.isEmpty {
                    group = NavigationGroupInsert(
                        id: group.id,
                        groupType: group.groupType,
                        photoIdsJSON: group.photoIdsJSON,
                        leadPhotoId: group.leadPhotoId,
                        explanation: group.explanation,
                        source: group.source,
                        fingerprint: fingerprint
                    )
                }
                try Self.insertGroup(db, sessionId: sessionId, group: group)
            }
        }
    }

    /// 拍摄行 = photos ⋈ metadata_cache ⋈ similarity_hashes + 每 asset_file 最新
    /// technical_quality（800 分块）。
    public func captureRows(sessionId: String) async throws -> [NavigationCaptureRow] {
        let rows = try await database.query(
            """
            SELECT p.id, p.filepath, p.filename,
                COALESCE(NULLIF(pmc.date_taken, ''), p.created_at) AS captured_at,
                COALESCE(pmc.camera_model, '') AS camera_model,
                COALESCE(sh.hash_hex, '') AS hash_hex,
                COALESCE(pmc.rating, 0) AS rating,
                p.asset_file_id
            FROM photos p
            LEFT JOIN photo_metadata_cache pmc ON pmc.photo_id = p.id
            LEFT JOIN similarity_hashes sh ON sh.photo_id = p.id AND sh.session_id = p.session_id
            WHERE p.session_id = ? AND p.status != 'missing'
            ORDER BY captured_at, p.rowid
            """,
            [.text(sessionId)]
        )

        var fileIds: [String] = []
        var seen = Set<String>()
        for row in rows {
            guard let fileId = row.text("asset_file_id"), !seen.contains(fileId) else { continue }
            seen.insert(fileId)
            fileIds.append(fileId)
        }
        var qualityByFile: [String: String] = [:]
        for chunk in fileIds.chunked(by: Self.qualityChunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let analysisRows = try await database.query(
                """
                SELECT asset_file_id, result_json FROM asset_analysis
                WHERE asset_file_id IN (\(placeholders)) AND analysis_type = 'technical_quality'
                ORDER BY asset_file_id, updated_at DESC
                """,
                chunk.map { .text($0) }
            )
            for row in analysisRows {
                guard let fileId = row.text("asset_file_id"), qualityByFile[fileId] == nil else { continue }
                qualityByFile[fileId] = row.text("result_json") ?? ""
            }
        }

        return rows.map { row in
            let assetFileId = row.text("asset_file_id")
            var rating = row.double("rating") ?? 0
            if let intRating = row.int("rating") { rating = Double(intRating) }
            return NavigationCaptureRow(
                id: row.text("id") ?? "",
                filepath: row.text("filepath") ?? "",
                filename: row.text("filename") ?? "",
                capturedAt: row.text("captured_at") ?? "",
                cameraModel: row.text("camera_model") ?? "",
                hashHex: row.text("hash_hex") ?? "",
                rating: rating,
                assetFileId: assetFileId,
                qualityJSON: assetFileId.flatMap { qualityByFile[$0] }
            )
        }
    }

    // MARK: 私有

    private static func insertGroup(
        _ db: isolated SQLiteDatabase,
        sessionId: String,
        group: NavigationGroupInsert
    ) throws {
        let now = nowISOString()
        try db.run(
            """
            INSERT INTO navigation_groups (
                id, session_id, group_type, photo_ids_json, lead_photo_id,
                explanation, input_fingerprint, source, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(group.id), .text(sessionId), .text(group.groupType),
                .text(group.photoIdsJSON),
                group.leadPhotoId.map { SQLiteValue.text($0) } ?? .null,
                .text(group.explanation), .text(group.fingerprint), .text(group.source),
                .text(now), .text(now),
            ]
        )
    }

    // MARK: 纯函数（与旧服务同语义）

    /// TS: JSON.parse(photo_ids_json) → string[]（非数组或畸形返回 nil）。
    internal static func parsePhotoIDs(_ json: String) -> [String]? {
        guard let value = try? JSONValue.parse(json), case .array(let items) = value else { return nil }
        let ids = items.compactMap { item -> String? in
            if case .string(let s) = item { return s }
            return nil
        }
        return ids.count == items.count ? ids : nil
    }

    /// TS: JSON.stringify(photoIds)。
    internal static func photoIDsJSON(_ ids: [String]) -> String {
        (try? JSONValue.stringify(JSONValue.array(ids.map { JSONValue.string($0) }))) ?? "[]"
    }
}
