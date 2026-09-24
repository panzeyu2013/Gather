// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Similarity/SimilarityHashReuseTests.swift
// W2c 步骤 1：SimilarityHashReuse 纯函数测试（无数据库：候选行直接构造）。
//
// 语义对照旧 Services/SimilarityServiceTests.swift 的 reuseSimilarityHashes
// 批量复用 4 用例（W2c 完成后随之删除；SQL 读写在 Store 有独立用例）：
// - reuseAcrossSessions：跨会话共享资产文件的候选可复用；
// - skipsOwnHashAndMismatches：排除目标自身行、size/mtime 不匹配零复用；
// - newestCandidateAcrossChunkBoundary：rowid 最大者胜出 + 400 分块边界；
// - keepsExistingTargetsUntouched：existingHashMap 中的目标保持不动。
// 补充：分块口径（0/1/2/3 块）、资产 id 去重序、无统计/无资产映射的跳过、
// writes 顺序确定性。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 最小夹具（不触碰数据库）

private func makeReuseProjection(
    _ id: String,
    assetFileId: String? = nil,
    filepath: String? = nil
) -> PhotoProjection {
    let path = filepath ?? "/shoot/\(id).jpg"
    return PhotoProjection(
        id: id, sessionId: "session", filepath: path,
        filename: (path as NSString).lastPathComponent,
        checksum: "checksum-\(id)", checksumFileSize: 0, checksumFileMtimeMs: 0,
        status: "pending", assetId: nil, assetFileId: assetFileId,
        width: 100, height: 100,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
    )
}

private func makeCandidate(
    _ id: Int64,
    _ photoId: String,
    _ hashHex: String,
    _ fileSize: Int,
    _ fileMtimeMs: Double,
    assetFileId: String
) -> SimilarityHashCandidate {
    SimilarityHashCandidate(
        id: id, photoId: photoId, hashHex: hashHex,
        fileSize: fileSize, fileMtimeMs: fileMtimeMs, assetFileId: assetFileId
    )
}

private func makeStat(_ size: Int, _ mtimeMs: Double) -> SimilaritySourceStat {
    SimilaritySourceStat(size: size, mtimeMs: mtimeMs)
}

@Suite("SimilarityHashReuse")
struct SimilarityHashReuseTests {

    // MARK: 旧用例 1：跨会话复用

    @Test("reuses hashes from sibling asset files in a single batch, including cross-session sources")
    func reuseAcrossSessions() {
        let photos = [
            makeReuseProjection("p1", assetFileId: "asset-a"),
            makeReuseProjection("p2", assetFileId: "asset-a"),
            makeReuseProjection("p3", assetFileId: "asset-b"),
        ]
        let plan = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: [
                "p1": makeStat(100, 1000), "p2": makeStat(100, 1000), "p3": makeStat(100, 1000),
            ],
            existingHashMap: [:],
            assetFileByPhoto: ["p1": "asset-a", "p2": "asset-a", "p3": "asset-b"],
            candidates: [
                // px 属于 other-session，但与 p1/p2 共享 asset-a。
                makeCandidate(7, "px", "a1b2c3d4e5f60718", 100, 1000, assetFileId: "asset-a"),
            ]
        )

        #expect(plan.reusedCount == 2)
        #expect(plan.writes == [
            SimilarityHashUpsert(photoId: "p1", hashHex: "a1b2c3d4e5f60718", fileSize: 100, fileMtimeMs: 1000),
            SimilarityHashUpsert(photoId: "p2", hashHex: "a1b2c3d4e5f60718", fileSize: 100, fileMtimeMs: 1000),
        ])
        #expect(plan.hashes["p1"] == "a1b2c3d4e5f60718")
        #expect(plan.hashes["p2"] == "a1b2c3d4e5f60718")
        #expect(plan.hashes["p3"] == nil)
    }

    // MARK: 旧用例 2：自身行与 size/mtime 不匹配

    @Test("never reuses a photo own hash row and skips size/mtime mismatches")
    func skipsOwnHashAndMismatches() {
        let photos = [
            makeReuseProjection("q1", assetFileId: "asset-c"),
            makeReuseProjection("q2", assetFileId: "asset-c"),
        ]
        let candidates = [
            makeCandidate(1, "q2", "q2ownhash", 200, 2000, assetFileId: "asset-c"),
        ]
        let mapping = ["q1": "asset-c", "q2": "asset-c"]

        let plan = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["q1": makeStat(200, 2000), "q2": makeStat(200, 2000)],
            existingHashMap: [:],
            assetFileByPhoto: mapping,
            candidates: candidates
        )
        #expect(plan.reusedCount == 1)
        #expect(plan.hashes["q1"] == "q2ownhash")
        // q2 的自身行不是来源；它没有别的前驱 → 不复用。
        #expect(plan.hashes["q2"] == nil)

        // 文件统计不匹配 → 零复用。
        let stale = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["q1": makeStat(999, 9999), "q2": makeStat(999, 9999)],
            existingHashMap: [:],
            assetFileByPhoto: mapping,
            candidates: candidates
        )
        #expect(stale.reusedCount == 0)
        #expect(stale.writes.isEmpty)
        #expect(stale.hashes.isEmpty)
    }

    @Test("accepts mtime differences below one millisecond and rejects exact one")
    func mtimeToleranceBoundary() {
        let photos = [makeReuseProjection("t1", assetFileId: "asset-t")]
        let mapping = ["t1": "asset-t"]

        let below = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["t1": makeStat(100, 1000.5)],
            existingHashMap: [:],
            assetFileByPhoto: mapping,
            candidates: [makeCandidate(1, "src", "hash-below", 100, 1000, assetFileId: "asset-t")]
        )
        #expect(below.reusedCount == 1)
        #expect(below.hashes["t1"] == "hash-below")
        // 落库统计值是目标照片的，不是候选行的。
        #expect(below.writes == [
            SimilarityHashUpsert(photoId: "t1", hashHex: "hash-below", fileSize: 100, fileMtimeMs: 1000.5),
        ])

        let exact = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["t1": makeStat(100, 1001)],
            existingHashMap: [:],
            assetFileByPhoto: mapping,
            candidates: [makeCandidate(1, "src", "hash-exact", 100, 1000, assetFileId: "asset-t")]
        )
        #expect(exact.reusedCount == 0)

        let sizeMismatch = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["t1": makeStat(101, 1000)],
            existingHashMap: [:],
            assetFileByPhoto: mapping,
            candidates: [makeCandidate(1, "src", "hash-size", 100, 1000, assetFileId: "asset-t")]
        )
        #expect(sizeMismatch.reusedCount == 0)
    }

    // MARK: 旧用例 3：最新候选 + 分块边界

    @Test("picks the newest candidate hash and crosses the 400-id chunk boundary")
    func newestCandidateAcrossChunkBoundary() {
        // 404 个资产文件 → 恰好 2 块（1 + ceil(404/400) 往返口径）。
        let assetFileIds = (0..<404).map { "asset-\($0)" }
        let chunked = SimilarityHashReuse.chunks(assetFileIds)
        #expect(chunked.count == 2)
        #expect(chunked[0].count == 400)
        #expect(chunked[1] == ["asset-400", "asset-401", "asset-402", "asset-403"])

        // r403 与 r404 共享 asset-403：其候选（含自身 stalehash）落在第二分块。
        let photos = [makeReuseProjection("r403", assetFileId: "asset-403")]
        let plan = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["r403": makeStat(300, 3000)],
            existingHashMap: [:],
            assetFileByPhoto: ["r403": "asset-403"],
            candidates: [
                makeCandidate(1, "r403", "stalehash", 300, 3000, assetFileId: "asset-403"),
                makeCandidate(2, "r404", "freshhash", 300, 3000, assetFileId: "asset-403"),
            ]
        )

        #expect(plan.reusedCount == 1)
        #expect(plan.hashes["r403"] == "freshhash")
        #expect(plan.writes == [
            SimilarityHashUpsert(photoId: "r403", hashHex: "freshhash", fileSize: 300, fileMtimeMs: 3000),
        ])
    }

    @Test("chunking stays exact at 0/400/401/800/801 ids")
    func chunkBoundaries() {
        #expect(SimilarityHashReuse.chunkSize == 400)
        #expect(SimilarityHashReuse.chunks([]).isEmpty)
        #expect(SimilarityHashReuse.chunks((0..<400).map(String.init)).count == 1)
        #expect(SimilarityHashReuse.chunks((0..<401).map(String.init)).count == 2)
        #expect(SimilarityHashReuse.chunks((0..<800).map(String.init)).count == 2)
        #expect(SimilarityHashReuse.chunks((0..<801).map(String.init)).count == 3)
        #expect(SimilarityHashReuse.chunks(["a"]).first == ["a"])
    }

    // MARK: 旧用例 4：已有 hash 的目标保持不动

    @Test("keeps targets already present in existingHashMap untouched")
    func keepsExistingTargetsUntouched() {
        let plan = SimilarityHashReuse.plan(
            photos: [
                makeReuseProjection("s1", assetFileId: "asset-e"),
                makeReuseProjection("s2", assetFileId: "asset-e"),
            ],
            sourceStats: ["s1": makeStat(400, 4000), "s2": makeStat(400, 4000)],
            existingHashMap: ["s1": "already-present"],
            assetFileByPhoto: ["s1": "asset-e", "s2": "asset-e"],
            candidates: [makeCandidate(1, "s2", "s2hash", 400, 4000, assetFileId: "asset-e")]
        )

        #expect(plan.reusedCount == 0)
        #expect(plan.writes.isEmpty)
        #expect(plan.hashes["s1"] == "already-present")
        // s2 有自身候选行 → 不回填；现有映射原样保留。
        #expect(plan.hashes["s2"] == nil)
    }

    // MARK: 补充守护

    @Test("assetFileIds dedupes and follows the projection order")
    func assetFileIdsAndOrder() {
        let photos = [
            makeReuseProjection("p1", assetFileId: "asset-a"),
            makeReuseProjection("p2", assetFileId: nil),
            makeReuseProjection("p3", assetFileId: "asset-b"),
            makeReuseProjection("p4", assetFileId: "asset-a"),
        ]
        let ids = SimilarityHashReuse.assetFileIds(
            photos: photos,
            assetFileByPhoto: ["p1": "asset-a", "p3": "asset-b", "p4": "asset-a"]
        )
        #expect(ids == ["asset-a", "asset-b"])
    }

    @Test("skips targets without stats, without asset mapping, or without candidates")
    func skipsIncompleteTargets() {
        let photos = [
            makeReuseProjection("a", assetFileId: "asset-x"),
            makeReuseProjection("b", assetFileId: "asset-y"),
            makeReuseProjection("c", assetFileId: "asset-z"),
        ]
        let plan = SimilarityHashReuse.plan(
            photos: photos,
            // a 有统计但无候选；b 无统计；c 无资产映射。
            sourceStats: ["a": makeStat(100, 1000), "b": makeStat(100, 1000)],
            existingHashMap: [:],
            assetFileByPhoto: ["a": "asset-x", "b": "asset-y"],
            candidates: []
        )
        #expect(plan.reusedCount == 0)
        #expect(plan.writes.isEmpty)
        #expect(plan.hashes.isEmpty)
    }

    @Test("writes follow photo order regardless of candidate order")
    func deterministicWriteOrder() {
        let photos = [
            makeReuseProjection("b", assetFileId: "asset-b"),
            makeReuseProjection("a", assetFileId: "asset-a"),
        ]
        let plan = SimilarityHashReuse.plan(
            photos: photos,
            sourceStats: ["a": makeStat(10, 100), "b": makeStat(10, 100)],
            existingHashMap: [:],
            assetFileByPhoto: ["a": "asset-a", "b": "asset-b"],
            candidates: [
                makeCandidate(2, "src-b", "hash-b", 10, 100, assetFileId: "asset-b"),
                makeCandidate(1, "src-a", "hash-a", 10, 100, assetFileId: "asset-a"),
            ]
        )
        #expect(plan.writes.map(\.photoId) == ["b", "a"])
        #expect(plan.hashes == ["a": "hash-a", "b": "hash-b"])
    }
}
