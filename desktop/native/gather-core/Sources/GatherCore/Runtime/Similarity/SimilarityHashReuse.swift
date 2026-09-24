// desktop/native/gather-core/Sources/GatherCore/Runtime/Similarity/SimilarityHashReuse.swift
// W2c 步骤 1：hash 复用计划（纯函数）。
//
// 来源：Services/SimilarityService.swift 427-503 行 reuseSimilarityHashes 的纯逻辑
// 下沉（SQL 读取与事务写入留在 Store / Runtime）：
// - 按 asset_file_id 分块批量读（chunkSize = 400，性能口径 1 + ceil(资产数/400)）；
// - 目标照片与来源照片共享资产文件且 size 相等、|mtime 差| < 1ms 时，复用来源
//   hash；候选排除目标自身，多候选取 rowid 最大者（最新行胜出）；
// - 落库值用目标的 sourceStat（不是候选行自身的 size/mtime），哈希用来源
//   hash_hex —— 与旧实现 494-497 行逐字一致。
//
// 设计 §1.1 语义修正 ③：旧实现的 TOCTOU（读候选与写回分处两个 await 窗口、
// 且 database 作为静态参数传入）由「纯 plan + Store 单事务写入」结构性消除 ——
// plan 在 Runtime actor 的同步临界区内基于已预读快照计算，写入一次事务落库。
//
// 类型归属：候选行 SimilarityHashCandidate 与 UPSERT 行 SimilarityHashUpsert 由
// Store/SimilarityStore.swift（W2c Store 扩展，同批落地）声明，本文件直接引用，
// 不重名声明。
//
// 边界：无 IO、无 SQL、无 Store 依赖；输入全为参数（投影 / 统计 / 候选行）。

import Foundation

/// 索引扫描/stat 得到的文件统计（reuse 的 size/mtime 匹配与落库值）。
public struct SimilaritySourceStat: Equatable, Sendable {
    public let size: Int
    public let mtimeMs: Double

    public init(size: Int, mtimeMs: Double) {
        self.size = size
        self.mtimeMs = mtimeMs
    }
}

/// reuse plan：待写入行（Store.upsertHashes 的入参）+ 复用计数 + 合并后的 hash
/// 映射（existing + reused，供后续聚类条目构建）。
public struct SimilarityHashReusePlan: Equatable, Sendable {
    public let reusedCount: Int
    public let writes: [SimilarityHashUpsert]
    public let hashes: [String: String]

    public init(reusedCount: Int, writes: [SimilarityHashUpsert], hashes: [String: String]) {
        self.reusedCount = reusedCount
        self.writes = writes
        self.hashes = hashes
    }
}

/// TS: reuseSimilarityHashes 的纯函数面（Store 读取/写入由 Runtime 编排）。
public enum SimilarityHashReuse {
    /// TS: REUSE_HASH_CHUNK_SIZE（Store.hashCandidates 的内部块大小同一口径）。
    public static let chunkSize = 400

    /// 资产文件 id 分块（每块 = 一次 IN 查询）。往返口径：
    /// 0 个资产 → 0 块；n 个资产 → ceil(n / 400) 块。
    public static func chunks(_ assetFileIds: [String]) -> [[String]] {
        stride(from: 0, to: assetFileIds.count, by: chunkSize).map { start in
            Array(assetFileIds[start..<min(start + chunkSize, assetFileIds.count)])
        }
    }

    /// 目标照片涉及的资产文件 id（按 photos 顺序去重）—— 供 Runtime 经
    /// PhotoStore.assetFileIdsByPhoto 取得映射后批量读候选（旧实现按 photos 全表
    /// 查询顺序收集；传入未折叠的同一投影即逐字等价）。
    public static func assetFileIds(
        photos: [PhotoProjection],
        assetFileByPhoto: [String: String]
    ) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for photo in photos {
            guard let assetFileId = assetFileByPhoto[photo.id] else { continue }
            if seen.insert(assetFileId).inserted {
                ids.append(assetFileId)
            }
        }
        return ids
    }

    /// TS: reuseSimilarityHashes 主体 —— 对每张尚无 hash 的目标照片，在共享同一
    /// 资产文件的候选中选 rowid 最大且 size 相等、|mtime 差| < 1 的来源，写入
    /// 目标统计值 + 来源 hash；已有 hash（existingHashMap）的目标保持不动。
    /// writes 顺序 = photos 顺序（确定性，Runtime 单事务按序 upsert）。
    public static func plan(
        photos: [PhotoProjection],
        sourceStats: [String: SimilaritySourceStat],
        existingHashMap: [String: String],
        assetFileByPhoto: [String: String],
        candidates: [SimilarityHashCandidate]
    ) -> SimilarityHashReusePlan {
        var candidatesByAssetFile: [String: [SimilarityHashCandidate]] = [:]
        for candidate in candidates {
            candidatesByAssetFile[candidate.assetFileId, default: []].append(candidate)
        }

        var hashes = existingHashMap
        var writes: [SimilarityHashUpsert] = []
        for photo in photos {
            if hashes[photo.id] != nil { continue }
            guard let sourceStat = sourceStats[photo.id],
                  let assetFileId = assetFileByPhoto[photo.id],
                  let fileCandidates = candidatesByAssetFile[assetFileId] else { continue }
            var source: SimilarityHashCandidate?
            for candidate in fileCandidates {
                if candidate.photoId == photo.id { continue }
                if candidate.fileSize != sourceStat.size { continue }
                if abs(candidate.fileMtimeMs - sourceStat.mtimeMs) >= 1 { continue }
                if source == nil || candidate.id > source!.id { source = candidate }
            }
            guard let source else { continue }
            writes.append(SimilarityHashUpsert(
                photoId: photo.id,
                hashHex: source.hashHex,
                fileSize: sourceStat.size,
                fileMtimeMs: sourceStat.mtimeMs
            ))
            hashes[photo.id] = source.hashHex
        }
        return SimilarityHashReusePlan(reusedCount: writes.count, writes: writes, hashes: hashes)
    }
}
