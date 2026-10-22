// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Paging.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// keyset 分页与 scope 计数（不含查询装配）。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    /// TS: listPage —— 资产分组 keyset 分页（RAW/JPEG 变体永不分页；total 精确）。
    public func listPage(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil,
        afterRowId: Int64? = nil,
        limit: Int = 200
    ) throws -> CullingPage {
        if let afterRowId, afterRowId < 1 {
            throw CullingServiceError.afterRowIdInvalid
        }
        guard limit >= 1, limit <= Self.pageLimitMax else {
            throw CullingServiceError.pageLimitInvalid
        }
        let page = try pagePhotosQuery(
            sessionId: sessionId, scope: scope, filters: filters,
            requestedGroupId: requestedGroupId, afterRowId: afterRowId, limit: limit
        )
        let lookup = try buildRichLookup(photos: page.photos, sessionId: sessionId, mode: .page)
        let assets = filterVisible(
            assembleAssets(photos: page.photos, lookup: lookup),
            scope: scope, filters: filters, requestedGroupId: requestedGroupId,
            conflictingPhotoPaths: try conflictPhotoPaths(sessionId: sessionId, filters: filters)
        )
        let total = try countForScope(
            sessionId: sessionId, scope: scope, filters: filters,
            requestedGroupId: requestedGroupId, similarityMap: lookup.similarityMap
        )
        return CullingPage(
            assets: assets,
            nextRowId: page.cursor.map(Int.init),
            total: total
        )
    }
    // MARK: - 分页（TS pagePhotosQuery / loadAssetRows / preferredRowPredicate /
    // buildFilteredWhere / buildSimilarityClause / countForScope）

    /// TS: pagePhotosQuery —— 三 scope 共用的两步资产分组 keyset 页：
    /// 1. 取至多 limit 个资产组（按组首 rowid 排序，first_rowid > afterRowId）；
    /// 2. 取这些组的全部行（一页恒为完整资产）。
    /// afterRowId 是上一页的 nextRowId（其最后资产组的首 rowid）；cursor 是
    /// 当前页组查询的 first_rowid —— 绝非从已加载行推导的值（最小 rowid 可能
    /// 属于不匹配谓词的变体，重新推导会让下一页重复选中该资产）。
    private func pagePhotosQuery(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        afterRowId: Int64?,
        limit: Int
    ) throws -> (photos: [CullingPhotoRow], cursor: Int64?) {
        if scope == .filtered {
            let page = try pageQuery.pageFiltered(
                sessionId: sessionId,
                filter: Self.pageFilter(filters),
                afterRowId: afterRowId,
                limit: limit
            )
            return (photos: page.rows.map { CullingPhotoRow(row: $0) }, cursor: page.cursor)
        }
        if scope == .similarityGroup, let similarity = Self.similarityScope(requestedGroupId) {
            let page = try pageQuery.pageSimilarity(
                sessionId: sessionId,
                similarity: similarity,
                afterRowId: afterRowId,
                limit: limit
            )
            return (photos: page.rows.map { CullingPhotoRow(row: $0) }, cursor: page.cursor)
        }
        let page = try photoRepo.getAssetPage(sessionId: sessionId, afterFirstRowid: afterRowId, limit: limit)
        return (photos: page.rows.map { CullingPhotoRow(row: $0) }, cursor: page.cursor)
    }

    /// CullingFilters → 存储侧过滤投影。枚举 → DB 值的映射留在应用层；
    /// SQL 谓词与子句顺序见 CullingPageQuery.filteredWhere（逐字搬移）。
    static func pageFilter(_ filters: CullingFilters?) -> CullingPageFilter {
        guard let filters else { return CullingPageFilter() }
        let decisions = filters.pickStates?.map { state -> String in
            switch state {
            case .picked: "keep"
            case .rejected: "reject"
            case .unreviewed: "pending"
            }
        }
        let quality: CullingQualityFilter?
        switch filters.qualityStatus {
        case .analysed: quality = .analysed
        case .failed: quality = .failed
        case .unanalysed: quality = .unanalysed
        case nil: quality = nil
        }
        return CullingPageFilter(
            decisions: decisions,
            ratings: filters.ratings,
            colorLabels: filters.colorLabels?.map(\.rawValue),
            unreviewedOnly: filters.unreviewedOnly,
            metadataConflictOnly: filters.metadataConflictOnly,
            qualityStatus: quality
        )
    }

    /// TS: buildSimilarityClause 的解析段 —— 组 id 无法解析时返回 nil
    ///（页面改经 JS 相似度映射过滤，仍精确、可能不满页）。
    static func similarityScope(_ requestedGroupId: String?) -> CullingSimilarityScope? {
        guard let requestedGroupId else { return .latest }
        let separator = requestedGroupId.lastIndex(of: ":")
        guard let separator else { return nil }
        // TS: Number(slice) —— 非整数（含 NaN）→ 无法解析 → nil 子句。
        guard let resultId = Int(requestedGroupId[requestedGroupId.startIndex..<separator]),
              let groupIndex = Int(requestedGroupId[requestedGroupId.index(after: separator)...]) else {
            return nil
        }
        return .group(resultId: Int64(resultId), groupIndex: Int64(groupIndex))
    }

    /// TS: countForScope —— scope/filters 的逻辑资产计数（total 匹配胶片条加载
    /// 全部页后的条目数：每资产一条，非每物理照片行一条）。
    private func countForScope(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        similarityMap: [String: String]
    ) throws -> Int {
        if scope == .similarityGroup {
            if let similarity = Self.similarityScope(requestedGroupId) {
                return try pageQuery.countSimilarity(sessionId: sessionId, similarity: similarity)
            }
            // 无法解析的组 id：无 SQL 谓词，按 JS 相似度映射计数（去重成员照片）。
            if let requestedGroupId {
                var count = 0
                for groupId in similarityMap.values where groupId == requestedGroupId {
                    count += 1
                }
                return count
            }
            return similarityMap.count
        }
        if scope == .filtered {
            return try pageQuery.countFiltered(
                sessionId: sessionId, filter: Self.pageFilter(filters))
        }
        return try photoRepo.countAssetsBySession(sessionId: sessionId)
    }
}
