// desktop/native/gather-core/Sources/GatherPersistence/Database/Repositories/ModelReviewRepo.swift
// model_review 结果的读写（asset_analysis，analysis_type = 'model_review'）。
//
// 与 QualityRepo 同一张表、同一套 UNIQUE 约束：换模型/换指纹自然并存，取最新一条。
import Foundation
import GatherProtocol

public struct ModelReviewInsert: Equatable, Sendable {
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

public final class ModelReviewRepo {
    public static let analysisType = "model_review"
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// 单事务批量写入（与 QualityRepo 的 INSERT OR REPLACE 同形）。
    public func insertResults(
        _ inserts: [ModelReviewInsert],
        modelId: String,
        modelVersion: String
    ) throws {
        guard !inserts.isEmpty else { return }
        try connection.transaction {
            let statement = try connection.prepare("""
                INSERT OR REPLACE INTO asset_analysis (
                  photo_id, asset_file_id, analysis_type, result_json, warnings_json,
                  model_id, model_version, input_fingerprint, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let now = nowISOString()
            for insert in inserts {
                _ = try statement.run([
                    .text(insert.photoId), .text(insert.assetFileId), .text(Self.analysisType),
                    .text(insert.resultJson), .text(insert.warningsJson),
                    .text(modelId), .text(modelVersion), .text(insert.fingerprint),
                    .text(now), .text(insert.updatedAt),
                ])
            }
        }
    }

    /// 每照片最新一条（updated_at DESC 首行），用于增量判断与页面富化。
    public func latest(photoIds: [String]) throws -> [String: (json: String, fingerprint: String)] {
        guard !photoIds.isEmpty else { return [:] }
        var result: [String: (json: String, fingerprint: String)] = [:]
        for chunk in chunks(photoIds, size: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT p.id AS photo_id, aa.result_json, aa.input_fingerprint
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'model_review' AND p.id IN (\(placeholders))
                  AND (aa.photo_id = p.id OR aa.photo_id IS NULL)
                ORDER BY aa.updated_at DESC, aa.id DESC
                """).query(chunk.map { .text($0) })
            for row in rows {
                let photoId = row[0].textValue ?? ""
                if result[photoId] != nil { continue }
                result[photoId] = (row[1].textValue ?? "", row[2].textValue ?? "")
            }
        }
        return result
    }

    /// 按资产文件取最新结果（triage 候选装配：与 quality 同一条 JOIN 口径）。
    public func latestByAssetFile(assetFileIds: [String]) throws -> [String: String] {
        guard !assetFileIds.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for chunk in chunks(assetFileIds, size: 400) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT asset_file_id, result_json
                FROM asset_analysis
                WHERE analysis_type = 'model_review' AND asset_file_id IN (\(placeholders))
                ORDER BY updated_at DESC, id DESC
                """).query(chunk.map { .text($0) })
            for row in rows {
                let fileId = row[0].textValue ?? ""
                if result[fileId] != nil { continue }
                result[fileId] = row[1].textValue ?? ""
            }
        }
        return result
    }

    private func chunks(_ ids: [String], size: Int) -> [[String]] {
        guard ids.count > size else { return [ids] }
        return stride(from: 0, to: ids.count, by: size).map {
            Array(ids[$0..<min($0 + size, ids.count)])
        }
    }
}
