// desktop/native/gather-core/Tests/GatherCoreTests/Services/SimilarityIncrementalServiceTests.swift
// 增量聚类的服务层接线（ROADMAP 1.3）：参数匹配 → 邻域增量（不调用全量聚类）、
// 版本号递增、连续增量计数、收敛间隔到期后的全量重聚类、阈值变化与 sequential
// 模式的退化路径。
//
// 夹具策略：为照片预置 checksum 尺寸/mtime 与 similarity_hashes 行，使 analyze
// 走 hash 复用路径（不触碰真实文件与解码），从而精确控制哈希与分量结构。

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

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
    let sessionRepo: SessionRepo
    let stateRepo: SimilarityClusterStateRepo
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

/// Cut 5 / 5b-2a：全量 provider 与生产默认同一入口（ClusterGraphPipeline 模式分发，
/// global 单趟 result+state 同源）；计数仍只加在“全量聚类”这一入口上
/// （增量路径不得触发）。
private func incrementalGraphCluster(
    _ entries: [HashEntry],
    _ threshold: Int,
    _ minGroupSize: Int,
    _ mode: HashGroupingMode,
    _ onProgress: ((Int, Int) -> Void)?
) throws -> ClusterGraphOutcome {
    try ClusterGraphPipeline.run(
        entries: entries, threshold: threshold,
        minGroupSize: minGroupSize, mode: mode, onProgress: onProgress)
}

private func makeIncrementalHarness(settings: [String: Double] = [:]) throws -> IncrementalHarness {
    let db = try makeTestDB()
    try insertSession(db, sessionId)
    let sessionRepo = SessionRepo(connection: db)
    let stateRepo = SimilarityClusterStateRepo(connection: db)
    let counter = ClusterCallCounter()
    let service = SimilarityService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        similarityResultRepo: SimilarityResultRepo(connection: db),
        clusterStateRepo: stateRepo,
        connection: db,
        getNumber: { key, defaultValue in settings[key] ?? defaultValue },
        thumbnailProvider: { _, _ in nil },
        clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
            counter.increment()
            return try incrementalGraphCluster(
                entries, threshold, minGroupSize, mode, onProgress
            )
        }
    )
    return IncrementalHarness(
        db: db, service: service, sessionRepo: sessionRepo,
        stateRepo: stateRepo, counter: counter, sessionId: sessionId
    )
}

private func hex(_ value: UInt64) -> String {
    let raw = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
}

/// state 行的隐式 rowid（普通 rowid 表；UPDATE 保留、DELETE+INSERT 会变）。
/// 用于观测“相同行不重写”：旧实现的 DELETE 全表重插会让所有 rowid 换代。
private func stateRowIDs(_ db: DBConnection) throws -> [String: Int64] {
    var ids: [String: Int64] = [:]
    for row in try db.prepare("""
        SELECT photo_id, rowid FROM similarity_cluster_state
        WHERE session_id = ? ORDER BY photo_id
      """).query([.text(sessionId)]) {
        guard let photoId = row[0].textValue, let rowid = row[1].intValue else { continue }
        ids[photoId] = rowid
    }
    return ids
}

/// state_write_audit 的写次数（INSERT/UPDATE/DELETE 触发器合计）。
private func stateWriteCount(_ db: DBConnection) throws -> Int {
    guard let value = try db.prepare("SELECT COUNT(*) FROM state_write_audit").get([])?[0].intValue else {
        return -1
    }
    return Int(value)
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
        let first = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(first.version == 1)
        #expect(first.incrementalUpdates == 0)
        #expect(first.memberCount == 4)
        #expect(first.paramThreshold == 10)
        #expect(first.groupingMode == "global")

        // 新增第二张邻域照片：必须走增量（不调用全量聚类），版本 +1、增量计数 +1。
        try addPhotoWithHash(harness.db, "p5", hash: hex(base ^ 0b111111))
        try await analyze(harness)
        #expect(harness.counter.count == 1, "增量路径不得调用全量聚类")
        let second = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(second.version == 2)
        #expect(second.incrementalUpdates == 1)
        #expect(second.memberCount == 5)

        // p4 是离群照片：新增 p5 后成组的是 {p1, p2, p3, p5}（4 张），p4 仍未成组。
        let result = try #require(try harness.service.getResult(sessionId: harness.sessionId))
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
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(meta.version == 2)
        #expect(meta.memberCount == 2)

        let result = try #require(try harness.service.getResult(sessionId: harness.sessionId))
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
        let result = try #require(try harness.service.getResult(sessionId: harness.sessionId))
        #expect(result.groups.count == 1)
        #expect(result.groups[0].count == 3)
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(meta.version == 2)
    }

    @Test("连续增量达到收敛间隔后自动全量重聚类并清零计数")
    func convergenceIntervalTriggersFullRecluster() async throws {
        let harness = try makeIncrementalHarness(settings: ["similarity_cluster_convergence_interval": 2])
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.incrementalUpdates == 0)

        try addPhotoWithHash(harness.db, "p3", hash: hex(base ^ 0b111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.incrementalUpdates == 1)

        try addPhotoWithHash(harness.db, "p4", hash: hex(base ^ 0b1111))
        try await analyze(harness)
        #expect(harness.counter.count == 1)
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.incrementalUpdates == 2)

        // 第三次增量：达到间隔 → 全量收敛，计数清零、版本继续递增。
        try addPhotoWithHash(harness.db, "p5", hash: hex(base ^ 0b11111))
        try await analyze(harness)
        #expect(harness.counter.count == 2, "达到收敛间隔应触发全量重聚类")
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
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
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.paramThreshold == 10)

        _ = try await harness.service.recluster(sessionId: harness.sessionId, threshold: 4, minGroupSize: 2)
        #expect(harness.counter.count == 2, "阈值变化必须全量重聚类")
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
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
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta != nil)

        try await harness.service.analyze(
            sessionId: harness.sessionId, threshold: 10, minGroupSize: 2, groupingMode: .sequential
        )
        #expect(harness.counter.count == 2)
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta == nil, "sequential 模式不保留增量状态")

        // 回到 global：状态缺失 → 全量重建。
        try await analyze(harness)
        #expect(harness.counter.count == 3)
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.groupingMode == "global")
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
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(meta.version == 2)
        #expect(meta.incrementalUpdates == 1)

        let result = try #require(try harness.service.getResult(sessionId: harness.sessionId))
        #expect(result.groups.count == 2)
        #expect(result.groups.map(\.count).sorted() == [3, 3])
    }

    /// Cut 5 / 5b-2a：服务落库的组序/组内序与簇状态，必须与直接调用唯一实现
    /// （ClusterGraphPipeline.run 的 result/state）逐位一致——锁的是服务层装配
    /// （路径映射 / JSON 往返 / 状态落库），算法本身由 fixture golden 锁定。
    @Test("单趟全量：落库结果/状态与 ClusterGraphPipeline 逐位一致")
    func singlePassOutcomeMatchesPipeline() async throws {
        let harness = try makeIncrementalHarness()
        let hashes: [(String, UInt64)] = [
            ("p1", base),
            ("p2", base ^ 0b11),
            ("p3", base ^ 0b1111),
            ("o1", outlier),
            ("o2", outlier ^ 0b1),
            ("o3", outlier ^ 0b11),
        ]
        for (id, value) in hashes {
            try addPhotoWithHash(harness.db, id, hash: hex(value))
        }
        try await analyze(harness)

        let entries = hashes.map { id, value in
            HashEntry(photoId: id, hash: hex(value))
        }
        let full = try ClusterGraphPipeline.run(
            entries: entries, threshold: 10, minGroupSize: 2
        )
        let expectedResult = full.result
        let expectedState = try #require(full.state, "global 全量必须产出 state")
        let expectedPaths = { (ids: [String]) in
            ids.map { id in "/tmp/fixtures/\(id).jpg" }
        }

        let result = try #require(try harness.service.getResult(sessionId: harness.sessionId))
        #expect(
            result.groups.map { group in group.images.map(\.path) }
                == expectedResult.groups.map(expectedPaths)
        )
        #expect(result.ungrouped.map(\.path) == expectedPaths(expectedResult.ungrouped))

        let snapshot = try #require(try harness.stateRepo.load(sessionId: harness.sessionId))
        #expect(snapshot.state == expectedState, "簇状态（分量/组序/组内序/hash）逐位一致")
    }

    /// Cut 5 / 5b-2a：多档预计算共享最高档并集行，每个档位的落库结果与直接调用
    /// ClusterGraphPipeline.runTiers 逐位一致（组序/组内序/未成组）。
    @Test("多档并集行：预计算档位结果与 runTiers 逐位一致")
    func precomputedTiersMatchPipelineTiers() async throws {
        let harness = try makeIncrementalHarness()
        let hashes: [(String, UInt64)] = [
            ("t1", base),
            ("t2", base ^ 0b1),
            ("t3", base ^ 0b1111),
            ("t4", base ^ 0b11111111),
            ("u1", outlier),
            ("u2", outlier ^ 0b11),
            ("u3", outlier ^ 0b111111),
            ("u4", 0x0F0F_0F0F_0F0F_0F0F),
        ]
        for (id, value) in hashes {
            try addPhotoWithHash(harness.db, id, hash: hex(value))
        }
        try await analyze(harness)

        let entries = hashes.map { id, value in
            HashEntry(photoId: id, hash: hex(value))
        }
        var savedTiers = Set<Int>([10])
        var tiers: [Int] = []
        for step in [8, 4, -4, -8] {
            let tier = max(0, min(30, 10 + step))
            if savedTiers.insert(tier).inserted { tiers.append(tier) }
        }
        let expectedTiers = try ClusterGraphPipeline.runTiers(
            entries: entries, thresholds: tiers, minGroupSize: 2
        )
        let expectedPaths = { (ids: [String]) in
            ids.map { id in "/tmp/fixtures/\(id).jpg" }
        }

        for (index, tier) in tiers.enumerated() {
            let result = try #require(
                try harness.service.getResult(sessionId: harness.sessionId, threshold: tier),
                "档位 \(tier) 必须已预计算"
            )
            #expect(result.stats.precomputed == true)
            #expect(
                result.groups.map { group in group.images.map(\.path) }
                    == expectedTiers[index].groups.map(expectedPaths),
                "档位 \(tier): groups 逐位一致"
            )
            #expect(
                result.ungrouped.map(\.path) == expectedPaths(expectedTiers[index].ungrouped),
                "档位 \(tier): ungrouped 逐位一致"
            )
        }
    }

    // MARK: - state 版本化 / 行级落库（Cut 5 / 5b-2b）

    @Test("落库状态带算法版本 / 参数指纹 / 内容摘要，且与快照一致")
    func persistedStateCarriesVersionSignatureDigest() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try await analyze(harness)

        let snapshot = try #require(try harness.stateRepo.load(sessionId: harness.sessionId))
        #expect(snapshot.meta.algorithmVersion == ClusterStateVersioning.currentAlgorithmVersion)
        #expect(snapshot.meta.inputSignature == ClusterStateVersioning.inputSignature(
            threshold: 10, minGroupSize: 2, groupingMode: "global"
        ))
        #expect(snapshot.meta.stateDigest == ClusterStateVersioning.stateDigest(snapshot.state))
    }

    @Test("algorithm_version 不符（旧实现落的 state）→ 失效：全量重算并覆盖版本")
    func mismatchedAlgorithmVersionInvalidatesState() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try await analyze(harness)
        #expect(harness.counter.count == 1)

        // 模拟旧 ClusterEngine / 未来版本落的行：阈值/组大小/模式全等，仅版本不符。
        _ = try harness.db.prepare("""
            UPDATE similarity_cluster_meta SET algorithm_version = 2 WHERE session_id = ?
          """).run([.text(harness.sessionId)])

        try await analyze(harness)
        #expect(harness.counter.count == 2, "版本不符必须走全量，不得增量复用旧分量")
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(meta.algorithmVersion == ClusterStateVersioning.currentAlgorithmVersion)
        #expect(meta.version == 2)
        #expect(meta.incrementalUpdates == 0, "全量覆盖后连续增量计数归零")
    }

    @Test("state_digest 被改坏 → 失效：全量重算并重写摘要")
    func mismatchedDigestInvalidatesState() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try await analyze(harness)

        _ = try harness.db.prepare("""
            UPDATE similarity_cluster_meta SET state_digest = 'fnv1a64:0000000000000000'
             WHERE session_id = ?
          """).run([.text(harness.sessionId)])

        try await analyze(harness)
        #expect(harness.counter.count == 2, "摘要不符必须走全量")
        let snapshot = try #require(try harness.stateRepo.load(sessionId: harness.sessionId))
        #expect(snapshot.meta.stateDigest == ClusterStateVersioning.stateDigest(snapshot.state))
        #expect(snapshot.meta.stateDigest != "fnv1a64:0000000000000000")
    }

    @Test("重复 apply 幂等：无变化再分析不重写 state 行（rowid 不变）")
    func repeatedApplyDoesNotRewriteRows() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try addPhotoWithHash(harness.db, "p3", hash: hex(base ^ 0b1111))
        try await analyze(harness)
        let firstRows = try stateRowIDs(harness.db)
        #expect(firstRows.count == 3)

        // 直接观测写：state 行的任何 INSERT/UPDATE/DELETE 都记进审计表。
        // 只靠 rowid 不够（同一事务里 DELETE 全表再按同序插入会复用 1..n 的
        // rowid），触发器能区分“真的没写”与“删了重插但行号碰巧相同”。
        try harness.db.exec("""
            CREATE TABLE state_write_audit (op TEXT NOT NULL);
            CREATE TRIGGER audit_state_insert AFTER INSERT ON similarity_cluster_state
            BEGIN INSERT INTO state_write_audit (op) VALUES ('insert'); END;
            CREATE TRIGGER audit_state_update AFTER UPDATE ON similarity_cluster_state
            BEGIN INSERT INTO state_write_audit (op) VALUES ('update'); END;
            CREATE TRIGGER audit_state_delete AFTER DELETE ON similarity_cluster_state
            BEGIN INSERT INTO state_write_audit (op) VALUES ('delete'); END;
            """)

        // 无输入变化：增量 update 产出的 state 与旧 state 逐行相同 → diff 为空。
        try await analyze(harness)
        #expect(harness.counter.count == 1, "无变化仍走增量")
        #expect(try stateRowIDs(harness.db) == firstRows, "相同行不得重写（DELETE 全表重插会换 rowid）")
        #expect(try stateWriteCount(harness.db) == 0, "相同行不得产生任何 state 写入")
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.version == 2)

        // 再 apply 一次同一状态：仍然只推进 meta 版本，不产生 state 行级写。
        try await analyze(harness)
        #expect(try stateRowIDs(harness.db) == firstRows)
        #expect(try stateWriteCount(harness.db) == 0)
        #expect(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta.version == 3)
    }

    @Test("全量覆盖也走行级 diff：参数变化但划分不变时 state 行不重写")
    func fullReclusterKeepsUnchangedRows() async throws {
        let harness = try makeIncrementalHarness()
        try addPhotoWithHash(harness.db, "p1", hash: hex(base))
        try addPhotoWithHash(harness.db, "p2", hash: hex(base ^ 0b11))
        try addPhotoWithHash(harness.db, "p3", hash: hex(outlier))
        try addPhotoWithHash(harness.db, "p4", hash: hex(outlier ^ 0b1))
        try await analyze(harness)
        let firstRows = try stateRowIDs(harness.db)
        #expect(firstRows.count == 4)

        // 阈值 10 → 4：参数指纹不符 → 全量；两簇划分不变 → diff 为空。
        _ = try await harness.service.recluster(
            sessionId: harness.sessionId, threshold: 4, minGroupSize: 2
        )
        #expect(harness.counter.count == 2, "阈值变化必须全量重聚类")
        #expect(try stateRowIDs(harness.db) == firstRows, "全量覆盖相同划分时也不得 DELETE 全表重插")
        let meta = try #require(try harness.stateRepo.load(sessionId: harness.sessionId)?.meta)
        #expect(meta.paramThreshold == 4)
        #expect(meta.version == 2)
    }
}
