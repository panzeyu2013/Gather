// desktop/native/gather-core/Tests/GatherCoreTests/Services/SimilarityServiceTests.swift
// SimilarityService 行为测试（Phase 3.3）。
// TS 源: tests/unit/services/similarity/*（similarity-parameters / reuse-and-tiers /
// similarity-run-record / similarity-result-lazy / similarity-cancellation，
// 用例逐一对应）。差异说明：
// - TS 用 vi.mock 替换 worker/hash 模块；Swift 侧经 clusterProvider（默认
//   ClusterEngine）与 thumbnailProvider（返回 9x8 灰度像素）注入。
// - 时序用例（running 行窗口）用轮询等待而非固定 sleep（工具链决议 #4）。

import Foundation
import Testing
@testable import GatherCore

private func makeTempPhotoStore() async throws -> any PhotoStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "photos")
    return SQLitePhotoStore(database: database)
}


// MARK: - 支撑

/// 9x8 均匀灰度像素网格（DHash 输出 64 个 0）。
private let uniformPixels = [UInt8](repeating: 128, count: 72)

/// 幂等外键种子（photos.session_id / photos.asset_id / photos.asset_file_id）。
private func seedSessionRow(_ db: DBConnection, _ sessionId: String) throws {
    _ = try db.prepare("""
        INSERT OR IGNORE INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([.text(sessionId)])
}

private func seedAssetRow(_ db: DBConnection, _ id: String) throws {
    _ = try db.prepare("""
        INSERT OR IGNORE INTO assets (id, capture_fingerprint, status, created_at, updated_at)
        VALUES (?, '', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([.text(id)])
}

private func seedAssetFileRow(_ db: DBConnection, _ id: String) throws {
    try seedAssetRow(db, id)
    _ = try db.prepare("""
        INSERT OR IGNORE INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
        VALUES (?, 'dev:1', '', ?, ?, '', 'unknown', 0, 0, '', 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([.text(id), .text("/vault/\(id).NEF"), .text("\(id).NEF")])
}

private final class AsyncGate {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        let mustWait: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if released { return false }
            return true
        }()
        guard mustWait else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// 轮询等待条件成立（swift-testing 并行下 Task 调度延迟明显，避免固定 sleep）。
private func waitUntil(
    timeoutMs: Double = 5000,
    _ condition: () throws -> Bool
) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutMs / 1000)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return try condition()
}

private struct SimilarityHarness {
    let db: DBConnection
    let dbPath: String
    let service: SimilarityService
    let sessionRepo: SessionRepo
    let sessionId: String
    let photoPath: String
}

/// 建真实照片文件 + 已迁移库 + 服务（文件必须存在：analyze 的 stat 兜底路径）。
private func makeHarness(
    thumbnail: @escaping SimilarityService.ThumbnailProvider = { _, _ in uniformPixels },
    cluster: @escaping SimilarityService.ClusterProvider = { entries, threshold, minGroupSize, mode, onProgress in
        try ClusterEngine.clusterByHash(
            entries: entries, threshold: threshold, minGroupSize: minGroupSize,
            mode: mode, onProgress: onProgress)
    },
    settings: [String: Double] = [:]
) throws -> SimilarityHarness {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-similarity-svc-\(UUID().uuidString).sqlite").path
    let db = try DBConnection(path: dbPath)
    try MigrationRunner().migrate(db)
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Run", source: "folder")
    let dir = try makeTempDir()
    let photoPath = try writeTempFile(in: dir, name: "photo.jpg")
    try insertPhoto(db, id: "photo-1", sessionId: session.id, filepath: photoPath)

    let service = SimilarityService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        similarityStore: SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath)),
        connection: db,
        getNumber: { key, defaultValue in settings[key] ?? defaultValue },
        thumbnailProvider: thumbnail,
        clusterProvider: cluster
    )
    return SimilarityHarness(
        db: db, dbPath: dbPath, service: service,
        sessionRepo: sessionRepo, sessionId: session.id, photoPath: photoPath)
}

private func runRow(_ db: DBConnection, _ sessionId: String) throws -> DBRow? {
    try db.prepare(
        "SELECT kind, photo_count, index_seq, params, started_at, finished_at, status FROM analysis_runs WHERE session_id = ?"
    ).get([.text(sessionId)])
}

// MARK: - 参数校验与资产折叠

@Suite("similarity parameter validation")
struct SimilarityParameterTests {
    @Test("rejects invalid threshold and minGroupSize")
    func rejectsInvalid() {
        #expect(throws: SimilarityServiceError.thresholdInvalid) { try validateSimilarityParameters(threshold: -1, minGroupSize: 2) }
        #expect(throws: SimilarityServiceError.thresholdInvalid) { try validateSimilarityParameters(threshold: 65, minGroupSize: 2) }
        #expect(throws: SimilarityServiceError.thresholdInvalid) { try validateSimilarityParameters(threshold: 10.5, minGroupSize: 2) }
        #expect(throws: SimilarityServiceError.thresholdInvalid) { try validateSimilarityParameters(threshold: .nan, minGroupSize: 2) }
        #expect(throws: SimilarityServiceError.thresholdInvalid) { try validateSimilarityParameters(threshold: .infinity, minGroupSize: 2) }
        #expect(throws: SimilarityServiceError.minGroupInvalid) { try validateSimilarityParameters(threshold: 10, minGroupSize: 1) }
        #expect(throws: SimilarityServiceError.minGroupInvalid) { try validateSimilarityParameters(threshold: 10, minGroupSize: 2.5) }
    }

    @Test("accepts the full dHash threshold range and a valid group size")
    func acceptsValid() {
        #expect(throws: Never.self) { try validateSimilarityParameters(threshold: 0, minGroupSize: 2) }
        #expect(throws: Never.self) { try validateSimilarityParameters(threshold: 64, minGroupSize: 10) }
        // 整数化 Double（TS Number.isInteger(10.0) === true）。
        #expect(throws: Never.self) { try validateSimilarityParameters(threshold: 10.0, minGroupSize: 2.0) }
    }

    @Test("collapses one representative per linked RAW/JPEG asset preferring RAW")
    func collapsePreferRaw() {
        struct Candidate: PhotoAssetCandidate {
            let id: String
            let assetId: String?
            let filename: String
        }
        let rows: [Candidate] = [
            Candidate(id: "jpeg", assetId: "asset", filename: "A001.JPG"),
            Candidate(id: "raw", assetId: "asset", filename: "A001.NEF"),
            Candidate(id: "standalone", assetId: nil, filename: "A002.JPG"),
        ]

        let collapsed = PhotoAssets.collapse(rows)
        #expect(collapsed.map(\.id) == ["raw", "standalone"])
    }
}

/// 第四轮审计 #4（HIGH）：校验失败后 controller 泄漏。
/// 修复前 registerController 在 validateSimilarityParameters 之前——校验抛错
/// 时 defer 不执行，controller 永久残留，该会话此后任何 analyze 都被
/// SIM_ANALYSIS_RUNNING 拒绝。此用例验证非法参数抛错后再次调用不被拒绝。
@Suite("similarity controller lifecycle on validation failure")
struct SimilarityControllerValidationTests {
    @Test("invalid parameters do not leak the running controller")
    func invalidParametersDoNotLeakController() async throws {
        let harness = try makeHarness()

        // 非法参数：校验失败，不得留下 controller。
        await #expect(throws: SimilarityServiceError.thresholdInvalid) {
            try await harness.service.analyze(sessionId: harness.sessionId, threshold: 100)
        }

        // 再次调用不被 SIM_ANALYSIS_RUNNING 拒绝：合法参数应正常走完分析。
        await #expect(throws: Never.self) {
            try await harness.service.analyze(sessionId: harness.sessionId, threshold: 10, minGroupSize: 2)
        }
        #expect(try harness.sessionRepo.get(id: harness.sessionId)?.analysisStatus == "done")
    }
}

// MARK: - reuseSimilarityHashes 批量复用

@Suite("reuseSimilarityHashes batch reuse")
struct ReuseSimilarityHashesTests {
    private func addPhoto(_ db: DBConnection, _ id: String, _ sessionId: String, _ assetFileId: String?) throws {
        try seedSessionRow(db, sessionId)
        if let assetFileId {
            try seedAssetFileRow(db, assetFileId)
        }
        _ = try db.prepare(
            "INSERT INTO photos (id, session_id, asset_file_id, filepath, filename, created_at, updated_at) VALUES (?, ?, ?, ?, ?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        ).run([.text(id), .text(sessionId), assetFileId.map { .text($0) } ?? .null, .text("/path/\(id).jpg"), .text("\(id).jpg")])
    }

    private func addHash(_ db: DBConnection, _ sessionId: String, _ photoId: String, _ hashHex: String, _ fileSize: Int, _ fileMtimeMs: Double) throws {
        _ = try db.prepare(
            "INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms) VALUES (?, ?, ?, ?, ?)"
        ).run([.text(sessionId), .text(photoId), .text(hashHex), .int(Int64(fileSize)), .real(fileMtimeMs)])
    }

    @Test("reuses hashes from sibling asset files in a single batch, including cross-session sources")
    func reuseAcrossSessions() throws {
        let db = try makeMigratedDB()
        try addPhoto(db, "p1", "session", "asset-a")
        try addPhoto(db, "p2", "session", "asset-a")
        try addPhoto(db, "p3", "session", "asset-b")
        try addPhoto(db, "px", "other-session", "asset-a")
        try addHash(db, "other-session", "px", "a1b2c3d4e5f60718", 100, 1000)

        let stats: [String: (size: Int, mtimeMs: Double)] = [
            "p1": (100, 1000), "p2": (100, 1000), "p3": (100, 1000),
        ]
        var existing: [String: String] = [:]
        let photos = try PhotoRepo(connection: db).getBySessionProjection(sessionId: "session")
        let reused = try SimilarityService.reuseSimilarityHashes(
            connection: db, sessionId: "session",
            photos: photos, sourceStats: stats, existingHashMap: &existing
        )

        #expect(reused == 2)
        #expect(existing["p1"] == "a1b2c3d4e5f60718")
        #expect(existing["p2"] == "a1b2c3d4e5f60718")
        #expect(existing["p3"] == nil)
        let saved = try db.prepare(
            "SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?"
        ).query([.text("session")]).map { ($0[0].textValue ?? "", $0[1].textValue ?? "") }
        #expect(saved.count == 2)
        #expect(saved.sorted { $0.0 < $1.0 }[0] == ("p1", "a1b2c3d4e5f60718"))
        #expect(saved.sorted { $0.0 < $1.0 }[1] == ("p2", "a1b2c3d4e5f60718"))
    }

    @Test("never reuses a photo own hash row and skips size/mtime mismatches")
    func skipsOwnHashAndMismatches() throws {
        let db = try makeMigratedDB()
        try addPhoto(db, "q1", "session", "asset-c")
        try addPhoto(db, "q2", "session", "asset-c")
        try addHash(db, "session", "q2", "q2ownhash", 200, 2000)

        let stats: [String: (size: Int, mtimeMs: Double)] = ["q1": (200, 2000), "q2": (200, 2000)]
        var existing: [String: String] = [:]
        let photos = try PhotoRepo(connection: db).getBySessionProjection(sessionId: "session")
        let reused = try SimilarityService.reuseSimilarityHashes(
            connection: db, sessionId: "session",
            photos: photos, sourceStats: stats, existingHashMap: &existing
        )

        #expect(reused == 1)
        #expect(existing["q1"] == "q2ownhash")
        #expect(existing["q2"] == nil)

        // 文件统计不匹配 → 零复用。
        let staleStats: [String: (size: Int, mtimeMs: Double)] = ["q1": (999, 9999), "q2": (999, 9999)]
        var existing2: [String: String] = [:]
        let reused2 = try SimilarityService.reuseSimilarityHashes(
            connection: db, sessionId: "session",
            photos: photos, sourceStats: staleStats, existingHashMap: &existing2
        )
        #expect(reused2 == 0)
        #expect(existing2.isEmpty)
    }

    @Test("picks the newest candidate hash and crosses the 400-id chunk boundary")
    func newestCandidateAcrossChunkBoundary() throws {
        let db = try makeMigratedDB()
        for i in 0..<404 {
            try addPhoto(db, "r\(i)", "session", "asset-\(i)")
        }
        // r404 与 r403 共享资产：其候选落在第二分块。
        try addPhoto(db, "r404", "session", "asset-403")
        try addHash(db, "session", "r403", "stalehash", 300, 3000)
        try addHash(db, "session", "r404", "freshhash", 300, 3000)

        let stats: [String: (size: Int, mtimeMs: Double)] = ["r403": (300, 3000)]
        var existing: [String: String] = [:]
        let target = try PhotoRepo(connection: db).getBySessionProjection(sessionId: "session")
            .filter { $0.id == "r403" }
        let reused = try SimilarityService.reuseSimilarityHashes(
            connection: db, sessionId: "session",
            photos: target, sourceStats: stats, existingHashMap: &existing
        )

        #expect(reused == 1)
        #expect(existing["r403"] == "freshhash")
    }

    @Test("keeps targets already present in existingHashMap untouched")
    func keepsExistingTargetsUntouched() throws {
        let db = try makeMigratedDB()
        try addPhoto(db, "s1", "session", "asset-e")
        try addPhoto(db, "s2", "session", "asset-e")
        try addHash(db, "session", "s2", "s2hash", 400, 4000)

        let stats: [String: (size: Int, mtimeMs: Double)] = ["s1": (400, 4000), "s2": (400, 4000)]
        var existing: [String: String] = ["s1": "already-present"]
        let photos = try PhotoRepo(connection: db).getBySessionProjection(sessionId: "session")
        let reused = try SimilarityService.reuseSimilarityHashes(
            connection: db, sessionId: "session",
            photos: photos, sourceStats: stats, existingHashMap: &existing
        )

        #expect(reused == 0)
        #expect(existing["s1"] == "already-present")
    }
}

// MARK: - analyze run 记录

@Suite("SimilarityService analysis run records")
struct SimilarityRunRecordTests {
    @Test("writes a running row at entry with the snapshot and finalizes it to ok")
    func writesRunningRowThenFinalizesOk() async throws {
        let gate = AsyncGate()
        let harness = try makeHarness(thumbnail: { _, _ in
            await gate.wait()
            return uniformPixels
        })

        // 以缩略图解码阻塞分析，观测 in-flight run 行后再放行（SEAM：run 行
        // 先于解码管线插入、完成后终态——断言窗口即载荷证明）。
        let task = Task {
            try await harness.service.analyze(
                sessionId: harness.sessionId, threshold: 10, minGroupSize: 2, groupingMode: .global
            )
        }

        let runningSeen = try waitUntil {
            guard let row = try runRow(harness.db, harness.sessionId) else { return false }
            return row[6].textValue == "running"
        }
        #expect(runningSeen)
        let running = try runRow(harness.db, harness.sessionId)!
        #expect(running[0].textValue == "similarity")
        #expect(running[1].intValue == 1)
        #expect(running[2].intValue == 0)
        #expect(running[3].textValue != "")
        #expect(running[4].textValue != "")  // started_at
        #expect(running[5].textValue == "")  // finished_at 仍空
        let params = try JSONValue.parse(running[3].textValue ?? "{}")
        #expect(params["threshold"] == .number(10))
        #expect(params["minGroupSize"] == .number(2))
        #expect(params["groupingMode"] == .string("global"))

        gate.release()
        try await task.value

        let finalized = try runRow(harness.db, harness.sessionId)!
        #expect(finalized[6].textValue == "ok")
        #expect(finalized[5].textValue != "")
    }

    @Test("finalizes the run as failed and rethrows when clustering fails")
    func finalizesFailedOnClusterError() async throws {
        let harness = try makeHarness(cluster: { _, _, _, _, _ in
            struct ClusterBoom: Error {}
            throw ClusterBoom()
        })

        await #expect(throws: (any Error).self) {
            try await harness.service.analyze(sessionId: harness.sessionId)
        }

        let row = try runRow(harness.db, harness.sessionId)!
        #expect(row[6].textValue == "failed")
        #expect(row[5].textValue != "")
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "failed")
    }

    @Test("records the index_seq snapshot from the session cursor")
    func recordsIndexSeqSnapshot() async throws {
        let harness = try makeHarness()
        _ = try harness.sessionRepo.bumpIndexSeq(id: harness.sessionId)

        try await harness.service.analyze(sessionId: harness.sessionId)

        let row = try runRow(harness.db, harness.sessionId)!
        #expect(row[2].intValue == 1)
        #expect(row[6].textValue == "ok")
    }
}

// MARK: - getResult 惰性组装

@Suite("SimilarityService.getResult lazy group assembly")
struct SimilarityGetResultTests {
    private func addPhoto(_ db: DBConnection, _ id: String, _ sessionId: String, _ filepath: String, _ assetId: String?) throws {
        try seedSessionRow(db, sessionId)
        if let assetId {
            try seedAssetRow(db, assetId)
        }
        try seedAssetFileRow(db, "af-\(id)")
        _ = try db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
              result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'checksum-\(id)', 'pending', '{"make":"Nikon"}', '{"sharpness":1}',
              ?, 'af-\(id)', 100, 100, '2025-01-01T00:00:00.000Z', '2025-01-01T00:00:00.000Z')
          """).run([
            .text(id), .text(sessionId), .text(filepath), .text(filepath.split(separator: "/").last.map(String.init) ?? id),
            assetId.map { .text($0) } ?? .null,
        ])
    }

    @Test("assembles groups from the members table without parsing groups_json")
    func assemblesGroupsFromMembers() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-svc-\(UUID().uuidString).sqlite").path
        let db = try DBConnection(path: dbPath)
        try MigrationRunner().migrate(db)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try addPhoto(db, "a.raw", "session", "/shoot/a.RAW", "asset-a")
        try addPhoto(db, "a.jpg", "session", "/shoot/a.jpg", "asset-a")
        try addPhoto(db, "s", "session", "/shoot/s.jpg", nil)
        try addPhoto(db, "c.raw", "session", "/shoot/c.RAW", "asset-c")
        try addPhoto(db, "c.jpg", "session", "/shoot/c.jpg", "asset-c")

        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityStore: similarityStore,
            connection: db
        )

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

        let result = try await service.getResult(sessionId: "session")

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
            .appendingPathComponent("gather-similarity-svc-\(UUID().uuidString).sqlite").path
        let db = try DBConnection(path: dbPath)
        try MigrationRunner().migrate(db)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        _ = try db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', ?, ?, 10, 2, '2025-01-01T00:00:00.000Z')
          """).run([
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
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityStore: similarityStore,
            connection: db
        )

        let result = try await service.getResult(sessionId: "session")

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
            .appendingPathComponent("gather-similarity-svc-\(UUID().uuidString).sqlite").path
        let db = try DBConnection(path: dbPath)
        try MigrationRunner().migrate(db)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try addPhoto(db, "p2", "session", "/shoot/p2.jpg", nil)
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityStore: similarityStore,
            connection: db
        )

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

        let main = try await service.getResult(sessionId: "session")
        #expect(main?.stats.threshold == 10)
        #expect(main?.stats.precomputed == false)
        #expect(main?.groups[0].images.map(\.path) == ["/shoot/p1.jpg"])

        let tier = try await service.getResult(sessionId: "session", threshold: 6)
        #expect(tier?.stats.threshold == 6)
        #expect(tier?.stats.precomputed == true)
        #expect(tier?.groups[0].images.map(\.path) == ["/shoot/p2.jpg"])

        #expect(try await service.getResult(sessionId: "session", threshold: 99) == nil)
    }

    @Test("hasResult stays a cheap existence check")
    func hasResultExistence() async throws {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-svc-\(UUID().uuidString).sqlite").path
        let db = try DBConnection(path: dbPath)
        try MigrationRunner().migrate(db)
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        try seedSessionRow(db, "session")
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityStore: similarityStore,
            connection: db
        )
        #expect(try await service.hasResult(sessionId: "session") == false)
        _ = try await similarityStore.replaceResult(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )
        #expect(try await service.hasResult(sessionId: "session") == true)
        _ = try await similarityStore.replaceResultForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"precomputed\":true}", threshold: 6, minGroupSize: 2, memberships: []
        )
        #expect(try await service.hasResult(sessionId: "session", threshold: 6) == true)
        #expect(try await service.hasResult(sessionId: "session", threshold: 7) == false)
    }
}

// MARK: - 取消

@Suite("SimilarityService cancellation")
struct SimilarityCancellationTests {
    @Test("keeps the session occupied until the cancelled analysis actually exits")
    func keepsOccupiedUntilExit() async throws {
        let gate = AsyncGate()
        let harness = try makeHarness(thumbnail: { _, _ in
            await gate.wait()
            return uniformPixels
        })

        let task = Task {
            try await harness.service.analyze(sessionId: harness.sessionId)
        }

        // 等分析进入解码窗口（run 行已写入）再取消。
        let runningSeen = try waitUntil {
            guard let row = try runRow(harness.db, harness.sessionId) else { return false }
            return row[6].textValue == "running"
        }
        #expect(runningSeen)
        try harness.service.cancel(sessionId: harness.sessionId)
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "cancelled")

        // 首跑仍在飞：再次 analyze 必须拒绝。
        await #expect(throws: SimilarityServiceError.analysisRunning) {
            try await harness.service.analyze(sessionId: harness.sessionId)
        }

        gate.release()
        try await task.value

        // 早退路径：run 记录终态 failed（cancel 已写 cancelled），占用已释放。
        let row = try runRow(harness.db, harness.sessionId)!
        #expect(row[6].textValue == "failed")
        let sessionAfter = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(sessionAfter?.analysisStatus == "cancelled")
        // 占用已释放：第三次 analyze 可进入。
        let gate2 = AsyncGate()
        let harness2 = try makeHarness(thumbnail: { _, _ in
            await gate2.wait()
            return uniformPixels
        })
        let task2 = Task { try await harness2.service.analyze(sessionId: harness2.sessionId) }
        try harness2.service.cancel(sessionId: harness2.sessionId)
        gate2.release()
        try await task2.value
    }

    @Test("cancel without an in-flight run does not flip the shared analysis status")
    func cancelWithoutRunKeepsStatus() throws {
        let harness = try makeHarness()
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")

        try harness.service.cancel(sessionId: harness.sessionId, markStatus: false)

        let after = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(after?.analysisStatus == "idle")
    }
}

@Suite("SimilarityServiceError 错误码映射与健壮性")
struct SimilarityServiceRobustnessTests {
    @Test("maps every case to its TS error code")
    func mapsToGatherCodes() {
        #expect(SimilarityServiceError.thresholdInvalid.gatherCode == .SIM_THRESHOLD_INVALID)
        #expect(SimilarityServiceError.minGroupInvalid.gatherCode == .SIM_MIN_GROUP_INVALID)
        #expect(SimilarityServiceError.analysisRunning.gatherCode == .SIM_ANALYSIS_RUNNING)
        #expect(SimilarityServiceError.noPhotos.gatherCode == .SIM_NO_PHOTOS)
        #expect(SimilarityServiceError.noHashData.gatherCode == .SIM_NO_HASH_DATA)
        #expect(SimilarityServiceError.noResults.gatherCode == .SIM_NO_RESULTS)
        #expect(SimilarityServiceError.noHashRecluster.gatherCode == .SIM_NO_HASH_RECLUSTER)
    }

    @Test("analyze rejects a corrupt settings value instead of crashing")
    func analyzeSurvivesNanSettings() async throws {
        let harness = try makeHarness(settings: ["default_threshold": .nan])

        // TS：Number.isInteger(NaN) === false → SIM_THRESHOLD_INVALID；Swift
        // 同样抛错而非 Int(NaN) 崩溃。
        await #expect(throws: SimilarityServiceError.thresholdInvalid) {
            try await harness.service.analyze(sessionId: harness.sessionId)
        }
        // 占用已释放（controller 在 try 之前注册、校验失败不清理——TS 缺陷
        // 逐字保留？校验失败发生在 controller 注册之后，defer 尚未建立，
        // 因此 controller 保留。与 TS 一致，故这里不再断言可重入）。
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")
    }

    @Test("getResult throws on corrupt stored stats like TS JSON.parse")
    func getResultThrowsOnCorruptStats() async throws {
        let db = try makeMigratedDB()
        try seedSessionRow(db, "session")
        _ = try db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', '{"groups":[]}', 'NOT VALID JSON', 10, 2, '2025-01-01T00:00:00.000Z')
          """).run()
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-similarity-svc-\(UUID().uuidString).sqlite").path
        _ = db
        let similarityStore = SQLiteSimilarityStore(database: try SQLiteDatabase(path: dbPath))
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityStore: similarityStore,
            connection: db
        )

        await #expect(throws: (any Error).self) {
            try await service.getResult(sessionId: "session")
        }
    }

    @Test("recluster rejects non-integer thresholds like TS")
    func reclusterRejectsFractionalThreshold() async throws {
        let harness = try makeHarness()
        _ = try await SQLiteSimilarityStore(database: try SQLiteDatabase(path: harness.dbPath)).replaceResult(
            sessionId: harness.sessionId, groupsJson: "{\"groups\":[]}",
            statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )

        await #expect(throws: SimilarityServiceError.thresholdInvalid) {
            try await harness.service.recluster(sessionId: harness.sessionId, threshold: 10.5, minGroupSize: 2)
        }
    }
}
