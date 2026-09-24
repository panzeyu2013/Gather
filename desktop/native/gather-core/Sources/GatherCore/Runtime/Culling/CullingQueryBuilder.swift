// desktop/native/gather-core/Sources/GatherCore/Runtime/Culling/CullingQueryBuilder.swift
// Culling 查询参数：无状态纯函数层（校验 / scope 编译 / 分页请求组装）。
// SQL 一律在 Store（CullingQueryStore）；本文件不含任何 SQL 与 DB 依赖。

import Foundation

/// 分页请求：Store 查询 + JS 层后置过滤（metadataConflictOnly 只能 JS 层判断）。
public struct CullingPostFilter: Sendable, Equatable {
    public let scope: CullingScope
    public let requestedGroupId: String?
    public let metadataConflictOnly: Bool
    public let specs: [CullingFilterSpec]

    public init(scope: CullingScope, requestedGroupId: String?, metadataConflictOnly: Bool, specs: [CullingFilterSpec]) {
        self.scope = scope
        self.requestedGroupId = requestedGroupId
        self.metadataConflictOnly = metadataConflictOnly
        self.specs = specs
    }
}

public struct CullingPageRequest: Sendable, Equatable {
    public let sessionId: String
    public let query: CullingPageQuery
    public let postFilter: CullingPostFilter
    public let afterRowId: Int64?
    public let limit: Int

    public init(sessionId: String, query: CullingPageQuery, postFilter: CullingPostFilter, afterRowId: Int64?, limit: Int) {
        self.sessionId = sessionId
        self.query = query
        self.postFilter = postFilter
        self.afterRowId = afterRowId
        self.limit = limit
    }
}

/// 纯函数：Culling 查询参数校验与编译（对应旧 CullingService 的 IPC 校验分支）。
public enum CullingQueryBuilder {
    public static let pageLimitMax = 2_000
    public static let batchMax = 10_000

    /// TS: listPage 入参校验（afterRowId 正数；limit 1...2000）。
    public static func normalize(afterRowId: Int64?, limit: Int) throws -> (afterRowId: Int64?, limit: Int) {
        if let afterRowId, afterRowId < 1 {
            throw CullingServiceError.afterRowIdInvalid
        }
        guard limit >= 1, limit <= pageLimitMax else {
            throw CullingServiceError.pageLimitInvalid
        }
        return (afterRowId, limit)
    }

    /// CullingFilters → 原子过滤谓词（唯一映射入口，SQL 与 Assembler 共用同一份）。
    public static func filterSpecs(_ filters: CullingFilters?) -> [CullingFilterSpec] {
        guard let filters else { return [] }
        return [CullingFilterSpec(filters: filters)]
    }

    /// TS: Number(slice) —— 组 id 形如 "resultId:groupIndex"，非整数即不可解析。
    public static func parseSimilarityGroupId(_ raw: String) -> (resultId: Int, groupIndex: Int)? {
        guard let separator = raw.lastIndex(of: ":") else { return nil }
        guard let resultId = Int(raw[raw.startIndex..<separator]),
              let groupIndex = Int(raw[raw.index(after: separator)...]) else {
            return nil
        }
        return (resultId, groupIndex)
    }

    /// scope/filters/groupId → Store 查询 + JS 后置过滤。
    public static func pageRequest(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        afterRowId: Int64? = nil,
        limit: Int = 200
    ) throws -> CullingPageRequest {
        let normalized = try normalize(afterRowId: afterRowId, limit: limit)
        let specs = filterSpecs(filters)
        let queryScope: CullingQueryScope
        switch scope {
        case .filtered:
            queryScope = .filtered(specs)
        case .similarityGroup:
            if let requestedGroupId, let parsed = parseSimilarityGroupId(requestedGroupId) {
                queryScope = .similarityGroup(resultId: parsed.resultId, groupIndex: parsed.groupIndex)
            } else {
                // 不可解析：走最新结果页 + JS 相似度映射过滤（可能不满页）。
                queryScope = .similarityLatest
            }
        case .all:
            queryScope = .all
        }
        let query = CullingPageQuery(
            sessionId: sessionId,
            scope: queryScope,
            afterRowId: normalized.afterRowId,
            limit: normalized.limit
        )
        let postFilter = CullingPostFilter(
            scope: scope,
            requestedGroupId: requestedGroupId,
            metadataConflictOnly: filters?.metadataConflictOnly == true,
            specs: specs
        )
        return CullingPageRequest(
            sessionId: sessionId,
            query: query,
            postFilter: postFilter,
            afterRowId: normalized.afterRowId,
            limit: normalized.limit
        )
    }

    /// total 与页同源：计数使用同一 scope 编译。
    public static func countQuery(_ request: CullingPageRequest) -> CullingPageQuery {
        CullingPageQuery(sessionId: request.sessionId, scope: request.query.scope, afterRowId: nil, limit: request.limit)
    }

    /// TS: batchUpdate 入参（去重保序；空 → CULLING_EMPTY_SELECTION；超限 → tooManyPhotoIds）。
    public static func validateBatch(_ photoIds: [String]) throws -> [String] {
        var uniqueIds: [String] = []
        for photoId in photoIds where !uniqueIds.contains(photoId) {
            uniqueIds.append(photoId)
        }
        if uniqueIds.isEmpty { throw CullingServiceError.emptySelection }
        if uniqueIds.count > batchMax { throw CullingServiceError.tooManyPhotoIds }
        return uniqueIds
    }

    /// TS: decideSimilarityGroup 的 keepPhotoIds 上限校验。
    public static func validateKeepIds(_ keepPhotoIds: [String]) throws -> [String] {
        guard keepPhotoIds.count <= batchMax else { throw CullingServiceError.tooManyKeepPhotoIds }
        return keepPhotoIds
    }

    /// TS: update/batchUpdate 的 patch 校验（字段互斥、范围、枚举白名单）。
    public static func validatePatch(_ patch: CullingUpdatePatch) throws {
        if patch.rating == nil && patch.pickState == nil && patch.colorLabel == nil {
            throw CullingServiceError.patchInvalid
        }
        if let rating = patch.rating,
           !(rating.rounded() == rating && (0...5).contains(rating)) {
            throw CullingServiceError.ratingOutOfRange
        }
        if let pickState = patch.pickState,
           ![PickState.unreviewed, .picked, .rejected].contains(pickState) {
            throw CullingServiceError.invalidPickState
        }
        if let colorLabel = patch.colorLabel,
           !CaptureOneColorLabel.allCases.contains(colorLabel) {
            throw CullingServiceError.invalidColorLabel
        }
    }
}
