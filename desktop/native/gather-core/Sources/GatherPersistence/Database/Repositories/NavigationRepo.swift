// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/NavigationRepo.swift
// WP3b-1：navigation_groups / captureRows 查询下沉（NavigationService 的 SQL）。
//
// 分组算法、lead 选择与指纹计算仍留在 Application；本仓储只负责 SQL、JSON
// 列编解码与事务边界（split/merge/persistAutomatic 的原事务语义逐条保留）。
import Foundation

public struct NavigationGroupRow: Equatable, Sendable {
    public let id: String
    public let type: String
    public let photoIdsJSON: String
    public let leadPhotoId: String?
    public let explanation: String
    public let source: String

    public init(
        id: String,
        type: String,
        photoIdsJSON: String,
        leadPhotoId: String?,
        explanation: String,
        source: String
    ) {
        self.id = id
        self.type = type
        self.photoIdsJSON = photoIdsJSON
        self.leadPhotoId = leadPhotoId
        self.explanation = explanation
        self.source = source
    }
}

public struct NavigationCaptureRow: Equatable, Sendable {
    public let id: String
    public let filepath: String
    public let filename: String
    public let capturedAt: String
    public let cameraModel: String
    public let hashHex: String
    public let rating: Double
    public let qualityJSON: String?

    public init(
        id: String,
        filepath: String,
        filename: String,
        capturedAt: String,
        cameraModel: String,
        hashHex: String,
        rating: Double,
        qualityJSON: String?
    ) {
        self.id = id
        self.filepath = filepath
        self.filename = filename
        self.capturedAt = capturedAt
        self.cameraModel = cameraModel
        self.hashHex = hashHex
        self.rating = rating
        self.qualityJSON = qualityJSON
    }
}

public struct NavigationGroupWrite: Equatable, Sendable {
    public let id: String
    public let type: String
    public let photoIds: [String]
    public let leadPhotoId: String?
    public let explanation: String
    public let source: String
    public let fingerprint: String

    public init(
        id: String,
        type: String,
        photoIds: [String],
        leadPhotoId: String?,
        explanation: String,
        source: String,
        fingerprint: String
    ) {
        self.id = id
        self.type = type
        self.photoIds = photoIds
        self.leadPhotoId = leadPhotoId
        self.explanation = explanation
        self.source = source
        self.fingerprint = fingerprint
    }
}

public final class NavigationRepo {
    private static let qualityChunkSize = 800

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 组行（旧 SQL 列序/排序逐字保留）。
    public func listGroups(sessionId: String) throws -> [NavigationGroupRow] {
        let rows = try connection.prepare("""
            SELECT id, group_type, photo_ids_json, lead_photo_id, explanation, source
            FROM navigation_groups WHERE session_id = ?
            ORDER BY group_type, created_at, id
        """).query([.text(sessionId)])
        return rows.map {
            NavigationGroupRow(
                id: $0[0].textValue ?? "",
                type: $0[1].textValue ?? "",
                photoIdsJSON: $0[2].textValue ?? "",
                leadPhotoId: $0[3].textValue,
                explanation: $0[4].textValue ?? "",
                source: $0[5].textValue ?? ""
            )
        }
    }

    /// captureRows：主查询 + 每 800 个 asset_file 一次 technical_quality 查询。
    /// qualityJSON 仍由 Application 解析（safeQuality 属导航业务）。
    public func captureRows(sessionId: String) throws -> [NavigationCaptureRow] {
        let rows = try connection.prepare("""
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
              AND \(PhotoVisibility.visiblePredicate())
            ORDER BY captured_at, p.rowid
        """).query([.text(sessionId)])

        let fileIds = Array(Set(rows.compactMap { $0[7].textValue }))
        var qualityByFile: [String: String] = [:]
        for offset in stride(from: 0, to: fileIds.count, by: Self.qualityChunkSize) {
            let chunk = Array(fileIds[offset..<min(offset + Self.qualityChunkSize, fileIds.count)])
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let analysisRows = try connection.prepare("""
                SELECT aa.asset_file_id, aa.result_json
                FROM asset_analysis aa
                WHERE aa.asset_file_id IN (\(placeholders)) AND aa.analysis_type = 'technical_quality'
                ORDER BY aa.asset_file_id, aa.updated_at DESC
            """).query(chunk.map(DBValue.text))
            for row in analysisRows {
                if let fileId = row[0].textValue, qualityByFile[fileId] == nil {
                    qualityByFile[fileId] = row[1].textValue ?? ""
                }
            }
        }

        return rows.map { row in
            let assetFileId = row[7].textValue
            let qualityJSON = assetFileId.flatMap { qualityByFile[$0] }
            let rating: Double
            if let intRating = row[6].intValue {
                rating = Double(intRating)
            } else {
                rating = row[6].doubleValue ?? 0
            }
            return NavigationCaptureRow(
                id: row[0].textValue ?? "",
                filepath: row[1].textValue ?? "",
                filename: row[2].textValue ?? "",
                capturedAt: row[3].textValue ?? "",
                cameraModel: row[4].textValue ?? "",
                hashHex: row[5].textValue ?? "",
                rating: rating,
                qualityJSON: qualityJSON
            )
        }
    }

    public func cachedFingerprint(sessionId: String) throws -> String? {
        try connection.prepare("""
            SELECT input_fingerprint FROM navigation_groups
            WHERE session_id = ? AND source = 'automatic' LIMIT 1
        """).get([.text(sessionId)])?[0].textValue
    }

    /// split：删除原组 + 插入两个 manual 组（同一事务）。
    public func replaceGroup(sessionId: String, groupId: String, with groups: [NavigationGroupWrite]) throws {
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM navigation_groups WHERE id = ? AND session_id = ?")
                .run([.text(groupId), .text(sessionId)])
            for group in groups {
                try insert(sessionId: sessionId, group: group)
            }
        }
    }

    /// merge：删除被合并组 + 插入 new manual 组（同一事务）。
    public func mergeGroups(sessionId: String, groupIds: [String], into group: NavigationGroupWrite) throws {
        try connection.transaction {
            let placeholders = groupIds.map { _ in "?" }.joined(separator: ", ")
            _ = try connection.prepare("""
                DELETE FROM navigation_groups
                WHERE session_id = ? AND id IN (\(placeholders))
            """).run([.text(sessionId)] + groupIds.map(DBValue.text))
            try insert(sessionId: sessionId, group: group)
        }
    }

    /// persistAutomatic：manual 成员查询（逐字保留原 SQL）。
    public func manualGroups(sessionId: String) throws -> [(type: String, photoIdsJSON: String)] {
        let rows = try connection.prepare("""
            SELECT group_type, photo_ids_json FROM navigation_groups
            WHERE session_id = ? AND source = 'manual'
        """).query([.text(sessionId)])
        return rows.map { (type: $0[0].textValue ?? "", photoIdsJSON: $0[1].textValue ?? "") }
    }

    /// persistAutomatic：清自动组 + 重插（同一事务）。
    public func replaceAutomaticGroups(sessionId: String, groups: [NavigationGroupWrite]) throws {
        try connection.transaction {
            _ = try connection.prepare(
                "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'"
            ).run([.text(sessionId)])
            for group in groups {
                try insert(sessionId: sessionId, group: group)
            }
        }
    }

    private func insert(sessionId: String, group: NavigationGroupWrite) throws {
        let now = nowISOString()
        let data = (try? JSONSerialization.data(withJSONObject: group.photoIds)) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"
        _ = try connection.prepare("""
            INSERT INTO navigation_groups (
                id, session_id, group_type, photo_ids_json, lead_photo_id,
                explanation, input_fingerprint, source, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """).run([
            .text(group.id),
            .text(sessionId),
            .text(group.type),
            .text(json),
            group.leadPhotoId.map(DBValue.text) ?? .null,
            .text(group.explanation),
            .text(group.fingerprint),
            .text(group.source),
            .text(now),
            .text(now),
        ])
    }
}
