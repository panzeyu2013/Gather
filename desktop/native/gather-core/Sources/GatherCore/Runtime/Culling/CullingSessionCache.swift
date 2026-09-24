// desktop/native/gather-core/Sources/GatherCore/Runtime/Culling/CullingSessionCache.swift
// W2b（设计 §2.4）：CullingSessionCache —— Runtime/Culling 的唯一长生命周期可变缓存，
// 完全独立（不依赖任何 Store / Service）。
//
// 解决的问题：旧实现 sessionLookupCache / sessionUpdateCache 存的是**可变 class** 条目
// （MainActor 写 + Task.detached 读 → 真实数据竞争）。本 actor + Sendable 值类型条目
// 结构性消除竞争：调用方只能拿到值拷贝，回写必须经 store；缓存内部状态只在 actor
// 执行器上变更。
//
// 约定：
// - 版本键：Lookup 为 (sessionId, indexSeq, similarityResultId)，Update 为
//   (sessionId, indexSeq)。index_seq / 结果 id 变化即自然 miss，因此不再需要旧
//   refreshSessionUpdateContext 的一次性刷新机制。
// - TTL 由本 actor 用可注入 clock 计时；值类型自身不携带 expiresAt。
// - 淘汰：先清过期，再按 expiresAt 最早优先；同刻并列按 key 升序，完全确定性
//   （修复旧实现 keys.first 的任意淘汰）。
// - Lookup / Update 是值类型，字段与旧 SessionLookupEntry / SessionUpdateEntry 对齐；
//   var 字段允许调用方做「读-改-写」懒解析（如 groupMap / analyses），并发安全由
//   actor 串行化 + 值拷贝保证。
// - 本文件禁止 SQL 文本与 SQLiteDatabase（W2b 门禁）。

import Foundation

/// 会话缓存时钟端口：默认 SystemCullingCacheClock（Date()）。测试注入假时钟以
/// 确定性验证 TTL、过期清理与淘汰顺序。
public protocol CullingCacheClock: Sendable {
    func now() -> Date
}

/// 生产时钟。
public struct SystemCullingCacheClock: CullingCacheClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// 会话级 lookup / update 缓存（actor）。容量默认各 8，TTL 默认各 5s。
public actor CullingSessionCache {

    // MARK: - 键

    /// 会话查找缓存版本键：(sessionId, indexSeq, similarityResultId)。
    /// indexSeq 是照片集版本（sessions.index_seq），similarityResultId 是最新相似度
    /// 结果行 id；任一变化即新键，旧条目自然 miss。
    public struct LookupKey: Hashable, Sendable, CustomStringConvertible {
        public let sessionId: String
        public let indexSeq: Int
        public let similarityResultId: Int64?

        public init(sessionId: String, indexSeq: Int, similarityResultId: Int64?) {
            self.sessionId = sessionId
            self.indexSeq = indexSeq
            self.similarityResultId = similarityResultId
        }

        public var description: String {
            let result = similarityResultId.map(String.init) ?? "nil"
            return "LookupKey(\(sessionId), seq=\(indexSeq), result=\(result))"
        }
    }

    /// 会话更新上下文缓存版本键：(sessionId, indexSeq)（index_seq 即照片集版本）。
    public struct UpdateKey: Hashable, Sendable, CustomStringConvertible {
        public let sessionId: String
        public let indexSeq: Int

        public init(sessionId: String, indexSeq: Int) {
            self.sessionId = sessionId
            self.indexSeq = indexSeq
        }

        public var description: String { "UpdateKey(\(sessionId), seq=\(indexSeq))" }
    }

    /// 两个缓存的当前条目数（读取前先清理过期条目，故永不包含陈旧项）。
    public struct EntryCounts: Equatable, Sendable {
        public let lookup: Int
        public let update: Int

        public init(lookup: Int, update: Int) {
            self.lookup = lookup
            self.update = update
        }
    }

    // MARK: - 值类型条目

    /// 会话查找条目（Sendable 值类型）：最新相似度结果 + 相似度成员映射 + 懒解析的
    /// 组索引 / 分析映射 / 组数。调用方读取到的是拷贝，回写用 store(_:for:)。
    public struct Lookup: Sendable {
        /// 最新相似度结果行（版本键的 resultRow；resultId 即其 id）。
        public var resultRow: SimilarityResultRecord?
        /// photo_id → similarity group index 字符串映射（Store.photoGroupMap）。
        public var similarityMap: [String: String]
        /// photo_id → "resultId:groupIndex" 组 id（懒解析，见 groupIndexResolved）。
        public var groupIndex: [String: String]
        /// groupIndex 是否已解析（含「无结果 → 空索引」也算已解析）。
        public var groupIndexResolved: Bool
        /// 质量 / 人脸 / 人物分析映射是否已装载（后台分析完成时由
        /// invalidateAnalyses 复位）。
        public var analysesLoaded: Bool
        public var qualityByPhoto: [String: CullingQuality]
        public var facesByPhoto: [String: [[Double]]]
        public var analysisMaxByPhoto: [String: Double]
        public var peopleByPhoto: [String: [String]]
        /// stats_json.totalGroups 解析结果（懒解析，见 groupCountResolved）。
        public var groupCount: Int
        public var groupCountResolved: Bool

        public init(
            resultRow: SimilarityResultRecord? = nil,
            similarityMap: [String: String] = [:],
            groupIndex: [String: String] = [:],
            groupIndexResolved: Bool = false,
            analysesLoaded: Bool = false,
            qualityByPhoto: [String: CullingQuality] = [:],
            facesByPhoto: [String: [[Double]]] = [:],
            analysisMaxByPhoto: [String: Double] = [:],
            peopleByPhoto: [String: [String]] = [:],
            groupCount: Int = 0,
            groupCountResolved: Bool = false
        ) {
            self.resultRow = resultRow
            self.similarityMap = similarityMap
            self.groupIndex = groupIndex
            self.groupIndexResolved = groupIndexResolved
            self.analysesLoaded = analysesLoaded
            self.qualityByPhoto = qualityByPhoto
            self.facesByPhoto = facesByPhoto
            self.analysisMaxByPhoto = analysisMaxByPhoto
            self.peopleByPhoto = peopleByPhoto
            self.groupCount = groupCount
            self.groupCountResolved = groupCountResolved
        }
    }

    /// 会话更新上下文条目（Sendable 值类型）：照片集 + id 索引 + 懒解析的组索引 /
    /// xmp 联动映射。无 refreshed 标志：index_seq 即版本键，照片集变化由新键体现。
    public struct Update: Sendable {
        public var photos: [CullingPhotoRow]
        public var photoById: [String: CullingPhotoRow]
        /// asset_id → 照片索引（无 asset_id 的照片跳过）。
        public var photosByAssetId: [String: [CullingPhotoRow]]
        /// photo_id → 组 id（懒解析；nil 即未解析）。
        public var groupMap: [String: String]?
        /// groupMap 解析时的相似度结果 id（版本核验用）。
        public var groupMapResultId: Int64?
        /// xmp sidecar path → 关联照片（懒解析；nil 即未解析）。
        public var linkedByXmp: [String: [CullingPhotoRow]]?

        public init(
            photos: [CullingPhotoRow] = [],
            photoById: [String: CullingPhotoRow]? = nil,
            photosByAssetId: [String: [CullingPhotoRow]]? = nil,
            groupMap: [String: String]? = nil,
            groupMapResultId: Int64? = nil,
            linkedByXmp: [String: [CullingPhotoRow]]? = nil
        ) {
            self.photos = photos
            self.photoById = photoById
                ?? Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.photosByAssetId = photosByAssetId ?? Update.buildPhotosByAssetIndex(photos)
            self.groupMap = groupMap
            self.groupMapResultId = groupMapResultId
            self.linkedByXmp = linkedByXmp
        }

        /// 旧 buildPhotosByAssetIndex 语义：只索引非 nil asset_id。
        public static func buildPhotosByAssetIndex(
            _ photos: [CullingPhotoRow]
        ) -> [String: [CullingPhotoRow]] {
            var index: [String: [CullingPhotoRow]] = [:]
            for photo in photos {
                guard let assetId = photo.assetId else { continue }
                index[assetId, default: []].append(photo)
            }
            return index
        }
    }

    // MARK: - 内部存储

    /// 内部条目：值与过期时刻（值类型不携带 expiresAt，TTL 归 actor 管）。
    private struct Entry<Value: Sendable>: Sendable {
        var value: Value
        var expiresAt: Date
    }

    private let clock: any CullingCacheClock
    private let lookupTTL: TimeInterval
    private let lookupCapacity: Int
    private let updateTTL: TimeInterval
    private let updateCapacity: Int

    private var lookupEntries: [LookupKey: Entry<Lookup>] = [:]
    private var updateEntries: [UpdateKey: Entry<Update>] = [:]

    public init(
        clock: any CullingCacheClock = SystemCullingCacheClock(),
        lookupTTL: TimeInterval = 5,
        lookupCapacity: Int = 8,
        updateTTL: TimeInterval = 5,
        updateCapacity: Int = 8
    ) {
        self.clock = clock
        self.lookupTTL = lookupTTL
        self.lookupCapacity = lookupCapacity
        self.updateTTL = updateTTL
        self.updateCapacity = updateCapacity
    }

    // MARK: - Lookup 读写

    /// 命中且未过期时返回值拷贝；过期或缺失返回 nil（顺带清理已过期条目）。
    public func lookup(for key: LookupKey) -> Lookup? {
        let now = clock.now()
        sweepExpired(&lookupEntries, now: now)
        return lookupEntries[key]?.value
    }

    /// 写入 / 覆盖条目并刷新 TTL，然后清理过期条目、按容量确定性淘汰。
    /// 新写入的条目自身绝不被本次淘汰（先腾位再插入）。
    public func store(_ lookup: Lookup, for key: LookupKey) {
        let now = clock.now()
        lookupEntries.removeValue(forKey: key)
        prune(&lookupEntries, downTo: max(0, lookupCapacity) - 1, now: now)
        lookupEntries[key] = Entry(value: lookup, expiresAt: now.addingTimeInterval(lookupTTL))
    }

    // MARK: - Update 读写

    /// 命中且未过期时返回值拷贝；过期或缺失返回 nil。
    public func update(for key: UpdateKey) -> Update? {
        let now = clock.now()
        sweepExpired(&updateEntries, now: now)
        return updateEntries[key]?.value
    }

    /// 写入 / 覆盖条目并刷新 TTL，然后清理过期条目、按容量确定性淘汰。
    public func store(_ update: Update, for key: UpdateKey) {
        let now = clock.now()
        updateEntries.removeValue(forKey: key)
        prune(&updateEntries, downTo: max(0, updateCapacity) - 1, now: now)
        updateEntries[key] = Entry(value: update, expiresAt: now.addingTimeInterval(updateTTL))
    }

    // MARK: - 失效

    /// 会话级完全失效：丢弃该会话的 lookup 与 update 全部版本条目。
    /// 用于会话删除 / 照片集重建等「一切已知状态不可信」的场合。
    public func invalidate(sessionId: String) {
        lookupEntries = lookupEntries.filter { $0.key.sessionId != sessionId }
        updateEntries = updateEntries.filter { $0.key.sessionId != sessionId }
    }

    /// 只失效分析派生的映射（质量 / 人脸 / 人物）：后台分析完成时调用。
    /// 保留版本键、相似度结果与映射，仅把分析字段复位（analysesLoaded = false），
    /// 下一次读取按需重载；update 条目不含分析，不受影响。
    public func invalidateAnalyses(sessionId: String) {
        for (key, entry) in lookupEntries where key.sessionId == sessionId {
            var value = entry.value
            value.analysesLoaded = false
            value.qualityByPhoto = [:]
            value.facesByPhoto = [:]
            value.analysisMaxByPhoto = [:]
            value.peopleByPhoto = [:]
            lookupEntries[key] = Entry(value: value, expiresAt: entry.expiresAt)
        }
    }

    /// 清空两个缓存（会话切换 / 测试）。
    public func removeAll() {
        lookupEntries.removeAll()
        updateEntries.removeAll()
    }

    /// 当前条目数（先清理过期条目）。供测试与诊断；并发 hammer 用它断言容量上限。
    public var entryCounts: EntryCounts {
        let now = clock.now()
        sweepExpired(&lookupEntries, now: now)
        sweepExpired(&updateEntries, now: now)
        return EntryCounts(lookup: lookupEntries.count, update: updateEntries.count)
    }

    // MARK: - 淘汰（先清过期，再按 expiresAt 最早优先；同刻并列按 key 升序）

    private func sweepExpired<Key: Hashable, Value: Sendable>(
        _ entries: inout [Key: Entry<Value>],
        now: Date
    ) {
        if entries.isEmpty { return }
        entries = entries.filter { $0.value.expiresAt > now }
    }

    /// 清过期后把条目数压到 limit 以内：按 expiresAt 升序淘汰，同刻按 key 升序，
    /// 保证确定性（旧实现 keys.first 的淘汰顺序不确定）。
    private func prune<Key: Hashable & Comparable, Value: Sendable>(
        _ entries: inout [Key: Entry<Value>],
        downTo limit: Int,
        now: Date
    ) {
        sweepExpired(&entries, now: now)
        let target = max(0, limit)
        guard entries.count > target else { return }
        let ordered = entries.sorted { lhs, rhs in
            if lhs.value.expiresAt != rhs.value.expiresAt {
                return lhs.value.expiresAt < rhs.value.expiresAt
            }
            return lhs.key < rhs.key
        }
        for entry in ordered.prefix(entries.count - target) {
            entries.removeValue(forKey: entry.key)
        }
    }
}

// MARK: - 确定性排序（同刻并列时的稳定次序）

extension CullingSessionCache.LookupKey: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
        if lhs.indexSeq != rhs.indexSeq { return lhs.indexSeq < rhs.indexSeq }
        return (lhs.similarityResultId ?? .min) < (rhs.similarityResultId ?? .min)
    }
}

extension CullingSessionCache.UpdateKey: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
        return lhs.indexSeq < rhs.indexSeq
    }
}
