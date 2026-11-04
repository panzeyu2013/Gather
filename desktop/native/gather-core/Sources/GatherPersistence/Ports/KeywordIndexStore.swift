// desktop/native/gather-core/Sources/GatherPersistence/Ports/KeywordIndexStore.swift
// 关键词索引的两个窄端口（#8：把 KeywordIndexSync 从具体 Repo 上摘下来）。
//
// 消费者只有一个（KeywordIndexSync）：
// - KeywordIndexStore：写/读 photo_keywords 与回填批次（5 个方法，来自 KeywordRepo）；
// - MetadataKeywordReading：读 photo_metadata_cache 的关键词（1 个方法，来自
//   MetadataCacheRepo）——只暴露「这一列」，避免把 23 列的缓存行类型漏给索引层。
import Foundation
import GatherProtocol

public protocol KeywordIndexStore: Sendable {
    /// 把路径补进 keywords 表（含祖先物化）；返回新增条数。
    @discardableResult
    func ensure(paths: [KeywordPath]) throws -> Int
    /// 用给定路径覆盖该照片的索引；返回增删集合。
    func replacePhotoKeywords(
        photoId: String, paths: [KeywordPath], source: String
    ) throws -> (inserted: [String], removed: [String])
    func photoKeywordPaths(photoId: String) throws -> [String]
    /// 清空该照片的索引并回写 usage_count；返回删除行数。
    @discardableResult
    func deletePhotoKeywords(photoId: String) throws -> Int
    /// 回填批次：photo_keywords 里还没有索引行的照片（按 photo_id 升序）。
    func pendingBackfillBatch(
        after photoId: String?, limit: Int
    ) throws -> [(photoId: String, sessionId: String, keywordsJSON: String)]
}

public protocol MetadataKeywordReading: Sendable {
    /// 缓存行不存在 → nil（索引层据此清空索引）；行存在但无关键词 → 空数组。
    func keywords(photoId: String) throws -> [String]?
}

extension KeywordRepo: KeywordIndexStore {}

extension MetadataCacheRepo: MetadataKeywordReading {
    public func keywords(photoId: String) throws -> [String]? {
        try get(photoId)?.keywords
    }
}
