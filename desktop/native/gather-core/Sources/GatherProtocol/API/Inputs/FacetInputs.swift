// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/FacetInputs.swift
// P1 / C：facet（筛选面板计数）的输入与结果契约。
import Foundation

public struct PhotoFacetInput: Decodable, Sendable, Equatable {
    public let sessionId: String
    /// 当前筛选条件（服务端会按维度剔除自身后计数）。
    public let criteria: FilterGroup
    /// 维度白名单（camera/lens/iso/year/label），空 = 全部。
    public let dimensions: [String]
    public let limit: Int

    public init(sessionId: String, criteria: FilterGroup, dimensions: [String] = [], limit: Int = 60) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.criteria = criteria
        self.dimensions = dimensions
        self.limit = max(1, min(limit, 200))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            criteria: try container.decode(FilterGroup.self, forKey: .criteria),
            dimensions: try container.decodeIfPresent([String].self, forKey: .dimensions) ?? [],
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 60
        )
    }

    private enum CodingKeys: String, CodingKey { case sessionId, criteria, dimensions, limit }
}

public struct PhotoFacetBucket: Codable, Equatable, Sendable {
    public var value: String
    public var count: Int
    public init(value: String, count: Int) {
        self.value = value
        self.count = count
    }
}

public struct PhotoFacetGroup: Codable, Equatable, Sendable {
    public var dimension: String
    public var buckets: [PhotoFacetBucket]
    public init(dimension: String, buckets: [PhotoFacetBucket]) {
        self.dimension = dimension
        self.buckets = buckets
    }
}
