// desktop/native/gather-core/Tests/GatherCoreTests/Services/SimilarityIncrementalServiceTests.swift
// 增量聚类的服务层接线（ROADMAP 1.3）：参数匹配 → 邻域增量（不调用全量聚类）、
// 版本号递增、连续增量计数、收敛间隔到期后的全量重聚类、阈值变化与 sequential
// 模式的退化路径。
//
// 夹具策略：为照片预置 checksum 尺寸/mtime 与 similarity_hashes 行，使 analyze
// 走 hash 复用路径（不触碰真实文件与解码），从而精确控制哈希与分量结构。

import Foundation
import Testing
@testable import GatherCore

private func makeTempPhotoStore() async throws -> any PhotoStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "photos")
    return SQLitePhotoStore(database: database)
}


/// 统计全量聚类调用次数（增量路径不得触发）。
private final class ClusterCallCounter {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct IncrementalHarness {
    let db: DBConnection
    let service: SimilarityService
    let sessionStore: any SessionStore
    let similarityStore: SQLiteSimilarityStore
    let counter: ClusterCallCounter
    let sessionId: String
}

private let sessionId = "sim-incremental"

private func addPhotoWithHash(_ db: DBConnection, _ id: String, hash: String) throws {
    try insertPhoto(db, id: id, sessionId: sessionId)
    // analyze 的文件统计优先取索引扫描结果：checksum 尺寸/mtime 与 hash 行一致时
    // 直接复用哈希，无需真实文件与缩略图解码。
    _ = try db.prepare("UPDATE photos SET checksum_file_size = 100, checksum_file_mtime_ms = 1000 WHERE id = ?")
        .run([.text(id)])
    _ = try db.prepare("""
        INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
        VALUES (?, ?, ?, 100, 1000)
      """).run([.text(sessionId), .text(id), .text(hash)])
}

private func updateHash(_ db: DBConnection, _ id: String, hash: String) throws {
    _ = try db.prepare("UPDATE similarity_hashes SET hash_hex = ? WHERE session_id = ? AND photo_id = ?")
        .run([.text(hash), .text(sessionId), .text(id)])
}

private func removePhoto(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("DELETE FROM similarity_hashes WHERE session_id = ? AND photo_id = ?")
        .run([.text(sessionId), .text(id)])
    _ = try db.prepare("DELETE FROM photos WHERE id = ?").run([.text(id)])
}

private func makeIncrementalHarness(settings: [String: Double] = [:]) throws -> IncrementalHarness {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-similarity-\(UUID().uuidString).sqlite").path
    let db = try DBConnection(path: dbPath)
    try MigrationRunner().migrate(db)
    try insertSession(db, sessionId)
    let counter = ClusterCallCounter()
    let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
    let service = SimilarityService(
        photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
        sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
        similarityStore: similarityStore,
        connection: db,
        getNumber: { key, defaultValue in settings[key] ?? defaultValue },
        thumbnailProvider: { _, _ in nil },
        clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
            counter.increment()
            return try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress
            )
        }
    )
    return IncrementalHarness(
        db: db, service: service, sessionStore: try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)),
        similarityStore: similarityStore, counter: counter, sessionId: sessionId
    )
}

private func hex(_ value: UInt64) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
}

private let base: UInt64 = 0xAAAA_AAAA_AAAA_AAAA
private let outlier: UInt64 = 0x5555_5555_5555_5555

private func analyze(_ harness: IncrementalHarness, threshold: Double = 10) async throws {
    try await harness.service.analyze(sessionId: harness.sessionId, threshold: threshold, minGroupSize: 2)
}

@Suite("SimilarityService 增量聚类路径")
struct SimilarityIncrementalServiceTests {
    @Test("首次分析全量并落状态，新增照片后走增量且版本递增")
    func incrementalPathSkipsFullClustering() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try addPhotoWithHash(harness.db, "p3", hash: hex(base ^ 0b1111))
        try addPhotoWithHash(harness.db, "p4", hash: hex(outlier))

        try await analyze(harness)
        #expect(harness.counter.count == 1, "首次分析应全量聚类")
        let first = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(first.version == 1)
        #expect(first.incrementalUpdates == 0)
        #expect(first.memberCount == 4)
        #expect(first.paramThreshold == 10)
        #expect(first.groupingMode == "global")

        // 新增第二张邻域照片：必须走增量（不调用全量聚类），版本 +1、增量计数 +1。
        try addPhotoWithHash(harness.db, "p5", hash: hex(base ^ 0b111111))
        try await analyze(harness)
        #expect(harness.counter.count == 1, "增量路径不得调用全量聚类")
        let second = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(second.version == 2)
        #expect(second.incrementalUpdates == 1)
        #expect(second.memberCount == 5)

        // p4 是离群照片：新增 p5 后成组的是 {p1, p2, p3, p5}（4 张），p4 仍未成组。
        let result = try #require(try await harness.service.getResult(sessionId: harness.sessionId))
        #expect(result.groups.count == 1)
        #expect(result.groups[0].count == 4)
        #expect(result.ungrouped.count == 1)
    }

    @Test("移除照片走增量且分量正确收缩")
    func removalGoesThroughIncremental() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try addPhotoWithHash(harness.db, "p3", hash: hex(base ^ 0b1111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)

        try removePhoto(harness.db, "p1")
        try await analyze(harness)
        #expect(harness.counter.count == 1, "移除也走增量")
        let meta = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(meta.version == 2)
        #expect(meta.memberCount == 2)

        let result = try #require(try await harness.service.getResult(sessionId: harness.sessionId))
        #expect(result.groups.count == 1)
        #expect(result.groups[0].count == 2)
    }

    @Test("哈希变化按移除 + 新增重算邻域")
    func hashChangeGoesThroughIncremental() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try addPhotoWithHash(harness.db, "p3", hash: hex(outlier))
        try await analyze(harness)

        // p3 变成 base 邻域 → 组从 2 张变 3 张。
        try updateHash(harness.db, "p3", hash: hex(base ^ 0b111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        let result = try #require(try await harness.service.getResult(sessionId: harness.sessionId))
        #expect(result.groups.count == 1)
        #expect(result.groups[0].count == 3)
        let meta = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(meta.version == 2)
    }

    @Test("连续增量达到收敛间隔后自动全量重聚类并清零计数")
    func convergenceIntervalTriggersFullRecluster() async throws {
        let harness = try makeIncrementalHarness(settings: ["similarity_cluster_convergence_interval": 2])
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId)?.incrementalUpdates == 0)

        try addPhotoWithHash(harness.db, "p3", hash: hex(base ^ 0b111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId)?.incrementalUpdates == 1)

        try addPhotoWithHash(harness.db, "p4", hash: hex(base ^ 0b1111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId)?.incrementalUpdates == 2)

        // 第三次增量：达到间隔 → 全量收敛，计数清零、版本继续递增。
        try addPhotoWithHash(harness.db, "p5", hash: hex(base ^ 0b11111))
        try await analyze(harness)
        #expect(harness.counter.count == 2, "达到收敛间隔应触发全量重聚类")
        let meta = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(meta.incrementalUpdates == 0)
        #expect(meta.version == 4)
    }

    @Test("阈值变化走全量并重写状态参数指纹")
    func thresholdChangeForcesFullRecluster() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId)?.paramThreshold == 10)

        _ = try await harness.service.recluster(sessionId: harness.sessionId, threshold: 4, minGroupSize: 2)
        #expect(harness.counter.count == 2, "阈值变化必须全量重聚类")
        let meta = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(meta.paramThreshold == 4)
        #expect(meta.incrementalUpdates == 0)
        #expect(meta.version == 2)

        // 变回原阈值：参数不匹配 → 仍走全量，而不是复用 4 的状态。
        _ = try await harness.service.recluster(sessionId: harness.sessionId, threshold: 10, minGroupSize: 2)
        #expect(harness.counter.count == 3)
    }

    @Test("sequential 模式无增量设施：全量并清除状态")
    func sequentialModeClearsState() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try await analyze(harness)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId) != nil)

        try await harness.service.analyze(
            sessionId: harness.sessionId, threshold: 10, minGroupSize: 2, groupingMode: .sequential
        )
        #expect(harness.counter.count == 2)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId) == nil, "sequential 模式不保留增量状态")

        // 回到 global：状态缺失 → 全量重建。
        try await analyze(harness)
        #expect(harness.counter.count == 3)
        await #expect(try await harness.service.clusterVersion(sessionId: harness.sessionId)?.groupingMode == "global")
    }

    @Test("状态行与结果一致：全量重算的划分与增量结果相同")
    func stateMatchesStoredResult() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try addPhotoWithHash(harness.db, "p3", hash: hex(outlier))
        try addPhotoWithHash(harness.db, "p4", hash: hex(outlier ^ 0b1))
        try addPhotoWithHash(harness.db, "p5", hash: hex(outlier ^ 0b11))
        try addPhotoWithHash(harness.db, "p6", hash: hex(base ^ 0b1111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)

        // 再跑一次：无变化时增量更新为幂等（版本递增、划分不变）。
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        let meta = try #require(try await harness.service.clusterVersion(sessionId: harness.sessionId))
        #expect(meta.version == 2)
        #expect(meta.incrementalUpdates == 1)

        let result = try #require(try await harness.service.getResult(sessionId: harness.sessionId))
        #expect(result.groups.count == 2)
        #expect(result.groups.map(\.count).sorted() == [3, 3])
    }
}
