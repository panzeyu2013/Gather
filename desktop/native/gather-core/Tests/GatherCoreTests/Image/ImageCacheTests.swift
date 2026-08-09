// desktop/native/gather-core/Tests/GatherCoreTests/Image/ImageCacheTests.swift
// 磁盘缓存重写（Phase 2 任务 2.1）测试。
// TS 源对照: desktop/src/main/services/image/disk-cache.ts + image.service.ts
// 语义要点：键 → sha256 hex 前 16 字符文件名；容量淘汰按策略窗口 + 脏集合合并；
//          put 原子写（tmp + rename）；flush 后重启对账；TTL 为 Swift 侧扩展（TS 无）。

import Foundation
import Testing
@testable import GatherCore

struct ImageCacheTests {
    private func makeCacheTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-image-cache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// 可控时钟（毫秒时间戳），供 TTL/淘汰时序测试注入。
    private final class TestClock {
        private let lock = NSLock()
        private var nowMs: Int64

        init(startMs: Int64) {
            nowMs = startMs
        }

        func now() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return nowMs
        }

        func set(_ value: Int64) {
            lock.lock()
            defer { lock.unlock() }
            nowMs = value
        }
    }

    // ── 写入/读取往返 ──

    @Test func putGetRoundtripPreservesContentAndMetadata() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)

        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        await cache.put(payload, forKey: "roundtrip-key")

        let entry = cache.metadata()["\(ImageCache.hashKey("roundtrip-key"))"]
        #expect(entry?.fileSize == Int64(payload.count))
        #expect(entry?.accessCount == 1, "put 后未访问，计数应为 1")
        #expect(entry?.createdAt == entry?.lastAccess)

        let data = await cache.get("roundtrip-key")
        #expect(data == payload)
        #expect(cache.metadata()["\(ImageCache.hashKey("roundtrip-key"))"]?.accessCount == 2, "get 命中应累加访问计数")

        let stats = cache.stats()
        #expect(stats.fileCount == 1)
        #expect(stats.totalSize == Int64(payload.count))
        #expect(stats.maxSize == 1 << 30)
        #expect(stats.policy == .lru)
    }

    @Test func fileLivesAtHashedPathWithJpgSuffix() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)

        let key = "/photos/2026/DSC_0001.jpg::t1024@123456@1700000000000"
        await cache.put(Data("bytes".utf8), forKey: key)

        let hash = ImageCache.hashKey(key)
        #expect(hash.count == 16)
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("\(hash).jpg")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let content = try Data(contentsOf: fileURL)
        #expect(content == Data("bytes".utf8))
    }

    @Test func missReturnsNil() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)

        #expect(await cache.get("never-put") == nil)
        #expect(cache.stats().fileCount == 0)
        #expect(cache.metadata().isEmpty)
    }

    @Test func readCapTreatsOversizedFileAsMiss() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30, readCapBytes: 8)

        await cache.put(Data(repeating: 0x41, count: 16), forKey: "big")
        #expect(await cache.get("big") == nil, "超过读上限应视为未命中（TS DISK_CACHE_READ_CAP_BYTES）")
        #expect(cache.stats().fileCount == 1, "读上限未命中不删除条目（TS 语义）")
    }

    // ── 容量淘汰（LRU/FIFO/LFU，与 TS 语义一致） ──

    @Test func lruEvictionMatchesTS() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock(startMs: 1000)
        let cache = ImageCache(
            cacheRootDir: dir,
            maxSizeBytes: 2 * 1024,
            policy: .lru,
            clock: { clock.now() }
        )
        let payload = Data(repeating: 0x42, count: 1024)

        clock.set(1000)
        await cache.put(payload, forKey: "a")
        clock.set(2000)
        await cache.put(payload, forKey: "b")
        clock.set(3000)
        await cache.put(payload, forKey: "c")
        #expect(await cache.get("a") == nil, "超出容量后应淘汰 lastAccess 最旧的 a")
        #expect(await cache.get("b") != nil)
        #expect(await cache.get("c") != nil)

        clock.set(4000)
        _ = await cache.get("b")
        clock.set(5000)
        await cache.put(payload, forKey: "d")
        #expect(await cache.get("c") == nil, "b 被访问过，应淘汰 c 而非 b")
        #expect(await cache.get("b") != nil)
        #expect(await cache.get("d") != nil)

        let stats = cache.stats()
        #expect(stats.fileCount == 2)
        #expect(stats.totalSize == 2 * 1024)
        #expect(stats.totalSize <= stats.maxSize)
    }

    @Test func fifoEvictionIgnoresAccessTime() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock(startMs: 1000)
        let cache = ImageCache(
            cacheRootDir: dir,
            maxSizeBytes: 2 * 1024,
            policy: .fifo,
            clock: { clock.now() }
        )
        let payload = Data(repeating: 0x43, count: 1024)

        clock.set(1000)
        await cache.put(payload, forKey: "a")
        clock.set(2000)
        await cache.put(payload, forKey: "b")
        clock.set(3000)
        await cache.put(payload, forKey: "c")
        #expect(await cache.get("a") == nil, "FIFO 按 createdAt 淘汰 a")

        clock.set(4000)
        _ = await cache.get("b")
        clock.set(5000)
        await cache.put(payload, forKey: "d")
        #expect(await cache.get("b") == nil, "FIFO 不看访问时间，b(createdAt=2000) 先于 c(3000) 淘汰")
        #expect(await cache.get("c") != nil)
        #expect(await cache.get("d") != nil)
    }

    @Test func lfuEvictionByAccessCount() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock(startMs: 1000)
        let cache = ImageCache(
            cacheRootDir: dir,
            maxSizeBytes: 2 * 1024,
            policy: .lfu,
            clock: { clock.now() }
        )
        let payload = Data(repeating: 0x44, count: 1024)

        clock.set(1000)
        await cache.put(payload, forKey: "a")
        clock.set(2000)
        await cache.put(payload, forKey: "b")
        for t in stride(from: 3000, through: 6000, by: 1000) {
            clock.set(Int64(t))
            _ = await cache.get("a")
        }
        clock.set(7000)
        _ = await cache.get("b")
        clock.set(8000)
        _ = await cache.get("b")
        clock.set(9000)
        await cache.put(payload, forKey: "c")

        #expect(cache.metadata()["\(ImageCache.hashKey("a"))"]?.accessCount == 5, "a = put(1) + 4 次 get")
        #expect(cache.metadata()["\(ImageCache.hashKey("b"))"]?.accessCount == 3, "b = put(1) + 2 次 get")

        #expect(await cache.get("c") == nil, "LFU 淘汰 accessCount 最小的 c(1) < b(3) < a(5)")
        #expect(await cache.get("a") != nil)
        #expect(await cache.get("b") != nil)
    }

    @Test func evictIfNeededIsIdempotentAndBringsUnderBudget() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 2 * 1024)
        let payload = Data(repeating: 0x45, count: 1024)

        await cache.put(payload, forKey: "a")
        await cache.put(payload, forKey: "b")
        await cache.put(payload, forKey: "c")

        await cache.evictIfNeeded()
        await cache.evictIfNeeded()
        #expect(cache.stats().totalSize <= cache.stats().maxSize)
        #expect(await cache.get("b") != nil)
        #expect(await cache.get("c") != nil)
    }

    // ── TTL 过期（Swift 侧扩展，TS 无） ──

    @Test func ttlEntrySurvivesWithinWindow() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock(startMs: 1000)
        let cache = ImageCache(
            cacheRootDir: dir,
            maxSizeBytes: 1 << 30,
            ttlMilliseconds: 1000,
            clock: { clock.now() }
        )

        clock.set(1000)
        await cache.put(Data("fresh".utf8), forKey: "k")
        clock.set(1500)
        #expect(await cache.get("k") == Data("fresh".utf8), "createdAt+ttl 窗口内不应过期")
        #expect(cache.stats().fileCount == 1)
    }

    @Test func ttlExpiryOnGetRemovesEntryAndFile() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock(startMs: 1000)
        let cache = ImageCache(
            cacheRootDir: dir,
            maxSizeBytes: 1 << 30,
            ttlMilliseconds: 1000,
            clock: { clock.now() }
        )

        clock.set(1000)
        await cache.put(Data("stale".utf8), forKey: "k")
        clock.set(2500)
        #expect(await cache.get("k") == nil, "过期条目应视为未命中")
        #expect(cache.stats().fileCount == 0)
        let hash = ImageCache.hashKey("k")
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/\(hash).jpg"), "过期条目应删除缓存文件")
    }

    @Test func ttlSweepHappensDuringEviction() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = TestClock(startMs: 1000)
        let cache = ImageCache(
            cacheRootDir: dir,
            maxSizeBytes: 1 << 30,
            ttlMilliseconds: 1000,
            clock: { clock.now() }
        )

        clock.set(1000)
        await cache.put(Data("a".utf8), forKey: "a")
        clock.set(1100)
        await cache.put(Data("b".utf8), forKey: "b")
        clock.set(3000)
        await cache.put(Data("c".utf8), forKey: "c")

        #expect(await cache.get("a") == nil)
        #expect(await cache.get("b") == nil)
        #expect(await cache.get("c") == Data("c".utf8))
        #expect(cache.stats().fileCount == 1)
    }

    // ── 并发写入 ──

    @Test func concurrentPutsLoseNoData() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)
        let count = 40

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let data = Data(repeating: UInt8(i % 251), count: 1024 + i)
                    await cache.put(data, forKey: "key-\(i)")
                }
            }
            await group.waitForAll()
        }

        for i in 0..<count {
            let data = await cache.get("key-\(i)")
            #expect(data == Data(repeating: UInt8(i % 251), count: 1024 + i))
        }
        let stats = cache.stats()
        #expect(stats.fileCount == count)
        #expect(stats.totalSize == Int64((0..<count).map { 1024 + $0 }.reduce(0, +)))
    }

    @Test func concurrentPutsSameKeyKeepStateConsistent() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)
        let payloads = (0..<20).map { Data(repeating: UInt8($0), count: 512) }

        await withTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    await cache.put(payload, forKey: "same-key")
                }
            }
            await group.waitForAll()
        }

        let data = await cache.get("same-key")
        #expect(data != nil)
        #expect(payloads.contains { $0 == data }, "并发同键写入，最终内容应为某个写入的完整 payload")
        #expect(cache.stats().fileCount == 1)

        let hash = ImageCache.hashKey("same-key")
        let attrs = try FileManager.default.attributesOfItem(atPath: "\(dir)/\(hash).jpg")
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value
        #expect(fileSize == data.map { Int64($0.count) }, "磁盘文件内容与 get 返回一致")
    }

    // ── flush / 重启对账（独立文件 DB 场景） ──

    @Test func flushPersistsAcrossRestart() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)

        #expect(FileManager.default.fileExists(atPath: "\(dir)/cache-meta.db"), "元数据应使用独立 DB 文件")

        await cache.put(Data("one".utf8), forKey: "k1")
        await cache.put(Data("two".utf8), forKey: "k2")
        await cache.put(Data("three".utf8), forKey: "k3")
        await cache.flush()

        let reopened = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)
        #expect(await reopened.get("k1") == Data("one".utf8))
        #expect(await reopened.get("k2") == Data("two".utf8))
        #expect(await reopened.get("k3") == Data("three".utf8))
        let stats = reopened.stats()
        #expect(stats.fileCount == 3)
        #expect(stats.totalSize == Int64("one".utf8.count + "two".utf8.count + "three".utf8.count))
    }

    @Test func orphanFilesAreAdoptedOnLoad() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let key = "orphan-key"
        let hash = ImageCache.hashKey(key)
        let orphanPath = "\(dir)/\(hash).jpg"
        try Data("orphan-content".utf8).write(to: URL(fileURLWithPath: orphanPath))

        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)
        #expect(cache.metadata()["\(hash)"]?.accessCount == 0, "收养的孤儿文件 accessCount 应为 0")
        #expect(cache.stats().fileCount == 1)
        #expect(cache.stats().totalSize == Int64("orphan-content".utf8.count))

        #expect(await cache.get(key) == Data("orphan-content".utf8), "孤儿文件应由启动对账收养")
    }

    @Test func danglingDbRowsAreDroppedOnLoad() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)
        await cache.put(Data("gone".utf8), forKey: "k")
        await cache.flush()

        let hash = ImageCache.hashKey("k")
        try FileManager.default.removeItem(atPath: "\(dir)/\(hash).jpg")

        let reopened = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)
        #expect(await reopened.get("k") == nil)
        #expect(reopened.stats().fileCount == 0)
        #expect(reopened.metadata().isEmpty)
    }

    // ── delete / 清理 API ──

    @Test func deleteRemovesEntryFileAndMetadata() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)

        await cache.put(Data("gone".utf8), forKey: "del")
        let hash = ImageCache.hashKey("del")

        await cache.delete("del")
        #expect(await cache.get("del") == nil)
        #expect(!FileManager.default.fileExists(atPath: "\(dir)/\(hash).jpg"))
        #expect(cache.stats().fileCount == 0)
        #expect(cache.metadata().isEmpty)

        await cache.delete("never-existed")
        #expect(cache.stats().fileCount == 0, "删除不存在的键应为空操作")
    }

    @Test func flushIsIdempotent() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cache = ImageCache(cacheRootDir: dir, maxSizeBytes: 1 << 30)

        await cache.flush()
        await cache.flush()
        await cache.put(Data("x".utf8), forKey: "x")
        await cache.flush()
        #expect(await cache.get("x") == Data("x".utf8))
    }

    // ── 哈希键（与 node crypto sha256 hex 前 16 字符对账） ──

    @Test func hashKeyMatchesNodeSha256Prefix() {
        #expect(ImageCache.hashKey("") == "e3b0c44298fc1c14")
        #expect(ImageCache.hashKey("abc") == "ba7816bf8f01cfea")
        #expect(ImageCache.hashKey("/photos/2026/DSC_0001.jpg::t1024@123456@1700000000000") == "acc3bd9867f701a3")
        #expect(ImageCache.hashKey("hello world") == "b94d27b9934d3e08")
        #expect(ImageCache.hashKey("🙂emoji-键") == "8173c8965cf9721c", "UTF-8 字节序与 node 一致")
    }

    @Test func sha256FullDigestMatchesFipsVectors() {
        #expect(hex(SHA256.hash(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex(SHA256.hash(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(SHA256.hash(Data("The quick brown fox jumps over the lazy dog".utf8))) == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        #expect(hex(SHA256.hash(Data("a".utf8))) == "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
        #expect(hex(SHA256.hash(Data("message digest".utf8))) == "f7846f55cf23e14eebeab5b4e1550cad5b509e3348fbc4efa3a1413d393cb650")
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // ── 统计字段 ──

    @Test func statsReflectsPolicyAndTtl() async throws {
        let dir = try makeCacheTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fifo = ImageCache(cacheRootDir: dir, maxSizeBytes: 4096, policy: .fifo, ttlMilliseconds: 5000)
        #expect(fifo.stats().policy == .fifo)
        #expect(fifo.stats().ttlMilliseconds == 5000)

        let lfu = ImageCache(cacheRootDir: dir + "/lfu", maxSizeBytes: 4096, policy: .lfu)
        #expect(lfu.stats().policy == .lfu)
        #expect(lfu.stats().ttlMilliseconds == nil)
    }
}
