// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/FacetInputs.swift
// P1 / C：facet（筛选面板计数）的输入与结果契约。
import Foundation

public struct PhotoFacetInput: Decodable, Sendable, Equatable {
    /// 允许的维度（与 Persistence 的 FacetDimension.rawValue 一一对应；
    /// Protocol 不能依赖 Persistence，故这里保留一份字符串白名单，二者由
    /// FacetQueryTests 的字段对照用例守住）。
    public static let allowedDimensions: [String] = ["camera", "lens", "iso", "year", "label"]

    public let sessionId: String
    /// 当前筛选条件（服务端会按维度剔除自身后计数）。
    public let criteria: FilterGroup
    /// 维度白名单（camera/lens/iso/year/label），空 = 全部；未知维显式失败，不静默丢弃。
    public let dimensions: [String]
    public let limit: Int

    public init(sessionId: String, criteria: FilterGroup, dimensions: [String] = [], limit: Int = 60) throws {
        self.sessionId = try APIValidation.nonBlank(sessionId, field: "sessionId", maxLength: 128)
        self.criteria = criteria
        var seen = Set<String>()
        var normalized: [String] = []
        for (index, raw) in dimensions.enumerated() {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard Self.allowedDimensions.contains(value) else {
                throw GatherError.invalidParameter(
                    field: "dimensions[\(index)]",
                    reason: "must be one of \(Self.allowedDimensions.joined(separator: "/"))")
            }
            if seen.insert(value).inserted { normalized.append(value) }
        }
        self.dimensions = normalized
        self.limit = try APIValidation.integerInRange(limit, field: "limit", 1...200)
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
