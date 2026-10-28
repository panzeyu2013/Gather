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
    public init(ids: [String], truncated: Bool = false) {
        self.ids = ids
        self.truncated = truncated
    }
}
