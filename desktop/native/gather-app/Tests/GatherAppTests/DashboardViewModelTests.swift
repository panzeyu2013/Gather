// desktop/native/gather-app/Tests/GatherAppTests/DashboardViewModelTests.swift
// Phase 3.1 Dashboard 视图模型行为测试。
// 覆盖：workspace status 加载、jobs 列表加载、scanJobs 派生、卡片计数文案
// （TS deriveCardIndexKind/photoCountLabel 语义）、cancel/retry/clear_completed
// 调用正确性、错误态（stub 注入）。
// 集成用例用真实临时 SQLite + 已移植服务。

import Foundation
import Testing
@testable import GatherApp
@testable import GatherCore

// MARK: - Stub（错误态注入）

private final class StubDashboardProvider: DashboardDataProvider {
    var sessions: [SessionData] = []
    var statuses: [String: WorkspaceStatus] = [:]
    var jobs: [AnalysisJobData] = []
    var listError: String?
    var jobListError: String?
    var createError: String?
    private(set) var createdNames: [String] = []
    private(set) var deletedIds: [String] = []
    /// 删除调用的 confirmed 取值：断言 VM/Provider 不把未确认伪造成确认。
    private(set) var deleteConfirmedFlags: [Bool] = []
    private(set) var cancelCalls: [String] = []
    private(set) var retryCalls: [String] = []
    private(set) var clearCallCount = 0
    /// 入队 metadata.scan 的作用域参数（nil = 目录全树；非 nil = 显式集合）。
    private(set) var indexScanCalls: [(sessionId: String, requestedPaths: [String]?)] = []

    func listSessions() throws -> [SessionData] {
        if let listError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: listError])
        }
        return sessions
    }

    func createSession(name: String, source: String, sourcePath: String) throws -> SessionData {
        if let createError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: createError])
        }
        createdNames.append(name)
        return Self.session(id: "new-\(createdNames.count)", name: name, sourcePath: sourcePath)
    }

    func deleteSession(_ sessionId: String, confirmed: Bool) throws {
        deletedIds.append(sessionId)
        deleteConfirmedFlags.append(confirmed)
    }

    func workspaceStatus(sessionId: String) throws -> WorkspaceStatus? {
        statuses[sessionId]
    }

    func listJobs(includeCheckpoint: Bool) throws -> [AnalysisJobData] {
        if let jobListError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: jobListError])
        }
        return jobs
    }

    func cancelJob(_ jobId: String) throws -> Bool {
        cancelCalls.append(jobId)
        return true
    }

    func retryJob(_ jobId: String) throws -> Bool {
        retryCalls.append(jobId)
        return true
    }

    func clearCompletedJobs() throws -> Int {
        clearCallCount += 1
        return 1
    }

    func enqueueIndexScan(sessionId: String, requestedPaths: [String]?) throws {
        indexScanCalls.append((sessionId, requestedPaths))
    }

    static func session(id: String, name: String = "会话", sourcePath: String = "") -> SessionData {
        SessionData(
            id: id,
            name: name,
            status: .photosLoaded,
            photoCount: 0,
            analysisStatus: .idle,
            writebackStatus: .idle,
            importSource: "folder",
            sourcePath: sourcePath,
            failedWritebackCount: 0,
            truncatedImport: false,
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
    }

    static func job(
        id: String,
        type: AnalysisJobType = .thumbnailBuild,
        scopeId: String = "s1",
        status: AnalysisJobStatus = .queued,
        current: Int = 0,
        total: Int = 0,
        progressMessage: String = "",
        updatedAt: String = "2026-01-01T00:00:00.000Z"
    ) -> AnalysisJobData {
        AnalysisJobData(
            id: id,
            type: type,
            scopeType: "session",
            scopeId: scopeId,
            dedupeKey: "\(type.rawValue):\(scopeId)",
            status: status,
            priority: 0,
            progressCurrent: current,
            progressTotal: total,
            progressMessage: progressMessage,
            inputFingerprint: "",
            modelId: "",
            modelVersion: "",
            checkpoint: [:],
            attemptCount: 1,
            leaseOwner: "",
            heartbeatAt: "",
            errorCode: "",
            errorMessage: "",
            createdAt: updatedAt,
            startedAt: "",
            finishedAt: "",
            updatedAt: updatedAt
        )
    }
}

/// 锁内以 zh-CN 取卡片计数文案：中文断言不得受并行切语言/系统语言影响。
@MainActor
private func chinesePhotoCountLabel(_ viewModel: DashboardViewModel, _ session: SessionData) -> String {
    AppLanguageLock.withCopy("zh-CN") { viewModel.photoCountLabel(for: session) }
}

@MainActor
private func makeStubVM() -> (DashboardViewModel, StubDashboardProvider) {
    let stub = StubDashboardProvider()
    return (DashboardViewModel(provider: stub), stub)
}

// MARK: - 真实服务集成（临时 SQLite）

private func makeLiveProvider() throws -> (LiveDashboardDataProvider, DBConnection) {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    let sessionRepo = SessionRepo(connection: db)
    let photoRepo = PhotoRepo(connection: db)
    let provider = LiveDashboardDataProvider(
        sessionService: SessionService(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            faceRepo: FaceRepo(connection: db),
            connection: db
        ),
        workspaceStatusService: WorkspaceStatusService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            outboxRepo: MetadataOutboxRepo(connection: db)
        ),
        jobService: JobService(repo: AnalysisJobRepo(connection: db))
    )
    return (provider, db)
}

private func insertSession(
    _ db: DBConnection,
    _ id: String,
    name: String = "工作区",
    updatedAt: String = "2026-01-01T00:00:00.000Z"
) throws {
    // store-index v-next：sessions 不再有 analysis_status（分析态由 analysis_jobs 派生）。
    // updated_at 可显式指定：会话列表按「最近活动」排序，夹具需确定性表达意图。
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, ?, 'photos_loaded', 'idle', 'folder', ?, ?)
    """).run([.text(id), .text(name), .text(updatedAt), .text(updatedAt)])
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text("/tmp/\(id).jpg"), .text("\(id).jpg")])
}

/// 种子 outbox 行（待同步写回计数，对齐 WorkspaceStatusServiceTests）。
private func insertOutboxRow(_ db: DBConnection, sessionId: String, xmpPath: String, status: String) throws {
    _ = try db.prepare("""
        INSERT INTO metadata_outbox (xmp_path, photo_path, patch_json, dirty_fields, source_module, revision, persisted_revision, status, updated_at)
        VALUES (?, '/tmp/p.jpg', '{}', '[]', 'culling', 1, 0, ?, '2026-01-01T00:00:00.000Z')
    """).run([.text(xmpPath), .text(status)])
    _ = try db.prepare("""
        INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
        VALUES (?, ?, '', '2026-01-01T00:00:00.000Z')
    """).run([.text(xmpPath), .text(sessionId)])
}

private func insertJob(_ db: DBConnection, id: String, type: String, scopeId: String, status: String, updatedAt: String) throws {
    _ = try db.prepare("""
        INSERT INTO analysis_jobs (id, type, scope_type, scope_id, dedupe_key, status, priority, created_at, updated_at)
        VALUES (?, ?, 'session', ?, ?, ?, 0, ?, ?)
    """).run([.text(id), .text(type), .text(scopeId), .text("\(type):\(scopeId)"), .text(status), .text(updatedAt), .text(updatedAt)])
}

// MARK: - 用例

@MainActor
@Suite("DashboardViewModel")
struct DashboardViewModelTests {
    // ── 加载与状态聚合 ──

    // 真实库：sessions + photos + outbox → 概览计数正确（workspace status 加载）。
    @Test func loadAllAggregatesWorkspaceStatus() async throws {
        let (provider, db) = try makeLiveProvider()
        // 活动时间显式区分：s2 更近 → 排序语义要求它在前（不去赌平手兜底）。
        try insertSession(db, "s1", name: "甲", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertSession(db, "s2", name: "乙", updatedAt: "2026-01-02T00:00:00.000Z")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        try insertPhoto(db, id: "p3", sessionId: "s2")
        // photoCount 为 sessions 表存储列（真实流程由 addPhotos → updatePhotoCount 维护）。
        _ = try db.prepare("UPDATE sessions SET photo_count = 2 WHERE id = 's1'").run([])
        _ = try db.prepare("UPDATE sessions SET photo_count = 1 WHERE id = 's2'").run([])
        try insertOutboxRow(db, sessionId: "s1", xmpPath: "a.xmp", status: "pending")
        try insertOutboxRow(db, sessionId: "s1", xmpPath: "b.xmp", status: "conflict")

        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()

        #expect(viewModel.phase == .loaded)
        #expect(viewModel.sessions.count == 2)
        #expect(viewModel.sessions.map(\.name) == ["乙", "甲"], "更近活动的会话排在前面")
        let summary = viewModel.summary()
        #expect(summary.sessionCount == 2)
        #expect(summary.photoCount == 3)
        #expect(summary.pendingXmp == 1)
        #expect(summary.conflictXmp == 1)
        // workspace status 按 session 落表。
        #expect(viewModel.statuses["s1"]?.sessionId == "s1")
        #expect(viewModel.statuses["s1"]?.stage == .imported)
    }

    // 排序语义：会话活动取「最近一次分析 job 活动 vs 会话自身 updated_at」的较大者，
    // 分析更近的会话必须排到最前（analysis_status 删列后不能再靠写 updated_at 副作用）。
    @Test func newerAnalysisActivityOrdersSessionFirst() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1", name: "甲", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertSession(db, "s2", name: "乙", updatedAt: "2026-01-02T00:00:00.000Z")
        try insertJob(db, id: "j1", type: "metadata.scan", scopeId: "s1", status: "running",
                      updatedAt: "2026-01-03T00:00:00.000Z")
        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()
        #expect(viewModel.sessions.map(\.name) == ["甲", "乙"], "更近分析活动把会话顶到最前")
    }

    // 平手契约：活动时间完全相同 → rowid DESC 兜底，次序仍确定（不留未定义顺序）。
    @Test func equalActivityFallsBackToRowidDesc() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1", name: "甲")
        try insertSession(db, "s2", name: "乙")
        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()
        #expect(viewModel.sessions.map(\.name) == ["乙", "甲"], "同刻按 rowid DESC 定序")
    }

    // 真实库：jobs.list 加载 → attention/history 分组 + scanJobs 种子。
    @Test func loadJobsGroupsAttentionAndHistory() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertJob(db, id: "j1", type: "thumbnail.build", scopeId: "s1", status: "queued", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertJob(db, id: "j2", type: "metadata.scan", scopeId: "s1", status: "running", updatedAt: "2026-01-01T00:00:01.000Z")
        try insertJob(db, id: "j3", type: "export.execute", scopeId: "s1", status: "succeeded", updatedAt: "2026-01-01T00:00:02.000Z")

        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()

        #expect(viewModel.jobs.count == 3)
        // 排序由 repo 决定（priority/created_at），分组断言用集合。
        #expect(Set(viewModel.attentionJobs.map(\.id)) == Set(["j1", "j2"]))
        #expect(viewModel.historyJobs.map(\.id) == ["j3"])
        // metadata.scan 进 scanJobs（active 快照：running）。
        #expect(viewModel.scanJobs["s1"]?.status == "running")
        #expect(deriveCardIndexKind(viewModel.scanJobs["s1"]) == .active)
    }

    // scanJobs 种子：同 session 多行取 updatedAt 最新；终态行失败态保留。
    @Test func scanJobsSeedPicksLatestPerSession() throws {
        let jobs = [
            StubDashboardProvider.job(
                id: "a1", type: .metadataScan, scopeId: "s1", status: .succeeded,
                current: 10, total: 10, updatedAt: "2026-01-01T00:00:01.000Z"
            ),
            StubDashboardProvider.job(
                id: "a2", type: .metadataScan, scopeId: "s1", status: .failed,
                current: 3, total: 10, updatedAt: "2026-01-01T00:00:02.000Z"
            ),
            StubDashboardProvider.job(
                id: "b1", type: .metadataScan, scopeId: "s2", status: .running,
                current: 5, total: 20, updatedAt: "2026-01-01T00:00:03.000Z"
            ),
            StubDashboardProvider.job(id: "c1", type: .thumbnailBuild, scopeId: "s2", status: .queued),
        ]
        let scanJobs = DashboardViewModel.seedScanJobs(from: jobs)
        #expect(scanJobs.count == 2)
        #expect(scanJobs["s1"]?.status == "failed")
        #expect(scanJobs["s1"]?.current == 3)
        #expect(scanJobs["s2"]?.status == "running")
    }

    // 真实库：jobs cancel → DB 状态翻转；retry → 回 queued。
    @Test func cancelAndRetryMutateRealDB() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertJob(db, id: "j1", type: "thumbnail.build", scopeId: "s1", status: "queued", updatedAt: "2026-01-01T00:00:00.000Z")

        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()

        await viewModel.cancelJob("j1")
        #expect(try AnalysisJobRepo(connection: db).get("j1")?.status == .cancelled)

        await viewModel.retryJob("j1")
        #expect(try AnalysisJobRepo(connection: db).get("j1")?.status == .queued)
        // 动作后列表已刷新（status 同步到内存）。
        #expect(viewModel.jobs.first(where: { $0.id == "j1" })?.status == .queued)
    }

    // 目录导入是唯一允许递归 source_path 全树的作用域：入队不得携带 requestedPaths。
    @Test func directoryCreateScanUsesDirectoryScope() async throws {
        let (viewModel, stub) = makeStubVM()
        let created = await viewModel.createSession(name: "新", sourcePath: "/tmp/新")
        #expect(created != nil)
        #expect(stub.indexScanCalls.count == 1)
        #expect(stub.indexScanCalls.first?.requestedPaths == nil)
    }

    // retry 由 JobService/checkpoint 继承保留原扫描作用域（重跑=续跑），
    // VM 不得凭空指定新集合，也不得把目录会话变成显式集合。
    @Test func retryScanDefersScopeToCheckpointInheritance() async throws {
        let (viewModel, stub) = makeStubVM()
        await viewModel.retryScan(sessionId: "s1")
        #expect(stub.indexScanCalls.count == 1)
        #expect(stub.indexScanCalls.first?.sessionId == "s1")
        #expect(stub.indexScanCalls.first?.requestedPaths == nil)
    }

    // 文件导入（C1 同路径）：source_path 必须为空，扫描范围由 job
    // checkpoint["requestedPaths"] 显式携带本次选中集合。
    @Test func fileImportLeavesSourcePathEmptyAndPersistsRequestedPaths() async throws {
        let (provider, _) = try makeLiveProvider()
        let dir = NSTemporaryDirectory() + "/gather-file-import-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = dir + "/a.jpg"
        let b = dir + "/b.jpg"
        try Data("a".utf8).write(to: URL(fileURLWithPath: a))
        try Data("b".utf8).write(to: URL(fileURLWithPath: b))

        let outcome = try provider.createSessionFromFiles(
            name: "C1", source: "capture-one", filepaths: [a, b])
        #expect(outcome.session.sourcePath == "", "文件导入不得把公共父目录落成 source_path")
        let listed = try provider.listSessions().first { $0.id == outcome.session.id }
        #expect(listed?.sourcePath == "", "落库的 source_path 也必须为空")

        let selected = normalizeImportFilepaths([a, b])
        try provider.enqueueIndexScan(sessionId: outcome.session.id, requestedPaths: selected)
        // 契约断言需要完整 checkpoint（Dashboard 运行时走轻投影）。
        let jobs = try provider.listJobs(includeCheckpoint: true)
        let scan = try #require(jobs.first {
            $0.type == .metadataScan && $0.scopeId == outcome.session.id
        })
        #expect(scan.checkpoint[GatherApp.scanRequestedPathsKey] != nil,
                "契约键名必须与 GatherApp.importFiles 一致")
        let requested = scan.checkpoint[GatherApp.scanRequestedPathsKey]?
            .arrayElements?.compactMap(\.stringValue) ?? []
        #expect(requested == selected, "job 必须携带本次选中文件集合，而不是公共父目录")
        #expect(!requested.contains(dir), "父目录不得出现在扫描集合中")
    }

    // 真实库：clear_completed 只清非阶段证据行（metadata.scan 保留）。
    @Test func clearCompletedKeepsStageEvidenceRows() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertJob(db, id: "scan1", type: "metadata.scan", scopeId: "s1", status: "succeeded", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertJob(db, id: "t1", type: "thumbnail.build", scopeId: "s1", status: "succeeded", updatedAt: "2026-01-01T00:00:00.000Z")

        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()
        #expect(viewModel.hasClearableJobs == true)

        await viewModel.clearCompletedJobs()
        let remaining = try provider.listJobs(includeCheckpoint: true)
        #expect(remaining.map(\.id) == ["scan1"])
        #expect(viewModel.hasClearableJobs == false)
    }

    // ── 卡片计数文案（TS deriveCardIndexKind + photoCountLabel 语义）──

    @Test func photoCountLabelDerivesFromScanJob() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "x")]
        let truncated = SessionData(
            id: "s2", name: "x", status: .photosLoaded, photoCount: 12,
            analysisStatus: .idle, writebackStatus: .idle, importSource: "folder",
            sourcePath: "", failedWritebackCount: 0, truncatedImport: true,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z"
        )
        await viewModel.loadAll()

        /// 经真实 seedScanJobs 路径注入 scan 快照（对齐 TS 从 jobs.list 派生）。
        func seedScan(status: String, current: Int, total: Int) async {
            stub.jobs = [StubDashboardProvider.job(
                id: "scan", type: .metadataScan, scopeId: "s2",
                status: AnalysisJobStatus(rawValue: status) ?? .queued,
                current: current, total: total
            )]
            await viewModel.refreshJobs()
        }

        // count：截断导入且 scan 未成功 → ≥ 前缀。
        #expect(chinesePhotoCountLabel(viewModel, truncated) == "≥12 张照片")
        // count：截断导入但 scan succeeded → 精确计数（≥ 前缀去除）。
        await seedScan(status: "succeeded", current: 12, total: 12)
        #expect(chinesePhotoCountLabel(viewModel, truncated) == "12 张照片")
        // active：有进度 → 正在索引 N。
        await seedScan(status: "running", current: 4, total: 20)
        #expect(chinesePhotoCountLabel(viewModel, truncated) == "正在索引 4…")
        // active：进度 0/0 → 扫描中。
        await seedScan(status: "queued", current: 0, total: 0)
        #expect(chinesePhotoCountLabel(viewModel, truncated) == "扫描中…")
        // failed：索引失败（绝不以阶段计数作权威展示）。
        await seedScan(status: "failed", current: 2, total: 20)
        #expect(chinesePhotoCountLabel(viewModel, truncated) == "索引失败")
    }

    @Test func deriveCardIndexKindMatchesTS() {
        #expect(deriveCardIndexKind(nil) == .count)
        #expect(deriveCardIndexKind(DashboardScanJob(status: nil, current: 0, total: 0)) == .active)
        #expect(deriveCardIndexKind(DashboardScanJob(status: "queued", current: 0, total: 0)) == .active)
        #expect(deriveCardIndexKind(DashboardScanJob(status: "running", current: 1, total: 5)) == .active)
        #expect(deriveCardIndexKind(DashboardScanJob(status: "cancelling", current: 0, total: 0)) == .active)
        #expect(deriveCardIndexKind(DashboardScanJob(status: "succeeded", current: 5, total: 5)) == .count)
        #expect(deriveCardIndexKind(DashboardScanJob(status: "failed", current: 0, total: 0)) == .failed)
        #expect(deriveCardIndexKind(DashboardScanJob(status: "cancelled", current: 0, total: 0)) == .count)
    }

    @Test func progressPercentMatchesTS() {
        let job = StubDashboardProvider.job(id: "j", status: .running, current: 2, total: 5)
        #expect(DashboardViewModel.progressPercent(of: job) == 40)
        let zero = StubDashboardProvider.job(id: "j", status: .queued)
        #expect(DashboardViewModel.progressPercent(of: zero) == 0)
    }

    // ── 进度事件（TS jobs:progress 逐帧订阅）──

    // 普通帧：仅 metadata.scan 更新 scanJobs 快照 + 任务中心行实时刷新，
    // 不整页刷新（毫秒级「正在索引 N…」）。
    @Test func applyProgressFrameUpdatesScanSnapshotAndJobRow() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "x")]
        stub.jobs = [StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .running, current: 2, total: 10
        )]
        await viewModel.loadAll()
        #expect(chinesePhotoCountLabel(viewModel, stub.sessions[0]) == "正在索引 2…")

        let frame = StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .running, current: 6, total: 10,
            progressMessage: "index.scanning"
        )
        viewModel.applyJobEvent(GatherJobEvent(
            job: frame,
            update: JobProgressUpdate(current: 6, total: 10, phase: "index.scanning")
        ))

        #expect(viewModel.scanJobs["s1"]?.status == "running")
        #expect(viewModel.scanJobs["s1"]?.current == 6)
        #expect(viewModel.scanJobs["s1"]?.total == 10)
        #expect(chinesePhotoCountLabel(viewModel, stub.sessions[0]) == "正在索引 6…")
        // 任务中心行进度实时同步（不必等 2s 轮询）。
        #expect(viewModel.jobs.first(where: { $0.id == "scan" })?.progressCurrent == 6)
    }

    // 原 2 条用例（failed 保留快照 / cancelled 删除快照）：同一终态分支、仅状态不同。
    // present=false 对应原 `scanJobs["s1"] == nil`（整条快照不存在，而非 status 为 nil）；
    // cancelled 分支原无文案断言，故 expectedLabel 为 nil 时不做该断言。
    @Test("终态帧：failed 保留 failed 快照 / cancelled 删除快照", arguments: [
        (AnalysisJobStatus.failed, true, "failed" as String?, "索引失败" as String?),
        (AnalysisJobStatus.cancelled, false, nil as String?, nil as String?),
    ])
    private func terminalFrameMatrix(
        terminalStatus: AnalysisJobStatus,
        expectSnapshotPresent: Bool,
        expectedSnapshotStatus: String?,
        expectedLabel: String?
    ) async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "x")]
        stub.jobs = [StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .running, current: 4, total: 10
        )]
        await viewModel.loadAll()

        let terminal = StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: terminalStatus, current: 4, total: 10
        )
        let event = GatherJobEvent(job: terminal, update: JobProgressUpdate(message: terminalStatus.rawValue))
        #expect(event.isTerminal)
        viewModel.applyJobEvent(event)
        // 同步断言：快照在终态帧下立即更新；终态后的整页刷新由内部 Task 完成。
        #expect((viewModel.scanJobs["s1"] != nil) == expectSnapshotPresent)
        #expect(viewModel.scanJobs["s1"]?.status == expectedSnapshotStatus)
        if let expectedLabel {
            #expect(chinesePhotoCountLabel(viewModel, stub.sessions[0]) == expectedLabel)
        }
    }

    // 非 metadata.scan 帧：不产生 scan 快照，但任务中心行仍实时更新。
    @Test func applyProgressFrameIgnoresNonScanSnapshots() async {
        let (viewModel, stub) = makeStubVM()
        stub.jobs = [StubDashboardProvider.job(id: "t1", scopeId: "s1", status: .running, current: 1, total: 5)]
        await viewModel.loadAll()

        let frame = StubDashboardProvider.job(
            id: "t1", scopeId: "s1", status: .running,
            current: 4, total: 5, progressMessage: "index.scanning"
        )
        viewModel.applyJobEvent(GatherJobEvent(job: frame, update: JobProgressUpdate(current: 4, total: 5)))
        #expect(viewModel.scanJobs.isEmpty)
        #expect(viewModel.jobs.first(where: { $0.id == "t1" })?.progressCurrent == 4)
    }

    // ── 动作委托 ──

    @Test func createDeleteCancelRetryClearDelegateToProvider() async throws {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "既有")]
        await viewModel.loadAll()

        // 创建 → provider 收到调用并刷新列表。
        stub.sessions = [StubDashboardProvider.session(id: "s1"), StubDashboardProvider.session(id: "s2", name: "新")]
        let created = await viewModel.createSession(name: "新", sourcePath: "/tmp/新")
        #expect(created?.id == "new-1")
        #expect(stub.createdNames == ["新"])
        #expect(viewModel.sessions.count == 2)
        #expect(viewModel.isCreating == false)

        // 删除 → provider 收到 id 与显式 confirmed。
        stub.sessions = [StubDashboardProvider.session(id: "s1")]
        let deleted = await viewModel.deleteSession("s2", confirmed: true)
        #expect(deleted == true)
        #expect(stub.deletedIds == ["s2"])
        #expect(stub.deleteConfirmedFlags == [true])
        #expect(viewModel.sessions.count == 1)

        // 任务动作 → provider 按 jobId 调用。
        await viewModel.cancelJob("j9")
        await viewModel.retryJob("j9")
        await viewModel.clearCompletedJobs()
        #expect(stub.cancelCalls == ["j9"])
        #expect(stub.retryCalls == ["j9"])
        #expect(stub.clearCallCount == 1)
        #expect(viewModel.actionError == nil)
    }

    // 假确认防线：confirmed 由调用方显式传入，VM/Provider 不得无条件自证；
    // 取消路径根本不会到达 delete（视图只在确认分支传 true）。
    @Test func deletePassesConfirmationThrough() async throws {
        let (viewModel, stub) = makeStubVM()
        _ = await viewModel.deleteSession("s1", confirmed: false)
        _ = await viewModel.deleteSessions(["s2", "s3"], confirmed: false)
        #expect(stub.deleteConfirmedFlags == [false, false, false])
        _ = await viewModel.deleteSession("s4", confirmed: true)
        #expect(stub.deleteConfirmedFlags.last == true, "确认分支必须原样透传 true")
    }

    // ── 错误态 ──

    @Test func loadFailureSetsFailedPhase() async {
        let (viewModel, stub) = makeStubVM()
        stub.listError = "DB 不可用"
        await viewModel.loadAll()
        // 文案断言与切语言的套件互斥（appLanguage 是进程级全局量）。
        AppLanguageLock.withStableCopy {
            // 非错误码诊断不得直显：经漏斗回退通用文案（原始细节只进日志）。
            #expect(viewModel.phase == .failed(GatherLocalization.errorText("DB 不可用")))
            #expect(viewModel.phase != .failed("DB 不可用"))
        }
    }

    @Test func jobListFailureShowsJobsErrorState() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1")]
        stub.jobListError = "任务读取失败"
        await viewModel.loadAll()
        // sessions 已加载但 jobs 失败 → 任务中心错误态（区别于「暂无后台任务」空态）。
        #expect(viewModel.phase == .loaded)
        AppLanguageLock.withStableCopy {
            #expect(viewModel.jobsError == GatherLocalization.errorText("任务读取失败"))
            #expect(viewModel.jobsError != "任务读取失败", "原始诊断不得直显")
            #expect(viewModel.actionError == nil)
        }

        // 重试成功 → 错误态清除，回到正常列表。
        stub.jobListError = nil
        await viewModel.refreshJobs()
        #expect(viewModel.jobsError == nil)
    }

    @Test func createFailureSetsCreateError() async {
        let (viewModel, stub) = makeStubVM()
        stub.createError = "SESSION_SOURCE_ROOT_FORBIDDEN"
        let created = await viewModel.createSession(name: "x", sourcePath: "/")
        #expect(created == nil)
        // 错误码必须经漏斗翻译成可本地化文案，不得显示裸码。
        AppLanguageLock.withStableCopy {
            #expect(viewModel.createError == GatherLocalization.errorText("SESSION_SOURCE_ROOT_FORBIDDEN"))
            #expect(viewModel.createError != "SESSION_SOURCE_ROOT_FORBIDDEN")
        }
        #expect(viewModel.isCreating == false)
    }

    @Test func workspaceStatusMissingSessionIsSkipped() async throws {
        // 真实库：无该 session → getStatus 返回 nil，不抛错、不进 statuses。
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.sessions.count == 1)
        #expect(viewModel.statuses.isEmpty == false)
    }
}
