// desktop/native/gather-core/Sources/GatherCore/Database/Repositories/FaceRepo.swift
// TS 源: desktop/src/main/db/repositories/face.repo.ts
// 偏差：TS 侧 SettingsService/app.getPath('userData') 尚未移植，缩略图目录改为
// 构造参数注入（faceThumbnailDir），缺省时回落用户主目录下的 face-thumbnails。
import Foundation

/// face_observations 表行（列序与 SELECT * 一致，见 Schema.swift）。
public struct FaceObservationRow {
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

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        photoId = row[1].textValue ?? ""
        sessionId = row[2].textValue ?? ""
        bboxX = row[3].doubleValue ?? 0
        bboxY = row[4].doubleValue ?? 0
        bboxW = row[5].doubleValue ?? 0
        bboxH = row[6].doubleValue ?? 0
        embedding = {
            if case .blob(let data) = row[7] { return data }
            return Data()
        }()
        confidence = row[8].doubleValue ?? 0
        sourceFileSize = row[9].intValue ?? 0
        sourceFileMtimeMs = row[10].doubleValue ?? 0
        analysisSignature = row[11].textValue ?? ""
    }
}

/// face_clusters 表行（列序与 SELECT * 一致）。
public struct FaceClusterRow {
    public let id: Int64
    public let sessionId: String
    public let label: String
    public let memberCount: Int64
    public let status: String
    public let thumbnailBase64: String
    public let thumbnailPath: String
    public var members: [FaceClusterMemberRow]?
    public var binding: FaceBindingData?

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        sessionId = row[1].textValue ?? ""
        label = row[2].textValue ?? ""
        memberCount = row[3].intValue ?? 0
        status = row[4].textValue ?? ""
        thumbnailBase64 = row[5].textValue ?? ""
        thumbnailPath = row[6].textValue ?? ""
        members = nil
        binding = nil
    }
}

/// face_cluster_members JOIN photos 的行（fm.id, fm.cluster_id, fm.session_id,
/// fm.photo_id, p.filepath AS photo_path, fm.bbox, fm.confidence, fm.observation_id）。
public struct FaceClusterMemberRow {
    public let id: Int64
    public let clusterId: Int64
    public let sessionId: String
    public let photoId: String
    public let photoPath: String
    public let bbox: String
    public let confidence: Double
    public let observationId: Int64?

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        clusterId = row[1].intValue ?? 0
        sessionId = row[2].textValue ?? ""
        photoId = row[3].textValue ?? ""
        photoPath = row[4].textValue ?? ""
        bbox = row[5].textValue ?? ""
        confidence = row[6].doubleValue ?? 0
        observationId = row[7].intValue
    }
}

/// role_bindings 行（id, cluster_id, session_id, role_name, keywords）。
public struct RoleBindingRow {
    public let id: Int64
    public let clusterId: Int64
    public let sessionId: String
    public let roleName: String
    public let keywords: String

    public init(row: DBRow) {
        id = row[0].intValue ?? 0
        clusterId = row[1].intValue ?? 0
        sessionId = row[2].textValue ?? ""
        roleName = row[3].textValue ?? ""
        keywords = row[4].textValue ?? "[]"
    }
}

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

// 复用型 DTO（FaceClusterMemberInput / FaceClusterInput / FaceBindingData / ClusterMemberLite /
// FaceBindingDetail）已迁至 Store/FaceStore.swift（R1 单一来源）。

/// getAnalysisStates 的映射值。
public struct FaceAnalysisState: Equatable, Sendable {
    public let sourceFileSize: Int64
    public let sourceFileMtimeMs: Double
    public let analysisSignature: String
}

/// reuseObservationsForAssetFile 的批量目标。
public struct FaceReuseTarget {
    public let photoId: String
    public let assetFileId: String?
    public let sourceFileSize: Int64
    public let sourceFileMtimeMs: Double
}

/// reuseObservationsForAssetFile 的单目标结果。
public struct ReuseResult: Equatable, Sendable {
    public let reused: Bool
    public let faceCount: Int64
}

/// 人脸仓库（TS FaceRepository）。
public final class FaceRepo {
    private let connection: DBConnection
    private let faceThumbnailDir: String?

    public init(connection: DBConnection, faceThumbnailDir: String? = nil) {
        self.connection = connection
        self.faceThumbnailDir = faceThumbnailDir
    }

    // ─────────────────────────── 观察 ───────────────────────────

    public func saveObservations(sessionId: String, observations: [FaceObservationInput]) throws -> [Int64] {
        var ids: [Int64] = []
        let stmt = try connection.prepare("""
            INSERT INTO face_observations
             (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
              source_file_size, source_file_mtime_ms, analysis_signature)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        try connection.transaction {
            for obs in observations {
                _ = try stmt.run([
                    .text(obs.photoId),
                    .text(sessionId),
                    .real(obs.bboxX),
                    .real(obs.bboxY),
                    .real(obs.bboxW),
                    .real(obs.bboxH),
                    .blob(Self.embeddingData(obs.embedding)),
                    .real(obs.confidence),
                    .int(obs.sourceFileSize ?? 0),
                    .real(obs.sourceFileMtimeMs ?? 0),
                    .text(obs.analysisSignature ?? ""),
                ])
                ids.append(connection.lastInsertRowid)
            }
        }
        return ids
    }

    public func getObservations(_ sessionId: String) throws -> [FaceObservationRow] {
        let rows = try connection.prepare(
            "SELECT * FROM face_observations WHERE session_id = ? ORDER BY id"
        ).query([.text(sessionId)])
        return rows.map { FaceObservationRow(row: $0) }
    }

    /// 批量照片的人脸观测计数（photo.id → 数量；无观测的照片不出现在结果中）。
    /// 供 photo 列表分页附带 faceCount（TS photo.ipc.ts assemblePhotos 的两次
    /// 小查询之一，原在宿主路由内联 SQL，下沉回 Repo）。
    public func countsByPhoto(sessionId: String, photoIds: [String]) throws -> [String: Int] {
        guard !photoIds.isEmpty else { return [:] }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ", ")
        let rows = try connection.prepare("""
            SELECT photo_id, COUNT(*) AS cnt FROM face_observations
            WHERE session_id = ? AND photo_id IN (\(placeholders)) GROUP BY photo_id
        """).query([.text(sessionId)] + photoIds.map(DBValue.text))
        var counts: [String: Int] = [:]
        for row in rows {
            guard let photoId = row[0].textValue else { continue }
            counts[photoId] = Int(row[1].intValue ?? 0)
        }
        return counts
    }

    public func getAnalysisStates(_ sessionId: String) throws -> [String: FaceAnalysisState] {
        let rows = try connection.prepare("""
            SELECT photo_id, source_file_size, source_file_mtime_ms, analysis_signature
            FROM face_analysis_state WHERE session_id = ?
          """).query([.text(sessionId)])
        var result: [String: FaceAnalysisState] = [:]
        for row in rows {
            result[row[0].textValue ?? ""] = FaceAnalysisState(
                sourceFileSize: row[1].intValue ?? 0,
                sourceFileMtimeMs: row[2].doubleValue ?? 0,
                analysisSignature: row[3].textValue ?? ""
            )
        }
        return result
    }

    /// 复用同 asset file、文件状态（size/mtime）与签名完全一致的观察（批量形式）。
    public func reuseObservationsForAssetFile(
        sessionId: String,
        targets: [FaceReuseTarget],
        analysisSignature: String
    ) throws -> [String: ReuseResult] {
        var results: [String: ReuseResult] = [:]
        var seen = Set<String>()
        let assetFileIds = targets.compactMap { target -> String? in
            guard let id = target.assetFileId, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }
        if assetFileIds.isEmpty { return results }
        // ORDER BY s.updated_at DESC ranks every candidate; per target the first
        // row that matches its file state is the source the per-photo query
        // (ORDER BY updated_at DESC LIMIT 1) would have picked.
        var sourcesByAssetFile: [String: [FaceReuseSource]] = [:]
        for chunk in assetFileIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT p.asset_file_id, s.photo_id, s.source_file_size,
                       s.source_file_mtime_ms, s.analysis_signature
                FROM photos p
                JOIN face_analysis_state s ON s.photo_id = p.id AND s.session_id = p.session_id
                WHERE p.asset_file_id IN (\(placeholders))
                ORDER BY s.updated_at DESC
              """).query(chunk.map { .text($0) })
            for row in rows {
                let key = row[0].textValue ?? ""
                var list = sourcesByAssetFile[key] ?? []
                list.append(FaceReuseSource(
                    photoId: row[1].textValue ?? "",
                    sourceFileSize: row[2].intValue ?? 0,
                    sourceFileMtimeMs: row[3].doubleValue ?? 0,
                    analysisSignature: row[4].textValue ?? ""
                ))
                sourcesByAssetFile[key] = list
            }
        }
        let deleteStmt = try connection.prepare(
            "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?"
        )
        let copyStmt = try connection.prepare("""
            INSERT INTO face_observations (
              photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
              source_file_size, source_file_mtime_ms, analysis_signature, created_at
            )
            SELECT ?, ?, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                   source_file_size, source_file_mtime_ms, analysis_signature, ?
            FROM face_observations
            WHERE photo_id = ?
              AND session_id = (SELECT session_id FROM photos WHERE id = ?)
          """)
        for target in targets {
            guard let assetFileId = target.assetFileId else { continue }
            let source = (sourcesByAssetFile[assetFileId] ?? []).first { candidate in
                candidate.photoId != target.photoId &&
                candidate.sourceFileSize == target.sourceFileSize &&
                abs(candidate.sourceFileMtimeMs - target.sourceFileMtimeMs) < 1 &&
                candidate.analysisSignature == analysisSignature
            }
            guard let source else { continue }
            var faceCount: Int64 = 0
            try connection.transaction {
                _ = try deleteStmt.run([.text(sessionId), .text(target.photoId)])
                let copied = try copyStmt.run([
                    .text(target.photoId), .text(sessionId), .text(nowISOString()),
                    .text(source.photoId), .text(source.photoId),
                ])
                faceCount = Int64(copied)
                try upsertAnalysisState(
                    sessionId: sessionId,
                    photoId: target.photoId,
                    sourceFileSize: target.sourceFileSize,
                    sourceFileMtimeMs: target.sourceFileMtimeMs,
                    analysisSignature: analysisSignature
                )
            }
            results[target.photoId] = ReuseResult(reused: true, faceCount: faceCount)
        }
        return results
    }

    /// 复用观察（单照片兼容形式：先解析目标的 asset file，再委托批量形式）。
    public func reuseObservationsForAssetFile(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) throws -> ReuseResult {
        let row = try connection.prepare(
            "SELECT asset_file_id FROM photos WHERE id = ? AND session_id = ?"
        ).get([.text(photoId), .text(sessionId)])
        let results = try reuseObservationsForAssetFile(
            sessionId: sessionId,
            targets: [FaceReuseTarget(
                photoId: photoId,
                assetFileId: row?[0].textValue,
                sourceFileSize: sourceFileSize,
                sourceFileMtimeMs: sourceFileMtimeMs
            )],
            analysisSignature: analysisSignature
        )
        return results[photoId] ?? ReuseResult(reused: false, faceCount: 0)
    }

    public func upsertAnalysisState(
        sessionId: String,
        photoId: String,
        sourceFileSize: Int64,
        sourceFileMtimeMs: Double,
        analysisSignature: String
    ) throws {
        _ = try connection.prepare("""
            INSERT INTO face_analysis_state
             (photo_id, session_id, source_file_size, source_file_mtime_ms, analysis_signature, updated_at)
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(photo_id) DO UPDATE SET
               session_id = excluded.session_id,
               source_file_size = excluded.source_file_size,
               source_file_mtime_ms = excluded.source_file_mtime_ms,
               analysis_signature = excluded.analysis_signature,
               updated_at = excluded.updated_at
          """).run([
            .text(photoId),
            .text(sessionId),
            .int(sourceFileSize),
            .real(sourceFileMtimeMs),
            .text(analysisSignature),
            .text(nowISOString()),
        ])
    }

    public func getClusterSignature(_ sessionId: String) throws -> String? {
        guard let row = try connection.prepare(
            "SELECT cluster_signature FROM face_cluster_state WHERE session_id = ?"
        ).get([.text(sessionId)]) else { return nil }
        return row[0].textValue
    }

    public func upsertClusterSignature(sessionId: String, signature: String) throws {
        _ = try connection.prepare("""
            INSERT INTO face_cluster_state (session_id, cluster_signature, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
              cluster_signature = excluded.cluster_signature,
              updated_at = excluded.updated_at
          """).run([.text(sessionId), .text(signature), .text(nowISOString())])
    }

    public func updateEmbedding(observationId: Int64, embedding: [Float]) throws {
        _ = try connection.prepare("UPDATE face_observations SET embedding = ? WHERE id = ?")
            .run([.blob(Self.embeddingData(embedding)), .int(observationId)])
    }

    public func deleteObservationsBySession(_ sessionId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM face_observations WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_analysis_state WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?").run([.text(sessionId)])
        }
    }

    public func deleteObservationsByPhoto(sessionId: String, photoId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?"
        ).run([.text(sessionId), .text(photoId)])
    }

    public func deleteAnalysisStateByPhoto(sessionId: String, photoId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM face_analysis_state WHERE session_id = ? AND photo_id = ?"
        ).run([.text(sessionId), .text(photoId)])
    }

    /// 原子替换照片的人脸观察：先删旧后插新，失败时旧数据不受影响。
    public func replaceObservationsByPhoto(
        sessionId: String,
        photoId: String,
        observations: [FaceObservationInput]
    ) throws -> [Int64] {
        var ids: [Int64] = []
        let deleteStmt = try connection.prepare(
            "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?"
        )
        let insertStmt = try connection.prepare("""
            INSERT INTO face_observations
             (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
              source_file_size, source_file_mtime_ms, analysis_signature)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        try connection.transaction {
            _ = try deleteStmt.run([.text(sessionId), .text(photoId)])
            for obs in observations {
                _ = try insertStmt.run([
                    .text(obs.photoId),
                    .text(sessionId),
                    .real(obs.bboxX),
                    .real(obs.bboxY),
                    .real(obs.bboxW),
                    .real(obs.bboxH),
                    .blob(Self.embeddingData(obs.embedding)),
                    .real(obs.confidence),
                    .int(obs.sourceFileSize ?? 0),
                    .real(obs.sourceFileMtimeMs ?? 0),
                    .text(obs.analysisSignature ?? ""),
                ])
                ids.append(connection.lastInsertRowid)
            }
        }
        return ids
    }

    // ─────────────────────────── 缩略图 ───────────────────────────

    public func getFaceThumbDir() throws -> String {
        let dir = resolveFaceThumbDir()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolveFaceThumbDir() -> String {
        if let faceThumbnailDir, !faceThumbnailDir.isEmpty { return faceThumbnailDir }
        #if os(macOS)
        return TSPath.join([NSHomeDirectory(), "Library", "Application Support", "Gather", "face-thumbnails"])
        #else
        return TSPath.join([NSHomeDirectory(), ".local", "share", "gather", "face-thumbnails"])
        #endif
    }

    private func deleteThumbnailFile(_ thumbnailPath: String) {
        if thumbnailPath.isEmpty { return }
        let fullPath = TSPath.join([resolveFaceThumbDir(), thumbnailPath])
        try? FileManager.default.removeItem(atPath: fullPath)
    }

    public func updateClusterThumbnail(clusterId: Int64, thumbnailPath: String) throws {
        _ = try connection.prepare("UPDATE face_clusters SET thumbnail_path = ? WHERE id = ?")
            .run([.text(thumbnailPath), .int(clusterId)])
    }

    // ─────────────────────────── 聚类 ───────────────────────────

    public func saveClusters(sessionId: String, clusters: [FaceClusterInput]) throws -> [Int64] {
        var ids: [Int64] = []
        let insertCluster = try connection.prepare(
            "INSERT INTO face_clusters (session_id, label, member_count, status, thumbnail_base64, thumbnail_path) VALUES (?, ?, ?, 'unbound', '', '')"
        )
        let insertMember = try connection.prepare(
            "INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for cluster in clusters {
                _ = try insertCluster.run([
                    .text(sessionId), .text(cluster.label), .int(Int64(cluster.members.count)),
                ])
                let clusterId = connection.lastInsertRowid
                ids.append(clusterId)
                for member in cluster.members {
                    let bboxJSON = try JSONValue.stringify(JSONValue.array(member.bbox.map { JSONValue.real($0) }))
                    _ = try insertMember.run([
                        .int(clusterId),
                        .text(sessionId),
                        .text(member.photoId),
                        .text(bboxJSON),
                        .real(member.confidence),
                        optDB(member.observationId),
                    ])
                }
            }
        }
        return ids
    }

    public func getClusters(_ sessionId: String, includeMembers: Bool = false) throws -> [FaceClusterRow] {
        let clusters = try connection.prepare(
            "SELECT * FROM face_clusters WHERE session_id = ? AND member_count > 0 ORDER BY id"
        ).query([.text(sessionId)]).map { FaceClusterRow(row: $0) }
        if !includeMembers || clusters.isEmpty { return clusters }
        let clusterIds = clusters.map(\.id)

        var membersByCluster: [Int64: [FaceClusterMemberRow]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id,
                       p.filepath as photo_path, fm.bbox, fm.confidence, fm.observation_id
                FROM face_cluster_members fm
                JOIN photos p ON fm.photo_id = p.id
                WHERE fm.cluster_id IN (\(placeholders))
                ORDER BY fm.id
              """).query(chunk.map { .int($0) })
            for row in rows {
                let member = FaceClusterMemberRow(row: row)
                var list = membersByCluster[member.clusterId] ?? []
                list.append(member)
                membersByCluster[member.clusterId] = list
            }
        }

        var bindingByCluster: [Int64: RoleBindingRow] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare(
                "SELECT * FROM role_bindings WHERE cluster_id IN (\(placeholders))"
            ).query(chunk.map { .int($0) })
            for row in rows {
                let binding = RoleBindingRow(row: row)
                bindingByCluster[binding.clusterId] = binding
            }
        }

        var result: [FaceClusterRow] = []
        for var cluster in clusters {
            cluster.members = membersByCluster[cluster.id] ?? []
            if let binding = bindingByCluster[cluster.id] {
                cluster.binding = FaceBindingData(
                    clusterId: String(binding.clusterId),
                    roleName: binding.roleName,
                    keywords: ((try? JSONValue.parse(binding.keywords)) as JSONValue?)?.arrayValue ?? []
                )
            }
            result.append(cluster)
        }
        return result
    }

    public func getClusterThumbnailPath(_ clusterId: Int64) throws -> String {
        guard let row = try connection.prepare("SELECT thumbnail_path FROM face_clusters WHERE id = ?")
            .get([.int(clusterId)]) else { return "" }
        return row[0].textValue ?? ""
    }

    public func getClusterSessionId(_ clusterId: Int64) throws -> String? {
        guard let row = try connection.prepare("SELECT session_id FROM face_clusters WHERE id = ?")
            .get([.int(clusterId)]) else { return nil }
        return row[0].textValue
    }

    public func getClusterMembers(_ clusterId: Int64) throws -> [ClusterMemberLite] {
        let rows = try connection.prepare(
            "SELECT photo_id, bbox, confidence FROM face_cluster_members WHERE cluster_id = ?"
        ).query([.int(clusterId)])
        return rows.map { row in
            ClusterMemberLite(
                photoId: row[0].textValue ?? "",
                bbox: Self.parseBbox(row[1].textValue ?? ""),
                confidence: row[2].doubleValue ?? 0
            )
        }
    }

    public func getThumbnailPathsBySession(_ sessionId: String) throws -> [String] {
        let rows = try connection.prepare(
            "SELECT thumbnail_path FROM face_clusters WHERE session_id = ? AND thumbnail_path != '' AND member_count > 0"
        ).query([.text(sessionId)])
        return rows.compactMap { $0[0].textValue }
    }

    // ─────────────────────────── 绑定 ───────────────────────────

    public func updateBinding(clusterId: Int64, roleName: String, keywords: [String]) throws {
        let existing = try connection.prepare("SELECT id FROM role_bindings WHERE cluster_id = ?")
            .get([.int(clusterId)])
        if existing != nil {
            _ = try connection.prepare(
                "UPDATE role_bindings SET role_name = ?, keywords = ? WHERE cluster_id = ?"
            ).run([
                .text(roleName),
                .text(try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))),
                .int(clusterId),
            ])
        } else {
            let cluster = try connection.prepare("SELECT session_id FROM face_clusters WHERE id = ?")
                .get([.int(clusterId)])
            _ = try connection.prepare(
                "INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)"
            ).run([
                .int(clusterId),
                .text(cluster?[0].textValue ?? ""),
                .text(roleName),
                .text(try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))),
            ])
        }
        _ = try connection.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?")
            .run([.int(clusterId)])
    }

    public func deleteBinding(clusterId: Int64) throws {
        _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(clusterId)])
        _ = try connection.prepare("UPDATE face_clusters SET status = 'unbound' WHERE id = ?")
            .run([.int(clusterId)])
    }

    public func restoreBinding(clusterId: Int64, sessionId: String, roleName: String, keywords: [String]) throws {
        try connection.transaction {
            _ = try connection.prepare(
                "INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)"
            ).run([
                .int(clusterId),
                .text(sessionId),
                .text(roleName),
                .text(try JSONValue.stringify(JSONValue.array(keywords.map { JSONValue.string($0) }))),
            ])
            _ = try connection.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?")
                .run([.int(clusterId)])
        }
    }

    public func mergeClusters(sourceId: Int64, targetId: Int64) throws {
        let sourcePath = try getClusterThumbnailPath(sourceId)
        try connection.transaction {
            let sourceMembers = try connection.prepare(
                "SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?"
            ).get([.int(sourceId)])
            _ = try connection.prepare("UPDATE face_cluster_members SET cluster_id = ? WHERE cluster_id = ?")
                .run([.int(targetId), .int(sourceId)])
            _ = try connection.prepare("UPDATE face_clusters SET member_count = member_count + ? WHERE id = ?")
                .run([.int(sourceMembers?[0].intValue ?? 0), .int(targetId)])
            _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(sourceId)])
            _ = try connection.prepare("UPDATE face_clusters SET member_count = 0, status = ? WHERE id = ?")
                .run([.text("unbound"), .int(sourceId)])
        }
        deleteThumbnailFile(sourcePath)
    }

    public func restoreMerge(
        sourceId: Int64,
        targetId: Int64,
        sessionId: String,
        sourceMemberIds: [Int64],
        sourceMemberCount: Int64,
        sourceBinding: FaceBindingData?
    ) throws {
        try connection.transaction {
            for memberId in sourceMemberIds {
                _ = try connection.prepare("UPDATE face_cluster_members SET cluster_id = ? WHERE id = ?")
                    .run([.int(sourceId), .int(memberId)])
            }
            let targetCount = try connection.prepare(
                "SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?"
            ).get([.int(targetId)])
            _ = try connection.prepare("UPDATE face_clusters SET member_count = ? WHERE id = ?")
                .run([.int(sourceMemberCount), .int(sourceId)])
            _ = try connection.prepare("UPDATE face_clusters SET member_count = ?, status = ? WHERE id = ?")
                .run([.int(max(0, targetCount?[0].intValue ?? 0)), .text("unbound"), .int(targetId)])
            if let sourceBinding {
                _ = try connection.prepare(
                    "INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)"
                ).run([
                    .int(sourceId),
                    .text(sessionId),
                    .text(sourceBinding.roleName),
                    .text(try JSONValue.stringify(JSONValue.array(sourceBinding.keywords.map { JSONValue.string($0) }))),
                ])
                _ = try connection.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?")
                    .run([.int(sourceId)])
            }
        }
    }

    public func deleteClustersBySession(_ sessionId: String) throws {
        let paths = try getThumbnailPathsBySession(sessionId)
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM role_bindings WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_clusters WHERE session_id = ?").run([.text(sessionId)])
        }
        for path in paths { deleteThumbnailFile(path) }
    }

    public func getBindingsBySession(_ sessionId: String) throws -> [FaceBindingDetail] {
        let bindings = try connection.prepare("""
            SELECT rb.cluster_id, rb.role_name, rb.keywords
            FROM role_bindings rb
            WHERE rb.session_id = ?
          """).query([.text(sessionId)])
        if bindings.isEmpty { return [] }
        let clusterIds = bindings.compactMap { $0[0].intValue }
        var memberPhotoIdsByCluster: [Int64: [String]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT DISTINCT cluster_id, photo_id FROM face_cluster_members
                WHERE cluster_id IN (\(placeholders))
              """).query(chunk.map { .int($0) })
            for row in rows {
                let clusterId = row[0].intValue ?? 0
                var list = memberPhotoIdsByCluster[clusterId] ?? []
                list.append(row[1].textValue ?? "")
                memberPhotoIdsByCluster[clusterId] = list
            }
        }
        return bindings.map { row in
            FaceBindingDetail(
                clusterId: row[0].intValue ?? 0,
                roleName: row[1].textValue ?? "",
                keywords: ((try? JSONValue.parse(row[2].textValue ?? "[]")) as JSONValue?)?.arrayValue ?? [],
                memberPhotoIds: memberPhotoIdsByCluster[row[0].intValue ?? 0] ?? []
            )
        }
    }

    public func removeMemberFromCluster(clusterId: Int64, memberId: Int64) throws -> Bool {
        let memberCount = try connection.prepare(
            "SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?"
        ).get([.int(clusterId)])
        let thumbnailPathToDelete = (memberCount?[0].intValue ?? 0) == 1
            ? try getClusterThumbnailPath(clusterId)
            : ""

        let deleted: Bool = try connection.transaction {
            let removed = try connection.prepare(
                "DELETE FROM face_cluster_members WHERE cluster_id = ? AND id = ?"
            ).run([.int(clusterId), .int(memberId)])
            if removed == 0 { return false }
            let remaining = try connection.prepare(
                "SELECT COUNT(*) as count FROM face_cluster_members WHERE cluster_id = ?"
            ).get([.int(clusterId)])
            if (remaining?[0].intValue ?? 0) == 0 {
                _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(clusterId)])
                _ = try connection.prepare("DELETE FROM face_clusters WHERE id = ?").run([.int(clusterId)])
            } else {
                _ = try connection.prepare("UPDATE face_clusters SET member_count = ? WHERE id = ?")
                    .run([.int(remaining?[0].intValue ?? 0), .int(clusterId)])
            }
            return true
        }
        if deleted { deleteThumbnailFile(thumbnailPathToDelete) }
        return deleted
    }

    // ─────────────────────────── 辅助 ───────────────────────────

    private struct FaceReuseSource {
        let photoId: String
        let sourceFileSize: Int64
        let sourceFileMtimeMs: Double
        let analysisSignature: String
    }

    private static func parseBbox(_ raw: String) -> [Double] {
        guard let value = try? JSONValue.parse(raw), case .array(let items) = value else { return [] }
        return items.compactMap {
            if case .number(let v) = $0 { return v }
            return nil
        }
    }

    /// TS `Buffer.from(new Float32Array(floats).buffer)`：原生字节序的 Float32 序列。
    private static func embeddingData(_ floats: [Float]) -> Data {
        var data = Data(count: floats.count * MemoryLayout<Float>.size)
        data.withUnsafeMutableBytes { buffer in
            floats.withUnsafeBytes { source in
                buffer.copyMemory(from: source)
            }
        }
        return data
    }
}
