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

// MARK: - 支撑

/// 9x8 均匀灰度像素网格（DHash 输出 64 个 0）。
private let uniformPixels = [UInt8](repeating: 128, count: 72)

/// 幂等外键种子（photos.session_id / photos.asset_id / photos.asset_file_id）。
private func seedSessionRow(_ db: DBConnection, _ sessionId: String) throws {
    _ = try db.prepare("""
        INSERT OR IGNORE INTO sessions (id, name, status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, '', 'draft', 'idle', 'unknown', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
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

/// 线程安全说明（Swift 6 `Sendable`）：`continuations`/`released` 只在
/// `lock`（NSLock）临界区内读写；门被 @Sendable 的 thumbnailProvider 闭包捕获，
/// 故标注 `@unchecked`（锁纪律无法被编译器静态验证）。
private final class AsyncGate: @unchecked Sendable {
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

/// 线程安全说明（Swift 6 `Sendable`）：全部存储属性构造后不可变（db/service/
/// sessionRepo/sessionId/photoPath），Task 会按值捕获整个 harness；DBConnection 自带
/// 连接锁、SimilarityService 的并发调用由会话占用槽串行化。结构无锁、无写者，
/// 故标注 `@unchecked`（不可变性即此处的人工承诺）。
private struct SimilarityHarness: @unchecked Sendable {
    let db: DBConnection
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
    let db = try makeMigratedDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Run", source: "folder")
    let dir = try makeTempDir()
    let photoPath = try writeTempFile(in: dir, name: "photo.jpg")
    try insertPhoto(db, id: "photo-1", sessionId: session.id, filepath: photoPath)

    let service = SimilarityService(
        photoRepo: PhotoRepo(connection: db),
        sessionRepo: sessionRepo,
        similarityResultRepo: SimilarityResultRepo(connection: db),
        clusterStateRepo: SimilarityClusterStateRepo(connection: db),
        connection: db,
        getNumber: { key, defaultValue in settings[key] ?? defaultValue },
        thumbnailProvider: thumbnail,
        clusterProvider: cluster
    )
    return SimilarityHarness(db: db, service: service, sessionRepo: sessionRepo, sessionId: session.id, photoPath: photoPath)
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
        // 状态真相源是 analysis_jobs：相似度不再写 sessions.analysis_status（方案 A）。
        #expect(try harness.sessionRepo.get(id: harness.sessionId)?.analysisStatus == "idle")
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
        // r403 与 r402/r404 共享资产：r403 自身被跳过，候选 = r402（id 小，旧 hash）
        // + r404（id 大，新 hash），二者 size/mtime 都匹配 ⇒ 必须按 "取 id 最大者"
        // 选中 r404。变异验证：此前只有 r404 一个候选，"最新候选" 与 "首个候选"
        // 不可区分（> 改 < 曾无人杀）；r404 的候选落在第二分块。
        try addPhoto(db, "r404", "session", "asset-403")
        // r402 已由上面的循环创建（asset-402）：改挂到 asset-403，使其成为第二个
        // 合格候选（id 比 r404 小、hash 是旧的）。
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'asset-403' WHERE id = 'r402'").run()
        try addHash(db, "session", "r402", "olderhash", 300, 3000)
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
        let running = try #require(try runRow(harness.db, harness.sessionId))
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

        let finalized = try #require(try runRow(harness.db, harness.sessionId))
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

        let row = try #require(try runRow(harness.db, harness.sessionId))
        #expect(row[6].textValue == "failed")
        #expect(row[5].textValue != "")
        // run 记录保留 ok/failed；会话列不再由相似度写入（job 表=真相源）。
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")
    }

    @Test("records the index_seq snapshot from the session cursor")
    func recordsIndexSeqSnapshot() async throws {
        let harness = try makeHarness()
        _ = try harness.sessionRepo.bumpIndexSeq(id: harness.sessionId)

        try await harness.service.analyze(sessionId: harness.sessionId)

        let row = try #require(try runRow(harness.db, harness.sessionId))
        #expect(row[2].intValue == 1)
        #expect(row[6].textValue == "ok")
    }

    /// 解码全部失败（缩略图 provider 返回 nil，等价损坏/不可读文件）→
    /// SIM_NO_HASH_DATA，run 终态 failed，不落任何结果。此前只有错误码映射
    /// 用例提到 noHashData，没有任何行为用例走到该分支（覆盖空洞）。
    @Test("all thumbnails failing throws SIM_NO_HASH_DATA without persisting a result")
    func allDecodeFailuresThrowNoHashData() async throws {
        let harness = try makeHarness(thumbnail: { _, _ in nil })

        await #expect(throws: SimilarityServiceError.noHashData) {
            try await harness.service.analyze(sessionId: harness.sessionId)
        }

        #expect(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId) == nil)
        #expect(try runRow(harness.db, harness.sessionId)?[6].textValue == "failed")
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
    func assemblesGroupsFromMembers() throws {
        let db = try makeMigratedDB()
        try addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try addPhoto(db, "a.raw", "session", "/shoot/a.RAW", "asset-a")
        try addPhoto(db, "a.jpg", "session", "/shoot/a.jpg", "asset-a")
        try addPhoto(db, "s", "session", "/shoot/s.jpg", nil)
        try addPhoto(db, "c.raw", "session", "/shoot/c.RAW", "asset-c")
        try addPhoto(db, "c.jpg", "session", "/shoot/c.jpg", "asset-c")

        let resultRepo = SimilarityResultRepo(connection: db)
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityResultRepo: resultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db
        )

        // 成员按序写入：组 0 成员在前，组 1 在后。
        _ = try resultRepo.replace(
            sessionId: "session",
            // 垃圾 JSON 证明成员路径从不解析 groups_json。
            groupsJson: "NOT VALID JSON",
            statsJson: """
            {"totalGroups":2,"totalUngrouped":1,"threshold":10,"minGroupSize":2,"groupingMode":"global"}
            """,
            threshold: 10,
            minGroupSize: 2,
            memberships: [
                (photoId: "p1", groupIndex: 0),
                (photoId: "a.raw", groupIndex: 0),
                (photoId: "s", groupIndex: 1),
            ]
        )

        let result = try service.getResult(sessionId: "session")

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

    @Test("stats 计数实时化：分析后新导入的照片计入 ungrouped，不用落库快照")
    func statsCountsAreLive() throws {
        let db = try makeMigratedDB()
        try addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try addPhoto(db, "p2", "session", "/shoot/p2.jpg", nil)
        let resultRepo = SimilarityResultRepo(connection: db)
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityResultRepo: resultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db
        )
        // 落库快照是分析当时的 0 组 / 0 未分组。
        _ = try resultRepo.replace(
            sessionId: "session",
            groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":0,\"totalUngrouped\":0,\"threshold\":10,\"minGroupSize\":2,\"groupingMode\":\"global\"}",
            threshold: 10, minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0)]
        )

        // p2 是分析后新导入（不在成员表）→ 实时 ungrouped 与计数都必须含它。
        let result = try #require(try service.getResult(sessionId: "session"))
        #expect(result.groups.map(\.count) == [1])
        #expect(result.ungrouped.map(\.path) == ["/shoot/p2.jpg"])
        #expect(result.stats.totalGroups == 1)
        #expect(result.stats.totalUngrouped == 1)
    }

    @Test("keeps the legacy groups_json path for rows without members")
    func legacyGroupsJsonPath() throws {
        let db = try makeMigratedDB()
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
            // 落库快照的未分组计数故意写错（0）：返回必须以 payload 实时计数为准。
            .text("""
            {"totalGroups":1,"totalUngrouped":0,"threshold":10,"minGroupSize":2,"groupingMode":"sequential"}
            """),
        ])
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityResultRepo: SimilarityResultRepo(connection: db),
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db
        )

        let result = try service.getResult(sessionId: "session")

        // 旧行（无成员）逐字解析 groups_json；计数由 payload 实时给出。
        #expect(result != nil)
        #expect(result!.groups[0].images == [
            SimilarityImage(path: "/shoot/p1.jpg", representative: true),
            SimilarityImage(path: "/shoot/legacy.jpg", representative: false),
        ])
        #expect(result!.ungrouped == [SimilarityImage(path: "/shoot/alone.jpg")])
        #expect(result!.stats.totalGroups == 1)
        #expect(result!.stats.totalUngrouped == 1)
        #expect(result!.stats.groupingMode == .sequential)
        #expect(result!.stats.precomputed == false)
    }

    @Test("resolves threshold tiers without regressing the default row")
    func resolvesThresholdTiers() throws {
        let db = try makeMigratedDB()
        try addPhoto(db, "p1", "session", "/shoot/p1.jpg", nil)
        try addPhoto(db, "p2", "session", "/shoot/p2.jpg", nil)
        let resultRepo = SimilarityResultRepo(connection: db)
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityResultRepo: resultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db
        )

        _ = try resultRepo.replace(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1,\"totalUngrouped\":1,\"threshold\":10,\"minGroupSize\":2,\"groupingMode\":\"global\"}",
            threshold: 10, minGroupSize: 2,
            memberships: [(photoId: "p1", groupIndex: 0)]
        )
        _ = try resultRepo.replaceForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"totalGroups\":1,\"totalUngrouped\":1,\"threshold\":6,\"minGroupSize\":2,\"groupingMode\":\"global\",\"precomputed\":true}",
            threshold: 6, minGroupSize: 2,
            memberships: [(photoId: "p2", groupIndex: 0)]
        )

        let main = try service.getResult(sessionId: "session")
        #expect(main?.stats.threshold == 10)
        #expect(main?.stats.precomputed == false)
        #expect(main?.groups[0].images.map(\.path) == ["/shoot/p1.jpg"])

        let tier = try service.getResult(sessionId: "session", threshold: 6)
        #expect(tier?.stats.threshold == 6)
        #expect(tier?.stats.precomputed == true)
        #expect(tier?.groups[0].images.map(\.path) == ["/shoot/p2.jpg"])

        #expect(try service.getResult(sessionId: "session", threshold: 99) == nil)
    }

    @Test("hasResult stays a cheap existence check")
    func hasResultExistence() throws {
        let db = try makeMigratedDB()
        try seedSessionRow(db, "session")
        let resultRepo = SimilarityResultRepo(connection: db)
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityResultRepo: resultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db
        )
        #expect(try service.hasResult(sessionId: "session") == false)
        _ = try resultRepo.replace(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )
        #expect(try service.hasResult(sessionId: "session") == true)
        _ = try resultRepo.replaceForThreshold(
            sessionId: "session", groupsJson: "{\"groups\":[]}",
            statsJson: "{\"precomputed\":true}", threshold: 6, minGroupSize: 2, memberships: []
        )
        #expect(try service.hasResult(sessionId: "session", threshold: 6) == true)
        #expect(try service.hasResult(sessionId: "session", threshold: 7) == false)
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
        // 取消只中断在飞操作，不写会话列（取消态由 job 表表达）。
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")

        // 首跑仍在飞：再次 analyze 必须拒绝。
        await #expect(throws: SimilarityServiceError.analysisRunning) {
            try await harness.service.analyze(sessionId: harness.sessionId)
        }

        gate.release()
        try await task.value

        // 早退路径：run 记录终态 failed，占用已释放。
        let row = try #require(try runRow(harness.db, harness.sessionId))
        #expect(row[6].textValue == "failed")
        let sessionAfter = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(sessionAfter?.analysisStatus == "idle")
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

    @Test("cancel without an in-flight run is a no-op and never touches sessions.analysis_status")
    func cancelWithoutRunKeepsStatus() throws {
        let harness = try makeHarness()
        let session = try SessionRepo(connection: harness.db).get(id: harness.sessionId)
        #expect(session?.analysisStatus == "idle")

        try harness.service.cancel(sessionId: harness.sessionId)

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
    func getResultThrowsOnCorruptStats() throws {
        let db = try makeMigratedDB()
        try seedSessionRow(db, "session")
        _ = try db.prepare("""
            INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES ('session', '{"groups":[]}', 'NOT VALID JSON', 10, 2, '2025-01-01T00:00:00.000Z')
          """).run()
        let service = SimilarityService(
            photoRepo: PhotoRepo(connection: db),
            sessionRepo: SessionRepo(connection: db),
            similarityResultRepo: SimilarityResultRepo(connection: db),
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db
        )

        #expect(throws: (any Error).self) {
            try service.getResult(sessionId: "session")
        }
    }

    @Test("recluster rejects non-integer thresholds like TS")
    func reclusterRejectsFractionalThreshold() async throws {
        let harness = try makeHarness()
        _ = try SimilarityResultRepo(connection: harness.db).replace(
            sessionId: harness.sessionId, groupsJson: "{\"groups\":[]}",
            statsJson: "{}", threshold: 10, minGroupSize: 2, memberships: []
        )

        await #expect(throws: SimilarityServiceError.thresholdInvalid) {
            try await harness.service.recluster(sessionId: harness.sessionId, threshold: 10.5, minGroupSize: 2)
        }
    }
}

// MARK: - recluster job 化：进度 / 取消 / 互斥 / 原子写（§4.2 P1 修复）

/// clusterProvider 调用次数门（线程安全）：按第 N 次调用触发副作用。
private final class ProviderCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let action: (Int) -> Void

    init(_ action: @escaping (Int) -> Void) { self.action = action }

    func fire() {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        action(current)
    }
}

/// 跨线程可见的布尔标记。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

@Suite("SimilarityService recluster job 语义")
struct SimilarityReclusterJobTests {
    private typealias ClusterProvider = SimilarityService.ClusterProvider

    /// 纯函数（无捕获状态）：以静态方法引用表达而非 static let 闭包——非 Sendable
    /// 闭包类型的全局常量在 Swift 6 下不可表达，而方法引用不需要 Sendable。
    private static func defaultCluster(
        _ entries: [HashEntry],
        _ threshold: Int,
        _ minGroupSize: Int,
        _ mode: HashGroupingMode,
        _ onProgress: ((Int, Int) -> Void)?
    ) throws -> ClusterResult {
        try ClusterEngine.clusterByHash(
            entries: entries, threshold: threshold, minGroupSize: minGroupSize,
            mode: mode, onProgress: onProgress)
    }

    /// 首轮 analyze 建结果与簇状态：photo-1（真实文件 → uniform hash 0）+
    /// p2（预置 checksum 统计与 hash 0）→ 同 hash 一组两张。
    private func makeReadyHarness(
        cluster: @escaping ClusterProvider = SimilarityReclusterJobTests.defaultCluster,
        analyze: Bool = true
    ) async throws -> SimilarityHarness {
        let harness = try makeHarness(cluster: cluster)
        try insertPhoto(harness.db, id: "p2", sessionId: harness.sessionId)
        _ = try harness.db.prepare(
            "UPDATE photos SET checksum_file_size = 100, checksum_file_mtime_ms = 1000 WHERE id = ?"
        ).run([.text("p2")])
        _ = try harness.db.prepare("""
            INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
            VALUES (?, 'p2', '0000000000000000', 100, 1000)
            """).run([.text(harness.sessionId)])
        if analyze {
            try await harness.service.analyze(sessionId: harness.sessionId, threshold: 10, minGroupSize: 2)
        }
        return harness
    }

    @Test("recluster 回传 cluster/thresholds 相位，结果与簇状态同版本切换")
    func progressPhasesAndAtomicPersist() async throws {
        let harness = try await makeReadyHarness()
        let beforeMeta = try #require(
            try SimilarityClusterStateRepo(connection: harness.db).load(sessionId: harness.sessionId)?.meta
        )

        var phases: [String] = []
        let result = try await harness.service.recluster(
            sessionId: harness.sessionId,
            threshold: 4,
            minGroupSize: 2,
            groupingMode: .global,
            onProgress: { _, _, phase in phases.append(phase) }
        )

        #expect(result.stats.threshold == 4)
        #expect(result.groups.map(\.count) == [2])
        #expect(phases.contains("similarity.cluster"))
        #expect(phases.contains("similarity.cluster-done"))
        #expect(phases.contains("similarity.thresholds"))

        // 结果与簇状态在同一事务提交：参数指纹与版本号一致推进。
        let stored = try #require(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId))
        #expect(stored.paramThreshold == 4)
        let meta = try #require(
            try SimilarityClusterStateRepo(connection: harness.db).load(sessionId: harness.sessionId)?.meta
        )
        #expect(meta.paramThreshold == 4)
        #expect(meta.version == beforeMeta.version + 1)
    }

    @Test("recluster 前置条件：无既有结果抛 SIM_NO_RESULTS")
    func reclusterRequiresExistingResult() async throws {
        let harness = try makeHarness()
        await #expect(throws: SimilarityServiceError.noResults) {
            try await harness.service.recluster(sessionId: harness.sessionId, threshold: 4, minGroupSize: 2)
        }
    }

    @Test("job 信号取消：cluster 返回后才取消 → 抛取消且结果/簇状态零变更")
    func externalSignalCancellationDoesNotPersist() async throws {
        let signal = JobAbortSignal()
        // 第 2 次 cluster 调用（recluster）返回前 abort 外部长信号。
        let gate = ProviderCallGate { call in
            if call == 2 { signal.abort() }
        }
        let harness = try await makeReadyHarness(cluster: { entries, threshold, minGroupSize, mode, onProgress in
            gate.fire()
            return try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        })
        let before = try #require(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId))
        let beforeVersion = try #require(
            try SimilarityClusterStateRepo(connection: harness.db).load(sessionId: harness.sessionId)?.meta.version
        )

        await #expect(throws: JobCancelledError()) {
            try await harness.service.recluster(
                sessionId: harness.sessionId, threshold: 4, minGroupSize: 2,
                groupingMode: .global, signal: signal
            )
        }

        let after = try #require(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId))
        #expect(after.id == before.id)
        #expect(after.paramThreshold == before.paramThreshold)
        #expect(
            try SimilarityClusterStateRepo(connection: harness.db).load(sessionId: harness.sessionId)?.meta.version
                == beforeVersion
        )
    }

    /// analyze 侧的对称契约：cluster 已返回、结果尚未落库时取消 → 抛取消且
    /// 结果/簇状态零变更，run 终态 failed。变异验证：删掉 analyze 里 cluster
    /// 返回后的 signal.aborted 检查曾无人杀（recluster 侧有守卫，analyze 侧没有）。
    @Test("analyze：cluster 返回后才取消 → 抛取消且结果/簇状态零变更")
    func analyzeExternalSignalCancellationDoesNotPersist() async throws {
        let signal = JobAbortSignal()
        // 第 1 次（也是唯一一次）cluster 调用返回前 abort 外部长信号。
        let gate = ProviderCallGate { call in
            if call == 1 { signal.abort() }
        }
        let harness = try await makeReadyHarness(cluster: { entries, threshold, minGroupSize, mode, onProgress in
            gate.fire()
            return try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        }, analyze: false)

        await #expect(throws: JobCancelledError()) {
            try await harness.service.analyze(
                sessionId: harness.sessionId, threshold: 10, minGroupSize: 2, signal: signal
            )
        }

        #expect(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId) == nil)
        #expect(try SimilarityClusterStateRepo(connection: harness.db).load(sessionId: harness.sessionId) == nil)
        #expect(try runRow(harness.db, harness.sessionId)?[6].textValue == "failed")
    }

    @Test("recluster 与 analyze 互斥：占用中抛 SIM_ANALYSIS_RUNNING（双向）")
    func reclusterAndAnalyzeAreMutuallyExclusive() async throws {
        // 方向 A：analyze 在飞 → recluster 被拒。
        let gate = AsyncGate()
        let harness = try makeHarness(thumbnail: { _, _ in
            await gate.wait()
            return uniformPixels
        })
        let analyzeTask = Task { try await harness.service.analyze(sessionId: harness.sessionId) }
        let runningSeen = try waitUntil {
            guard let row = try runRow(harness.db, harness.sessionId) else { return false }
            return row[6].textValue == "running"
        }
        #expect(runningSeen)
        await #expect(throws: SimilarityServiceError.analysisRunning) {
            try await harness.service.recluster(sessionId: harness.sessionId, threshold: 4, minGroupSize: 2)
        }
        gate.release()
        try await analyzeTask.value

        // 方向 B：recluster 在飞（阻塞在 clusterProvider）→ analyze 被拒。
        let blocked = LockedFlag()
        let release = DispatchSemaphore(value: 0)
        let calls = ProviderCallGate { call in
            if call >= 2 {
                blocked.set()
                release.wait()
            }
        }
        let harness2 = try await makeReadyHarness(cluster: { entries, threshold, minGroupSize, mode, onProgress in
            calls.fire()
            return try ClusterEngine.clusterByHash(
                entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                mode: mode, onProgress: onProgress)
        })
        let reclusterTask = Task {
            try await harness2.service.recluster(sessionId: harness2.sessionId, threshold: 4, minGroupSize: 2)
        }
        #expect(try waitUntil { blocked.value })
        await #expect(throws: SimilarityServiceError.analysisRunning) {
            try await harness2.service.analyze(sessionId: harness2.sessionId)
        }
        release.signal()
        _ = try await reclusterTask.value
    }

    @Test("结果与簇状态单事务原子写：状态落库失败时结果一并回滚")
    func resultAndStatePersistAtomically() async throws {
        let harness = try await makeReadyHarness()
        let before = try #require(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId))

        // 阻断簇状态的全部删除路径（replace 失败后的降级 delete 也会失败）：
        // persistClusterOutcome 的事务必须整体回滚，主结果不得被替换。
        _ = try harness.db.prepare("""
            CREATE TRIGGER block_meta_delete BEFORE DELETE ON similarity_cluster_meta
            BEGIN SELECT RAISE(ABORT, 'blocked'); END;
            """).run()

        await #expect(throws: (any Error).self) {
            try await harness.service.recluster(sessionId: harness.sessionId, threshold: 4, minGroupSize: 2)
        }

        let after = try #require(try SimilarityResultRepo(connection: harness.db).getLatest(sessionId: harness.sessionId))
        #expect(after.id == before.id)
        #expect(after.paramThreshold == before.paramThreshold)
        #expect(after.statsJson == before.statsJson)
    }

    @Test("analyze 链接 job 信号：预取消的外部长信号 → 零落库退出并释放占用")
    func analyzeLinksExternalSignal() async throws {
        let harness = try makeHarness()
        let signal = JobAbortSignal()
        signal.abort()

        try await harness.service.analyze(sessionId: harness.sessionId, signal: signal)

        #expect(try runRow(harness.db, harness.sessionId) == nil)
        // 占用已释放：随后无信号的分析正常执行。
        try await harness.service.analyze(sessionId: harness.sessionId)
        #expect(try runRow(harness.db, harness.sessionId)?[6].textValue == "ok")
    }
}
