// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/CullingSelectionInputs.swift
// P0 / A1：跨页选择集的只读查询（"全选当前范围" / 移出前的完整选择集）。
//
// 为什么需要独立接口：网格只加载一页（200 条），快捷键全选只能选已加载项；
// 而"移出淘汰件"必须能覆盖整个筛选结果。沿用 page 的 scope/filters 语义，
// 返回**代表行** photo id（与网格选中项同一口径），由服务端在移出时再按资产展开。
import Foundation

public struct CullingSelectionQuery: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let scope: CullingScope
    public let filters: CullingFilters?
    public let groupId: String?
    /// 上限由结果截断表达；请求侧仍给一个显式上限（1...maxIds）。
    public let limit: Int?

    /// 与 CullingMoveRejectedInput.maxPhotoIds 同值：全选后直接移出不需要二次裁剪。
    public static let maxIds = 20_000

    public init(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        groupId: String? = nil,
        limit: Int? = nil
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.scope = scope
        if let filters {
            for (index, rating) in (filters.ratings ?? []).enumerated() {
                _ = try APIValidation.integer(rating, field: "filters.ratings[\(index)]", in: 0...5)
            }
        }
        self.filters = filters
        self.groupId = groupId
        if let filters, filters.hasAnyFilter, scope == .all {
            throw GatherError(code: .CULLING_FILTER_INVALID, params: ["scope": scope.rawValue])
        }
        if let verdicts = filters?.triageVerdicts, !verdicts.isEmpty, scope != .filtered {
            throw GatherError(code: .CULLING_FILTER_INVALID, params: ["scope": scope.rawValue])
        }
        self.limit = try APIValidation.integerInRange(
            limit ?? Self.maxIds, field: "limit", 1...Self.maxIds)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            scope: try container.decode(CullingScope.self, forKey: .scope),
            filters: try container.decodeIfPresent(CullingFilters.self, forKey: .filters),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, scope, filters, groupId, limit
    }
}

public struct CullingSelectionIds: Codable, Equatable, Sendable {
    public var ids: [String]
    /// true = 命中上限被截断（UI 必须提示"仅选中前 N 张"，不能假装全选）。
    public var truncated: Bool
    /// 排序后 ID 集合的 SHA-256；updateSelection 用它绑定“承诺/执行”同一次查询。
    public var idsHash: String?

    public init(ids: [String], truncated: Bool = false, idsHash: String? = nil) {
        self.ids = ids
        self.truncated = truncated
        self.idsHash = idsHash
    }
}

/// P1-7：按 scope/filters 重算选择并批量更新，不信任客户端 ID 列表。
public struct CullingSelectionUpdateInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let scope: CullingScope
    public let filters: CullingFilters?
    public let groupId: String?
    public let expectedIdsHash: String
    public let expectedCount: Int
    public let limit: Int?
    public let patch: CullingUpdatePatch

    public init(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        groupId: String? = nil,
        expectedIdsHash: String,
        expectedCount: Int,
        limit: Int? = nil,
        patch: CullingUpdatePatch
    ) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.scope = scope
        self.filters = filters
        self.groupId = groupId
        self.expectedIdsHash = try APIValidation.nonBlank(
            expectedIdsHash, field: "expectedIdsHash", maxLength: 128)
        self.expectedCount = try APIValidation.integerInRange(
            expectedCount, field: "expectedCount", 0...CullingSelectionQuery.maxIds)
        self.limit = try APIValidation.integerInRange(
            limit ?? CullingSelectionQuery.maxIds,
            field: "limit", 1...CullingSelectionQuery.maxIds)
        try validateCullingPatch(patch)
        self.patch = patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            scope: try container.decode(CullingScope.self, forKey: .scope),
            filters: try container.decodeIfPresent(CullingFilters.self, forKey: .filters),
            groupId: try container.decodeIfPresent(String.self, forKey: .groupId),
            expectedIdsHash: try container.decode(String.self, forKey: .expectedIdsHash),
            expectedCount: try container.decode(Int.self, forKey: .expectedCount),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit),
            patch: try container.decode(CullingUpdatePatch.self, forKey: .patch)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, scope, filters, groupId, expectedIdsHash, expectedCount, limit, patch
    }
}

public struct CullingBatchSkip: Codable, Equatable, Sendable {
    public let photoId: String
    /// 机器码（当前为 "unchanged"：合并变体或决策未变化）；UI 负责本地化。
    public let reason: String
    public init(photoId: String, reason: String) {
        self.photoId = photoId
        self.reason = reason
    }
}

public struct CullingBatchFailure: Codable, Equatable, Sendable {
    /// 失败块的代表照片 id；空串 = 整块失败（见 detail 的块序号）。
    public let photoId: String
    /// 稳定错误码（GatherErrorCode.rawValue）；空串 = 未编码错误，诊断见 detail。
    public let code: String
    public let detail: String
    public init(photoId: String, code: String, detail: String) {
        self.photoId = photoId
        self.code = code
        self.detail = detail
    }
}

public struct CullingSelectionUpdateResult: Codable, Equatable, Sendable {
    public let requested: Int
    public let applied: Int
    public let skipped: [CullingBatchSkip]
    public let failed: [CullingBatchFailure]
    public let historyOperationIds: [Int]
    public let truncated: Bool
    /// 本次实际写入的照片状态（含变体/共享 sidecar 联动）。
    /// UI 直接合并到当前页，避免 20k 选择在已加载 >2000 张时无法整页重取、
    /// 缩略图/检查器停留在旧 revision。状态行可能多于 requested（变体展开）。
    public let states: [AssetCullingState]

    public init(
        requested: Int,
        applied: Int,
        skipped: [CullingBatchSkip] = [],
        failed: [CullingBatchFailure] = [],
        historyOperationIds: [Int] = [],
        truncated: Bool = false,
        states: [AssetCullingState] = []
    ) {
        self.requested = requested
        self.applied = applied
        self.skipped = skipped
        self.failed = failed
        self.historyOperationIds = historyOperationIds
        self.truncated = truncated
        self.states = states
    }
}
