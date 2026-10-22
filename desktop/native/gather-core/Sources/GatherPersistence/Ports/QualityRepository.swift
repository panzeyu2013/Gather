// desktop/native/gather-core/Sources/GatherPersistence/Ports/QualityRepository.swift
// WP3b-1：Quality 查询/落库端口。
import Foundation

public protocol QualityRepository {
    func insertResults(
        _ inserts: [QualityAnalysisInsert],
        modelId: String,
        modelVersion: String
    ) throws
    func latestResults(photoIds: [String]) throws -> [(photoId: String, resultJson: String)]
    func cachedResults(photoIds: [String], modelId: String, modelVersion: String) throws -> [QualityCachedRow]
    func maxFaceBoxes(sessionId: String, photoIds: [String]) throws -> [QualityFaceRecord]
    func latestSimilarityGroups(sessionId: String) throws -> [Int: [String]]?
}

extension QualityRepo: QualityRepository {}
