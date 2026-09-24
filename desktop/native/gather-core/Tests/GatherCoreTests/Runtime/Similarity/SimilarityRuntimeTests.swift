// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Similarity/SimilarityRuntimeTests.swift
// W2c：SimilarityRuntime 行为测试 —— 承接旧 SimilarityServiceTests 的
// - run 记录 3 用例（running 行 / 失败终态 / index_seq 快照）；
// - hasResult 存在性 1 用例；
// - getResult 装配 3 用例（成员表 / 旧 groups_json / 阈值档回退）；
// 并新增校验失败不泄漏 flight 的断言（设计 §1.1 ②）。
//
// 差异说明（与旧测试逐条对应）：
// - TS 用 vi.mock 替换 worker/hash 模块；Swift 侧经 Providers.thumbnail /
//   Providers.cluster 注入（返回 9x8 灰度像素）。
// - 真实库统一用 makeMigratedStore(path:)（Store schema）。
// - in-flight 观测用轮询等待而非固定 sleep（工具链决议 #4）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 支撑

/// 9x8 均匀灰度像素网格（DHash 输出 64 个 0）。
let simRuntimeUniformPixels = [UInt8](repeating: 128, count: 72)

/// 一次性异步闸门（actor 化；released 后所有等待立即返回）。
actor SimRuntimeGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// 轮询等待条件成立（swift-testing 并行下 Task 调度延迟明显，避免固定 sleep）。
func simRuntimeWaitUntil(timeoutMs: Double = 5000, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutMs / 1000)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// 后台操作结果（限时观测；任何等待都有上界，测试失败而非永久挂起）。
enum SimRuntimeOutcome: Equatable {
    case succeeded
    case failed(String)

    var failedDescription: String? {
        if case let .failed(description) = self { return description }
        return nil
    }
}

/// 任务完成标记（actor；配合 simRuntimeWaitUntil 做限时等待）。
actor SimRuntimeTaskTracker {
    private var outcome: SimRuntimeOutcome?

    func succeed() { outcome = .succeeded }
    func fail(_ description: String) { outcome = .failed(description) }
    var value: SimRuntimeOutcome? { outcome }

    /// 启动一个后台操作并在此 tracker 上记录结果（调用方限时观测）。
    static func track(_ operation: @escaping @Sendable () async throws -> Void) -> SimRuntimeTaskTracker {
        let tracker = SimRuntimeTaskTracker()
        Task {
            do {
                try await operation()
                await tracker.succeed()
            } catch {
                await tracker.fail(String(describing: error))
            }
        }
        return tracker
    }
}

/// 限时等待 tracker 完成；超时返回 nil（不让测试进程挂起）。
func simRuntimeAwaitTracker(
    _ tracker: SimRuntimeTaskTracker,
    timeoutMs: Double = 8000
) async -> SimRuntimeOutcome? {
    guard await simRuntimeWaitUntil(timeoutMs: timeoutMs, { await tracker.value != nil }) else {
        return nil
    }
    return await tracker.value
}

/// 运行一个操作并限时等待结果；超时返回 nil。
func simRuntimeRunOutcome(
    timeoutMs: Double = 8000,
    _ operation: @escaping @Sendable () async throws -> Void
) async -> SimRuntimeOutcome? {
    await simRuntimeAwaitTracker(SimRuntimeTaskTracker.track(operation), timeoutMs: timeoutMs)
}

struct SimRuntimeHarness {
    let db: SQLiteDatabase
    let dbPath: String
    let runtime: SimilarityRuntime
    let sessionStore: any SessionStore
    let sessionId: String
    let photoPath: String
}

/// 建真实照片文件 + 已迁移库 + actor（文件必须存在：analyze 的 stat 兜底路径）。
/// sessionStoreWrap 用于注入测试用 SessionStore 包装（闸门）。
func simRuntimeMakeHarness(
    thumbnail: @escaping SimilarityRuntime.ThumbnailProvider = { _, _ in simRuntimeUniformPixels },
    cluster: @escaping SimilarityRuntime.ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
        try ClusterEngine.clusterByHash(
            entries: entries, threshold: threshold, minGroupSize: minGroupSize,
            mode: mode, onProgress: onProgress)
    },
    multiCluster: @escaping SimilarityRuntime.MultiClusterProvider = { entries, thresholds, minGroupSize, mode, onProgress in
        try ClusterEngine.clusterByHashMulti(
            entries: entries, thresholds: thresholds, minGroupSize: minGroupSize,
            mode: mode, onProgress: onProgress)
    },
    settings: [String: Double] = [:],
    sessionStoreWrap: ((any SessionStore) -> any SessionStore)? = nil
) async throws -> SimRuntimeHarness {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-similarity-rt-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedStore(path: dbPath)
    let baseSessionStore = SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
    let sessionStore: any SessionStore = sessionStoreWrap?(baseSessionStore) ?? baseSessionStore
    let session = try await sessionStore.create(name: "Run", source: "folder", sourcePath: "", truncatedImport: false)
    let dir = try makeTempDir()
    let photoPath = try writeTempFile(in: dir, name: "photo.jpg")
    try await insertPhoto(db, id: "photo-1", sessionId: session.id, filepath: photoPath)

    let runtime = SimilarityRuntime(
        dependencies: SimilarityRuntime.Dependencies(
            photoStore: SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
            sessionStore: sessionStore,
            similarityStore: SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath)),
            jobStore: SQLiteJobStore(database: try SQLiteDatabase(path: dbPath)),
            getNumber: { key, defaultValue in settings[key] ?? defaultValue }
        ),
        providers: SimilarityRuntime.Providers(
            thumbnail: thumbnail, cluster: cluster, multiCluster: multiCluster
        )
    )
    return SimRuntimeHarness(
        db: db, dbPath: dbPath, runtime: runtime,
        sessionStore: sessionStore, sessionId: session.id, photoPath: photoPath
    )
}

/// 建一个只读路径用的 runtime（getResult / hasResult 用例）。
func simRuntimeMakeRuntime(databasePath: String, settings: [String: Double] = [:]) throws -> SimilarityRuntime {
    SimilarityRuntime(
        dependencies: SimilarityRuntime.Dependencies(
            photoStore: SQLitePhotoStore(database: try SQLiteDatabase(path: databasePath)),
            sessionStore: SQLiteSessionStore(database: try SQLiteDatabase(path: databasePath)),
            similarityStore: SQLiteSimilarityStore(database: try SQLiteDatabase(path: databasePath)),
            jobStore: SQLiteJobStore(database: try SQLiteDatabase(path: databasePath)),
            getNumber: { key, defaultValue in settings[key] ?? defaultValue }
        )
    )
}

/// 最近一条 run 行（列序：kind, photo_count, index_seq, params, started_at, finished_at, status）。
func simRuntimeRunRow(_ db: SQLiteDatabase, _ sessionId: String) async throws -> SQLiteRow? {
    try await db.queryOne(
        """
        SELECT kind, photo_count, index_seq, params, started_at, finished_at, status
        FROM analysis_runs WHERE session_id = ? ORDER BY id DESC LIMIT 1
        """,
        [.text(sessionId)]
    )
}

struct SimRuntimeRunRecord: Equatable {
    let id: Int64
    let status: String
    let finishedAt: String
    let indexSeq: Int
}

func simRuntimeRunRecords(_ db: SQLiteDatabase, _ sessionId: String) async throws -> [SimRuntimeRunRecord] {
    try await db.query(
        "SELECT id, status, finished_at, index_seq FROM analysis_runs WHERE session_id = ? ORDER BY id",
        [.text(sessionId)]
    ).map {
        SimRuntimeRunRecord(
            id: $0.int(at: 0) ?? 0,
            status: $0.text(at: 1) ?? "",
            finishedAt: $0.text(at: 2) ?? "",
            indexSeq: Int($0.int(at: 3) ?? 0)
        )
    }
}

/// 等 run 行状态（Store 查询为 async）。
func simRuntimeWaitForAnalysisRunStatus(
    _ harness: SimRuntimeHarness,
    _ expected: String,
    timeoutMs: Double = 4000
) async -> Bool {
    await simRuntimeWaitUntil(timeoutMs: timeoutMs) {
        guard let row = try? await simRuntimeRunRow(harness.db, harness.sessionId) else { return false }
        return row.text(at: 6) == expected
    }
}

/// 等会话 analysis_status。
func simRuntimeWaitForSessionStatus(
    _ harness: SimRuntimeHarness,
    _ expected: String,
    timeoutMs: Double = 4000
) async -> Bool {
    await simRuntimeWaitUntil(timeoutMs: timeoutMs) {
        guard let record = try? await harness.sessionStore.get(id: harness.sessionId) else { return false }
        return record.analysisStatus == expected
    }
}

// MARK: - flight 生命周期（校验失败不泄漏占用）

@Suite("SimilarityRuntime flight registration")
struct SimilarityRuntimeFlightRegistrationTests {
    @Test("invalid parameters do not leak the flight and corrupt settings never crash")
    func invalidParametersDoNotLeakFlight() async throws {
        // 畸形设置（NaN）：校验抛错而非 Int(NaN) 陷阱，且不留下 flight。
        let harness = try await simRuntimeMakeHarness(settings: ["default_threshold": .nan])

        await #expect(throws: SimilarityError.thresholdInvalid) {
            try await harness.runtime.analyze(sessionId: harness.sessionId)
        }
        // 占用已释放：合法参数可以进入并完成。
        await #expect(throws: Never.self) {
            try await harness.runtime.analyze(sessionId: harness.sessionId, threshold: 10, minGroupSize: 2)
        }
        #expect(try await harness.sessionStore.get(id: harness.sessionId)?.analysisStatus == "done")

        // 非法参数同样不泄漏占用（校验先于注册）。
        await #expect(throws: SimilarityError.minGroupInvalid) {
            try await harness.runtime.analyze(sessionId: harness.sessionId, threshold: 10, minGroupSize: 1)
        }
        await #expect(throws: Never.self) {
            try await harness.runtime.analyze(sessionId: harness.sessionId, threshold: 8, minGroupSize: 2)
        }
    }
}

// MARK: - analyze run 记录

@Suite("SimilarityRuntime analysis run records")
struct SimilarityRuntimeRunRecordTests {
    @Test("writes a running row at entry with the snapshot and finalizes it to ok")
    func writesRunningRowThenFinalizesOk() async throws {
        let gate = SimRuntimeGate()
        let harness = try await simRuntimeMakeHarness(thumbnail: { _, _ in
            await gate.wait()
            return simRuntimeUniformPixels
        })

        // 以缩略图解码阻塞分析，观测 in-flight run 行后再放行（SEAM：run 行
        // 先于解码管线插入、完成后终态——断言窗口即载荷证明）。
        let runtime = harness.runtime
        let sessionId = harness.sessionId
        let tracker = SimRuntimeTaskTracker.track {
            try await runtime.analyze(
                sessionId: sessionId, threshold: 10, minGroupSize: 2, groupingMode: .global
            )
        }

        let runningSeen = await simRuntimeWaitForAnalysisRunStatus(harness, "running")
        #expect(runningSeen)
        let runningRow = try await simRuntimeRunRow(harness.db, harness.sessionId)
        let running = try #require(runningRow)
        #expect(running.text(at: 0) == "similarity")
        #expect(running.int(at: 1) == 1)
        #expect(running.int(at: 2) == 0)
        #expect(running.text(at: 3) != "")
        #expect(running.text(at: 4) != "")  // started_at
        #expect(running.text(at: 5) == "")  // finished_at 仍空
        let params = try JSONValue.parse(running.text(at: 3) ?? "{}")
        #expect(params["threshold"] == .number(10))
        #expect(params["minGroupSize"] == .number(2))
        #expect(params["groupingMode"] == .string("global"))

        await gate.release()
        #expect(await simRuntimeAwaitTracker(tracker) == .succeeded)

        let finalizedRow = try await simRuntimeRunRow(harness.db, harness.sessionId)
        let finalized = try #require(finalizedRow)
        #expect(finalized.text(at: 6) == "ok")
        #expect(finalized.text(at: 5) != "")
    }

    @Test("finalizes the run as failed and rethrows when clustering fails")
    func finalizesFailedOnClusterError() async throws {
        let harness = try await simRuntimeMakeHarness(cluster: { _, _, _, _, _ in
            struct ClusterBoom: Error {}
            throw ClusterBoom()
        })

        await #expect(throws: (any Error).self) {
            try await harness.runtime.analyze(sessionId: harness.sessionId)
        }

        let failedRow = try await simRuntimeRunRow(harness.db, harness.sessionId)
        let row = try #require(failedRow)
        #expect(row.text(at: 6) == "failed")
        #expect(row.text(at: 5) != "")
        let session = try await harness.sessionStore.get(id: harness.sessionId)
        #expect(session?.analysisStatus == "failed")
    }

    @Test("records the index_seq snapshot from the session cursor")
    func recordsIndexSeqSnapshot() async throws {
        let harness = try await simRuntimeMakeHarness()
        _ = try await harness.sessionStore.bumpIndexSeq(id: harness.sessionId)

        try await harness.runtime.analyze(sessionId: harness.sessionId)

        let okRow = try await simRuntimeRunRow(harness.db, harness.sessionId)
        let row = try #require(okRow)
        #expect(row.int(at: 2) == 1)
        #expect(row.text(at: 6) == "ok")
    }
}

// MARK: - getResult 惰性组装

@Suite("SimilarityRuntime.getResult lazy group assembly")
struct SimilarityRuntimeGetResultTests {
    private func seedSessionRow(_ db: SQLiteDatabase, _ sessionId: String) async throws {
        _ = try await db.run("""
            INSERT OR IGNORE INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
            VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(sessionId)])
    }

    private func seedAssetRow(_ db: SQLiteDatabase, _ id: String) async throws {
        _ = try await db.run("""
            INSERT OR IGNORE INTO assets (id, capture_fingerprint, status, created_at, updated_at)
            VALUES (?, '', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(id)])
    }

    private func seedAssetFileRow(_ db: SQLiteDatabase, _ id: String) async throws {
        try await seedAssetRow(db, id)
        _ = try await db.run("""
            INSERT OR IGNORE INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES (?, 'dev:1', '', ?, ?, '', 'unknown', 0, 0, '', 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(id), .text("/vault/\(id).NEF"), .text("\(id).NEF")])
    }

    private func addPhoto(
        _ db: SQLiteDatabase,
        _ id: String,
        _ sessionId: String,
        _ filepath: String,
        _ assetId: String?
    ) async throws {
        try await seedSessionRow(db, sessionId)
        if let assetId {
            try await seedAssetRow(db, assetId)
        }
        try await seedAssetFileRow(db, "af-\(id)")
        _ = try await db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
              result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'pending', '{"make":"Nikon"}', '{"sharpness":1}',
              ?, ?, 100, 100, '2025-01-01T00:00:00.000Z', '2025-01-01T00:00:00.000Z')
          """, [
            .text(id), .text(sessionId), .text(filepath),
            .text(filepath.split(separator: "/").last.map(String.init) ?? id),
            .text("checksum-\(id)"),
            assetId.map { .text($0) } ?? .null, .text("af-\(id)"),
        ])
    }

    @Test("assembles groups from the members table without parsing groups_json")
    func assemblesGroupsFromMembers() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-rt-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try await addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try await addPhoto(db, "a.raw", "session", "/shoot/a.RAW", "asset-a")
        try await addPhoto(db, "a.jpg", "session", "/shoot/a.jpg", "asset-a")
        try await addPhoto(db, "s", "session", "/shoot/s.jpg", nil)
        try await addPhoto(db, "c.raw", "session", "/shoot/c.RAW", "asset-c")
        try await addPhoto(db, "c.jpg", "session", "/shoot/c.jpg", "asset-c")

        let runtime = try simRuntimeMakeRuntime(databasePath: dbPath)

        // 成员按序写入：组 0 成员在前，组 1 在后。
        _ = try await similarityStore.replaceResult(
            sessionId: "session",
            // 垃圾 JSON 证明成员路径从不解析 groups_json。
            groupsJson: "NOT VALID JSON",
            statsJson: """
            {"totalGroups":2,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"global"}
            """,
            threshold: 10,
            minGroupSize: 2,
            memberships: [
                SimilarityMembership(photoId: "p1", groupIndex: 0),
                SimilarityMembership(photoId: "a.raw", groupIndex: 0),
                SimilarityMembership(photoId: "s", groupIndex: 1),
            ]
        )

        let result = try await runtime.getResult(sessionId: "session")

        #expect(result != nil)
        #expect(result!.groups.map(\.id) == [1, 2])
        #expect(result!.groups == [
            SimilarityGroup(id: 1, label: "Group 1", count: 2, images: [
                SimilarityImage(path: "/shoot/p1.jpg", representative: true),
                SimilarityImage(path: "/shoot/a.RAW", representative: false),
            ]),
            SimilarityGroup(id: 2, label: "Group 2", count: 1, images: [
                SimilarityImage(path: "/shoot/s.jpg", representative: true),
            ]),
        ])
        // Ungrouped 镜像 analyze：折叠资产（RAW 优先）减成员表，asset-c 的
        // JPEG 变体被排除。
        #expect(result!.ungrouped == [SimilarityImage(path: "/shoot/c.RAW")])
        #expect(result!.stats.totalGroups == 2)
        #expect(result!.stats.totalUngrouped == 1)
        #expect(result!.stats.threshold == 10)
        #expect(result!.stats.minGroupSize == 2)
        #expect(result!.stats.groupingMode == .global)
        #expect(result!.stats.precomputed == false)
    }

    @Test("keeps the legacy groups_json path for rows without members")
    func legacyGroupsJsonPath() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-rt-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        try await addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        _ = try await db.run("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', ?, ?, 10, 2, '2025-01-01T00:00:00.000Z')
          """, [
            .text("""
            {"groups":[{"id":1,"label":"Group 1","count":2,"images":[
              {"path":"/shoot/p1.jpg","representative":true},
              {"path":"/shoot/legacy.jpg","representative":false}]}],
             "ungrouped":[{"path":"/shoot/alone.jpg"}]}
            """),
            .text("""
            {"totalGroups":1,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"sequential"}
            """),
        ])
        let runtime = try simRuntimeMakeRuntime(databasePath: dbPath)

        let result = try await runtime.getResult(sessionId: "session")

        // 旧行（无成员）逐字解析 groups_json。
        #expect(result != nil)
        #expect(result!.groups[0].images == [
            SimilarityImage(path: "/shoot/p1.jpg", representative: true),
            SimilarityImage(path: "/shoot/legacy.jpg", representative: false),
        ])
        #expect(result!.ungrouped == [SimilarityImage(path: "/shoot/alone.jpg")])
        #expect(result!.stats.groupingMode == .sequential)
        #expect(result!.stats.precomputed == false)
    }

    @Test("resolves threshold tiers without regressing the default row")
    func resolvesThresholdTiers() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-rt-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try await addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try await addPhoto(db, "p2", "session", "/shoot/p2.jpg", nil)
        let runtime = try simRuntimeMakeRuntime(databasePath: dbPath)

        _ = try await similarityStore.replaceResult(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1,\"totalUngrouped\":1,\"threshold\":10,\"minGroupSize\":2,\"groupingMode\":\"global\"}",
            threshold: 10, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p1", groupIndex: 0)]
        )
        _ = try await similarityStore.replaceResultForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1,\"totalUngrouped\":1,\"threshold\":6,\"minGroupSize\":2,\"groupingMode\":\"global\",\"precomputed\":true}",
            threshold: 6, minGroupSize: 2,
            memberships: [SimilarityMembership(photoId: "p2", groupIndex: 0)]
        )

        let main = try await runtime.getResult(sessionId: "session")
        #expect(main?.stats.threshold == 10)
        #expect(main?.stats.precomputed == false)
        #expect(main?.groups[0].images.map(\.path) == ["/shoot/p1.jpg"])

        let tier = try await runtime.getResult(sessionId: "session", threshold: 6)
        #expect(tier?.stats.threshold == 6)
        #expect(tier?.stats.precomputed == true)
        #expect(tier?.groups[0].images.map(\.path) == ["/shoot/p2.jpg"])

        #expect(try await runtime.getResult(sessionId: "session", threshold: 99) == nil)
    }

    @Test("hasResult stays a cheap existence check")
    func hasResultExistence() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-rt-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try await seedSessionRow(db, "session")
        let runtime = try simRuntimeMakeRuntime(databasePath: dbPath)

        #expect(try await runtime.hasResult(sessionId: "session") == false)
        _ = try await similarityStore.replaceResult(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )
        #expect(try await runtime.hasResult(sessionId: "session") == true)
        _ = try await similarityStore.replaceResultForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"precomputed\":true}", threshold: 6, minGroupSize: 2, memberships: []
        )
        #expect(try await runtime.hasResult(sessionId: "session", threshold: 6) == true)
        #expect(try await runtime.hasResult(sessionId: "session", threshold: 7) == false)
    }

    @Test("getResult throws on corrupt stored stats like TS JSON.parse")
    func getResultThrowsOnCorruptStats() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-rt-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        try await seedSessionRow(db, "session")
        _ = try await db.run("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', '{"groups":[]}', 'NOT VALID JSON', 10, 2, '2025-01-01T00:00:00.000Z')
          """)
        let runtime = try simRuntimeMakeRuntime(databasePath: dbPath)

        await #expect(throws: (any Error).self) {
            try await runtime.getResult(sessionId: "session")
        }
    }
}
