// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/QualityRepo.swift
// WP3b-1：QualityService 的 asset_analysis / face_observations / similarity 查询下沉。
//
// 计算、评分与 JSON 解码仍留在 Application；本仓储只负责 SQL 与分块边界
// （400/块，与 QualityService.inChunkSize 一致）。
import Foundation

public struct QualityAnalysisInsert: Equatable, Sendable {
    public let photoId: String
    public let assetFileId: String
    public let resultJson: String
    public let warningsJson: String
    public let fingerprint: String
    public let updatedAt: String

    public init(
        photoId: String,
        assetFileId: String,
        resultJson: String,
        warningsJson: String,
        fingerprint: String,
        updatedAt: String
    ) {
        self.photoId = photoId
        self.assetFileId = assetFileId
        self.resultJson = resultJson
        self.warningsJson = warningsJson
        self.fingerprint = fingerprint
        self.updatedAt = updatedAt
    }
}

public struct QualityCachedRow: Equatable, Sendable {
    public let photoId: String
    public let fingerprint: String
    public let resultJson: String

    public init(photoId: String, fingerprint: String, resultJson: String) {
        self.photoId = photoId
        self.fingerprint = fingerprint
        self.resultJson = resultJson
    }
}

public struct QualityFaceRecord: Equatable, Sendable {
    public let photoId: String
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public let analysisSignature: String

    public init(photoId: String, x: Double, y: Double, w: Double, h: Double, analysisSignature: String) {
        self.photoId = photoId
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.analysisSignature = analysisSignature
    }
}

public final class QualityRepo {
    public static let inChunkSize = 400

    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 全部结果单事务串行提交（旧实现同一语句复用 + 事务）。
    public func insertResults(
        _ inserts: [QualityAnalysisInsert],
        modelId: String,
        modelVersion: String
    ) throws {
        guard !inserts.isEmpty else { return }
        let statement = try connection.prepare("""
            INSERT OR REPLACE INTO asset_analysis (
              photo_id, asset_file_id, analysis_type, result_json, warnings_json,
              model_id, model_version, input_fingerprint, created_at, updated_at
            ) VALUES (?, ?, 'technical_quality', ?, ?, ?, ?, ?, ?, ?)
          """)
        try connection.transaction {
            for insert in inserts {
                _ = try statement.run([
                    .text(insert.photoId),
                    .text(insert.assetFileId),
                    .text(insert.resultJson),
                    .text(insert.warningsJson),
                    .text(modelId),
                    .text(modelVersion),
                    .text(insert.fingerprint),
                    .text(insert.updatedAt),
                    .text(insert.updatedAt),
                ])
            }
        }
    }

    /// 每照片最新一条 technical_quality 结果（updated_at DESC）。
    public func latestResults(photoIds: [String]) throws -> [(photoId: String, resultJson: String)] {
        var rows: [(photoId: String, resultJson: String)] = []
        for chunk in chunkIds(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let queryRows = try connection.prepare("""
                SELECT aa.result_json, p.id AS requested_photo_id
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'technical_quality' AND p.id IN (\(placeholders))
                ORDER BY aa.updated_at DESC
              """).query(chunk.map { .text($0) })
            for row in queryRows {
                rows.append((photoId: row[1].textValue ?? "", resultJson: row[0].textValue ?? ""))
            }
        }
        return rows
    }

    /// 同 model/version 的存储结果（updated_at DESC）。
    public func cachedResults(
        photoIds: [String],
        modelId: String,
        modelVersion: String
    ) throws -> [QualityCachedRow] {
        var rows: [QualityCachedRow] = []
        for chunk in chunkIds(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let queryRows = try connection.prepare("""
                SELECT p.id AS photo_id, aa.result_json, aa.input_fingerprint
                FROM asset_analysis aa
                JOIN photos p ON p.asset_file_id = aa.asset_file_id
                WHERE p.id IN (\(placeholders)) AND aa.analysis_type = 'technical_quality'
                  AND model_id = ? AND model_version = ?
                ORDER BY aa.updated_at DESC
              """).query(chunk.map { .text($0) } + [.text(modelId), .text(modelVersion)])
            for row in queryRows {
                rows.append(QualityCachedRow(
                    photoId: row[0].textValue ?? "",
                    fingerprint: row[2].textValue ?? "",
                    resultJson: row[1].textValue ?? ""
                ))
            }
        }
        return rows
    }

    /// 每照片最大人脸观测（bbox 面积降序首行）。
    public func maxFaceBoxes(sessionId: String, photoIds: [String]) throws -> [QualityFaceRecord] {
        var records: [QualityFaceRecord] = []
        for chunk in chunkIds(photoIds) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
                FROM face_observations
                WHERE session_id = ? AND photo_id IN (\(placeholders))
                ORDER BY bbox_w * bbox_h DESC
              """).query([.text(sessionId)] + chunk.map { .text($0) })
            for row in rows {
                records.append(QualityFaceRecord(
                    photoId: row[0].textValue ?? "",
                    x: row[1].doubleValue ?? 0,
                    y: row[2].doubleValue ?? 0,
                    w: row[3].doubleValue ?? 0,
                    h: row[4].doubleValue ?? 0,
                    analysisSignature: row[5].textValue ?? ""
                ))
            }
        }
        return records
    }

    /// 最新 similarity_results 的组成员（无结果 → nil）。
    public func latestSimilarityGroups(sessionId: String) throws -> [Int: [String]]? {
        let latest = try connection.prepare(
            "SELECT id FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1"
        ).get([.text(sessionId)])
        guard let latest, let resultId = latest[0].intValue else { return nil }
        let rows = try connection.prepare("""
            SELECT group_index, photo_id
            FROM similarity_result_members
            WHERE session_id = ? AND result_id = ?
            ORDER BY group_index, photo_id
          """).query([.text(sessionId), .int(resultId)])
        var groups: [Int: [String]] = [:]
        for row in rows {
            groups[Int(row[0].intValue ?? 0), default: []].append(row[1].textValue ?? "")
        }
        return groups
    }

    private func chunkIds(_ ids: [String]) -> [[String]] {
        var chunks: [[String]] = []
        for offset in stride(from: 0, to: ids.count, by: Self.inChunkSize) {
            chunks.append(Array(ids[offset..<min(offset + Self.inChunkSize, ids.count)]))
        }
        return chunks
    }
}
