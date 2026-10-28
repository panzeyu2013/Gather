// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/FaceRepo+Observations.swift
// 源：FaceRepo.swift（HEAD c4aa5b5）；纯拆分（observations），方法体/SQL/错误逐字未改。
// 访问级：connection 为 internal；共享 helper 的放宽见 FaceRepo.swift 头部记账。

import Foundation
import GatherProtocol

/// face_observations 行（V1 17 列；SELECT 显式列，不再读 source_file_size/mtime）。
public struct FaceObservationRow {
    /// SELECT 与位置解码共用的唯一列清单；顺序 = SchemaCurrent face_observations 的物理列序。
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

extension FaceRepo {

    // ─────────────────────────── 观察 ───────────────────────────

    public func getObservations(_ sessionId: String) throws -> [FaceObservationRow] {
        let columns = FaceObservationRow.columns.joined(separator: ", ")
        let rows = try connection.prepare(
            "SELECT \(columns) FROM face_observations WHERE session_id = ? ORDER BY id"
        ).query([.text(sessionId)])
        return try rows.map { try FaceObservationRow(row: $0) }
    }

    /// 轻量人脸框（不含 embedding blob），供模型级初审按框取 ROI。
    /// 20k 会话直接复用 getObservations 会把 512 维向量全部搬进内存，故单列此查询。
    public func faceBoxes(
        sessionId: String,
        photoIds: [String]
    ) throws -> [(photoId: String, x: Double, y: Double, width: Double, height: Double, quality: Double)] {
        guard !photoIds.isEmpty else { return [] }
        var result: [(photoId: String, x: Double, y: Double, width: Double, height: Double, quality: Double)] = []
        for chunk in stride(from: 0, to: photoIds.count, by: 400).map({
            Array(photoIds[$0..<min($0 + 400, photoIds.count)])
        }) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try connection.prepare("""
                SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, quality
                FROM face_observations
                WHERE session_id = ? AND photo_id IN (\(placeholders))
                ORDER BY bbox_w * bbox_h DESC
            """).query([.text(sessionId)] + chunk.map(DBValue.text))
            for row in rows {
                guard let photoId = row[0].textValue else { continue }
                result.append((
                    photoId: photoId,
                    x: row[1].doubleValue ?? 0,
                    y: row[2].doubleValue ?? 0,
                    width: row[3].doubleValue ?? 0,
                    height: row[4].doubleValue ?? 0,
                    quality: row[5].doubleValue ?? 0))
            }
        }
        return result
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

    private struct FaceReuseSource {
        let photoId: String
        let sourceFileSize: Int64
        let sourceFileMtimeMs: Double
        let analysisSignature: String
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
