// desktop/native/gather-core/Sources/GatherApplication/Services/Keyword/KeywordThesaurus.swift
// P1 下一波 §3.6.5：同义词只在**检索期**展开，绝不写盘。
//
// 端口形态（与 plan §2.2 的差异，已记录）：plan 表里写"生产实现 KeywordRepo"，但
// KeywordRepo 在 GatherPersistence、协议在这里（Application），Persistence 不能反
// 依赖 Application。因此：协议留在 Application，生产实现是包着 repo 的
// RepositoryKeywordThesaurus（同一个 target 里构造，组合根只多一行）。
import Foundation
import GatherPersistence
import GatherProtocol

public protocol KeywordThesaurus: Sendable {
    /// 该关键词路径的直接同义词（不递归、不含自身）。
    func synonyms(for path: KeywordPath) throws -> [String]

    /// 检索期展开：term 本身 + 它作为关键词的同义词 + 它是某个关键词的同义词
    /// 时所归属的关键词路径（一跳，不递归）。fold 去重、保序、不改写输入。
    ///
    /// 只在 keyword_thesaurus_search == 1 时由调用方使用；写盘路径**不得**调用它
    /// （否则同义词会被当成真关键词写进 XMP）。
    func expand(_ term: String) throws -> [String]
}

public struct RepositoryKeywordThesaurus: KeywordThesaurus, Sendable {
    /// @unchecked Sendable：KeywordRepo 只有不可变的 connection 引用，
    /// 可变状态由 DBConnection 的连接锁串行（与其它 Repo/Domain 服务同一约定）。
    private let repo: KeywordRepo

    public init(repo: KeywordRepo) {
        self.repo = repo
    }

    public init(connection: DBConnection) {
        self.repo = KeywordRepo(connection: connection)
    }

    public func synonyms(for path: KeywordPath) throws -> [String] {
        try repo.synonyms(path: path.serialized)
    }

    public func expand(_ term: String) throws -> [String] {
        guard let normalized = KeywordNormalizer.normalize(term) else {
            // 非法输入（空/控制字符）：原样返回，不编造展开结果。
            return term.isEmpty ? [] : [term]
        }
        var seen = Set<String>()
        var result: [String] = []
        func append(_ value: String) {
            guard let trimmed = KeywordNormalizer.normalize(value) else { return }
            let key = KeywordNormalizer.fold(trimmed)
            guard seen.insert(key).inserted else { return }
            result.append(trimmed)
        }
        append(normalized)
        // 1) term 本身是一个关键词路径：带上它的同义词。
        if let path = KeywordPath.parse(normalized) {
            for synonym in try repo.synonyms(path: path.serialized) { append(synonym) }
        }
        // 2) 反查：term 是某关键词的同义词 → 带上那个关键词（以及它的兄弟同义词）。
        let needle = KeywordNormalizer.fold(normalized)
        var owners: [String] = []
        for entry in try repo.allSynonyms()
        where KeywordNormalizer.fold(entry.synonym) == needle {
            if !owners.contains(entry.keywordPath) { owners.append(entry.keywordPath) }
        }
        for owner in owners {
            append(owner)
            for synonym in try repo.synonyms(path: owner) { append(synonym) }
        }
        return result
    }
}
