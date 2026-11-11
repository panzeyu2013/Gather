// desktop/native/gather-core/Sources/GatherApplication/Services/Keyword/KeywordLibraryService.swift
// Wave2 task-13：关键词库（受控词表）应用服务 —— 协议方法与持久化之间的唯一编排层。
//
// 职责边界：
// - 读：keywords 全量/前缀 + keyword_synonyms → KeywordLibraryNode（树/补全共用）；
// - 写：改名/合并/删除/同义词/新建全部委托 KeywordRepo 的**单事务**实现
//   （photo_keywords、keyword_synonyms、keywords 的一致性由仓储保证；本层不
//   自行拼多步 SQL，避免失败半途）；
// - 错误：仓储的业务错误（不存在/有成员/有子级/有同义词/目标已存在）统一映射
//   成 GatherError(.METADATA_KEYWORDS_INVALID)，params 携带 field/reason；
//   UI 只按码表兜底，不解析仓储类型；
// - 不写 XMP：词库改名/合并只改索引与照片索引，不重写盘上文件；下次显式写回
//   （关键词面板/模板）才把规范路径写进 dc:subject + lr:hierarchicalSubject。
import Foundation
import GatherProtocol
import GatherPersistence

public struct KeywordLibraryService: Sendable {
    private let store: KeywordRepo

    public init(store: KeywordRepo) {
        self.store = store
    }

    // MARK: - 读

    /// 词库树（含同义词）；prefix 非空时只返回路径/叶子以前缀开头的节点。
    ///
    /// 结果按 path 升序（UI DisclosureGroup 逐层筛子级，顺序稳定才能避免每次
    /// 刷新树节点跳动）。
    public func library(_ query: KeywordLibraryQuery) throws -> [KeywordLibraryNode] {
        let synonyms = try store.allSynonyms()
        let rows: [KeywordRow]
        if let prefix = query.prefix {
            rows = try store.prefixMatches(prefix, limit: query.limit)
        } else {
            rows = try store.all()
        }
        let nodes = rows.map { row in
            KeywordLibraryNode(
                path: row.path,
                name: row.name,
                parentPath: row.parentPath,
                usageCount: row.usageCount,
                synonyms: synonyms[row.path] ?? [])
        }
        return nodes.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }.prefix(query.limit).map { $0 }
    }

    /// 自动补全：词库路径前缀 + 同义词前缀 → 规范路径（同义词只做命中入口）。
    public func suggestions(_ query: KeywordSuggestionQuery) throws -> [KeywordSuggestion] {
        let prefixRows = try store.prefixMatches(query.prefix, limit: max(query.limit * 3, 24))
        let synonyms = try store.allSynonyms()
        let nodes = prefixRows.map { row in
            KeywordLibraryNode(
                path: row.path,
                name: row.name,
                parentPath: row.parentPath,
                usageCount: row.usageCount,
                synonyms: synonyms[row.path] ?? [])
        }
        let synonymMatches = try store.synonymMatches(query.prefix, limit: max(query.limit * 2, 16))
        return KeywordSuggestionBuilder.merge(
            prefix: query.prefix, limit: query.limit,
            nodes: nodes, synonymMatches: synonymMatches)
    }

    // MARK: - 写（全部破坏性，协议层由 Confirmed<T> 收口）

    public func rename(_ input: KeywordRenameInput) throws -> KeywordMutationSummary {
        let from = try KeywordLibraryValidator.parsePath(input.from, field: "from")
        let to = try KeywordLibraryValidator.parsePath(input.to, field: "to")
        try KeywordLibraryValidator.requireDistinctRename(from: from, to: to)
        let result: KeywordMutationResult = try mapRepoError {
            try store.rename(from: from, to: to)
        }
        return summary(from: result)
    }

    public func merge(_ input: KeywordMergeInput) throws -> KeywordMutationSummary {
        let source = try KeywordLibraryValidator.parsePath(input.source, field: "source")
        let target = try KeywordLibraryValidator.parsePath(input.target, field: "target")
        try KeywordLibraryValidator.requireDistinctMerge(source: source, target: target)
        let result: KeywordMutationResult = try mapRepoError {
            try store.merge(from: source, into: target)
        }
        return summary(from: result)
    }

    public func delete(_ input: KeywordDeleteInput) throws -> KeywordMutationSummary {
        let path = try KeywordLibraryValidator.parsePath(input.path)
        let result: KeywordMutationResult = try mapRepoError {
            try store.delete(path: path, cascade: input.cascade)
        }
        return summary(from: result)
    }

    public func setSynonyms(_ input: KeywordSynonymsInput) throws -> KeywordMutationSummary {
        let path = try KeywordLibraryValidator.parsePath(input.path)
        let synonyms = KeywordLibraryValidator.normalizeSynonyms(input.synonyms)
        let count = try mapRepoError {
            try store.setSynonyms(path: path, synonyms: synonyms)
        }
        return KeywordMutationSummary(nodes: 0, members: 0, synonyms: count)
    }

    public func create(_ input: KeywordCreateInput) throws -> KeywordMutationSummary {
        let path = try KeywordLibraryValidator.parsePath(input.path)
        let inserted = try mapRepoError {
            try store.ensure(paths: [path])
        }
        return KeywordMutationSummary(nodes: inserted, members: 0, synonyms: 0)
    }

    // MARK: - 结果与错误映射

    /// Persistence 的 KeywordMutationResult → Protocol 的 KeywordMutationSummary。
    /// 两个类型字段一致但分属协议层/持久层；显式逐字段转换，避免隐式跨层类型。
    private func summary(from result: KeywordMutationResult) -> KeywordMutationSummary {
        KeywordMutationSummary(
            nodes: result.nodes, members: result.members, synonyms: result.synonyms)
    }

    private func mapRepoError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as KeywordRepoError {
            throw GatherError.invalidParameter(
                code: .METADATA_KEYWORDS_INVALID,
                field: "path",
                reason: Self.reason(for: error))
        }
    }

    static func reason(for error: KeywordRepoError) -> String {
        switch error {
        case .notFound(let path):
            return "关键词不存在：\(path)"
        case .hasMembers(let path, let count):
            return "关键词 \(path) 仍被 \(count) 张照片使用，不能删除"
        case .hasChildren(let path, let count):
            return "关键词 \(path) 仍有 \(count) 个子级，不能删除"
        case .notLeaf(let path):
            return "只能合并叶子关键词：\(path)"
        case .targetExists(let path):
            return "目标关键词已存在：\(path)"
        case .hasSynonyms(let path, let count):
            return "关键词 \(path) 仍有 \(count) 个同义词，请先清空同义词再删除"
        }
    }
}
