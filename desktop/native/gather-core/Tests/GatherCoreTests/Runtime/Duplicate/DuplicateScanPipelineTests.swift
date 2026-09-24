// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Duplicate/DuplicateScanPipelineTests.swift
// W2c：DuplicateScanPipeline 纯函数测试（无数据库、无 Store 方法）。
//
// 语义对照旧 Services/DuplicateServiceTests.swift:174-231（TS 对账）：
// excludeExactDuplicateHashesFiltersExactIds / computeVisualHashesSamePixelsSameHash /
// computeVisualHashesSkipsCorruptPhotos，另补齐 checksum/视觉 hash 复用、候选、
// 聚类输入与并发常量（旧实现散落在 _scanDuplicates 内、无独立测试）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 夹具（不触碰数据库）

private func makePhoto(
    id: String,
    filepath: String? = nil,
    checksum: String = "",
    checksumFileSize: Int64 = 0,
    checksumFileMtimeMs: Double = 0
) -> DuplicatePhotoRecord {
    DuplicatePhotoRecord(
        id: id,
        filepath: filepath ?? "/photos/\(id).jpg",
        checksum: checksum,
        checksumFileSize: checksumFileSize,
        checksumFileMtimeMs: checksumFileMtimeMs
    )
}

private func makeStat(_ size: Int64, _ mtimeMs: Double) -> DuplicateScanPipeline.FileStat {
    DuplicateScanPipeline.FileStat(
        size: size,
        mtimeMs: mtimeMs,
        mtimeISO: isoString(Date(timeIntervalSince1970: mtimeMs / 1000))
    )
}

/// 9x8 均匀灰度像素网格（DHash 输出 64 个 0）。
private let pipelineUniformPixels = [UInt8](repeating: 128, count: 72)

/// provider 调用计数（线程安全）。
private final class PipelineCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("DuplicateScanPipeline 纯函数（W2c）")
struct DuplicateScanPipelineTests {
    // MARK: 常量

    @Test("并发常量与旧服务逐位对齐")
    func constantsMatchLegacyService() {
        #expect(DuplicateScanPipeline.statConcurrency == 32)
        #expect(DuplicateScanPipeline.checksumConcurrency == 2)
        #expect(DuplicateScanPipeline.visualHashConcurrency == 8)
        #expect(DuplicateScanPipeline.defaultVisualThreshold == 4)
        #expect(DuplicateScanPipeline.minVisualGroupSize == 2)
        #expect(DuplicateScanPipeline.thumbnailSize == 256)
    }

    // MARK: checksum 复用 / 候选

    @Test("checksum 复用要求非空且 size/mtime 一致（|Δmtime| < 1ms）")
    func checksumReuseRequiresFingerprintMatch() {
        let photos = [
            makePhoto(id: "exact", checksum: "sum-a", checksumFileSize: 100, checksumFileMtimeMs: 1000),
            makePhoto(id: "tolerant", checksum: "sum-b", checksumFileSize: 100, checksumFileMtimeMs: 1000.5),
            makePhoto(id: "empty", checksum: "", checksumFileSize: 100, checksumFileMtimeMs: 1000),
            makePhoto(id: "size", checksum: "sum-c", checksumFileSize: 99, checksumFileMtimeMs: 1000),
            makePhoto(id: "mtime", checksum: "sum-d", checksumFileSize: 100, checksumFileMtimeMs: 1001),
            makePhoto(id: "unreadable", checksum: "sum-e", checksumFileSize: 100, checksumFileMtimeMs: 1000),
        ]
        let stats: [String: DuplicateScanPipeline.FileStat] = [
            "exact": makeStat(100, 1000),
            "tolerant": makeStat(100, 1000),
            "empty": makeStat(100, 1000),
            "size": makeStat(100, 1000),
            // |1001 - 1000| == 1，不满足 < 1。
            "mtime": makeStat(100, 1000),
        ]

        let resolved = DuplicateScanPipeline.checksumReuse(photos: photos, stats: stats)

        #expect(resolved == ["exact": "sum-a", "tolerant": "sum-b"])
    }

    @Test("checksum 候选只取 size 相同组（≥2）且未复用者，按 size 升序")
    func checksumCandidatesFilterGroups() {
        let photos = [
            makePhoto(id: "pair-a", checksum: "", checksumFileSize: 0, checksumFileMtimeMs: 0),
            makePhoto(id: "pair-b", checksum: "", checksumFileSize: 0, checksumFileMtimeMs: 0),
            makePhoto(id: "solo", checksum: "", checksumFileSize: 0, checksumFileMtimeMs: 0),
            makePhoto(id: "reused", checksum: "sum", checksumFileSize: 200, checksumFileMtimeMs: 500),
            makePhoto(id: "unreadable", checksum: "", checksumFileSize: 0, checksumFileMtimeMs: 0),
        ]
        let stats: [String: DuplicateScanPipeline.FileStat] = [
            "pair-a": makeStat(200, 500),
            "pair-b": makeStat(200, 500),
            "solo": makeStat(300, 500),
            "reused": makeStat(200, 500),
        ]

        let groups = DuplicateScanPipeline.sizeGroups(photos: photos, stats: stats)
        #expect(groups[200] == ["pair-a", "pair-b", "reused"])
        #expect(groups[300] == ["solo"])
        #expect(groups[999] == nil)

        let resolved = DuplicateScanPipeline.checksumReuse(photos: photos, stats: stats)
        #expect(resolved == ["reused": "sum"])

        let candidates = DuplicateScanPipeline.checksumCandidates(
            sizeGroups: groups, resolvedChecksums: resolved, photos: photos
        )
        #expect(candidates.map(\.id) == ["pair-a", "pair-b"])
        #expect(candidates.map(\.filepath) == ["/photos/pair-a.jpg", "/photos/pair-b.jpg"])
    }

    // MARK: 视觉 hash 复用 / 计算

    @Test("视觉 hash 复用要求 size/mtime 一致，misses 为其余照片")
    func visualHashReuseMatchesFingerprint() {
        let photos = [
            makePhoto(id: "reuse"),
            makePhoto(id: "stale"),
            makePhoto(id: "missing"),
        ]
        let stats: [String: DuplicateScanPipeline.FileStat] = [
            "reuse": makeStat(100, 1000),
            "stale": makeStat(100, 1000),
            "missing": makeStat(100, 1000),
        ]
        let rows = [
            DuplicateVisualHashRecord(photoId: "reuse", hashHex: "abcd", fileSize: 100, fileMtimeMs: 1000),
            DuplicateVisualHashRecord(photoId: "stale", hashHex: "dead", fileSize: 100, fileMtimeMs: 2000),
            // 不在会话/无 stat 的行不得进入复用表。
            DuplicateVisualHashRecord(photoId: "unknown", hashHex: "ffff", fileSize: 100, fileMtimeMs: 1000),
        ]

        let result = DuplicateScanPipeline.visualHashReuse(rows: rows, photos: photos, stats: stats)

        #expect(result.reused == ["reuse": "abcd"])
        #expect(result.misses.map(\.id) == ["stale", "missing"])
    }

    @Test("computeVisualHashes：相同像素得到相同 hash，每张照片恰好调用一次")
    func computeVisualHashesSamePixelsSameHash() async {
        let calls = PipelineCallCounter()
        let result = await DuplicateScanPipeline.computeVisualHashes(
            photos: [
                (id: "first", filepath: "/first.raw"),
                (id: "second", filepath: "/second.raw"),
            ],
            thumbnailProvider: { _, _ in
                calls.increment()
                return pipelineUniformPixels
            }
        )

        #expect(result.failures.isEmpty)
        #expect(result.hashes.count == 2)
        #expect(result.hashes["first"] == result.hashes["second"])
        #expect(result.hashes["first"] == DHash.compute(pixels9x8: pipelineUniformPixels))
        #expect(calls.value == 2)
    }

    @Test("computeVisualHashes：corrupt 图片进入 failures，其余照常计算")
    func computeVisualHashesSkipsCorruptPhotos() async {
        let result = await DuplicateScanPipeline.computeVisualHashes(
            photos: [
                (id: "corrupt", filepath: "/corrupt.raw"),
                (id: "ok", filepath: "/ok.raw"),
            ],
            thumbnailProvider: { filepath, _ in
                filepath == "/corrupt.raw" ? nil : pipelineUniformPixels
            }
        )

        #expect(result.failures == ["corrupt"])
        #expect(result.hashes["corrupt"] == nil)
        #expect(result.hashes["ok"] == DHash.compute(pixels9x8: pipelineUniformPixels))
    }

    // MARK: 聚类输入 / 视觉聚类

    @Test("视觉聚类输入剔除精确重复并建立 photoId → hash 索引")
    func visualClusteringEntriesExcludeExact() {
        let rows = [
            DuplicateHashPair(photoId: "exact-a", hashHex: "0000"),
            DuplicateHashPair(photoId: "exact-b", hashHex: "0000"),
            DuplicateHashPair(photoId: "visual-a", hashHex: "0001"),
            DuplicateHashPair(photoId: "visual-b", hashHex: "0002"),
        ]
        let exactPhotoIds: Set<String> = ["exact-a", "exact-b"]

        let filtered = DuplicateScanPipeline.excludeExactDuplicateHashes(
            rows: rows, exactPhotoIds: exactPhotoIds
        )
        #expect(filtered.map(\.photoId) == ["visual-a", "visual-b"])
        #expect(filtered.map(\.hashHex) == ["0001", "0002"])

        let entries = DuplicateScanPipeline.visualClusteringEntries(
            rows: rows, exactPhotoIds: exactPhotoIds
        )
        #expect(entries.entries.map(\.photoId) == ["visual-a", "visual-b"])
        #expect(entries.hashByPhotoId == ["visual-a": "0001", "visual-b": "0002"])
    }

    @Test("hash 行 <2 不聚类；≥2 时按 threshold/minGroupSize/global 调 provider")
    func visualComponentsGuardsAndDelegates() throws {
        var calls = 0
        var capturedThreshold: Int?
        var capturedMinGroupSize: Int?
        var capturedMode: HashGroupingMode?
        var capturedCount: Int?
        let provider: DuplicateClusterProvider = { entries, threshold, minGroupSize, mode, _ in
            calls += 1
            capturedThreshold = threshold
            capturedMinGroupSize = minGroupSize
            capturedMode = mode
            capturedCount = entries.count
            return ClusterResult(groups: [entries.map(\.photoId)], ungrouped: [])
        }

        let single = [DuplicateHashPair(photoId: "a", hashHex: "0000000000000000")]
        let singleGroups = try DuplicateScanPipeline.visualComponents(
            entries: single, threshold: 4, clusterProvider: provider
        )
        #expect(singleGroups.isEmpty)
        #expect(calls == 0)

        let pair = [
            DuplicateHashPair(photoId: "a", hashHex: "0000000000000000"),
            DuplicateHashPair(photoId: "b", hashHex: "0000000000000000"),
        ]
        let groups = try DuplicateScanPipeline.visualComponents(
            entries: pair, threshold: 6, clusterProvider: provider
        )
        #expect(groups == [["a", "b"]])
        #expect(calls == 1)
        #expect(capturedThreshold == 6)
        #expect(capturedMinGroupSize == 2)
        #expect(capturedMode == .global)
        #expect(capturedCount == 2)
    }

    @Test("默认 clusterProvider 走 ClusterEngine（相同 hash 成组、远 hash 不成组）")
    func visualComponentsDefaultProvider() throws {
        let identical = try DuplicateScanPipeline.visualComponents(
            entries: [
                DuplicateHashPair(photoId: "a", hashHex: "0000000000000000"),
                DuplicateHashPair(photoId: "b", hashHex: "0000000000000000"),
            ],
            threshold: 4
        )
        #expect(identical.count == 1)
        #expect(Set(identical[0]) == ["a", "b"])

        let distinct = try DuplicateScanPipeline.visualComponents(
            entries: [
                DuplicateHashPair(photoId: "a", hashHex: "0000000000000000"),
                DuplicateHashPair(photoId: "b", hashHex: "ffffffffffffffff"),
            ],
            threshold: 4
        )
        #expect(distinct.isEmpty)

        // 单条即便 provider 也给不出组（< minGroupSize=2 直接返回空组件）。
        #expect(try DuplicateScanPipeline.visualComponents(entries: [], threshold: 4).isEmpty)
    }
}
