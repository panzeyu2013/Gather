// desktop/native/gather-core/Sources/GatherPersistence/Ports/CullingRepository.swift
// WP3b-2：Culling 读模型端口（分页/计数 + 富查询）。
//
// Application 只表达「哪个 scope、哪些照片」，SQL 谓词/分块/代表行规则留在
// CullingAssetPageQuery / CullingReadQuery；写事务仍由 TransactionRunner 提供。
import Foundation

public protocol CullingPageReading {
    func pageFiltered(
        sessionId: String,
        filter: CullingPageFilter,
        afterRowId: Int64?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?)
    func pageSimilarity(
        sessionId: String,
        similarity: CullingSimilarityScope,
        afterRowId: Int64?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: Int64?)
    func countFiltered(sessionId: String, filter: CullingPageFilter) throws -> Int
    func countSimilarity(sessionId: String, similarity: CullingSimilarityScope) throws -> Int
}

public protocol CullingRichReading {
    func qualityRows(photoIds: [String]) throws -> [CullingQualityResultRow]
    func faceRows(sessionId: String) throws -> [CullingFaceObservationRow]
    func faceRows(sessionId: String, photoIds: [String]) throws -> [CullingFaceObservationRow]
    func personRows(sessionId: String) throws -> [CullingPersonNameRow]
    func personRows(sessionId: String, photoIds: [String]) throws -> [CullingPersonNameRow]
    func deliveryModuleRows(xmpPaths: [String]) throws -> [CullingDeliveryModuleRow]
    func conflictPhotoPaths(sessionId: String) throws -> Set<String>
    func existingPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String>
    func summaryCacheRows(photoIds: [String]) throws -> [CullingSummaryCacheRow]
    func clearCullingProjection(photoIds: [String]) throws
}

extension CullingAssetPageQuery: CullingPageReading {}
extension CullingReadQuery: CullingRichReading {}
