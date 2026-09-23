// Store/FaceStore.swift
// R1：face_observations / face_analysis_state / face_cluster_state / face_clusters /
// face_cluster_members / role_bindings 的访问入口（取代 Database/Repositories/FaceRepo.swift；
// 本轮先落观察/分析状态/复用/缩略图目录，集群与绑定随后并入同一 Store）。
import Foundation

public struct FaceObservationRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let photoId: String
    public let sessionId: String
    public let bboxX: Double
    public let bboxY: Double
    public let bboxW: Double
    public let bboxH: Double
    public let embedding: Data
    public let confidence: Double
    public let sourceFileSize: Int64
    public let sourceFileMtimeMs: Double
    public let analysisSignature: String

    enum CodingKeys: String, CodingKey {
        case id, embedding, confidence
        case photoId = "photo_id"
        case sessionId = "session_id"
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxW = "bbox_w"
        case bboxH = "bbox_h"
        case sourceFileSize = "source_file_size"
        case sourceFileMtimeMs = "source_file_mtime_ms"
        case analysisSignature = "analysis_signature"
    }
}

public struct FaceAnalysisStateRecord: Equatable, Sendable {
    public let sourceFileSize: Int64
    public let sourceFileMtimeMs: Double
    public let analysisSignature: String
}

/// 复用目标的批量输入。
public struct FaceReuseTargetInput: Equatable, Sendable {
    public let photoId: String
    public let assetFileId: String?
    public let sourceFileSize: Int64
    public let sourceFileMtimeMs: Double

    public init(photoId: String, assetFileId: String?, sourceFileSize: Int64, sourceFileMtimeMs: Double) {
        self.photoId = photoId
        self.assetFileId = assetFileId
        self.sourceFileSize = sourceFileSize
        self.sourceFileMtimeMs = sourceFileMtimeMs
    }
}

public struct FaceReuseResult: Equatable, Sendable {
    public let reused: Bool
    public let faceCount: Int64

    public init(reused: Bool, faceCount: Int64) {
        self.reused = reused
        self.faceCount = faceCount
    }
}

struct FaceReuseSource: Equatable, Sendable {
    let photoId: String
    let sourceFileSize: Int64
    let sourceFileMtimeMs: Double
    let analysisSignature: String
}

public protocol FaceStore: Sendable {
    // 观察
    func saveObservations(sessionId: String, observations: [FaceObservationInput]) async throws -> [Int64]
    func observations(sessionId: String) async throws -> [FaceObservationRecord]
    func countsByPhoto(sessionId: String, photoIds: [String]) async throws -> [String: Int]
    func replaceObservationsByPhoto(
        sessionId: String,
        photoId: String,
        observations: [FaceObservationInput]
    ) async throws -> [Int64]
    func updateEmbedding(observationId: Int64, embedding: [Float]) async throws
    func deleteObservationsBySession(_ sessionId: String) async throws
    func deleteObservationsByPhoto(sessionId: String, photoId: String) async throws

    // 分析状态
    func analysisStates(sessionId: String) async throws -> [String: FaceAnalysisStateRecord]
    func upsertAnalysisState(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) async throws
    func deleteAnalysisStateByPhoto(sessionId: String, photoId: String) async throws

    // 复用
    func reuseObservations(
        sessionId: String,
        targets: [FaceReuseTargetInput],
        analysisSignature: String
    ) async throws -> [String: FaceReuseResult]
    func reuseObservations(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) async throws -> FaceReuseResult

    // 集群签名
    func clusterSignature(sessionId: String) async throws -> String?
    func upsertClusterSignature(sessionId: String, signature: String) async throws

    // 缩略图目录
    func faceThumbnailDir() async throws -> String

    // MARK: 聚类

    func updateClusterThumbnail(clusterId: Int64, thumbnailPath: String) async throws
    func saveClusters(sessionId: String, clusters: [FaceClusterInput]) async throws -> [Int64]
    func clusters(sessionId: String, includeMembers: Bool) async throws -> [FaceClusterRecord]
    func clusterThumbnailPath(clusterId: Int64) async throws -> String
    func clusterSessionId(clusterId: Int64) async throws -> String?
    func clusterMembers(clusterId: Int64) async throws -> [ClusterMemberLite]
    func thumbnailPaths(sessionId: String) async throws -> [String]
    func mergeClusters(sourceId: Int64, targetId: Int64) async throws
    func restoreMerge(
        sourceId: Int64,
        targetId: Int64,
        sessionId: String,
        sourceMemberIds: [Int64],
        sourceMemberCount: Int64,
        sourceBinding: FaceBindingData?
    ) async throws
    func deleteClustersBySession(_ sessionId: String) async throws
    func removeMemberFromCluster(clusterId: Int64, memberId: Int64) async throws -> Bool

    // MARK: 绑定

    func updateBinding(clusterId: Int64, roleName: String, keywords: [String]) async throws
    func deleteBinding(clusterId: Int64) async throws
    func restoreBinding(clusterId: Int64, sessionId: String, roleName: String, keywords: [String]) async throws
    func bindingsBySession(_ sessionId: String) async throws -> [FaceBindingDetail]
}

public struct FaceClusterRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let sessionId: String
    public let label: String
    public let memberCount: Int64
    public let status: String
    public let thumbnailBase64: String
    public let thumbnailPath: String
    public var members: [FaceClusterMemberRecord]?
    public var binding: FaceBindingData?

    enum CodingKeys: String, CodingKey {
        case id, label, status
        case sessionId = "session_id"
        case memberCount = "member_count"
        case thumbnailBase64 = "thumbnail_base64"
        case thumbnailPath = "thumbnail_path"
    }
}

public struct FaceClusterMemberRecord: Decodable, Equatable, Sendable {
    public let id: Int64
    public let clusterId: Int64
    public let sessionId: String
    public let photoId: String
    public let photoPath: String
    public let bbox: String
    public let confidence: Double
    public let observationId: Int64?

    enum CodingKeys: String, CodingKey {
        case id, bbox, confidence
        case clusterId = "cluster_id"
        case sessionId = "session_id"
        case photoId = "photo_id"
        case photoPath = "photo_path"
        case observationId = "observation_id"
    }
}

public struct SQLiteFaceStore: FaceStore {
    private let database: SQLiteDatabase
    private let faceThumbnailDirOverride: String?

    public init(database: SQLiteDatabase, faceThumbnailDir: String? = nil) {
        self.database = database
        self.faceThumbnailDirOverride = faceThumbnailDir
    }

    // MARK: 观察

    public func saveObservations(sessionId: String, observations: [FaceObservationInput]) async throws -> [Int64] {
        var ids: [Int64] = []
        try await database.transaction { db in
            for observation in observations {
                try db.run(
                    """
                    INSERT INTO face_observations
                     (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                      source_file_size, source_file_mtime_ms, analysis_signature)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    Self.observationValues(sessionId: sessionId, observation: observation)
                )
                ids.append(db.lastInsertRowID)
            }
        }
        return ids
    }

    public func observations(sessionId: String) async throws -> [FaceObservationRecord] {
        try await database.query(
            "SELECT * FROM face_observations WHERE session_id = ? ORDER BY id",
            [.text(sessionId)]
        ).map { try $0.decode(FaceObservationRecord.self) }
    }

    public func countsByPhoto(sessionId: String, photoIds: [String]) async throws -> [String: Int] {
        guard !photoIds.isEmpty else { return [:] }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ", ")
        let rows = try await database.query(
            """
            SELECT photo_id, COUNT(*) AS cnt FROM face_observations
            WHERE session_id = ? AND photo_id IN (\(placeholders)) GROUP BY photo_id
            """,
            [.text(sessionId)] + photoIds.map { .text($0) }
        )
        var counts: [String: Int] = [:]
        for row in rows {
            guard let photoId = row.text("photo_id") else { continue }
            counts[photoId] = Int(row.int("cnt") ?? 0)
        }
        return counts
    }

    /// 原子替换照片的人脸观察：先删旧后插新，失败时旧数据不受影响。
    public func replaceObservationsByPhoto(
        sessionId: String,
        photoId: String,
        observations: [FaceObservationInput]
    ) async throws -> [Int64] {
        var ids: [Int64] = []
        try await database.transaction { db in
            try db.run(
                "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?",
                [.text(sessionId), .text(photoId)]
            )
            for observation in observations {
                try db.run(
                    """
                    INSERT INTO face_observations
                     (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                      source_file_size, source_file_mtime_ms, analysis_signature)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    Self.observationValues(sessionId: sessionId, observation: observation)
                )
                ids.append(db.lastInsertRowID)
            }
        }
        return ids
    }

    public func updateEmbedding(observationId: Int64, embedding: [Float]) async throws {
        try await database.run(
            "UPDATE face_observations SET embedding = ? WHERE id = ?",
            [.blob(Self.embeddingData(embedding)), .int(observationId)]
        )
    }

    public func deleteObservationsBySession(_ sessionId: String) async throws {
        try await database.transaction { db in
            try db.run("DELETE FROM face_observations WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM face_analysis_state WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM face_cluster_state WHERE session_id = ?", [.text(sessionId)])
        }
    }

    public func deleteObservationsByPhoto(sessionId: String, photoId: String) async throws {
        try await database.run(
            "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?",
            [.text(sessionId), .text(photoId)]
        )
    }

    // MARK: 分析状态

    public func analysisStates(sessionId: String) async throws -> [String: FaceAnalysisStateRecord] {
        let rows = try await database.query(
            """
            SELECT photo_id, source_file_size, source_file_mtime_ms, analysis_signature
            FROM face_analysis_state WHERE session_id = ?
            """,
            [.text(sessionId)]
        )
        var result: [String: FaceAnalysisStateRecord] = [:]
        for row in rows {
            result[row.text("photo_id") ?? ""] = FaceAnalysisStateRecord(
                sourceFileSize: row.int("source_file_size") ?? 0,
                sourceFileMtimeMs: row.double("source_file_mtime_ms") ?? 0,
                analysisSignature: row.text("analysis_signature") ?? ""
            )
        }
        return result
    }

    public func upsertAnalysisState(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) async throws {
        try await database.run(
            Self.upsertAnalysisStateSQL,
            [
                .text(photoId), .text(sessionId), .int(sourceFileSize),
                .real(sourceFileMtimeMs), .text(analysisSignature), .text(nowISOString()),
            ]
        )
    }

    public func deleteAnalysisStateByPhoto(sessionId: String, photoId: String) async throws {
        try await database.run(
            "DELETE FROM face_analysis_state WHERE session_id = ? AND photo_id = ?",
            [.text(sessionId), .text(photoId)]
        )
    }

    // MARK: 复用

    /// 复用同 asset file、文件状态（size/mtime）与签名完全一致的观察（批量形式）。
    public func reuseObservations(
        sessionId: String,
        targets: [FaceReuseTargetInput],
        analysisSignature: String
    ) async throws -> [String: FaceReuseResult] {
        var results: [String: FaceReuseResult] = [:]
        var seen = Set<String>()
        let assetFileIds = targets.compactMap { target -> String? in
            guard let id = target.assetFileId, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }
        if assetFileIds.isEmpty { return results }

        var sourcesByAssetFile: [String: [FaceReuseSource]] = [:]
        for chunk in assetFileIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try await database.query(
                """
                SELECT p.asset_file_id, s.photo_id, s.source_file_size,
                       s.source_file_mtime_ms, s.analysis_signature
                FROM photos p
                JOIN face_analysis_state s ON s.photo_id = p.id AND s.session_id = p.session_id
                WHERE p.asset_file_id IN (\(placeholders))
                ORDER BY s.updated_at DESC
                """,
                chunk.map { .text($0) }
            )
            for row in rows {
                let key = row.text("asset_file_id") ?? ""
                sourcesByAssetFile[key, default: []].append(FaceReuseSource(
                    photoId: row.text("photo_id") ?? "",
                    sourceFileSize: row.int("source_file_size") ?? 0,
                    sourceFileMtimeMs: row.double("source_file_mtime_ms") ?? 0,
                    analysisSignature: row.text("analysis_signature") ?? ""
                ))
            }
        }

        for target in targets {
            guard let assetFileId = target.assetFileId else { continue }
            let source = (sourcesByAssetFile[assetFileId] ?? []).first { candidate in
                candidate.photoId != target.photoId &&
                candidate.sourceFileSize == target.sourceFileSize &&
                abs(candidate.sourceFileMtimeMs - target.sourceFileMtimeMs) < 1 &&
                candidate.analysisSignature == analysisSignature
            }
            guard let source else { continue }
            let faceCount = try await database.transaction { db -> Int64 in
                try db.run(
                    "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?",
                    [.text(sessionId), .text(target.photoId)]
                )
                let copied = try db.run(
                    """
                    INSERT INTO face_observations (
                      photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                      source_file_size, source_file_mtime_ms, analysis_signature, created_at
                    )
                    SELECT ?, ?, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                           source_file_size, source_file_mtime_ms, analysis_signature, ?
                    FROM face_observations
                    WHERE photo_id = ?
                      AND session_id = (SELECT session_id FROM photos WHERE id = ?)
                    """,
                    [
                        .text(target.photoId), .text(sessionId), .text(nowISOString()),
                        .text(source.photoId), .text(source.photoId),
                    ]
                )
                try db.run(
                    Self.upsertAnalysisStateSQL,
                    [
                        .text(target.photoId), .text(sessionId), .int(target.sourceFileSize),
                        .real(target.sourceFileMtimeMs), .text(analysisSignature), .text(nowISOString()),
                    ]
                )
                return Int64(copied)
            }
            results[target.photoId] = FaceReuseResult(reused: true, faceCount: faceCount)
        }
        return results
    }

    public func reuseObservations(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) async throws -> FaceReuseResult {
        let assetFileId = try await database.queryOne(
            "SELECT asset_file_id FROM photos WHERE id = ? AND session_id = ?",
            [.text(photoId), .text(sessionId)]
        )?.text("asset_file_id")
        let results = try await reuseObservations(
            sessionId: sessionId,
            targets: [
                FaceReuseTargetInput(
                    photoId: photoId,
                    assetFileId: assetFileId,
                    sourceFileSize: sourceFileSize,
                    sourceFileMtimeMs: sourceFileMtimeMs
                )
            ],
            analysisSignature: analysisSignature
        )
        return results[photoId] ?? FaceReuseResult(reused: false, faceCount: 0)
    }

    // MARK: 集群签名

    public func clusterSignature(sessionId: String) async throws -> String? {
        try await database.queryOne(
            "SELECT cluster_signature FROM face_cluster_state WHERE session_id = ?",
            [.text(sessionId)]
        )?.text("cluster_signature")
    }

    public func upsertClusterSignature(sessionId: String, signature: String) async throws {
        try await database.run(
            """
            INSERT INTO face_cluster_state (session_id, cluster_signature, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
              cluster_signature = excluded.cluster_signature,
              updated_at = excluded.updated_at
            """,
            [.text(sessionId), .text(signature), .text(nowISOString())]
        )
    }

    // MARK: 缩略图目录

    public func faceThumbnailDir() async throws -> String {
        let dir = resolveFaceThumbnailDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolveFaceThumbnailDir() -> String {
        if let faceThumbnailDirOverride, !faceThumbnailDirOverride.isEmpty { return faceThumbnailDirOverride }
        #if os(macOS)
        return TSPath.join([NSHomeDirectory(), "Library", "Application Support", "Gather", "face-thumbnails"])
        #else
        return TSPath.join([NSHomeDirectory(), ".local", "share", "gather", "face-thumbnails"])
        #endif
    }

    // MARK: 私有辅助

    static let upsertAnalysisStateSQL = """
        INSERT INTO face_analysis_state
         (photo_id, session_id, source_file_size, source_file_mtime_ms, analysis_signature, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(photo_id) DO UPDATE SET
           session_id = excluded.session_id,
           source_file_size = excluded.source_file_size,
           source_file_mtime_ms = excluded.source_file_mtime_ms,
           analysis_signature = excluded.analysis_signature,
           updated_at = excluded.updated_at
        """

    private static func observationValues(
        sessionId: String,
        observation: FaceObservationInput
    ) -> [SQLiteValue] {
        [
            .text(observation.photoId),
            .text(sessionId),
            .real(observation.bboxX),
            .real(observation.bboxY),
            .real(observation.bboxW),
            .real(observation.bboxH),
            .blob(embeddingData(observation.embedding)),
            .real(observation.confidence),
            .int(observation.sourceFileSize ?? 0),
            .real(observation.sourceFileMtimeMs ?? 0),
            .text(observation.analysisSignature ?? ""),
        ]
    }

    /// TS: Buffer.from(new Float32Array(embedding).buffer)。
    internal static func embeddingData(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }
}

// MARK: - 聚类与绑定实现

public extension SQLiteFaceStore {
    func updateClusterThumbnail(clusterId: Int64, thumbnailPath: String) async throws {
        try await database.run(
            "UPDATE face_clusters SET thumbnail_path = ? WHERE id = ?",
            [.text(thumbnailPath), .int(clusterId)]
        )
    }

    func saveClusters(sessionId: String, clusters: [FaceClusterInput]) async throws -> [Int64] {
        var ids: [Int64] = []
        try await database.transaction { db in
            for cluster in clusters {
                try db.run(
                    """
                    INSERT INTO face_clusters
                      (session_id, label, member_count, status, thumbnail_base64, thumbnail_path)
                    VALUES (?, ?, ?, 'unbound', '', '')
                    """,
                    [.text(sessionId), .text(cluster.label), .int(Int64(cluster.members.count))]
                )
                let clusterId = db.lastInsertRowID
                ids.append(clusterId)
                for member in cluster.members {
                    let bboxJSON = try JSONValue.stringify(
                        JSONValue.array(member.bbox.map { JSONValue.real($0) })
                    )
                    try db.run(
                        """
                        INSERT INTO face_cluster_members
                          (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .int(clusterId), .text(sessionId), .text(member.photoId),
                            .text(bboxJSON), .real(member.confidence),
                            member.observationId.map { SQLiteValue.int($0) } ?? .null,
                        ]
                    )
                }
            }
        }
        return ids
    }

    func clusters(sessionId: String, includeMembers: Bool = false) async throws -> [FaceClusterRecord] {
        let records = try await database.query(
            "SELECT * FROM face_clusters WHERE session_id = ? AND member_count > 0 ORDER BY id",
            [.text(sessionId)]
        ).map { try $0.decode(FaceClusterRecord.self) }
        if !includeMembers || records.isEmpty { return records }
        let clusterIds = records.map(\.id)

        var membersByCluster: [Int64: [FaceClusterMemberRecord]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id,
                       p.filepath AS photo_path, fm.bbox, fm.confidence, fm.observation_id
                FROM face_cluster_members fm
                JOIN photos p ON fm.photo_id = p.id
                WHERE fm.cluster_id IN (\(placeholders))
                ORDER BY fm.id
                """,
                chunk.map { .int($0) }
            )
            for row in rows {
                let member = try row.decode(FaceClusterMemberRecord.self)
                membersByCluster[member.clusterId, default: []].append(member)
            }
        }

        var bindingByCluster: [Int64: (roleName: String, keywords: [String])] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                "SELECT cluster_id, role_name, keywords FROM role_bindings WHERE cluster_id IN (\(placeholders))",
                chunk.map { .int($0) }
            )
            for row in rows {
                guard let clusterId = row.int("cluster_id") else { continue }
                bindingByCluster[clusterId] = (
                    roleName: row.text("role_name") ?? "",
                    keywords: ((try? JSONValue.parse(row.text("keywords") ?? "[]")) as JSONValue?)?.arrayValue ?? []
                )
            }
        }

        return records.map { record in
            var cluster = record
            cluster.members = membersByCluster[record.id] ?? []
            if let binding = bindingByCluster[record.id] {
                cluster.binding = FaceBindingData(
                    clusterId: String(record.id),
                    roleName: binding.roleName,
                    keywords: binding.keywords
                )
            }
            return cluster
        }
    }

    func clusterThumbnailPath(clusterId: Int64) async throws -> String {
        try await database.queryOne(
            "SELECT thumbnail_path FROM face_clusters WHERE id = ?",
            [.int(clusterId)]
        )?.text("thumbnail_path") ?? ""
    }

    func clusterSessionId(clusterId: Int64) async throws -> String? {
        try await database.queryOne(
            "SELECT session_id FROM face_clusters WHERE id = ?",
            [.int(clusterId)]
        )?.text("session_id")
    }

    func clusterMembers(clusterId: Int64) async throws -> [ClusterMemberLite] {
        try await database.query(
            "SELECT photo_id, bbox, confidence FROM face_cluster_members WHERE cluster_id = ?",
            [.int(clusterId)]
        ).map {
            ClusterMemberLite(
                photoId: $0.text("photo_id") ?? "",
                bbox: Self.parseBbox($0.text("bbox") ?? ""),
                confidence: $0.double("confidence") ?? 0
            )
        }
    }

    func thumbnailPaths(sessionId: String) async throws -> [String] {
        try await database.query(
            "SELECT thumbnail_path FROM face_clusters WHERE session_id = ? AND thumbnail_path != '' AND member_count > 0",
            [.text(sessionId)]
        ).compactMap { $0.text("thumbnail_path") }
    }

    func mergeClusters(sourceId: Int64, targetId: Int64) async throws {
        let sourcePath = try await clusterThumbnailPath(clusterId: sourceId)
        try await database.transaction { db in
            let sourceMembers = try db.scalarInt(
                "SELECT COUNT(*) AS count FROM face_cluster_members WHERE cluster_id = ?",
                [.int(sourceId)]
            ) ?? 0
            try db.run(
                "UPDATE face_cluster_members SET cluster_id = ? WHERE cluster_id = ?",
                [.int(targetId), .int(sourceId)]
            )
            try db.run(
                "UPDATE face_clusters SET member_count = member_count + ? WHERE id = ?",
                [.int(sourceMembers), .int(targetId)]
            )
            try db.run("DELETE FROM role_bindings WHERE cluster_id = ?", [.int(sourceId)])
            try db.run(
                "UPDATE face_clusters SET member_count = 0, status = ? WHERE id = ?",
                [.text("unbound"), .int(sourceId)]
            )
        }
        deleteThumbnailFile(sourcePath)
    }

    func restoreMerge(
        sourceId: Int64,
        targetId: Int64,
        sessionId: String,
        sourceMemberIds: [Int64],
        sourceMemberCount: Int64,
        sourceBinding: FaceBindingData?
    ) async throws {
        try await database.transaction { db in
            for memberId in sourceMemberIds {
                try db.run(
                    "UPDATE face_cluster_members SET cluster_id = ? WHERE id = ?",
                    [.int(sourceId), .int(memberId)]
                )
            }
            let targetCount = try db.scalarInt(
                "SELECT COUNT(*) AS count FROM face_cluster_members WHERE cluster_id = ?",
                [.int(targetId)]
            ) ?? 0
            try db.run(
                "UPDATE face_clusters SET member_count = ? WHERE id = ?",
                [.int(sourceMemberCount), .int(sourceId)]
            )
            try db.run(
                "UPDATE face_clusters SET member_count = ?, status = ? WHERE id = ?",
                [.int(max(0, targetCount)), .text("unbound"), .int(targetId)]
            )
            if let sourceBinding {
                try db.run(
                    """
                    INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords)
                    VALUES (?, ?, ?, ?)
                    """,
                    [
                        .int(sourceId), .text(sessionId), .text(sourceBinding.roleName),
                        .text(try JSONValue.stringify(
                            JSONValue.array(sourceBinding.keywords.map { JSONValue.string($0) })
                        )),
                    ]
                )
                try db.run("UPDATE face_clusters SET status = 'bound' WHERE id = ?", [.int(sourceId)])
            }
        }
    }

    func deleteClustersBySession(_ sessionId: String) async throws {
        let paths = try await thumbnailPaths(sessionId: sessionId)
        try await database.transaction { db in
            try db.run("DELETE FROM face_cluster_members WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM role_bindings WHERE session_id = ?", [.text(sessionId)])
            try db.run("DELETE FROM face_clusters WHERE session_id = ?", [.text(sessionId)])
        }
        for path in paths { deleteThumbnailFile(path) }
    }

    func removeMemberFromCluster(clusterId: Int64, memberId: Int64) async throws -> Bool {
        let memberCount = try await database.scalarInt(
            "SELECT COUNT(*) AS count FROM face_cluster_members WHERE cluster_id = ?",
            [.int(clusterId)]
        ) ?? 0
        let thumbnailPathToDelete = memberCount == 1 ? try await clusterThumbnailPath(clusterId: clusterId) : ""

        let deleted = try await database.transaction { db -> Bool in
            let removed = try db.run(
                "DELETE FROM face_cluster_members WHERE cluster_id = ? AND id = ?",
                [.int(clusterId), .int(memberId)]
            )
            if removed == 0 { return false }
            let remaining = try db.scalarInt(
                "SELECT COUNT(*) AS count FROM face_cluster_members WHERE cluster_id = ?",
                [.int(clusterId)]
            ) ?? 0
            if remaining == 0 {
                try db.run("DELETE FROM role_bindings WHERE cluster_id = ?", [.int(clusterId)])
                try db.run("DELETE FROM face_clusters WHERE id = ?", [.int(clusterId)])
            } else {
                try db.run(
                    "UPDATE face_clusters SET member_count = ? WHERE id = ?",
                    [.int(remaining), .int(clusterId)]
                )
            }
            return true
        }
        if deleted { deleteThumbnailFile(thumbnailPathToDelete) }
        return deleted
    }

    // MARK: 绑定

    func updateBinding(clusterId: Int64, roleName: String, keywords: [String]) async throws {
        let keywordsJSON = try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))
        try await database.transaction { db in
            let existing = try db.queryOne("SELECT id FROM role_bindings WHERE cluster_id = ?", [.int(clusterId)])
            if existing != nil {
                try db.run(
                    "UPDATE role_bindings SET role_name = ?, keywords = ? WHERE cluster_id = ?",
                    [.text(roleName), .text(keywordsJSON), .int(clusterId)]
                )
            } else {
                let sessionId = try db.queryOne("SELECT session_id FROM face_clusters WHERE id = ?", [.int(clusterId)])?
                    .text("session_id") ?? ""
                try db.run(
                    "INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)",
                    [.int(clusterId), .text(sessionId), .text(roleName), .text(keywordsJSON)]
                )
            }
            try db.run("UPDATE face_clusters SET status = 'bound' WHERE id = ?", [.int(clusterId)])
        }
    }

    func deleteBinding(clusterId: Int64) async throws {
        try await database.transaction { db in
            try db.run("DELETE FROM role_bindings WHERE cluster_id = ?", [.int(clusterId)])
            try db.run("UPDATE face_clusters SET status = 'unbound' WHERE id = ?", [.int(clusterId)])
        }
    }

    func restoreBinding(clusterId: Int64, sessionId: String, roleName: String, keywords: [String]) async throws {
        let keywordsJSON = try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))
        try await database.transaction { db in
            try db.run(
                "INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)",
                [.int(clusterId), .text(sessionId), .text(roleName), .text(keywordsJSON)]
            )
            try db.run("UPDATE face_clusters SET status = 'bound' WHERE id = ?", [.int(clusterId)])
        }
    }

    func bindingsBySession(_ sessionId: String) async throws -> [FaceBindingDetail] {
        let bindings = try await database.query(
            "SELECT cluster_id, role_name, keywords FROM role_bindings WHERE session_id = ?",
            [.text(sessionId)]
        )
        if bindings.isEmpty { return [] }
        let clusterIds = bindings.compactMap { $0.int("cluster_id") }
        var memberPhotoIdsByCluster: [Int64: [String]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try await database.query(
                """
                SELECT DISTINCT cluster_id, photo_id FROM face_cluster_members
                WHERE cluster_id IN (\(placeholders))
                """,
                chunk.map { .int($0) }
            )
            for row in rows {
                guard let clusterId = row.int("cluster_id") else { continue }
                memberPhotoIdsByCluster[clusterId, default: []].append(row.text("photo_id") ?? "")
            }
        }
        return bindings.map { row in
            let clusterId = row.int("cluster_id") ?? 0
            return FaceBindingDetail(
                clusterId: clusterId,
                roleName: row.text("role_name") ?? "",
                keywords: ((try? JSONValue.parse(row.text("keywords") ?? "[]")) as JSONValue?)?.arrayValue ?? [],
                memberPhotoIds: memberPhotoIdsByCluster[clusterId] ?? []
            )
        }
    }

    // MARK: 缩略图文件

    private func deleteThumbnailFile(_ thumbnailPath: String) {
        if thumbnailPath.isEmpty { return }
        let fullPath = TSPath.join([resolveFaceThumbnailDir(), thumbnailPath])
        try? FileManager.default.removeItem(atPath: fullPath)
    }

    internal static func parseBbox(_ raw: String) -> [Double] {
        guard let value = try? JSONValue.parse(raw), case .array(let items) = value else { return [] }
        return items.compactMap {
            if case .number(let v) = $0 { return v }
            return nil
        }
    }
}

// MARK: - 复用型 DTO（从 Database/Repositories/FaceRepo.swift 迁入，R1 单一来源）

/// TS FaceClusterInput.members 元素。
public struct FaceClusterMemberInput {
    public let photoId: String
    public let photoPath: String
    public let bbox: [Double]
    public let confidence: Double
    public let observationId: Int64?

    public init(photoId: String, photoPath: String, bbox: [Double], confidence: Double, observationId: Int64? = nil) {
        self.photoId = photoId
        self.photoPath = photoPath
        self.bbox = bbox
        self.confidence = confidence
        self.observationId = observationId
    }
}

/// TS FaceClusterInput。
public struct FaceClusterInput {
    public let label: String
    public let members: [FaceClusterMemberInput]

    public init(label: String, members: [FaceClusterMemberInput]) {
        self.label = label
        self.members = members
    }
}

/// 绑定信息（TS FaceClusterRow.binding）。
public struct FaceBindingData: Equatable, Sendable {
    public let clusterId: String
    public let roleName: String
    public let keywords: [String]

    public init(clusterId: String, roleName: String, keywords: [String]) {
        self.clusterId = clusterId
        self.roleName = roleName
        self.keywords = keywords
    }
}

/// getClusterMembers 的成员投影。
public struct ClusterMemberLite {
    public let photoId: String
    public let bbox: [Double]
    public let confidence: Double

    public init(photoId: String, bbox: [Double], confidence: Double) {
        self.photoId = photoId
        self.bbox = bbox
        self.confidence = confidence
    }
}

/// getBindingsBySession 的绑定详情。
public struct FaceBindingDetail {
    public let clusterId: Int64
    public let roleName: String
    public let keywords: [String]
    public let memberPhotoIds: [String]

    public init(clusterId: Int64, roleName: String, keywords: [String], memberPhotoIds: [String]) {
        self.clusterId = clusterId
        self.roleName = roleName
        self.keywords = keywords
        self.memberPhotoIds = memberPhotoIds
    }
}

// MARK: - 观察输入（从 Database/Repositories/FaceRepo.swift 迁入，R1 单一来源）

/// TS FaceObservationInput。
public struct FaceObservationInput {
    public let photoId: String
    public let bboxX: Double
    public let bboxY: Double
    public let bboxW: Double
    public let bboxH: Double
    public let embedding: [Float]
    public let confidence: Double
    public var sourceFileSize: Int64?
    public var sourceFileMtimeMs: Double?
    public var analysisSignature: String?

    public init(
        photoId: String,
        bboxX: Double,
        bboxY: Double,
        bboxW: Double,
        bboxH: Double,
        embedding: [Float],
        confidence: Double,
        sourceFileSize: Int64? = nil,
        sourceFileMtimeMs: Double? = nil,
        analysisSignature: String? = nil
    ) {
        self.photoId = photoId
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxW = bboxW
        self.bboxH = bboxH
        self.embedding = embedding
        self.confidence = confidence
        self.sourceFileSize = sourceFileSize
        self.sourceFileMtimeMs = sourceFileMtimeMs
        self.analysisSignature = analysisSignature
    }
}
