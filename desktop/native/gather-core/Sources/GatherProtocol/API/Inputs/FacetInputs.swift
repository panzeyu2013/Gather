// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/FacetInputs.swift
// P1 / C：facet（筛选面板计数）的输入与结果契约。
// P1 下一波 §3.6.4：新增 keyword 维与 `keywordPrefix`（层级下钻）。
import Foundation

public struct PhotoFacetInput: Decodable, Sendable, Equatable {
    /// 允许的维度（与 Persistence 的 FacetDimension.rawValue 一一对应；
    /// Protocol 不能依赖 Persistence，故这里保留一份字符串白名单，二者由
    /// FacetQueryTests 的字段对照用例守住）。
    public static let allowedDimensions: [String] = [
        "camera", "lens", "iso", "year", "label", "keyword",
        // Wave2 / task-14：场景标签（photo_keywords 下 SemanticKeywordPath.scene 子树）
        // 与人物（person_photos）。两维的桶值都直接落成图库可用的筛选值：
        // scene → keyword_path starts_with，person → person contains/eq。
        "scene", "person",
    ]

    public let sessionId: String
    /// 当前筛选条件（服务端会按维度剔除自身后计数）。
    public let criteria: FilterGroup
    /// 维度白名单（camera/lens/iso/year/label/keyword），空 = 全部；
    /// 未知维显式失败，不静默丢弃。
    public let dimensions: [String]
    public let limit: Int
    /// keyword 维的下钻节点（"A" 或 "A|B"）。nil/空 = 顶级桶（每条的**首段**）。
    ///
    /// 语义：只统计 `keyword_path` 以该节点为前缀（含节点自身）的照片，
    /// 桶名取"前缀之后的下一段"——于是点 A 之后的 keyword facet 变成 A 的子级列表。
    public let keywordPrefix: String?

    public init(
        sessionId: String,
        criteria: FilterGroup,
        dimensions: [String] = [],
        limit: Int = 60,
        keywordPrefix: String? = nil
    ) throws {
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
        self.keywordPrefix = try Self.normalizedPrefix(keywordPrefix)
    }

    /// 下钻节点归一化：trim + NFC；非法路径（全部段为空）显式失败，
    /// 不把 "|" / 空白当成"一个合法的前缀"去扫全表。
    static func normalizedPrefix(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let path = KeywordPath.parse(trimmed) else {
            throw GatherError.invalidParameter(
                field: "keywordPrefix", reason: "must be a non-empty keyword path")
        }
        guard path.serialized.utf8.count <= 512 else {
            throw GatherError.invalidParameter(
                field: "keywordPrefix", reason: "must be at most 512 bytes")
        }
        return path.serialized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionId: try container.decode(String.self, forKey: .sessionId),
            criteria: try container.decode(FilterGroup.self, forKey: .criteria),
            dimensions: try container.decodeIfPresent([String].self, forKey: .dimensions) ?? [],
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 60,
            keywordPrefix: try container.decodeIfPresent(String.self, forKey: .keywordPrefix)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, criteria, dimensions, limit, keywordPrefix
    }
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
