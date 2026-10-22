// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo.swift
// 人脸域仓储（全量重写；TS face.repo.ts 时代的存档计数与整会话删绑定已删除）。
//
// 核心约定：
// 1. 用户数据 vs 派生数据。role_bindings / face_clusters.matched_person_id 是用户
//    身份数据；face_observations / face_cluster_members / face_cluster_state 是派生
//    数据。内容/路径变化只销毁派生数据（invalidateDerivedResults），**绝不**删除
//    role_bindings、face_clusters 或 metadata_keyword_origins —— 绑定只能由用户
//    显式解绑（deleteBinding）或人物身份生命周期（PersonRepo）变更。
// 2. 成员计数唯一真相 = COUNT(face_cluster_members)。V1 已删除 member_count 物理列
//    （读取恒为 COUNT 别名，写侧不再维护缓存）；成员清单用 LEFT JOIN photos，
//    照片行缺失的成员不再静默消失 → 计数与清单恒一致。
// 3. 孤儿绑定（成员为 0 但仍有 role_bindings）必须可读（getClusters 返回），
//    这是「解绑路径独立于簇成员身份」的载体，也是 XMP 人物关键词的清理入口。
import Foundation
import GatherProtocol

/// face_observations 行（V1 17 列；SELECT 显式列，不再读 source_file_size/mtime）。
public struct FaceObservationRow {
    /// SELECT 与位置解码共用的唯一列清单；顺序 = SchemaV1 face_observations 的物理列序。
    /// created_at 在 V1 移到列尾（旧库物理列序不同，显式 SELECT 解除该依赖）。
    public static let columns = [
        "id", "photo_id", "session_id", "bbox_x", "bbox_y", "bbox_w", "bbox_h",
        "embedding", "confidence", "analysis_signature", "quality", "face_size_px",
        "roll_degrees", "model_id", "model_version", "embedding_dim", "created_at",
    ]
    public let id: Int64
    public let photoId: String
    public let sessionId: String
    public let bboxX: Double
    public let bboxY: Double
    public let bboxW: Double
    public let bboxH: Double
    public let embedding: Data
    public let confidence: Double
    public let analysisSignature: String
    /// v34：对齐后的综合质量（[0,1]）与 bbox 短边像素、滚转角（度）。
    public let quality: Double
    public let faceSizePx: Double
    public let rollDegrees: Double
    /// 产生该向量的模型标识/版本与维度（embedding_dim 与 embedding blob 同源）。
    public let modelId: String
    public let modelVersion: String
    public let embeddingDim: Int
    public let createdAt: String

    // 列序: id(0), photo_id(1), session_id(2), bbox_x(3)…bbox_h(6), embedding(7),
    // confidence(8), analysis_signature(9), quality(10), face_size_px(11),
    // roll_degrees(12), model_id(13), model_version(14), embedding_dim(15), created_at(16)
    public init(row: DBRow) throws {
        guard row.count >= 17 else { throw DBError.message("FaceObservationRow 列数不足: \(row.count)") }
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
        analysisSignature = row[9].textValue ?? ""
        quality = row[10].doubleValue ?? 0
        faceSizePx = row[11].doubleValue ?? 0
        rollDegrees = row[12].doubleValue ?? 0
        modelId = row[13].textValue ?? ""
        modelVersion = row[14].textValue ?? ""
        embeddingDim = Int(row[15].intValue ?? 0)
        createdAt = row[16].textValue ?? ""
    }
}

/// face_clusters 行 + 实时成员计数 + 身份匹配建议（V1 10 个结果列）。
/// 列序: id(0), session_id(1), label(2), member_count(3), status(4),
///       thumbnail_path(5), matched_person_id(6), match_confidence(7),
///       created_at(8), updated_at(9)。
/// V1 删除了 thumbnail_base64；缩略图文件由 thumbnail_path 承载。
public struct FaceClusterRow {
    /// SELECT 与位置解码共用的唯一列清单（member_count 为 COUNT 别名，非物理列）。
    public static let columns = [
        "id", "session_id", "label", "member_count", "status", "thumbnail_path",
        "matched_person_id", "match_confidence", "created_at", "updated_at",
    ]
    public let id: Int64
    public let sessionId: String
    public let label: String
    /// 实时 COUNT(face_cluster_members)，不是存档列。
    public let memberCount: Int64
    public let status: String
    public let thumbnailPath: String
    /// 身份链接（PersonRepo.bindRole / 跨会话匹配写入）。
    public let matchedPersonId: String?
    public let matchConfidence: Double?
    public let createdAt: String
    public let updatedAt: String
    public var members: [FaceClusterMemberRow]?
    public var binding: FaceBindingData?

    public init(row: DBRow) throws {
        guard row.count >= 10 else { throw DBError.message("FaceClusterRow 列数不足: \(row.count)") }
        id = row[0].intValue ?? 0
        sessionId = row[1].textValue ?? ""
        label = row[2].textValue ?? ""
        memberCount = row[3].intValue ?? 0
        status = row[4].textValue ?? ""
        thumbnailPath = row[5].textValue ?? ""
        matchedPersonId = row[6].textValue
        matchConfidence = row[7].doubleValue
        createdAt = row[8].textValue ?? ""
        updatedAt = row[9].textValue ?? ""
        members = nil
        binding = nil
    }
}

/// face_cluster_members LEFT JOIN photos 的行（fm.id, fm.cluster_id, fm.session_id,
/// fm.photo_id, p.filepath AS photo_path, fm.bbox, fm.confidence, fm.observation_id）。
/// 照片行缺失时 photoPath 为空字符串（成员仍在计数与清单中，不再被 JOIN 丢掉）。
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

/// 绑定信息（TS FaceClusterRow.binding）。
public struct FaceBindingData: Equatable, Sendable {
    public let clusterId: String
    public let roleName: String
    public let keywords: [String]
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
    /// v34 人脸质量/几何/模型版本。全部带默认值：既有调用点零改动即可编译。
    public var quality: Double
    public var faceSizePx: Double
    public var rollDegrees: Double
    public var modelId: String
    public var modelVersion: String
    /// 向量维度。0 表示"未声明"，写入路径回退为 embedding.count（如实记录）。
    public var embeddingDim: Int

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
        analysisSignature: String? = nil,
        quality: Double = 0,
        faceSizePx: Double = 0,
        rollDegrees: Double = 0,
        modelId: String = "",
        modelVersion: String = "",
        embeddingDim: Int = 0
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
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.rollDegrees = rollDegrees
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.embeddingDim = embeddingDim
    }
}

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

/// getAnalysisStates 的映射值。
public struct FaceAnalysisState: Equatable, Sendable {
    public let sourceFileSize: Int64
    public let sourceFileMtimeMs: Double
    public let analysisSignature: String

    public init(sourceFileSize: Int64, sourceFileMtimeMs: Double, analysisSignature: String) {
        self.sourceFileSize = sourceFileSize
        self.sourceFileMtimeMs = sourceFileMtimeMs
        self.analysisSignature = analysisSignature
    }
}

/// reuseObservationsForAssetFile 的批量目标。
public struct FaceReuseTarget {
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

/// reuseObservationsForAssetFile 的单目标结果。
public struct ReuseResult: Equatable, Sendable {
    public let reused: Bool
    public let faceCount: Int64
}

/// getClusterMembers 的成员投影。
public struct ClusterMemberLite {
    public let photoId: String
    public let bbox: [Double]
    public let confidence: Double
}

/// 簇成员的观察向量：跨会话匹配的查询集，也是 person_embeddings 的入库来源
/// （两者共用同一读取口径，避免"写入的向量"与"匹配读的向量"分叉）。
public struct ClusterMemberEmbedding {
    public let memberId: Int64
    public let photoId: String
    public let sessionId: String
    public let observationId: Int64
    public let embedding: [Float]
    public let bbox: [Double]
    public let confidence: Double
    /// v34：观察行的质量/几何/模型元数据（跨会话匹配的加权依据）。
    public let quality: Double
    public let faceSizePx: Double
    public let rollDegrees: Double
    public let modelId: String
    public let modelVersion: String
    public let embeddingDim: Int

    public init(
        memberId: Int64,
        photoId: String,
        sessionId: String,
        observationId: Int64,
        embedding: [Float],
        bbox: [Double],
        confidence: Double,
        quality: Double = 0,
        faceSizePx: Double = 0,
        rollDegrees: Double = 0,
        modelId: String = "",
        modelVersion: String = "",
        embeddingDim: Int = 0
    ) {
        self.memberId = memberId
        self.photoId = photoId
        self.sessionId = sessionId
        self.observationId = observationId
        self.embedding = embedding
        self.bbox = bbox
        self.confidence = confidence
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.rollDegrees = rollDegrees
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.embeddingDim = embeddingDim
    }
}

/// getBindingsBySession 的绑定详情。
public struct FaceBindingDetail {
    public let clusterId: Int64
    public let roleName: String
    public let keywords: [String]
    public let memberPhotoIds: [String]
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

    public func getObservations(_ sessionId: String) throws -> [FaceObservationRow] {
        let columns = FaceObservationRow.columns.joined(separator: ", ")
        let rows = try connection.prepare(
            "SELECT \(columns) FROM face_observations WHERE session_id = ? ORDER BY id"
        ).query([.text(sessionId)])
        return try rows.map { try FaceObservationRow(row: $0) }
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
        // 观察被替换前先删其 person_embeddings：该列无 FK（见 Schema 注释），
        // 残留向量会被 FaceMatcher 的库查询读到。
        let deleteEmbeddingsStmt = try connection.prepare("""
            DELETE FROM person_embeddings WHERE face_observation_id IN (
              SELECT id FROM face_observations WHERE session_id = ? AND photo_id = ?
            )
            """)
        // V1 的 face_observations 没有 source_file_size/mtime（输入指纹唯一真相源是
        // face_analysis_state）；拷贝观察只带 16 列，文件状态由上方 JOIN 状态表比较。
        let copyStmt = try connection.prepare("""
            INSERT INTO face_observations (
              photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
              analysis_signature, created_at,
              quality, face_size_px, roll_degrees, model_id, model_version, embedding_dim
            )
            SELECT ?, ?, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                   analysis_signature, ?,
                   quality, face_size_px, roll_degrees, model_id, model_version, embedding_dim
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
                _ = try deleteEmbeddingsStmt.run([.text(sessionId), .text(target.photoId)])
                try detachObservationMembers(sessionId: sessionId, photoId: target.photoId)
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

    /// 清空聚类签名（Cut 5 / 5c-2）。用于三阶段分析的失效边界：观测已更新但簇未
    /// 更新（B 阶段失败 / A 与 C 之间取消 / C 的 index_seq 守卫失败）时，签名必须
    /// 失效，否则下一次 analyze 会把旧簇误判为"仍然有效"而跳过重聚类。
    public func clearClusterSignature(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    /// 保留成员几何和人工标签，但在替换派生观测前解除旧外键。
    private func detachObservationMembers(sessionId: String, photoId: String? = nil) throws {
        let suffix = photoId == nil ? "" : " AND photo_id = ?"
        var values: [DBValue] = [.text(sessionId)]
        if let photoId { values.append(.text(photoId)) }
        _ = try connection.prepare("UPDATE face_cluster_members SET observation_id = NULL WHERE observation_id IN (SELECT id FROM face_observations WHERE session_id = ?\(suffix))")
            .run(values)
    }

    public func deleteObservationsBySession(_ sessionId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("""
                DELETE FROM person_embeddings WHERE face_observation_id IN (
                  SELECT id FROM face_observations WHERE session_id = ?
                )
                """).run([.text(sessionId)])
            try detachObservationMembers(sessionId: sessionId)
            _ = try connection.prepare("DELETE FROM face_observations WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_analysis_state WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?").run([.text(sessionId)])
        }
    }

    public func deleteObservationsByPhoto(sessionId: String, photoId: String) throws {
        try connection.transaction {
            _ = try connection.prepare("""
                DELETE FROM person_embeddings WHERE face_observation_id IN (
                  SELECT id FROM face_observations WHERE session_id = ? AND photo_id = ?
                )
                """).run([.text(sessionId), .text(photoId)])
            try detachObservationMembers(sessionId: sessionId, photoId: photoId)
            _ = try connection.prepare(
                "DELETE FROM face_observations WHERE session_id = ? AND photo_id = ?"
            ).run([.text(sessionId), .text(photoId)])
        }
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
        // 同 reuseObservationsForAssetFile：替换观察必须先清向量（无 FK，见 Schema 注释）。
        let deleteEmbeddingsStmt = try connection.prepare("""
            DELETE FROM person_embeddings WHERE face_observation_id IN (
              SELECT id FROM face_observations WHERE session_id = ? AND photo_id = ?
            )
            """)
        // V1 的 face_observations 没有 source_file_size/mtime；输入指纹只写
        // face_analysis_state（upsertAnalysisState），观察行不再复制一份。
        let insertStmt = try connection.prepare("""
            INSERT INTO face_observations
             (photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
              analysis_signature, quality, face_size_px, roll_degrees,
              model_id, model_version, embedding_dim)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """)
        try connection.transaction {
            _ = try deleteEmbeddingsStmt.run([.text(sessionId), .text(photoId)])
            try detachObservationMembers(sessionId: sessionId, photoId: photoId)
            _ = try deleteStmt.run([.text(sessionId), .text(photoId)])
            for obs in observations {
                // embedding_dim 如实记录写入的向量长度：显式 >0 的声明维度优先，
                // 默认 0（既有调用点）回退到 embedding.count，避免旧调用点写 0。
                let embeddingDim = obs.embeddingDim > 0 ? obs.embeddingDim : obs.embedding.count
                _ = try insertStmt.run([
                    .text(obs.photoId),
                    .text(sessionId),
                    .real(obs.bboxX),
                    .real(obs.bboxY),
                    .real(obs.bboxW),
                    .real(obs.bboxH),
                    .blob(Self.embeddingData(obs.embedding)),
                    .real(obs.confidence),
                    .text(obs.analysisSignature ?? ""),
                    .real(obs.quality),
                    .real(obs.faceSizePx),
                    .real(obs.rollDegrees),
                    .text(obs.modelId),
                    .text(obs.modelVersion),
                    .int(Int64(embeddingDim)),
                ])
                ids.append(connection.lastInsertRowid)
            }
        }
        return ids
    }

    // ─────────────────────────── 派生结果失效 ───────────────────────────

    /// 内容/路径变化后的派生结果失效（Indexer 唯一入口）。
    ///
    /// 与旧实现的关键差异：**不删簇、不删绑定**。照片行仍存在时保留其成员行
    /// （绑定的照片集合不随派生数据消失，只解除对观察的外键引用）；照片行已消失
    /// 时该成员行是孤儿，删除。随后只清观察/分析状态/聚类签名。
    /// role_bindings、face_clusters、metadata_keyword_origins、person_* 一律不动。
    public func invalidateDerivedResults(sessionId: String, photoIds: [String]) throws {
        try connection.transaction {
            for chunk in photoIds.chunked(by: 400) where !chunk.isEmpty {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                // 1) 先解除成员对观察的引用（否则删除观察会破坏外键）。
                _ = try connection.prepare("""
                    UPDATE face_cluster_members SET observation_id = NULL
                    WHERE session_id = ? AND photo_id IN (\(placeholders)) AND observation_id IS NOT NULL
                    """).run([.text(sessionId)] + chunk.map { .text($0) })
                // 2) 照片行已消失 → 成员行是孤儿，删除。
                _ = try connection.prepare("""
                    DELETE FROM face_cluster_members
                    WHERE session_id = ? AND photo_id IN (\(placeholders))
                      AND photo_id NOT IN (SELECT id FROM photos)
                    """).run([.text(sessionId)] + chunk.map { .text($0) })
                // 3) 观察消失前先删除其 person_embeddings 向量：否则跨会话匹配
                // 会命中已不存在的人脸（库与观察必须同生命周期）。
                _ = try connection.prepare("""
                    DELETE FROM person_embeddings WHERE face_observation_id IN (
                      SELECT id FROM face_observations WHERE session_id = ? AND photo_id IN (\(placeholders))
                    )
                    """).run([.text(sessionId)] + chunk.map { .text($0) })
                // 4) 派生观察与缓存状态。
                _ = try connection.prepare(
                    "DELETE FROM face_observations WHERE session_id = ? AND photo_id IN (\(placeholders))"
                ).run([.text(sessionId)] + chunk.map { .text($0) })
                _ = try connection.prepare(
                    "DELETE FROM face_analysis_state WHERE session_id = ? AND photo_id IN (\(placeholders))"
                ).run([.text(sessionId)] + chunk.map { .text($0) })
            }
            _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?").run([.text(sessionId)])
        }
    }

    // ─────────────────────────── 缩略图 ───────────────────────────

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

    // ─────────────────────────── 聚类 ───────────────────────────

    public func saveClusters(sessionId: String, clusters: [FaceClusterInput]) throws -> [Int64] {
        var ids: [Int64] = []
        // V1 的 face_clusters 没有 member_count/thumbnail_base64：成员计数是
        // COUNT(face_cluster_members) 的读取别名，缩略图只走 thumbnail_path（默认 ''）。
        let insertCluster = try connection.prepare(
            "INSERT INTO face_clusters (session_id, label, status, thumbnail_path) VALUES (?, ?, 'unbound', '')"
        )
        let insertMember = try connection.prepare(
            "INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id) VALUES (?, ?, ?, ?, ?, ?)"
        )
        try connection.transaction {
            for cluster in clusters {
                _ = try insertCluster.run([
                    .text(sessionId), .text(cluster.label),
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

    /// 会话簇清单。
    /// - memberCount 恒为实时 COUNT(face_cluster_members)；
    /// - 成员清单 LEFT JOIN photos（孤儿成员保留，photoPath 为空）；
    /// - **有绑定但无成员的孤儿绑定同样返回**（size=0），作为清理入口。
    public func getClusters(_ sessionId: String, includeMembers: Bool = false) throws -> [FaceClusterRow] {
        // SELECT 列序由 FaceClusterRow.columns 单点定义；member_count 是实时 COUNT 别名。
        let selectList = FaceClusterRow.columns.map { column in
            column == "member_count"
                ? "(SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = c.id) AS member_count"
                : "c." + column
        }.joined(separator: ", ")
        let clusters = try connection.prepare("""
            SELECT \(selectList)
            FROM face_clusters c
            WHERE c.session_id = ?
              AND (
                (SELECT COUNT(*) FROM face_cluster_members m WHERE m.cluster_id = c.id) > 0
                OR EXISTS (SELECT 1 FROM role_bindings rb WHERE rb.cluster_id = c.id)
              )
            ORDER BY c.id
            """).query([.text(sessionId)]).map { try FaceClusterRow(row: $0) }
        if !includeMembers || clusters.isEmpty { return clusters }
        let clusterIds = clusters.map(\.id)

        var membersByCluster: [Int64: [FaceClusterMemberRow]] = [:]
        for chunk in clusterIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT fm.id, fm.cluster_id, fm.session_id, fm.photo_id,
                       COALESCE(p.filepath, '') AS photo_path, fm.bbox, fm.confidence, fm.observation_id
                FROM face_cluster_members fm
                LEFT JOIN photos p ON fm.photo_id = p.id
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
            // role_bindings：7 列（TableColumns.roleBindings；RoleBindingRow 只读 0-4）
            let rows = try connection.prepare(
                "SELECT \(TableColumns.sql(TableColumns.roleBindings)) FROM role_bindings WHERE cluster_id IN (\(placeholders))"
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

    /// 跨库匹配的一次性批量输入（Cut 5 / 5c-2）：簇匹配状态 + 成员几何。
    /// 一条 LEFT JOIN 查询同时给出"哪些簇已绑定人物"与"每个簇的成员"，取代旧路径
    /// 的 getClusters(includeMembers:)（3 条 SELECT：簇/成员/绑定），使
    /// FaceKwService.matchClustersAgainstLibrary 的固定 SELECT 数降到 4：
    /// 库向量 + 本查询 + feedback + 人物阈值。
    /// 无成员的簇也返回一行（memberPhotoId == nil），调用方无需再补查簇表。
    public struct FaceClusterMatchRow: Equatable, Sendable {
        public let clusterId: Int64
        public let matchedPersonId: String?
        public let memberPhotoId: String?
        public let memberBbox: String

        public init(
            clusterId: Int64,
            matchedPersonId: String?,
            memberPhotoId: String?,
            memberBbox: String
        ) {
            self.clusterId = clusterId
            self.matchedPersonId = matchedPersonId
            self.memberPhotoId = memberPhotoId
            self.memberBbox = memberBbox
        }
    }

    /// 按簇 id 批量读取匹配状态与成员（一次 IN 查询；>800 簇按 800 分块）。
    /// session_id 过滤保证不会跨会话读到别的簇。
    public func getClusterMatchRows(
        sessionId: String,
        clusterIds: [Int64]
    ) throws -> [FaceClusterMatchRow] {
        guard !clusterIds.isEmpty else { return [] }
        var result: [FaceClusterMatchRow] = []
        for chunk in clusterIds.chunked(by: 800) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT c.id, c.matched_person_id, m.photo_id, m.bbox
                FROM face_clusters c
                LEFT JOIN face_cluster_members m ON m.cluster_id = c.id
                WHERE c.session_id = ? AND c.id IN (\(placeholders))
                ORDER BY c.id, m.id
              """).query([.text(sessionId)] + chunk.map { .int($0) })
            for row in rows {
                result.append(FaceClusterMatchRow(
                    clusterId: row[0].intValue ?? 0,
                    matchedPersonId: row[1].textValue,
                    memberPhotoId: row[2].textValue,
                    memberBbox: row[3].textValue ?? ""))
            }
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

    /// 簇成员及其观察向量（仅 observation_id 非空且观察仍存在的成员）。
    public func getClusterMemberEmbeddings(_ clusterId: Int64) throws -> [ClusterMemberEmbedding] {
        let rows = try connection.prepare("""
            SELECT fm.id, fm.photo_id, fm.session_id, fo.id, fo.embedding, fm.bbox, fm.confidence,
                   fo.quality, fo.face_size_px, fo.roll_degrees,
                   fo.model_id, fo.model_version, fo.embedding_dim
            FROM face_cluster_members fm
            JOIN face_observations fo ON fo.id = fm.observation_id
            WHERE fm.cluster_id = ?
            ORDER BY fm.id
            """).query([.int(clusterId)])
        return rows.compactMap { row in
            guard let observationId = row[3].intValue else { return nil }
            let embedding: Data = {
                if case .blob(let data) = row[4] { return data }
                return Data()
            }()
            return ClusterMemberEmbedding(
                memberId: row[0].intValue ?? 0,
                photoId: row[1].textValue ?? "",
                sessionId: row[2].textValue ?? "",
                observationId: observationId,
                embedding: Self.floats(from: embedding),
                bbox: Self.parseBbox(row[5].textValue ?? ""),
                confidence: row[6].doubleValue ?? 0,
                quality: row[7].doubleValue ?? 0,
                faceSizePx: row[8].doubleValue ?? 0,
                rollDegrees: row[9].doubleValue ?? 0,
                modelId: row[10].textValue ?? "",
                modelVersion: row[11].textValue ?? "",
                embeddingDim: Int(row[12].intValue ?? 0)
            )
        }
    }

    /// 写入/清除簇的身份匹配建议（跨会话重识别；显式绑定经 PersonRepo 写同一列）。
    public func setClusterMatch(clusterId: Int64, personId: String?, confidence: Double?) throws {
        _ = try connection.prepare("""
            UPDATE face_clusters SET matched_person_id = ?, match_confidence = ?, updated_at = ? WHERE id = ?
            """).run([
            personId.map { .text($0) },
            confidence.map { .real($0) },
            .text(nowISOString()),
            .int(clusterId),
        ])
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

    /// 有成员的簇的缩略图文件（孤儿绑定没有缩略图）。
    public func getThumbnailPathsBySession(_ sessionId: String) throws -> [String] {
        let rows = try connection.prepare("""
            SELECT thumbnail_path FROM face_clusters c
            WHERE c.session_id = ? AND c.thumbnail_path != ''
              AND EXISTS (SELECT 1 FROM face_cluster_members m WHERE m.cluster_id = c.id)
            """).query([.text(sessionId)])
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

    /// 合并簇：成员并入目标，源绑定删除、源簇保留为空行（调用方决定删除源簇还是
    /// 保留为孤儿绑定），源缩略图文件删除，计数按成员表重算。
    /// 注：撤销合并需要调用方持有 sourceMemberIds/sourceBinding 日志，本仓库不再
    /// 提供 restoreMerge（全仓无生产记录点，日志能力超出本域）。
    public func mergeClusters(sourceId: Int64, targetId: Int64) throws {
        let sourcePath = try getClusterThumbnailPath(sourceId)
        try connection.transaction {
            _ = try connection.prepare("UPDATE face_cluster_members SET cluster_id = ? WHERE cluster_id = ?")
                .run([.int(targetId), .int(sourceId)])
            _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(sourceId)])
            _ = try connection.prepare("UPDATE face_clusters SET status = 'unbound', updated_at = ? WHERE id = ?")
                .run([.text(nowISOString()), .int(sourceId)])
        }
        deleteThumbnailFile(sourcePath)
    }

    /// 会话删除专用：整会话簇/绑定/成员清理。**不得**用于内容/路径变化后的失效
    /// （那必须走 invalidateDerivedResults，绑定必须保留）。
    public func deleteClustersBySession(_ sessionId: String) throws {
        let paths = try getThumbnailPathsBySession(sessionId)
        try connection.transaction {
            _ = try connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM role_bindings WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_clusters WHERE session_id = ?").run([.text(sessionId)])
            _ = try connection.prepare("DELETE FROM face_cluster_state WHERE session_id = ?").run([.text(sessionId)])
        }
        for path in paths { deleteThumbnailFile(path) }
    }

    // MARK: - WP3b-2：FaceKwService 的内联 SQL 下沉

    /// 无脸结果清理的成员段（clearOnEmpty）：清空会话成员行，簇行留给
    /// deleteUnboundClusters 只删未绑定的（绑定必须保留）。调用方事务内。
    public func clearClusterMembers(sessionId: String) throws {
        _ = try connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?")
            .run([.text(sessionId)])
    }

    /// 无脸结果清理的簇段：删除会话内没有 role_bindings 引用的簇（旧语义逐字保留）。
    public func deleteUnboundClusters(sessionId: String) throws {
        _ = try connection.prepare(
            "DELETE FROM face_clusters WHERE session_id = ? AND id NOT IN (SELECT cluster_id FROM role_bindings)"
        ).run([.text(sessionId)])
    }

    /// 增量聚类 C 段：向已有簇追加成员（语句只准备一次，调用方事务内）。
    public func appendClusterMembers(
        sessionId: String,
        groups: [(clusterId: Int64, members: [FaceClusterMemberInput])]
    ) throws {
        guard groups.contains(where: { !$0.members.isEmpty }) else { return }
        let insertMember = try connection.prepare("""
            INSERT INTO face_cluster_members
             (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
             VALUES (?, ?, ?, ?, ?, ?)
            """)
        for group in groups {
            for member in group.members {
                let bboxJSON = try JSONValue.stringify(
                    JSONValue.array(member.bbox.map { JSONValue.real($0) }))
                _ = try insertMember.run([
                    .int(group.clusterId),
                    .text(sessionId),
                    .text(member.photoId),
                    .text(bboxJSON),
                    .real(member.confidence),
                    optDB(member.observationId),
                ])
            }
        }
    }

    /// 按成员行 id 删除（幽灵成员清理；400 分块防参数上限，调用方事务内）。
    public func deleteClusterMembers(ids: [Int64]) throws {
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "DELETE FROM face_cluster_members WHERE id IN (\(placeholders))"
            ).run(chunk.map { .int($0) })
        }
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

    /// 移除成员。最后一个成员被移除时：
    /// - 还有绑定 → 保留簇行与绑定（孤儿绑定，供 UI 解绑并清理 XMP 关键词）；
    /// - 无绑定 → 删除簇行。
    public func removeMemberFromCluster(clusterId: Int64, memberId: Int64) throws -> Bool {
        let liveCountBefore = try memberCount(clusterId: clusterId)
        let hasBinding = try bindingExists(clusterId: clusterId)
        let thumbnailPathToDelete = liveCountBefore == 1 ? try getClusterThumbnailPath(clusterId) : ""

        let deleted: Bool = try connection.transaction {
            let removed = try connection.prepare(
                "DELETE FROM face_cluster_members WHERE cluster_id = ? AND id = ?"
            ).run([.int(clusterId), .int(memberId)])
            if removed == 0 { return false }
            let remaining = try memberCount(clusterId: clusterId)
            if remaining == 0 && !hasBinding {
                _ = try connection.prepare("DELETE FROM role_bindings WHERE cluster_id = ?").run([.int(clusterId)])
                _ = try connection.prepare("DELETE FROM face_clusters WHERE id = ?").run([.int(clusterId)])
            } else {
                // member_count 不再是物理列（V1）：读取恒为实时 COUNT，只更新 updated_at。
                _ = try connection.prepare("UPDATE face_clusters SET updated_at = ? WHERE id = ?")
                    .run([.text(nowISOString()), .int(clusterId)])
            }
            return true
        }
        if deleted { deleteThumbnailFile(thumbnailPathToDelete) }
        return deleted
    }

    // ─────────────────────────── 辅助 ───────────────────────────

    private func memberCount(clusterId: Int64) throws -> Int64 {
        try connection.prepare("SELECT COUNT(*) FROM face_cluster_members WHERE cluster_id = ?")
            .get([.int(clusterId)])?[0].intValue ?? 0
    }

    private func bindingExists(clusterId: Int64) throws -> Bool {
        try connection.prepare("SELECT 1 FROM role_bindings WHERE cluster_id = ? LIMIT 1")
            .get([.int(clusterId)]) != nil
    }

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

    /// 存储 BLOB 的 Float32 视图（与 FaceKwService.floats 同语义）。
    private static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
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
