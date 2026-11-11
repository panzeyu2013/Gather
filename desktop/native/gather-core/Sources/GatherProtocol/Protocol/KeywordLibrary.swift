// desktop/native/gather-core/Sources/GatherProtocol/Protocol/KeywordLibrary.swift
// Wave2 task-13：关键词库（受控词表）的纯值、树形投影、校验与补全合并。
//
// 数据层已有 keywords / keyword_synonyms / photo_keywords 三表（见
// SchemaCurrent+DDLWorkbench），Persistence 的 KeywordRepo 负责事务化改名/合并/
// 同义词；本文件只放"值 + 纯函数"，供 API/UI/测试共用：
// - KeywordLibraryNode：词库一行（含同义词），UI 直接渲染树；
// - KeywordLibraryTree：扁平路径 → 父子关系（不做 IO、不依赖 DB）；
// - KeywordLibraryValidator：输入归一化与"改名/合并不能同路径"等边界；
// - KeywordSuggestionBuilder：词库前缀 + 同义词命中合并成补全候选（同义词参与
//   补全但不改变落盘路径）。
//
// 语义冻结：
// - 路径即层级（"A|B|C"），同义词只挂在路径上，不改写 XMP；
// - 补全候选的 path 永远是规范路径，matchedSynonym 只用于 UI 提示"由同义词命中"；
// - 去重用 KeywordNormalizer.fold（大小写/宽度不敏感），落盘拼写保持原样。
import Foundation

/// 词库一行（keywords 表 + keyword_synonyms）。
public struct KeywordLibraryNode: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var parentPath: String?
    /// 该路径自身的照片数（usage_count 口径：不含子树）。
    public var usageCount: Int
    public var synonyms: [String]

    public var id: String { path }
    public var keywordPath: KeywordPath? { KeywordPath(path) }
    public var depth: Int { keywordPath?.depth ?? 1 }

    public init(
        path: String,
        name: String,
        parentPath: String?,
        usageCount: Int,
        synonyms: [String] = []
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.usageCount = usageCount
        self.synonyms = synonyms
    }
}

/// 词库写操作的影响计数（事务提交后的值）。
public struct KeywordMutationSummary: Codable, Equatable, Sendable {
    public var nodes: Int
    public var members: Int
    public var synonyms: Int

    public init(nodes: Int = 0, members: Int = 0, synonyms: Int = 0) {
        self.nodes = nodes
        self.members = members
        self.synonyms = synonyms
    }

    public static let empty = KeywordMutationSummary()
}

/// 自动补全候选：规范路径 + 命中来源（前缀 / 同义词）。
public struct KeywordSuggestion: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    /// nil = 路径本身前缀命中；非 nil = 由该同义词前缀命中。
    public var matchedSynonym: String?
    public var usageCount: Int

    public var id: String {
        guard let matchedSynonym else { return path }
        return path + "::" + matchedSynonym
    }

    public init(path: String, matchedSynonym: String? = nil, usageCount: Int = 0) {
        self.path = path
        self.matchedSynonym = matchedSynonym
        self.usageCount = usageCount
    }
}

/// 扁平路径列表 → 树形子级（UI DisclosureGroup 逐层取用）。
public enum KeywordLibraryTree {
    /// 直接子级；parentPath == nil 时取顶级。结果按 path 稳定排序。
    public static func children(
        of parentPath: String?,
        in nodes: [KeywordLibraryNode]
    ) -> [KeywordLibraryNode] {
        nodes
            .filter { node in
                if let parentPath {
                    return node.parentPath == parentPath
                }
                return node.parentPath == nil
            }
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    /// 该路径是否有子级（UI 决定是否显示展开箭头）。
    public static func hasChildren(of path: String, in nodes: [KeywordLibraryNode]) -> Bool {
        nodes.contains { $0.parentPath == path }
    }

    /// 路径深度（"A" = 1，"A|B" = 2）。
    public static func depth(of path: String) -> Int {
        KeywordPath(path)?.depth ?? 1
    }
}

/// 词库输入校验（API 实现与 UI 共用；错误统一走 GatherError）。
public enum KeywordLibraryValidator {
    /// 归一化路径；非法（空/全空段/超长）显式失败。
    public static func parsePath(_ raw: String, field: String = "path") throws -> KeywordPath {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = KeywordPath.parse(trimmed) else {
            throw GatherError.invalidParameter(
                field: field, reason: "must be a non-empty keyword path")
        }
        guard path.serialized.utf8.count <= 1_024 else {
            throw GatherError.invalidParameter(field: field, reason: "must be at most 1024 bytes")
        }
        return path
    }

    /// 同义词归一化 + fold 去重（空/非法项丢弃，不整批失败）。
    public static func normalizeSynonyms(_ raw: [String]) -> [String] {
        KeywordNormalizer.unique(raw.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// 改名目标必须与源不同；相同 = 无操作（显式失败，避免 UI 误以为已执行）。
    public static func requireDistinctRename(from: KeywordPath, to: KeywordPath) throws {
        guard from.serialized != to.serialized else {
            throw GatherError.invalidParameter(
                field: "to", reason: "must differ from the current path")
        }
    }

    /// 合并的源与目标不能相同。
    public static func requireDistinctMerge(source: KeywordPath, target: KeywordPath) throws {
        guard source.serialized != target.serialized else {
            throw GatherError.invalidParameter(
                field: "target", reason: "must differ from source")
        }
    }
}

/// 补全候选合并：词库前缀命中 + 同义词前缀命中 → 规范路径去重排序。
public enum KeywordSuggestionBuilder {
    /// - prefix：用户输入（可为任意大小写/宽度）；
    /// - nodes：词库全量（调用方已按 usage_count 排好也可，结果会再排一次）；
    /// - synonymMatches：repo 按同义词前缀查出的 (路径, 同义词) 对。
    ///
    /// 规则：
    /// 1. 路径或其叶子以 prefix 开头算命中；同义词以 prefix 开头也算命中；
    /// 2. 同一路径命中多次只留一条：路径命中优先于同义词命中，同义词按字典序取第一条；
    /// 3. 与 prefix 完全相同的路径不算"候选"（避免输入完整路径后补全自己）；
    /// 4. 排序：usage_count 降序 → 路径升序；limit 截断。
    public static func merge(
        prefix: String,
        limit: Int,
        nodes: [KeywordLibraryNode],
        synonymMatches: [(path: String, synonym: String)] = []
    ) -> [KeywordSuggestion] {
        let needle = KeywordNormalizer.fold(prefix)
        guard !needle.isEmpty, limit > 0 else { return [] }
        var byPath: [String: KeywordSuggestion] = [:]
        var order: [String] = []

        func insert(_ suggestion: KeywordSuggestion) {
            let key = KeywordNormalizer.fold(suggestion.path)
            if var existing = byPath[key] {
                // 路径直命中优先；同义词命中保留字典序更小者。
                if existing.matchedSynonym != nil, suggestion.matchedSynonym == nil {
                    existing = suggestion
                } else if let current = existing.matchedSynonym,
                          let incoming = suggestion.matchedSynonym,
                          incoming < current {
                    existing.matchedSynonym = incoming
                }
                byPath[key] = existing
            } else {
                byPath[key] = suggestion
                order.append(key)
            }
        }

        for node in nodes {
            let pathKey = KeywordNormalizer.fold(node.path)
            let leafKey = KeywordNormalizer.fold(node.name)
            let isPathHit = pathKey.hasPrefix(needle) || leafKey.hasPrefix(needle)
            guard isPathHit, pathKey != needle else { continue }
            insert(KeywordSuggestion(
                path: node.path, matchedSynonym: nil, usageCount: node.usageCount))
        }

        for match in synonymMatches {
            let synonymKey = KeywordNormalizer.fold(match.synonym)
            let pathKey = KeywordNormalizer.fold(match.path)
            guard synonymKey.hasPrefix(needle), pathKey != needle else { continue }
            insert(KeywordSuggestion(
                path: match.path,
                matchedSynonym: match.synonym,
                usageCount: byPath[pathKey]?.usageCount ?? 0))
        }

        return order.compactMap { byPath[$0] }
            .map { suggestion in
                var enriched = suggestion
                if let node = nodes.first(where: {
                    KeywordNormalizer.fold($0.path) == KeywordNormalizer.fold(suggestion.path)
                }) {
                    enriched.usageCount = max(enriched.usageCount, node.usageCount)
                }
                return enriched
            }
            .sorted { lhs, rhs in
                if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }
}
