// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Paging.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// keyset 分页与 scope 计数（不含查询装配）。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension CullingService {
    /// 唯一分页入口：limit/scope/cursor 的合法性由 CullingPageQuery.init 单点校验。
    public func listPage(_ query: CullingPageQuery) throws -> CullingPage {
        let gate = try triageGate(sessionId: query.sessionId)
        // 没有门控就没有“当前建议”的判定；带着 verdict 过滤会把历史行当现状。
        if let verdicts = query.filters?.triageVerdicts, !verdicts.isEmpty, gate == nil {
            throw GatherError(
                code: .CULLING_FILTER_INVALID,
                params: ["reason": "triage filter requires enabled triage"])
        }
        let page = try pagePhotosQuery(
            sessionId: query.sessionId, scope: query.scope, filters: query.filters,
            requestedGroupId: query.groupId, sort: query.sort, cursor: query.cursor,
            limit: query.limit, gate: gate
        )
        let lookup = try buildRichLookup(photos: page.photos, sessionId: query.sessionId, mode: .page)
        let assets = filterVisible(
            assembleAssets(photos: page.photos, lookup: lookup),
            scope: query.scope, filters: query.filters, requestedGroupId: query.groupId,
            conflictingPhotoPaths: try conflictPhotoPaths(
                sessionId: query.sessionId, filters: query.filters)
        )
        let totalKey = pageTotalKey(query, gate: gate)
        let total: Int
        if let cached = pageTotalCache[totalKey],
           query.cursor != nil,
           Date().timeIntervalSince(cached.at) < Self.pageTotalTTLSeconds {
            // 续页不再重算精确 total；首页/reset（cursor=nil）会覆盖缓存。
            total = cached.total
        } else {
            total = try countForScope(
                sessionId: query.sessionId, scope: query.scope, filters: query.filters,
                requestedGroupId: query.groupId, similarityMap: lookup.similarityMap,
                gate: gate
            )
            pageTotalCache[totalKey] = (total, Date())
            if pageTotalCache.count > Self.pageTotalCacheMax {
                let keep = pageTotalCache
                    .sorted { $0.value.at > $1.value.at }
                    .prefix(Self.pageTotalCacheMax)
                pageTotalCache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
        return CullingPage(assets: assets, total: total, nextCursor: page.cursor)
    }
    /// P0 / A1：当前 scope/filters 下的完整选中集（代表行 id）。
    ///
    /// 与 listPage 同源：triage 门控/过滤校验、scope→similarity 解析、filters 投影
    /// 全部复用，避免"全选"和网格看到的不是同一批照片。
    public func selectableIds(_ query: CullingSelectionQuery) throws -> CullingSelectionIds {
        let gate = try triageGate(sessionId: query.sessionId)
        if let verdicts = query.filters?.triageVerdicts, !verdicts.isEmpty, gate == nil {
            throw GatherError(
                code: .CULLING_FILTER_INVALID,
                params: ["reason": "triage filter requires enabled triage"])
        }
        let similarity: CullingSimilarityScope? = query.scope == .similarityGroup
            ? Self.similarityScope(query.groupId) : nil
        if query.scope == .similarityGroup, similarity == nil {
            // 组 id 无法解析：没有可比对的成员集合，返回空集而不是回退到全部照片。
            return CullingSelectionIds(ids: [], truncated: false)
        }
        let result = try pageQuery.representativeIds(
            sessionId: query.sessionId,
            scope: query.scope,
            filter: Self.pageFilter(query.filters, gate: gate),
            similarity: similarity,
            limit: query.limit ?? CullingSelectionQuery.maxIds
        )
        return CullingSelectionIds(ids: result.ids, truncated: result.truncated)
    }

    // MARK: - 分页（TS pagePhotosQuery / loadAssetRows / preferredRowPredicate /
    // buildFilteredWhere / buildSimilarityClause / countForScope）

    /// 三 scope 共用的资产组 keyset 页：scope 只决定 WHERE，sort 决定 keyset 键。
    private func pagePhotosQuery(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        sort: CullingSort,
        cursor: CullingPageCursor?,
        limit: Int,
        gate: (fingerprint: String, policyVersion: String)?
    ) throws -> (photos: [CullingPhotoRow], cursor: CullingPageCursor?) {
        let similarity = scope == .similarityGroup
            ? Self.similarityScope(requestedGroupId)
            : nil
        let page = try pageQuery.pageSorted(
            sessionId: sessionId,
            scope: scope,
            filter: Self.pageFilter(filters, gate: gate),
            similarity: similarity,
            sort: sort,
            cursor: cursor,
            limit: limit
        )
        return (photos: page.rows.map { CullingPhotoRow(row: $0) }, cursor: page.cursor)
    }

    /// T0 门控（指纹 + 策略版本）：只在匹配/关闭两态；未接入时返回 nil。
    private func triageGate(
        sessionId: String
    ) throws -> (fingerprint: String, policyVersion: String)? {
        guard let policy = try triageDisplayPolicy?(sessionId) else { return nil }
        guard case .matching(let gate) = policy else { return nil }
        return (gate.fingerprint, gate.policyVersion)
    }

    /// CullingFilters → 存储侧过滤投影。枚举 → DB 值的映射留在应用层；
    /// SQL 谓词与子句顺序见 CullingPageQuery.filteredWhere（逐字搬移）。
    static func pageFilter(
        _ filters: CullingFilters?,
        gate: (fingerprint: String, policyVersion: String)? = nil
    ) -> CullingPageFilter {
        guard let filters else {
            return CullingPageFilter(
                triageFingerprint: gate?.fingerprint,
                triagePolicyVersion: gate?.policyVersion)
        }
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
            qualityStatus: quality,
            triageVerdicts: filters.triageVerdicts?.map(\.rawValue),
            triageFingerprint: gate?.fingerprint,
            triagePolicyVersion: gate?.policyVersion
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

    private func pageTotalKey(
        _ query: CullingPageQuery,
        gate: (fingerprint: String, policyVersion: String)?
    ) -> String {
        let filterKey = (try? JSONEncoder().encode(query.filters))?.base64EncodedString() ?? ""
        return [
            query.sessionId, query.scope.rawValue, query.groupId ?? "", filterKey,
            gate?.fingerprint ?? "", gate?.policyVersion ?? "",
        ].joined(separator: "|")
    }

    /// TS: countForScope —— scope/filters 的逻辑资产计数（total 匹配胶片条加载
    /// 全部页后的条目数：每资产一条，非每物理照片行一条）。
    private func countForScope(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        similarityMap: [String: String],
        gate: (fingerprint: String, policyVersion: String)?
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
                sessionId: sessionId, filter: Self.pageFilter(filters, gate: gate))
        }
        return try photoRepo.countAssetsBySession(sessionId: sessionId)
    }
}
