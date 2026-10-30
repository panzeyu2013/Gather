// desktop/native/gather-core/Sources/GatherApplication/Services/Keyword/KeywordIndexSync.swift
// P1 下一波 §3.6.4：photo_keywords 的增量同步与回填。
//
// 触发点（由各流程显式调用，本类型不订阅事件）：
// - 索引/扫描完成 → syncFromCache(photoId:)；
// - 写回成功 → sync(photoId:keywords:source:)（盘上值是权威）；
// - 校样导入 → sync(photoId:keywords:source: .manual)；
// - 新库首次启动/首次索引 → backfillStep 分批回填（每 5k 行一批，后台 job，可断点）。
//
// 口径：photo_keywords 按 photo_id；facet 计数必须按逻辑资产去重（FacetQuery 负责），
// 所以这里**只**维护行，不做任何去重假设。
import Foundation
import GatherPersistence
import GatherProtocol

/// photo_keywords.source 的合法取值（与 DDL 的 CHECK 一一对应）。
public enum KeywordIndexSource: String, CaseIterable, Sendable {
    case xmp
    case culling
    /// face-keyword：人脸自动打词（DDL 里的连字符拼写）。
    case faceKeyword = "face-keyword"
    case similarity
    case manual
}

public struct KeywordSyncSummary: Equatable, Sendable {
    public let inserted: [String]
    public let removed: [String]

    public init(inserted: [String], removed: [String]) {
        self.inserted = inserted
        self.removed = removed
    }

    public var isEmpty: Bool { inserted.isEmpty && removed.isEmpty }
    public static let empty = KeywordSyncSummary(inserted: [], removed: [])
}

/// 回填的一步结果（可断点：nextCursor 传回 backfillStep 即继续）。
public struct KeywordBackfillStep: Equatable, Sendable {
    public let scanned: Int
    public let indexed: Int
    public let nextCursor: String?
    public let isDone: Bool

    public init(scanned: Int, indexed: Int, nextCursor: String?, isDone: Bool) {
        self.scanned = scanned
        self.indexed = indexed
        self.nextCursor = nextCursor
        self.isDone = isDone
    }
}

public final class KeywordIndexSync: Sendable {
    /// @unchecked Sendable：可变状态全在 DB 连接锁里（同其它 Repo/Domain 服务）。
    private let repo: KeywordRepo
    private let cacheRepo: MetadataCacheRepo

    public init(repo: KeywordRepo, cacheRepo: MetadataCacheRepo) {
        self.repo = repo
        self.cacheRepo = cacheRepo
    }

    public init(connection: DBConnection) {
        self.repo = KeywordRepo(connection: connection)
        self.cacheRepo = MetadataCacheRepo(connection: connection)
    }

    // MARK: - 单张同步

    /// 用盘上/调用方给的关键词覆盖该照片的索引（单事务 diff）。
    ///
    /// - 路径先过 KeywordPath（NFC/trim/丢空段/去重），与写盘编码同一套；
    /// - 先把路径补进 keywords 表：facet 的 usage_count 排序需要行存在；
    ///   A3：ensure 现在会连同每一级祖先一起物化（"A|B" 也建 A），这样
    ///   children(parentPath:)/rename 能在 keywords 上找到完整路径链 —— 原实现只插
    ///   叶子，keywords 与 photo_keywords 的路径集合永久不一致。
    /// - 返回增删集合（调用方可据此提示"新增 3 个词"）。
    @discardableResult
    public func sync(
        photoId: String,
        keywords: [String],
        source: KeywordIndexSource = .xmp
    ) throws -> KeywordSyncSummary {
        let paths = KeywordCodec.parse(keywords)
        if !paths.isEmpty { _ = try repo.ensure(paths: paths) }
        let result = try repo.replacePhotoKeywords(
            photoId: photoId, paths: paths, source: source.rawValue)
        return KeywordSyncSummary(inserted: result.inserted, removed: result.removed)
    }

    /// 从 photo_metadata_cache.keywords（JSON）同步——索引/扫描完成后的默认入口。
    @discardableResult
    public func syncFromCache(photoId: String) throws -> KeywordSyncSummary {
        guard let row = try cacheRepo.get(photoId) else {
            // 缓存行不存在 = 该照片还没解析出元数据：清空索引比留着陈旧词更安全。
            return try remove(photoId: photoId)
        }
        return try sync(photoId: photoId, keywords: row.keywords, source: .xmp)
    }

    /// 照片被移除/清空关键词时同步清索引（photos 的 CASCADE 也会兜住删除，
    /// 但"清空关键词"不删照片行，必须显式清）。
    @discardableResult
    public func remove(photoId: String) throws -> KeywordSyncSummary {
        let current = try repo.photoKeywordPaths(photoId: photoId)
        guard !current.isEmpty else { return .empty }
        let deleted = try repo.deletePhotoKeywords(photoId: photoId)
        _ = deleted
        return KeywordSyncSummary(inserted: [], removed: current.sorted())
    }

    // MARK: - 回填（photo_metadata_cache → photo_keywords）

    /// 回填一步：按 photo_id 升序处理一批（默认 5k），返回下一个游标。
    ///
    /// 幂等：只处理 photo_keywords 里还没有行的照片；重复调用/中断重跑都安全。
    @discardableResult
    public func backfillStep(
        after photoId: String? = nil,
        batchSize: Int = 5_000
    ) throws -> KeywordBackfillStep {
        let size = max(1, min(20_000, batchSize))
        let batch = try repo.pendingBackfillBatch(after: photoId, limit: size)
        guard !batch.isEmpty else {
            return KeywordBackfillStep(
                scanned: 0, indexed: 0, nextCursor: photoId, isDone: true)
        }
        var indexed = 0
        for row in batch {
            // try Task.checkCancellation 由调用方（后台 job）在批间做；这里逐张事务。
            let summary = try sync(
                photoId: row.photoId,
                keywords: Self.parseKeywords(row.keywordsJSON),
                source: .xmp)
            if !summary.isEmpty { indexed += 1 }
        }
        let nextCursor = batch.last?.photoId
        return KeywordBackfillStep(
            scanned: batch.count,
            indexed: indexed,
            nextCursor: nextCursor,
            isDone: batch.count < size)
    }

    /// 关键词 JSON（["A|B", ...]）解析；坏数据按空列表处理（不抛错打断回填）。
    static func parseKeywords(_ json: String) -> [String] {
        do {
            guard case .array(let items) = try JSONValue.parse(json) else { return [] }
            return items.compactMap { item in
                if let text = item.stringValue { return text }
                if let number = item.numberValue { return String(number) }
                return nil
            }
        } catch {
            return []
        }
    }
}
