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
