// desktop/native/gather-core/Sources/GatherApplication/Services/Keyword/KeywordService.swift
// P1 下一波 §3.6.5：关键词库（树/计数/新建/改名/合并/删除/同义词/自动补全）。
//
// 纪律：
// - 改名/合并/删除都是**单事务级联**（实现落在 KeywordRepo，本文件只做编排与错误映射）；
// - 不写盘：XMP 由后续"写入 XMP"的显式批量重写负责（rename/merge 只动库与 photo_keywords）；
// - 计数口径 = 网格口径：按 COALESCE(asset_id, id) 去重（assetCounts），usage_count 只排序。
import Foundation
import GatherPersistence
import GatherProtocol

/// 词库树的一个节点（扁平列表 + parentPath，UI 自己拼树）。
public struct KeywordNodeData: Equatable, Sendable {
    public let path: String
    public let name: String
    public let parentPath: String?
    public let depth: Int
    /// 按逻辑资产去重的成员数（与网格 / facet 同口径）。
    public let photoCount: Int
    /// keywords.usage_count：排序权重，**不是**展示计数。
    public let usageCount: Int
    public let childCount: Int
    public let synonyms: [String]

    public init(
        path: String, name: String, parentPath: String?, depth: Int,
        photoCount: Int, usageCount: Int, childCount: Int, synonyms: [String]
    ) {
        self.path = path
        self.name = name
        self.parentPath = parentPath
        self.depth = depth
        self.photoCount = photoCount
        self.usageCount = usageCount
        self.childCount = childCount
        self.synonyms = synonyms
    }
}

/// 自动补全候选：已有路径（不新建近义词）。
public struct KeywordSuggestion: Equatable, Sendable {
    public let path: String
    public let name: String
    public let photoCount: Int
    /// true = 因为同义词命中而被带回的路径（UI 可加"同义词"角标）。
    public let viaSynonym: Bool

    public init(path: String, name: String, photoCount: Int, viaSynonym: Bool) {
        self.path = path
        self.name = name
        self.photoCount = photoCount
        self.viaSynonym = viaSynonym
    }
}

public final class KeywordService: Sendable {
    /// @unchecked Sendable 依据同 RepositoryKeywordThesaurus：可变状态全在 DB 连接锁里。
    private let repo: KeywordRepo

    public init(repo: KeywordRepo) {
        self.repo = repo
    }

    public init(connection: DBConnection) {
        self.repo = KeywordRepo(connection: connection)
    }

    // MARK: - 读

    /// 扁平节点列表（按 path 排序），带子树成员计数与同义词。
    ///
    /// sessionId == nil 表示跨会话（词库管理面板）；非 nil 时计数只算该会话可见照片。
    public func tree(sessionId: String? = nil) throws -> [KeywordNodeData] {
        let rows = try repo.all()
        var counts = try repo.assetCounts(sessionId: sessionId)
        // 父级计数 = 自身 + 全部子孙（否则树上父节点永远是 0，用户看不出层级规模）。
        for row in rows {
            var ancestors: [String] = []
            var current = row.parentPath
            while let path = current {
                ancestors.append(path)
                current = KeywordPath(path)?.parent?.serialized
            }
            guard let own = counts[row.path], own > 0 else { continue }
            for ancestor in ancestors {
                counts[ancestor, default: 0] += own
            }
        }
        var childCounts: [String: Int] = [:]
        for row in rows {
            if let parent = row.parentPath { childCounts[parent, default: 0] += 1 }
        }
        // 元组不支持 key path，手工分组（一次全表读，词库规模在万级以内）。
        var synonymsByPath: [String: [String]] = [:]
        for entry in try repo.allSynonyms() {
            synonymsByPath[entry.keywordPath, default: []].append(entry.synonym)
        }
        let synonyms = synonymsByPath.mapValues { $0.sorted() }
        return rows.map { row in
            let depth = KeywordPath(row.path)?.depth ?? 1
            return KeywordNodeData(
                path: row.path,
                name: row.name,
                parentPath: row.parentPath,
                depth: depth,
                photoCount: counts[row.path] ?? 0,
                usageCount: row.usageCount,
                childCount: childCounts[row.path] ?? 0,
                synonyms: synonyms[row.path] ?? [])
        }
    }

    public func synonyms(for path: KeywordPath) throws -> [String] {
        try repo.synonyms(path: path.serialized)
    }

    /// 自动补全：前缀匹配 + 同义词命中；按成员数降序，最多 limit 条。
    public func suggestions(
        prefix: String,
        sessionId: String? = nil,
        limit: Int = 12
    ) throws -> [KeywordSuggestion] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let capped = max(1, min(50, limit))
        let counts = try repo.assetCounts(sessionId: sessionId)
        var seen = Set<String>()
        var result: [KeywordSuggestion] = []
        for row in try repo.prefixMatches(trimmed, limit: capped) {
            guard seen.insert(KeywordNormalizer.fold(row.path)).inserted else { continue }
            result.append(KeywordSuggestion(
                path: row.path, name: row.name,
                photoCount: counts[row.path] ?? 0, viaSynonym: false))
        }
        // 同义词命中：用户输入"日落"应能选中"Sunset"（只带回已有路径）。
        let needle = KeywordNormalizer.fold(trimmed)
        var synonymHits: [(path: String, synonym: String)] = []
        for entry in try repo.allSynonyms()
        where KeywordNormalizer.fold(entry.synonym).hasPrefix(needle) {
            synonymHits.append((entry.keywordPath, entry.synonym))
        }
        for hit in synonymHits where result.count < capped {
            guard seen.insert(KeywordNormalizer.fold(hit.path)).inserted else { continue }
            guard let keyword = try repo.keyword(path: hit.path) else { continue }
            result.append(KeywordSuggestion(
                path: keyword.path, name: keyword.name,
                photoCount: counts[keyword.path] ?? 0, viaSynonym: true))
        }
        return result
    }

    // MARK: - 写

    /// 新建（已存在则幂等返回）。
    @discardableResult
    public func create(_ path: KeywordPath) throws -> KeywordNodeData {
        _ = try repo.ensure(paths: [path])
        guard let row = try repo.keyword(path: path.serialized) else {
            throw GatherError.invalidParameter(field: "path", reason: "failed to create keyword")
        }
        return KeywordNodeData(
            path: row.path, name: row.name, parentPath: row.parentPath,
            depth: KeywordPath(row.path)?.depth ?? 1,
            photoCount: 0, usageCount: row.usageCount, childCount: 0, synonyms: [])
    }

    /// 改名（子孙路径一并级联；不写盘）。
    public func rename(from: KeywordPath, to: KeywordPath) throws -> KeywordMutationResult {
        try translated { try repo.rename(from: from, to: to) }
    }

    /// 合并（source 的成员与同义词并入 target，然后删掉 source；source 必须是叶子）。
    public func merge(from source: KeywordPath, into target: KeywordPath) throws -> KeywordMutationResult {
        try translated { try repo.merge(from: source, into: target) }
    }

    /// 删除（cascade=false 时要求无成员且无子级）。
    public func delete(_ path: KeywordPath, cascade: Bool = false) throws -> KeywordMutationResult {
        try translated { try repo.delete(path: path, cascade: cascade) }
    }

    /// 覆盖式设置同义词（fold 去重；空数组 = 清空）。返回落库条数。
    @discardableResult
    public func setSynonyms(_ path: KeywordPath, synonyms: [String]) throws -> Int {
        try translated { try repo.setSynonyms(path: path, synonyms: synonyms) }
    }

    // MARK: - 错误映射

    /// Repo 的结构化错误 → API 层已有的 INVALID_PARAM（不新增全局错误码）。
    private func translated<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as KeywordRepoError {
            switch error {
            case .notFound(let path):
                throw GatherError.invalidParameter(field: "path", reason: "not found: \(path)")
            case .hasMembers(let path, let count):
                throw GatherError.invalidParameter(
                    field: "path", reason: "still has \(count) members: \(path)")
            case .hasChildren(let path, let count):
                throw GatherError.invalidParameter(
                    field: "path", reason: "still has \(count) children: \(path)")
            case .notLeaf(let path):
                throw GatherError.invalidParameter(
                    field: "path", reason: "merge requires a leaf keyword: \(path)")
            }
        }
    }
}
