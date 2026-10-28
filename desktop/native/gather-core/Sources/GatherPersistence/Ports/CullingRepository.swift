// desktop/native/gather-core/Sources/GatherPersistence/Ports/CullingRepository.swift
// WP3b-2：Culling 读模型端口（分页/计数 + 富查询）。
//
// Application 只表达「哪个 scope、哪些照片」，SQL 谓词/分块/代表行规则留在
// CullingAssetPageQuery / CullingReadQuery；写事务仍由 TransactionRunner 提供。
import Foundation
import GatherProtocol

public protocol CullingPageReading {
    /// 全 scope 唯一的 keyset 分页入口。
    func pageSorted(
        sessionId: String,
        scope: CullingScope,
        filter: CullingPageFilter,
        similarity: CullingSimilarityScope?,
        sort: CullingSort,
        cursor: CullingPageCursor?,
        limit: Int
    ) throws -> (rows: [PhotoPageRow], cursor: CullingPageCursor?)
    func countFiltered(sessionId: String, filter: CullingPageFilter) throws -> Int
    func countSimilarity(sessionId: String, similarity: CullingSimilarityScope) throws -> Int
    /// P0 / A1：当前 scope/filters 下的代表行 id（跨页全选/移出）。
    func representativeIds(
        sessionId: String,
        scope: CullingScope,
        filter: CullingPageFilter,
        similarity: CullingSimilarityScope?,
        limit: Int
    ) throws -> (ids: [String], truncated: Bool)
}

public protocol CullingRichReading {
    func qualityRows(photoIds: [String]) throws -> [CullingQualityResultRow]
    /// 20k 首屏摘要：唯一实现是 SQL 聚合。
    func summaryCounts(sessionId: String, colorLabels: [String]) throws -> CullingSummaryCounts
    /// P0 / T0：按逻辑资产 gid 的建议（代表行一条）。
    func triageRows(sessionId: String) throws -> [CullingTriageRow]
    func triageRows(sessionId: String, photoIds: [String]) throws -> [CullingTriageRow]
    func faceRows(sessionId: String) throws -> [CullingFaceObservationRow]
    func faceRows(sessionId: String, photoIds: [String]) throws -> [CullingFaceObservationRow]
    func personRows(sessionId: String) throws -> [CullingPersonNameRow]
    func personRows(sessionId: String, photoIds: [String]) throws -> [CullingPersonNameRow]
    func deliveryModuleRows(xmpPaths: [String]) throws -> [CullingDeliveryModuleRow]
    func conflictPhotoPaths(sessionId: String) throws -> Set<String>
    func existingPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String>
    func clearCullingProjection(photoIds: [String]) throws
}

extension CullingAssetPageQuery: CullingPageReading {}
extension CullingReadQuery: CullingRichReading {}
