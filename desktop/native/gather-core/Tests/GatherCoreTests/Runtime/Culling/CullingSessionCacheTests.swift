// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Culling/CullingSessionCacheTests.swift
// W2b §2.4：CullingSessionCache actor 行为测试。
// 覆盖：TTL 过期（含边界）、容量上限与确定性淘汰、版本键 miss、invalidate 与
// invalidateAnalyses 语义差异、值拷贝需显式回写、并发 hammer。无需数据库。

import Testing
import Foundation
@testable import GatherCore

/// 可推进 / 可设定的假时钟（锁保护，供并发 hammer 安全读取）。
private final class FakeClock: CullingCacheClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}

private let cacheStart = Date(timeIntervalSince1970: 1_700_000_000)

private func lookupKey(
    _ session: String, seq: Int = 1, result: Int64? = 10
) -> CullingSessionCache.LookupKey {
    CullingSessionCache.LookupKey(sessionId: session, indexSeq: seq, similarityResultId: result)
}

private func updateKey(_ session: String, seq: Int = 1) -> CullingSessionCache.UpdateKey {
    CullingSessionCache.UpdateKey(sessionId: session, indexSeq: seq)
}

private func makeRow(_ id: String, assetId: String? = nil) -> CullingPhotoRow {
    CullingPhotoRow(
        id: id, sessionId: "s1", filepath: "/tmp/\(id).cr3", filename: "\(id).cr3",
        checksum: "sum-\(id)", status: "ready", assetId: assetId, assetFileId: nil,
        width: 100, height: 100, metadata: nil, result: nil,
        createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z"
    )
}

private func makeQuality(_ score: Double = 0.9) -> CullingQuality {
    CullingQuality(status: .succeeded, score: score, sharpness: 0.8, exposure: 0.7, warnings: [])
}

struct CullingSessionCacheTests {

    // MARK: - TTL

    @Test func defaultTTLIsFiveSeconds() async {
        let clock = FakeClock(start: cacheStart)
        let cache = CullingSessionCache(clock: clock)
        let key = lookupKey("s1")
        await cache.store(CullingSessionCache.Lookup(similarityMap: ["p1": "0"]), for: key)

        clock.set(cacheStart.addingTimeInterval(4.999))
        let before = await cache.lookup(for: key)
        #expect(before != nil, "4.999s < 5s TTL 应命中")

        // 恰好 5.000s：expiresAt > now 不成立（TTL 边界即过期）。
        clock.set(cacheStart.addingTimeInterval(5.0))
        let atBoundary = await cache.lookup(for: key)
        #expect(atBoundary == nil, "恰好 TTL 边界应过期")
    }

    @Test func expiredEntriesAreSweptFromCounts() async {
        let clock = FakeClock(start: cacheStart)
        let cache = CullingSessionCache(clock: clock, lookupTTL: 5, updateTTL: 5)
        await cache.store(CullingSessionCache.Lookup(), for: lookupKey("s1"))
        await cache.store(CullingSessionCache.Update(photos: [makeRow("p1")]), for: updateKey("s1"))

        clock.advance(6)
        let counts = await cache.entryCounts
        #expect(counts == CullingSessionCache.EntryCounts(lookup: 0, update: 0))
        let lookup = await cache.lookup(for: lookupKey("s1"))
        let update = await cache.update(for: updateKey("s1"))
        #expect(lookup == nil)
        #expect(update == nil)
    }

    @Test func storeRefreshesTTLForExistingKey() async {
        let clock = FakeClock(start: cacheStart)
        let cache = CullingSessionCache(clock: clock, lookupTTL: 5)
        let key = lookupKey("s1")
        await cache.store(CullingSessionCache.Lookup(similarityMap: ["p1": "v1"]), for: key)

        clock.advance(4)
        await cache.store(CullingSessionCache.Lookup(similarityMap: ["p1": "v2"]), for: key)

        clock.advance(4.5) // t=8.5：若 TTL 不随写入刷新（t0+5）则早已过期
        let hit = await cache.lookup(for: key)
        #expect(hit?.similarityMap == ["p1": "v2"], "覆盖写入应刷新 TTL 且返回新值")

        clock.advance(0.4) // t=8.9 < 9：第二次写入的 expiresAt = t0+4+5 = t0+9
        let stillHit = await cache.lookup(for: key)
        #expect(stillHit != nil)

        clock.advance(0.2) // t=9.1 > 9 → 过期
        let expired = await cache.lookup(for: key)
        #expect(expired == nil)
    }

    // MARK: - 容量与确定性淘汰

    @Test func defaultCapacityIsEightAndEvictsEarliest() async {
        let clock = FakeClock(start: cacheStart)
        let cache = CullingSessionCache(clock: clock)
        for i in 0..<9 {
            clock.advance(0.1)
            await cache.store(CullingSessionCache.Lookup(), for: lookupKey("s\(i)"))
        }
        let counts = await cache.entryCounts
        #expect(counts.lookup == 8, "默认容量 8")

        // 0.9s 内无过期：淘汰的是 expiresAt 最早的 s0。
        let evicted = await cache.lookup(for: lookupKey("s0"))
        #expect(evicted == nil, "最早写入者应被淘汰")
        let newest = await cache.lookup(for: lookupKey("s8"))
        #expect(newest != nil, "最新写入自身绝不被本次淘汰")
    }

    @Test func capacityEvictsEarliestExpiryForBothCaches() async {
        let clock = FakeClock(start: cacheStart)
        let cache = CullingSessionCache(
            clock: clock, lookupTTL: 60, lookupCapacity: 3, updateTTL: 60, updateCapacity: 3
        )
        for i in 0..<3 {
            clock.advance(10)
            await cache.store(
                CullingSessionCache.Lookup(similarityMap: ["p1": "\(i)"]), for: lookupKey("s\(i)")
            )
            await cache.store(
                CullingSessionCache.Update(photos: [makeRow("p\(i)")]), for: updateKey("s\(i)")
            )
        }
        clock.advance(10)
        await cache.store(CullingSessionCache.Lookup(similarityMap: ["p1": "3"]), for: lookupKey("s3"))
        await cache.store(CullingSessionCache.Update(photos: [makeRow("p3")]), for: updateKey("s3"))

        let counts = await cache.entryCounts
        #expect(counts == CullingSessionCache.EntryCounts(lookup: 3, update: 3))

        let evictedLookup = await cache.lookup(for: lookupKey("s0"))
        let evictedUpdate = await cache.update(for: updateKey("s0"))
        #expect(evictedLookup == nil, "lookup 应淘汰 expiresAt 最早的 s0")
        #expect(evictedUpdate == nil, "update 应淘汰 expiresAt 最早的 s0")

        for i in 1...3 {
            let lookup = await cache.lookup(for: lookupKey("s\(i)"))
            let update = await cache.update(for: updateKey("s\(i)"))
            #expect(lookup != nil)
            #expect(update != nil)
        }
    }

    @Test func evictionTieBreakIsDeterministicByKeyAscending() async {
        let clock = FakeClock(start: cacheStart) // 时钟不动：所有条目 expiresAt 相同
        let cache = CullingSessionCache(clock: clock, lookupTTL: 60, lookupCapacity: 2, updateTTL: 60, updateCapacity: 2)
        await cache.store(CullingSessionCache.Lookup(), for: lookupKey("a"))
        await cache.store(CullingSessionCache.Lookup(), for: lookupKey("b"))
        await cache.store(CullingSessionCache.Lookup(), for: lookupKey("c"))

        let a = await cache.lookup(for: lookupKey("a"))
        let b = await cache.lookup(for: lookupKey("b"))
        let c = await cache.lookup(for: lookupKey("c"))
        #expect(a == nil, "同刻并列按键升序淘汰：a 先出局（修复 keys.first 任意淘汰）")
        #expect(b != nil)
        #expect(c != nil)

        // 重复构造同一序列必须得到同一结果（确定性）。
        let clock2 = FakeClock(start: cacheStart)
        let cache2 = CullingSessionCache(clock: clock2, lookupTTL: 60, lookupCapacity: 2)
        await cache2.store(CullingSessionCache.Lookup(), for: lookupKey("a"))
        await cache2.store(CullingSessionCache.Lookup(), for: lookupKey("b"))
        await cache2.store(CullingSessionCache.Lookup(), for: lookupKey("c"))
        let a2 = await cache2.lookup(for: lookupKey("a"))
        let b2 = await cache2.lookup(for: lookupKey("b"))
        let c2 = await cache2.lookup(for: lookupKey("c"))
        #expect(a2 == nil)
        #expect(b2 != nil)
        #expect(c2 != nil)
    }

    // MARK: - 版本键

    @Test func lookupKeyVersioningMissesOnIndexSeqOrResultIdChange() async {
        let cache = CullingSessionCache(clock: FakeClock(start: cacheStart))
        let base = lookupKey("s1", seq: 7, result: 42)
        await cache.store(CullingSessionCache.Lookup(similarityMap: ["p1": "0"]), for: base)

        let hit = await cache.lookup(for: base)
        #expect(hit != nil)

        let seqMiss = await cache.lookup(for: lookupKey("s1", seq: 8, result: 42))
        #expect(seqMiss == nil, "indexSeq 变化必须 miss")

        let resultMiss = await cache.lookup(for: lookupKey("s1", seq: 7, result: 43))
        #expect(resultMiss == nil, "similarityResultId 变化必须 miss")

        let nilResultMiss = await cache.lookup(for: lookupKey("s1", seq: 7, result: nil))
        #expect(nilResultMiss == nil, "结果从有到无（nil）也必须 miss")

        let sessionMiss = await cache.lookup(for: lookupKey("s2", seq: 7, result: 42))
        #expect(sessionMiss == nil, "sessionId 变化必须 miss")
    }

    @Test func updateKeyVersioningMissesOnIndexSeqChange() async {
        let cache = CullingSessionCache(clock: FakeClock(start: cacheStart))
        let key = updateKey("s1", seq: 1)
        await cache.store(CullingSessionCache.Update(photos: [makeRow("p1")]), for: key)

        let hit = await cache.update(for: key)
        #expect(hit?.photos.count == 1)

        let seqMiss = await cache.update(for: updateKey("s1", seq: 2))
        #expect(seqMiss == nil, "indexSeq 变化必须 miss（index_seq 即版本）")

        let sessionMiss = await cache.update(for: updateKey("s2", seq: 1))
        #expect(sessionMiss == nil)
    }

    // MARK: - 值语义 / 显式回写

    @Test func updateDerivesIndexesAndRequiresExplicitWriteBack() async {
        let cache = CullingSessionCache(clock: FakeClock(start: cacheStart))
        let key = updateKey("s1")
        let rows = [makeRow("p1", assetId: "asset-1"), makeRow("p2", assetId: "asset-1"), makeRow("p3")]
        await cache.store(CullingSessionCache.Update(photos: rows), for: key)

        var fetched = await cache.update(for: key)
        #expect(fetched?.photoById.count == 3)
        #expect(fetched?.photosByAssetId["asset-1"]?.count == 2, "asset 索引应聚合共享 asset_id")
        #expect(fetched?.photosByAssetId["p3"] == nil, "无 asset_id 的照片跳过索引")
        #expect(fetched?.groupMap == nil, "懒解析字段初始为 nil")

        // 值拷贝：本地修改不回写则缓存不受影响。
        fetched?.groupMap = ["p1": "9:0"]
        let unchanged = await cache.update(for: key)
        #expect(unchanged?.groupMap == nil, "值语义：未 store 的修改不可见")

        if let fetched {
            await cache.store(fetched, for: key)
        }
        let written = await cache.update(for: key)
        #expect(written?.groupMap == ["p1": "9:0"], "显式回写后可见")
    }

    // MARK: - 失效语义

    @Test func invalidateAnalysesResetsAnalysesButKeepsEntries() async {
        let cache = CullingSessionCache(clock: FakeClock(start: cacheStart))
        let key = lookupKey("s1", seq: 3, result: 9)
        await cache.store(
            CullingSessionCache.Lookup(
                similarityMap: ["p1": "0"],
                groupIndex: ["p1": "9:0"],
                groupIndexResolved: true,
                analysesLoaded: true,
                qualityByPhoto: ["p1": makeQuality()],
                facesByPhoto: ["p1": [[0.1, 0.2]]],
                analysisMaxByPhoto: ["p1": 0.5],
                peopleByPhoto: ["p1": ["Alice"]],
                groupCount: 2,
                groupCountResolved: true
            ),
            for: key
        )
        await cache.store(
            CullingSessionCache.Update(photos: [makeRow("p1")], groupMap: ["p1": "9:0"]),
            for: updateKey("s1", seq: 3)
        )
        await cache.store(CullingSessionCache.Lookup(similarityMap: ["p2": "1"]), for: lookupKey("s2"))

        await cache.invalidateAnalyses(sessionId: "s1")

        let kept = await cache.lookup(for: key)
        #expect(kept != nil, "invalidateAnalyses 保留条目（不整条丢弃）")
        #expect(kept?.analysesLoaded == false, "分析标记复位")
        #expect(kept?.qualityByPhoto.isEmpty == true)
        #expect(kept?.facesByPhoto.isEmpty == true)
        #expect(kept?.analysisMaxByPhoto.isEmpty == true)
        #expect(kept?.peopleByPhoto.isEmpty == true)
        #expect(kept?.similarityMap == ["p1": "0"], "版本 / 相似度映射保留")
        #expect(kept?.groupIndex == ["p1": "9:0"], "组索引保留")
        #expect(kept?.groupCountResolved == true, "组数解析保留")

        let updateKept = await cache.update(for: updateKey("s1", seq: 3))
        #expect(updateKept?.groupMap == ["p1": "9:0"], "update 条目不含分析，不受 invalidateAnalyses 影响")

        let other = await cache.lookup(for: lookupKey("s2"))
        #expect(other != nil, "其他会话不受影响")
    }

    @Test func invalidateDropsAllVersionsForSessionOnly() async {
        let cache = CullingSessionCache(clock: FakeClock(start: cacheStart))
        let oldVersion = lookupKey("s1", seq: 1, result: 9)
        let newVersion = lookupKey("s1", seq: 2, result: 10)
        await cache.store(CullingSessionCache.Lookup(), for: oldVersion)
        await cache.store(CullingSessionCache.Lookup(), for: newVersion)
        await cache.store(CullingSessionCache.Update(photos: [makeRow("p1")]), for: updateKey("s1", seq: 2))
        await cache.store(CullingSessionCache.Lookup(), for: lookupKey("s2", seq: 1, result: 9))

        await cache.invalidate(sessionId: "s1")

        let old = await cache.lookup(for: oldVersion)
        let new = await cache.lookup(for: newVersion)
        let update = await cache.update(for: updateKey("s1", seq: 2))
        let other = await cache.lookup(for: lookupKey("s2", seq: 1, result: 9))
        #expect(old == nil, "invalidate 丢弃该会话全部版本（含旧版本键）")
        #expect(new == nil)
        #expect(update == nil)
        #expect(other != nil, "其他会话不受影响")

        let counts = await cache.entryCounts
        #expect(counts == CullingSessionCache.EntryCounts(lookup: 1, update: 0))
    }

    @Test func removeAllClearsBothCaches() async {
        let cache = CullingSessionCache(clock: FakeClock(start: cacheStart))
        await cache.store(CullingSessionCache.Lookup(), for: lookupKey("s1"))
        await cache.store(CullingSessionCache.Update(photos: [makeRow("p1")]), for: updateKey("s1"))

        await cache.removeAll()

        let counts = await cache.entryCounts
        #expect(counts == CullingSessionCache.EntryCounts(lookup: 0, update: 0))
        let lookup = await cache.lookup(for: lookupKey("s1"))
        let update = await cache.update(for: updateKey("s1"))
        #expect(lookup == nil)
        #expect(update == nil)
    }

    // MARK: - 并发 hammer

    @Test func concurrentHammerKeepsCountsBounded() async {
        let clock = FakeClock(start: cacheStart)
        let cache = CullingSessionCache(
            clock: clock, lookupTTL: 600, lookupCapacity: 4, updateTTL: 600, updateCapacity: 4
        )

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<300 {
                        let session = "s\(i % 6)"
                        let lk = CullingSessionCache.LookupKey(
                            sessionId: session, indexSeq: i % 3, similarityResultId: Int64(i % 2)
                        )
                        let uk = CullingSessionCache.UpdateKey(sessionId: session, indexSeq: i % 3)
                        switch (worker + i) % 6 {
                        case 0:
                            await cache.store(
                                CullingSessionCache.Lookup(similarityMap: ["p\(i)": "\(i % 3)"]), for: lk
                            )
                        case 1:
                            _ = await cache.lookup(for: lk)
                        case 2:
                            await cache.store(
                                CullingSessionCache.Update(photos: [makeRow("p\(i)")]), for: uk
                            )
                        case 3:
                            _ = await cache.update(for: uk)
                        case 4:
                            await cache.invalidateAnalyses(sessionId: session)
                        default:
                            if i % 29 == 0 {
                                await cache.invalidate(sessionId: session)
                            } else {
                                await cache.store(CullingSessionCache.Lookup(), for: lk)
                            }
                        }

                        let counts = await cache.entryCounts
                        if counts.lookup > 4 || counts.update > 4 {
                            Issue.record(
                                "并发下容量越界：lookup=\(counts.lookup) update=\(counts.update)"
                            )
                            return
                        }
                    }
                }
            }
            await group.waitForAll()
        }

        let counts = await cache.entryCounts
        #expect(counts.lookup <= 4)
        #expect(counts.update <= 4)
    }
}
