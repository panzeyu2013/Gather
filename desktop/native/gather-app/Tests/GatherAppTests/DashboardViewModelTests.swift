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
    private(set) var cancelCalls: [String] = []
    private(set) var retryCalls: [String] = []
    private(set) var clearCallCount = 0

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

    func deleteSession(_ sessionId: String) throws {
        deletedIds.append(sessionId)
    }

    func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? {
        statuses[sessionId]
    }

    func listJobs() throws -> [AnalysisJobData] {
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

@MainActor
private func makeStubVM() -> (DashboardViewModel, StubDashboardProvider) {
    let stub = StubDashboardProvider()
    return (DashboardViewModel(provider: stub), stub)
}

// MARK: - 真实服务集成（临时 SQLite）

private func makeLiveProvider() throws -> (LiveDashboardDataProvider, DBConnection, SQLiteJobStore) {
    // workspace.status 已切到 WorkspaceAPI（Store 连接）：两条连接指向同一临时库文件。
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-dashboard-\(UUID().uuidString).sqlite").path
    let db = try DBConnection(path: path)
    try MigrationRunner().migrate(db)
    let sessionRepo = SessionRepo(connection: db)
    let storeDatabase = try SQLiteDatabase(path: path)
    let container = AppContainer(database: storeDatabase)
    let jobStore = SQLiteJobStore(database: storeDatabase)
    let provider = LiveDashboardDataProvider(
        sessionService: SessionService(
            sessionRepo: sessionRepo,
            photoStore: SQLitePhotoStore(database: storeDatabase),
            faceStore: container.faces,
            connection: db
        ),
        workspace: GatherAPI(container: container).workspace,
        jobService: JobService(jobStore: jobStore)
    )
    return (provider, db, jobStore)
}

private func insertSession(_ db: DBConnection, _ id: String, name: String = "工作区") throws {
    _ = try db.prepare("""
        INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
        VALUES (?, ?, 'photos_loaded', 'idle', 'idle', 'folder', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(name)])
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
        let (provider, db, jobStore) = try makeLiveProvider()
        try insertSession(db, "s1", name: "甲")
        try insertSession(db, "s2", name: "乙")
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
        #expect(viewModel.sessions[0].name == "甲")
        let summary = viewModel.summary()
        #expect(summary.sessionCount == 2)
        #expect(summary.photoCount == 3)
        #expect(summary.pendingXmp == 1)
        #expect(summary.conflictXmp == 1)
        // workspace status 按 session 落表。
        #expect(viewModel.statuses["s1"]?.sessionId == "s1")
        #expect(viewModel.statuses["s1"]?.stage == .imported)
    }

    // 真实库：jobs.list 加载 → attention/history 分组 + scanJobs 种子。
    @Test func loadJobsGroupsAttentionAndHistory() async throws {
        let (provider, db, jobStore) = try makeLiveProvider()
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
        let (provider, db, jobStore) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertJob(db, id: "j1", type: "thumbnail.build", scopeId: "s1", status: "queued", updatedAt: "2026-01-01T00:00:00.000Z")

        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()

        await viewModel.cancelJob("j1")
        #expect(try await jobStore.get("j1")?.status == .cancelled)

        await viewModel.retryJob("j1")
        #expect(try await jobStore.get("j1")?.status == .queued)
        // 动作后列表已刷新（status 同步到内存）。
        #expect(viewModel.jobs.first(where: { $0.id == "j1" })?.status == .queued)
    }

    // 真实库：clear_completed 只清非阶段证据行（metadata.scan 保留）。
    @Test func clearCompletedKeepsStageEvidenceRows() async throws {
        let (provider, db, jobStore) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertJob(db, id: "scan1", type: "metadata.scan", scopeId: "s1", status: "succeeded", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertJob(db, id: "t1", type: "thumbnail.build", scopeId: "s1", status: "succeeded", updatedAt: "2026-01-01T00:00:00.000Z")

        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()
        #expect(viewModel.hasClearableJobs == true)

        await viewModel.clearCompletedJobs()
        let remaining = try await provider.listJobs()
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
        #expect(viewModel.photoCountLabel(for: truncated) == "≥12 张照片")
        // count：截断导入但 scan succeeded → 精确计数（≥ 前缀去除）。
        await seedScan(status: "succeeded", current: 12, total: 12)
        #expect(viewModel.photoCountLabel(for: truncated) == "12 张照片")
        // active：有进度 → 正在索引 N。
        await seedScan(status: "running", current: 4, total: 20)
        #expect(viewModel.photoCountLabel(for: truncated) == "正在索引 4…")
        // active：进度 0/0 → 扫描中。
        await seedScan(status: "queued", current: 0, total: 0)
        #expect(viewModel.photoCountLabel(for: truncated) == "扫描中…")
        // failed：索引失败（绝不以阶段计数作权威展示）。
        await seedScan(status: "failed", current: 2, total: 20)
        #expect(viewModel.photoCountLabel(for: truncated) == "索引失败")
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
        #expect(viewModel.photoCountLabel(for: stub.sessions[0]) == "正在索引 2…")

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
        #expect(viewModel.photoCountLabel(for: stub.sessions[0]) == "正在索引 6…")
        // 任务中心行进度实时同步（不必等 2s 轮询）。
        #expect(viewModel.jobs.first(where: { $0.id == "scan" })?.progressCurrent == 6)
    }

    // 终态帧：failed → 快照保留为 failed（卡片「索引失败 + 重试」）。
    @Test func applyTerminalFailedEventKeepsFailedSnapshot() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "x")]
        stub.jobs = [StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .running, current: 4, total: 10
        )]
        await viewModel.loadAll()

        let terminal = StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .failed, current: 4, total: 10
        )
        let event = GatherJobEvent(job: terminal, update: JobProgressUpdate(message: "failed"))
        #expect(event.isTerminal)
        viewModel.applyJobEvent(event)
        // 同步断言：快照立即置为 failed；终态后的整页刷新由内部 Task 完成。
        #expect(viewModel.scanJobs["s1"]?.status == "failed")
        #expect(viewModel.photoCountLabel(for: stub.sessions[0]) == "索引失败")
    }

    // 终态帧：cancelled → 快照删除（卡片回到截断 ≥ 计数，对齐 TS 终态分支）。
    @Test func applyTerminalCancelledEventDropsSnapshot() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "x")]
        stub.jobs = [StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .running, current: 3, total: 10
        )]
        await viewModel.loadAll()

        let terminal = StubDashboardProvider.job(
            id: "scan", type: .metadataScan, scopeId: "s1",
            status: .cancelled, current: 3, total: 10
        )
        viewModel.applyJobEvent(GatherJobEvent(job: terminal, update: JobProgressUpdate(message: "cancelled")))
        #expect(viewModel.scanJobs["s1"] == nil)
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

        // 删除 → provider 收到 id。
        stub.sessions = [StubDashboardProvider.session(id: "s1")]
        let deleted = await viewModel.deleteSession("s2")
        #expect(deleted == true)
        #expect(stub.deletedIds == ["s2"])
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

    // ── 错误态 ──

    @Test func loadFailureSetsFailedPhase() async {
        let (viewModel, stub) = makeStubVM()
        stub.listError = "DB 不可用"
        await viewModel.loadAll()
        #expect(viewModel.phase == .failed("DB 不可用"))
    }

    @Test func jobListFailureShowsJobsErrorState() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1")]
        stub.jobListError = "任务读取失败"
        await viewModel.loadAll()
        // sessions 已加载但 jobs 失败 → 任务中心错误态（区别于「暂无后台任务」空态）。
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.jobsError == "任务读取失败")
        #expect(viewModel.actionError == nil)

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
        #expect(viewModel.createError == "SESSION_SOURCE_ROOT_FORBIDDEN")
        #expect(viewModel.isCreating == false)
    }

    @Test func workspaceStatusMissingSessionIsSkipped() async throws {
        // 真实库：无该 session → getStatus 返回 nil，不抛错、不进 statuses。
        let (provider, db, jobStore) = try makeLiveProvider()
        try insertSession(db, "s1")
        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()
        #expect(viewModel.phase == .loaded)
        #expect(viewModel.sessions.count == 1)
        #expect(viewModel.statuses.isEmpty == false)
    }
}
