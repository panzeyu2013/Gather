// desktop/native/gather-core/Sources/GatherPersistence/Database/Queries/CullingReadQuery.swift
// WP3b-2：Culling 富查询读模型下沉（原 CullingService 的 buildRichLookup 支撑查询）。
//
// 只搬 SQL 与分块：JSON 解析、bbox 语义、名称去重、缓存装配仍留在 Application。
// 所有返回类型都是 Persistence 自己的窄行，避免把 Application 的读模型拉进来。
import Foundation

/// face_observations 的 bbox/signature 投影。
public struct CullingFaceObservationRow: Equatable, Sendable {
    public let photoId: String
    public let bbox: [Double]
    public let analysisSignature: String

    public init(photoId: String, bbox: [Double], analysisSignature: String) {
        self.photoId = photoId
        self.bbox = bbox
        self.analysisSignature = analysisSignature
    }
}

/// person_photos JOIN persons 的名称投影。
public struct CullingPersonNameRow: Equatable, Sendable {
    public let photoId: String
    public let name: String

    public init(photoId: String, name: String) {
        self.photoId = photoId
        self.name = name
    }
}

/// asset_analysis 的质量结果投影（JSON 解析留给调用方）。
public struct CullingQualityResultRow: Equatable, Sendable {
    public let photoId: String
    public let resultJSON: String

    public init(photoId: String, resultJSON: String) {
        self.photoId = photoId
        self.resultJSON = resultJSON
    }
}

/// delivery_items 的 module 投影（按侧车路径）。
public struct CullingDeliveryModuleRow: Equatable, Sendable {
    public let xmpPath: String
    public let module: String

    public init(xmpPath: String, module: String) {
        self.xmpPath = xmpPath
        self.module = module
    }
}

/// photo_metadata_cache 的轻投影（getSummary 计数用）。
public struct CullingSummaryCacheRow: Equatable, Sendable {
    public let photoId: String
    public let rating: Int64
    public let label: String?

    public init(photoId: String, rating: Int64, label: String?) {
        self.photoId = photoId
        self.rating = rating
        self.label = label
    }
}

public final class CullingReadQuery {
    /// 每批 IN 参数上限（与旧 CullingService.chunkSize 同值）。
    static let chunkSize = 800

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// TS: loadQualityByPhoto —— technical_quality 分析行（按 updated_at 倒序）。
    public func qualityRows(photoIds: [String]) throws -> [CullingQualityResultRow] {
        try chunked(photoIds) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try connection.prepare("""
                SELECT p.id AS requested_photo_id, aa.result_json
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'technical_quality'
                  AND p.id IN (\(placeholders))
                ORDER BY aa.updated_at DESC
              """).query(chunk.map { .text($0) }).map {
                CullingQualityResultRow(
                    photoId: $0[0].textValue ?? "", resultJSON: $0[1].textValue ?? "{}")
            }
        }
    }

    /// TS: loadFaces（会话模式）—— 整个会话的人脸观测。
    public func faceRows(sessionId: String) throws -> [CullingFaceObservationRow] {
        try faceRows(statement: """
            SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
            FROM face_observations
            WHERE session_id = ?
            ORDER BY id
          """, params: [.text(sessionId)])
    }

    /// TS: loadFaces（页模式）—— 指定照片的人脸观测。
    public func faceRows(sessionId: String, photoIds: [String]) throws -> [CullingFaceObservationRow] {
        try chunked(photoIds) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try faceRows(statement: """
                SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
                FROM face_observations
                WHERE session_id = ? AND photo_id IN (\(placeholders))
                ORDER BY id
              """, params: [.text(sessionId)] + chunk.map { .text($0) })
        }
    }

    /// TS: loadPeople（会话模式）。
    public func personRows(sessionId: String) throws -> [CullingPersonNameRow] {
        try personRows(statement: """
            SELECT pp.photo_id, p.name
            FROM person_photos pp
            JOIN persons p ON p.id = pp.person_id
            WHERE pp.session_id = ?
            ORDER BY p.name
          """, params: [.text(sessionId)])
    }

    /// TS: loadPeople（页模式）。
    public func personRows(sessionId: String, photoIds: [String]) throws -> [CullingPersonNameRow] {
        try chunked(photoIds) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try personRows(statement: """
                SELECT pp.photo_id, p.name
                FROM person_photos pp
                JOIN persons p ON p.id = pp.person_id
                WHERE pp.session_id = ? AND pp.photo_id IN (\(placeholders))
                ORDER BY p.name
              """, params: [.text(sessionId)] + chunk.map { .text($0) })
        }
    }

    /// 交付项的 module 投影（每侧车取最近更新的 item）。
    public func deliveryModuleRows(xmpPaths: [String]) throws -> [CullingDeliveryModuleRow] {
        let unique = Array(Set(xmpPaths))
        guard !unique.isEmpty else { return [] }
        return try chunked(unique) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try connection.prepare("""
                SELECT d.xmp_path, di.module
                FROM delivery_items di
                JOIN deliveries d ON d.id = di.delivery_id
                WHERE d.xmp_path IN (\(placeholders))
                ORDER BY di.updated_at DESC, di.id DESC
              """).query(chunk.map { .text($0) }).compactMap { row in
                guard let xmpPath = row[0].textValue, let module = row[1].textValue else {
                    return nil
                }
                return CullingDeliveryModuleRow(xmpPath: xmpPath, module: module)
            }
        }
    }

    /// metadataConflictOnly 的冲突照片路径集合（deliveries.status='conflict'）。
    public func conflictPhotoPaths(sessionId: String) throws -> Set<String> {
        let rows = try connection.prepare("""
            SELECT DISTINCT d.photo_path
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE ds.session_id = ? AND d.status = 'conflict'
          """).query([.text(sessionId)])
        return Set(rows.compactMap { $0[0].textValue })
    }

    /// 会话内存在的照片 id（分块 IN；历史重放的跳过规则）。
    public func existingPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String> {
        var found = Set<String>()
        for chunk in photoIds.chunked(by: Self.chunkSize) where !chunk.isEmpty {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT id FROM photos WHERE session_id = ? AND id IN (\(placeholders))"
            ).query([.text(sessionId)] + chunk.map { .text($0) })
            for row in rows {
                if let id = row[0].textValue { found.insert(id) }
            }
        }
        return found
    }

    /// TS: loadSummaryCacheByPhoto —— 轻 photo_metadata_cache 投影（只有 rating/label）。
    public func summaryCacheRows(photoIds: [String]) throws -> [CullingSummaryCacheRow] {
        try chunked(photoIds) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try connection.prepare("""
                SELECT photo_id, rating, label
                FROM photo_metadata_cache
                WHERE photo_id IN (\(placeholders))
              """).query(chunk.map { .text($0) }).map {
                CullingSummaryCacheRow(
                    photoId: $0[0].textValue ?? "",
                    rating: $0[1].intValue ?? 0,
                    label: $0[2].textValue
                )
            }
        }
    }

    /// reset 的投影撤回：只清 rating/label，不触碰 cached_at。
    public func clearCullingProjection(photoIds: [String]) throws {
        for chunk in photoIds.chunked(by: Self.chunkSize) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare("""
                UPDATE photo_metadata_cache
                SET rating = 0, label = 'None'
                WHERE photo_id IN (\(placeholders))
              """).run(chunk.map { .text($0) })
        }
    }

    // MARK: - 内部

    private func chunked<T>(
        _ ids: [String],
        _ body: ([String]) throws -> [T]
    ) throws -> [T] {
        var rows: [T] = []
        for chunkStart in stride(from: 0, to: ids.count, by: Self.chunkSize) {
            let chunk = Array(ids[chunkStart..<min(chunkStart + Self.chunkSize, ids.count)])
            rows.append(contentsOf: try body(chunk))
        }
        return rows
    }

    private func faceRows(
        statement: String,
        params: [DBValue?]
    ) throws -> [CullingFaceObservationRow] {
        try connection.prepare(statement).query(params).map {
            CullingFaceObservationRow(
                photoId: $0[0].textValue ?? "",
                bbox: [$0[1].doubleValue ?? 0, $0[2].doubleValue ?? 0,
                       $0[3].doubleValue ?? 0, $0[4].doubleValue ?? 0],
                analysisSignature: $0[5].textValue ?? ""
            )
        }
    }

    private func personRows(
        statement: String,
        params: [DBValue?]
    ) throws -> [CullingPersonNameRow] {
        try connection.prepare(statement).query(params).map {
            CullingPersonNameRow(photoId: $0[0].textValue ?? "", name: $0[1].textValue ?? "")
        }
    }
}
