// desktop/native/gather-core/Sources/GatherCore/Runtime/Duplicate/DuplicateScanPipeline.swift
// W2c：DuplicateRuntime 纯函数层（扫描管线的复用/候选/聚类输入计算）。
//
// 来源与边界（Services/DuplicateService.swift:198-457 的纯逻辑下沉）：
// - checksumReuse / sizeGroups / checksumCandidates / visualHashReuse /
//   excludeExactDuplicateHashes / visualClusteringEntries / visualComponents /
//   computeVisualHashes 逐字对齐旧实现；stat / sha256 / 落库 / 分组重建等 IO
//   留在 Runtime + Store（本文件无 SQL、无数据库类型、不调用任何 Store 方法）。
// - 并发常量与旧实现逐位对齐（stat 32 / sha256 2 / 视觉 hash 8；阈值默认 4、
//   聚类 minGroupSize=2 mode=global、缩略图 256）。
//
// 语义注记（设计 docs/ARCHITECTURE-W2C-DESIGN.md §2.2）：
// - sizeGroups/checksumCandidates 按 size 升序迭代（旧实现遍历 Dictionary 的
//   顺序不确定）；只影响并发调度顺序，最终分组结果与旧语义逐字一致（§2.2 ⑧）。
// - computeVisualHashes 按 §2.2 ② 把旧的 \`try?\` 静默降级改为显式
//   \`(hashes, failures)\`：provider 返回 nil（corrupt 图片）进入 failures，
//   仍不参与视觉聚类（行为不变，仅提高可观测性）。
// - batchMap 用 actor 游标（无锁、无可检查逃逸的并发断言）：滑动窗口调度、
//   结果按输入索引保序、首个失败停止调度并传播，与旧 batchAsync 语义一致。

import Foundation

/// TS: clusterHashesInWorker 注入缝（Runtime 可替换 fake；本文件只定义类型）。
public typealias DuplicateClusterProvider = ([HashEntry], Int, Int, HashGroupingMode, ((Int, Int) -> Void)?) throws -> ClusterResult

public enum DuplicateScanPipeline {
    // MARK: - 并发常量（旧 DuplicateService._scanDuplicates 逐字对齐）

    /// TS: batchAsync(photos, 32) —— stat 阶段并发窗口。
    public static let statConcurrency = 32
    /// TS: batchAsync(candidates, 2) —— sha256 阶段并发窗口。
    public static let checksumConcurrency = 2
    /// TS: computeVisualHashes 并发 8。
    public static let visualHashConcurrency = 8
    /// TS: visualThreshold ?? 4。
    public static let defaultVisualThreshold = 4
    /// TS: clusterHashesInWorker(..., minGroupSize=2, mode='global')。
    public static let minVisualGroupSize = 2
    /// TS: imageService.getThumbnail(filepath, 256)。
    public static let thumbnailSize = 256

    // MARK: - 值类型

    /// TS: fs.stat 结果（_scanDuplicates stat 阶段）。
    public struct FileStat: Equatable, Sendable {
        public let size: Int64
        public let mtimeMs: Double
        public let mtimeISO: String

        public init(size: Int64, mtimeMs: Double, mtimeISO: String) {
            self.size = size
            self.mtimeMs = mtimeMs
            self.mtimeISO = mtimeISO
        }
    }

    /// sha256 候选照片（size 组 ≥2 且 checksum 未复用的照片，按 size 升序）。
    public struct PhotoCandidate: Equatable, Sendable {
        public let id: String
        public let filepath: String

        public init(id: String, filepath: String) {
            self.id = id
            self.filepath = filepath
        }
    }

    /// 视觉 hash 计算结果：成功 hash + provider 返回 nil（corrupt）的照片 id（输入序）。
    public struct VisualHashComputation: Equatable, Sendable {
        public let hashes: [String: String]
        public let failures: [String]

        public init(hashes: [String: String], failures: [String]) {
            self.hashes = hashes
            self.failures = failures
        }
    }

    // MARK: - 阶段 1：stat 聚合

    /// TS:114-130 —— 可读文件的 size 分组（不可读文件跳过）。
    public static func sizeGroups(
        photos: [DuplicatePhotoRecord],
        stats: [String: FileStat]
    ) -> [Int64: [String]] {
        var groups: [Int64: [String]] = [:]
        for photo in photos {
            guard let meta = stats[photo.id] else { continue }
            groups[meta.size, default: []].append(photo.id)
        }
        return groups
    }

    // MARK: - 阶段 2：checksum 复用与候选

    /// TS:132-153 —— 存储的 checksum 与 size/mtime 一致（|Δmtime| < 1ms）则复用。
    public static func checksumReuse(
        photos: [DuplicatePhotoRecord],
        stats: [String: FileStat]
    ) -> [String: String] {
        var resolved: [String: String] = [:]
        for photo in photos {
            guard let meta = stats[photo.id],
                  !photo.checksum.isEmpty,
                  photo.checksumFileSize == meta.size,
                  abs(photo.checksumFileMtimeMs - meta.mtimeMs) < 1 else { continue }
            resolved[photo.id] = photo.checksum
        }
        return resolved
    }

    /// TS:132-153 —— 只有 size 相同的组（≥2 张）里 checksum 未复用的照片才需要
    /// 重新 sha256；按 size 升序保证候选序确定。
    public static func checksumCandidates(
        sizeGroups: [Int64: [String]],
        resolvedChecksums: [String: String],
        photos: [DuplicatePhotoRecord]
    ) -> [PhotoCandidate] {
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var candidates: [PhotoCandidate] = []
        for size in sizeGroups.keys.sorted() {
            guard let photoIds = sizeGroups[size], photoIds.count >= 2 else { continue }
            for photoId in photoIds where resolvedChecksums[photoId] == nil {
                guard let photo = photoById[photoId] else { continue }
                candidates.append(PhotoCandidate(id: photo.id, filepath: photo.filepath))
            }
        }
        return candidates
    }

    // MARK: - 阶段 3：视觉 hash 复用与计算

    /// TS:170-190 —— similarity_hashes 行在 size/mtime 一致时复用，否则该照片进
    /// misses 待重新计算。
    public static func visualHashReuse(
        rows: [DuplicateVisualHashRecord],
        photos: [DuplicatePhotoRecord],
        stats: [String: FileStat]
    ) -> (reused: [String: String], misses: [DuplicatePhotoRecord]) {
        var reused: [String: String] = [:]
        for row in rows {
            guard let meta = stats[row.photoId],
                  meta.size == row.fileSize,
                  abs(meta.mtimeMs - row.fileMtimeMs) < 1 else { continue }
            reused[row.photoId] = row.hashHex
        }
        let misses = photos.filter { reused[$0.id] == nil }
        return (reused, misses)
    }

    /// TS: computeVisualHashes —— 并发 8 计算视觉 hash；corrupt 图片（provider 返回
    /// nil）静默跳过（进入 failures），结果按输入序收集。
    public static func computeVisualHashes(
        photos: [(id: String, filepath: String)],
        thumbnailProvider: @escaping (String, Int) async -> [UInt8]?
    ) async -> VisualHashComputation {
        let computed = (try? await batchMap(photos, concurrency: visualHashConcurrency) { photo -> (String, String)? in
            guard let pixels = await thumbnailProvider(photo.filepath, thumbnailSize) else { return nil }
            return (photo.id, DHash.compute(pixels9x8: pixels))
        }) ?? []
        var hashes: [String: String] = [:]
        var failures: [String] = []
        for (index, entry) in computed.enumerated() {
            if let pair = entry {
                hashes[pair.0] = pair.1
            } else if index < photos.count {
                failures.append(photos[index].id)
            }
        }
        return VisualHashComputation(hashes: hashes, failures: failures)
    }

    // MARK: - 阶段 4：聚类输入与视觉聚类

    /// TS: excludeExactDuplicateHashes —— 从视觉 hash 行里剔除精确重复照片。
    public static func excludeExactDuplicateHashes(
        rows: [DuplicateHashPair],
        exactPhotoIds: Set<String>
    ) -> [DuplicateHashPair] {
        rows.filter { !exactPhotoIds.contains($0.photoId) }
    }

    /// TS:260-274 —— 视觉聚类输入（已剔除精确重复 + photoId → hash 索引）。
    /// 输入顺序即聚类顺序（旧实现来自 SQL ORDER BY sh.photo_id）。
    public static func visualClusteringEntries(
        rows: [DuplicateHashPair],
        exactPhotoIds: Set<String>
    ) -> (entries: [DuplicateHashPair], hashByPhotoId: [String: String]) {
        let entries = excludeExactDuplicateHashes(rows: rows, exactPhotoIds: exactPhotoIds)
        var hashByPhotoId: [String: String] = [:]
        for row in entries { hashByPhotoId[row.photoId] = row.hashHex }
        return (entries, hashByPhotoId)
    }

    /// TS:275-288 —— hash 行 ≥2 才聚类；否则空组件。默认走 ClusterEngine
    /// （threshold 传入、minGroupSize=2、mode='global'）。
    public static func visualComponents(
        entries: [DuplicateHashPair],
        threshold: Int,
        clusterProvider: DuplicateClusterProvider? = nil
    ) throws -> [[String]] {
        guard entries.count >= minVisualGroupSize else { return [] }
        let provider: DuplicateClusterProvider = clusterProvider ?? { hashes, threshold, minGroupSize, mode, onProgress in
            try ClusterEngine.clusterByHash(
                entries: hashes, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        }
        return try provider(
            entries.map { HashEntry(photoId: $0.photoId, hash: $0.hashHex) },
            threshold, minVisualGroupSize, .global, nil
        ).groups
    }
}

// MARK: - 私有并发支撑

/// 共享取号游标（actor：跨任务安全，无可检查逃逸的并发断言）。
private actor PipelineCursor {
    private let count: Int
    private var next = 0
    private var failed = false

    init(count: Int) { self.count = count }

    func nextIndex() -> Int? {
        guard !failed, next < count else { return nil }
        defer { next += 1 }
        return next
    }

    func markFailed() { failed = true }
}

/// TS: batchAsync —— 固定数量常驻 runner 从共享游标取任务（滑动窗口，慢项不
/// 阻塞整批）；结果按输入索引保序；首个失败停止调度、在飞项跑完，错误按完成序
/// 取第一个（与 TS 语义一致）。
private func batchMap<T, R>(
    _ items: [T],
    concurrency: Int,
    body: @escaping (T) async throws -> R
) async throws -> [R] {
    let limit = max(1, concurrency)
    guard !items.isEmpty else { return [] }
    let cursor = PipelineCursor(count: items.count)
    var collected: [(index: Int, value: R)] = []
    try await withThrowingTaskGroup(of: [(Int, R)].self) { group in
        for _ in 0..<min(limit, items.count) {
            group.addTask {
                var local: [(Int, R)] = []
                while !Task.isCancelled, let index = await cursor.nextIndex() {
                    do {
                        local.append((index, try await body(items[index])))
                    } catch {
                        await cursor.markFailed()
                        throw error
                    }
                }
                return local
            }
        }
        for try await chunk in group {
            collected.append(contentsOf: chunk)
        }
    }
    collected.sort { $0.index < $1.index }
    return collected.map(\.value)
}
