// desktop/native/gather-core/Sources/GatherProtocol/API/Inputs/KeywordInputs.swift
// Wave2 task-13：关键词库（词库树 / 补全 / 改名 / 合并 / 删除 / 同义词 / 新建）
// 的输入契约。
//
// 校验归属（D-012：默认可解码失败，范围错误显式抛 INVALID_PARAM）：
// - 路径一律经 KeywordLibraryValidator 归一化（NFC/trim/空段丢弃），空路径失败；
// - 同义词在输入层归一化 + fold 去重，空项丢弃（不整批失败）；
// - limit 有上限（词库树 2000 / 补全 50），防止一次拉全量把 UI 拖死；
// - 破坏性动作（改名/合并/删除/同义词覆盖/新建）由 API 层要求 Confirmed<T>，
//   输入类型本身不携带确认字段（D-011）。
import Foundation

/// 词库查询：nil/空 prefix = 全量（树面板）；非空 = 只回前缀匹配（移动端/紧凑面板）。
public struct KeywordLibraryQuery: Decodable, Sendable, Equatable {
    public let prefix: String?
    public let limit: Int
    public static let maxLimit = 2_000

    public init(prefix: String? = nil, limit: Int = 2_000) throws {
        self.prefix = try Self.normalizedPrefix(prefix)
        self.limit = try APIValidation.integerInRange(limit, field: "limit", 1...Self.maxLimit)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            prefix: try container.decodeIfPresent(String.self, forKey: .prefix),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.maxLimit
        )
    }

    static func normalizedPrefix(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try APIValidation.bounded(trimmed, field: "prefix", maxLength: 1_024, allowEmpty: false)
    }

    private enum CodingKeys: String, CodingKey { case prefix, limit }
}

/// 自动补全查询（词库前缀 + 同义词命中）。
public struct KeywordSuggestionQuery: Decodable, Sendable, Equatable {
    public let prefix: String
    public let limit: Int
    public static let maxLimit = 50

    public init(prefix: String, limit: Int = 8) throws {
        self.prefix = try APIValidation.nonBlank(prefix, field: "prefix", maxLength: 256)
        self.limit = try APIValidation.integerInRange(limit, field: "limit", 1...Self.maxLimit)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            prefix: try container.decode(String.self, forKey: .prefix),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? 8
        )
    }

    private enum CodingKeys: String, CodingKey { case prefix, limit }
}

/// 改名：from → to（含子孙前缀级联，事务化）。
public struct KeywordRenameInput: Decodable, Sendable, Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) throws {
        let source = try KeywordLibraryValidator.parsePath(from, field: "from")
        let target = try KeywordLibraryValidator.parsePath(to, field: "to")
        try KeywordLibraryValidator.requireDistinctRename(from: source, to: target)
        self.from = source.serialized
        self.to = target.serialized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            from: try container.decode(String.self, forKey: .from),
            to: try container.decode(String.self, forKey: .to)
        )
    }

    private enum CodingKeys: String, CodingKey { case from, to }
}

/// 合并：source 的成员/同义词并入 target（只允许叶子，事务化）。
public struct KeywordMergeInput: Decodable, Sendable, Equatable {
    public let source: String
    public let target: String

    public init(source: String, target: String) throws {
        let sourcePath = try KeywordLibraryValidator.parsePath(source, field: "source")
        let targetPath = try KeywordLibraryValidator.parsePath(target, field: "target")
        try KeywordLibraryValidator.requireDistinctMerge(source: sourcePath, target: targetPath)
        self.source = sourcePath.serialized
        self.target = targetPath.serialized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: try container.decode(String.self, forKey: .source),
            target: try container.decode(String.self, forKey: .target)
        )
    }

    private enum CodingKeys: String, CodingKey { case source, target }
}

/// 删除：cascade=false 时要求无成员/无子级/无同义词（仓储守卫）。
public struct KeywordDeleteInput: Decodable, Sendable, Equatable {
    public let path: String
    public let cascade: Bool

    public init(path: String, cascade: Bool = false) throws {
        self.path = try KeywordLibraryValidator.parsePath(path).serialized
        self.cascade = cascade
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: try container.decode(String.self, forKey: .path),
            cascade: try container.decodeIfPresent(Bool.self, forKey: .cascade) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey { case path, cascade }
}

/// 覆盖式设置同义词（空数组 = 清空）。同义词只影响补全/检索，不写 XMP。
public struct KeywordSynonymsInput: Decodable, Sendable, Equatable {
    public let path: String
    public let synonyms: [String]
    public static let maxSynonyms = 64

    public init(path: String, synonyms: [String]) throws {
        self.path = try KeywordLibraryValidator.parsePath(path).serialized
        let normalized = KeywordLibraryValidator.normalizeSynonyms(synonyms)
        guard normalized.count <= Self.maxSynonyms else {
            throw GatherError.invalidParameter(
                field: "synonyms", reason: "must be at most \(Self.maxSynonyms) items")
        }
        self.synonyms = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: try container.decode(String.self, forKey: .path),
            synonyms: try container.decodeIfPresent([String].self, forKey: .synonyms) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey { case path, synonyms }
}

/// 新建一个空路径（用于词库树里"新建子级"；已存在时幂等返回空影响）。
public struct KeywordCreateInput: Decodable, Sendable, Equatable {
    public let path: String

    public init(path: String) throws {
        self.path = try KeywordLibraryValidator.parsePath(path).serialized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(path: try container.decode(String.self, forKey: .path))
    }

    private enum CodingKeys: String, CodingKey { case path }
}
