// desktop/native/gather-app/Tests/GatherAppTests/DashboardViewModelTests.swift
// Phase 3.1 Dashboard 视图模型行为测试。
// 覆盖：workspace status 加载、jobs 列表加载、scanJobs 派生、卡片计数文案
// （TS deriveCardIndexKind/photoCountLabel 语义）、cancel/retry/clear_completed
// 调用正确性、错误态（stub 注入）。
// 集成用例用真实临时 SQLite + 已移植服务。

import Foundation
import Testing
@testable import GatherUI
@testable import GatherHost
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication
import GatherTestSupport

// MARK: - Stub（错误态注入）

private final class StubDashboardProvider: DashboardDataProvider, @unchecked Sendable {
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
    /// 真正删掉的 id（deleteSessions 默认实现是逐条删除，失败前可能已删一部分）。
    private(set) var deleteSucceededIds: [String] = []
    /// 删除失败注入：成功 N 条后抛错（nil = 不注入；默认实现逐条删除）。
    var deleteFailureAfter: Int?
    private(set) var cancelCalls: [String] = []
    private(set) var retryCalls: [String] = []
    private(set) var clearCallCount = 0
    /// 入队 metadata.scan 的作用域参数（nil = 目录全树；非 nil = 显式集合）。
    private(set) var indexScanCalls: [(sessionId: String, requestedPaths: [String]?)] = []

    func listSessions() async throws -> [SessionData] {
        if let listError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: listError])
        }
        return sessions
    }

    func createSession(name: String, source: String, sourcePath: String) async throws -> SessionData {
        if let createError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: createError])
        }
        createdNames.append(name)
        return Self.session(id: "new-\(createdNames.count)", name: name, sourcePath: sourcePath)
    }

    func deleteSession(_ sessionId: String, confirmed: Bool) async throws {
        deletedIds.append(sessionId)
        deleteConfirmedFlags.append(confirmed)
        if let deleteFailureAfter, deleteSucceededIds.count >= deleteFailureAfter {
            throw NSError(
                domain: "stub",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "delete failed"]
            )
        }
        deleteSucceededIds.append(sessionId)
        sessions.removeAll { $0.id == sessionId }
    }

    func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? {
        statuses[sessionId]
    }

    func listJobs(includeCheckpoint: Bool) async throws -> [AnalysisJobData] {
        if let jobListError {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: jobListError])
        }
        return jobs
    }

    func cancelJob(_ jobId: String) async throws -> Bool {
        cancelCalls.append(jobId)
        return true
    }

    func retryJob(_ jobId: String) async throws -> Bool {
        retryCalls.append(jobId)
        return true
    }

    func clearCompletedJobs() async throws -> Int {
        clearCallCount += 1
        return 1
    }

    func retryIndexScan(sessionId: String) async throws {
        indexScanCalls.append((sessionId, nil))
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

/// 以 zh-CN 渲染卡片计数文案（4b-2e：VM 只返回 LocalizedText，渲染期显式传语言；
/// 不再依赖进程级语言，故无需 AppLanguageLock）。
@MainActor
private func chinesePhotoCountLabel(_ viewModel: DashboardViewModel, _ session: SessionData) -> String {
    L10n(language: .zhCN).resolve(viewModel.photoCountLabel(for: session))
}

@MainActor
private func makeStubVM() -> (DashboardViewModel, StubDashboardProvider) {
    let stub = StubDashboardProvider()
    return (DashboardViewModel(provider: stub), stub)
}

// MARK: - 真实服务集成（临时 SQLite）

private func makeLiveProvider() throws -> (LiveDashboardDataProvider, DBConnection) {
    let db = try makeTestDB()
    let sessionRepo = SessionRepo(connection: db)
    let photoRepo = PhotoRepo(connection: db)
    let jobService = JobService(repo: AnalysisJobRepo(connection: db))
    // WP4b：Live provider 已移到 GatherHost；测试直接构造类型化 Live API，
    // 不再经同步端口注入同步核。
    let sessionAPI = LiveSessionAPI(
        sessionService: SessionService(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            faceRepo: FaceRepo(connection: db),
            connection: db
        ),
        workspaceStatusService: WorkspaceStatusService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: photoRepo
        ),
        jobService: jobService
    )
    let jobAPI = LiveJobAPI(jobService: jobService)
    let provider = LiveDashboardDataProvider(
        sessionAPI: sessionAPI,
        jobAPI: jobAPI
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
        INSERT INTO sessions (id, name, status, created_at, updated_at)
        VALUES (?, ?, 'photos_loaded', ?, ?)
    """).run([.text(id), .text(name), .text(updatedAt), .text(updatedAt)])
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, '', 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
    """).run([.text(id), .text(sessionId), .text("/tmp/\(id).jpg"), .text("\(id).jpg")])
}

/// 种子一条交付行（待同步写回计数，对齐 WorkspaceStatusServiceTests）。
/// 工作区计数只读 deliveries / delivery_items，item 挂到本会话已有照片 p1。
private func insertDeliveryRow(_ db: DBConnection, sessionId: String, xmpPath: String, status: String) throws {
    let now = "2026-01-01T00:00:00.000Z"
    _ = try db.prepare("""
        INSERT INTO deliveries (xmp_path, photo_path, status, revision, created_at, updated_at)
        VALUES (?, '/tmp/p.jpg', ?, 1, ?, ?)
    """).run([.text(xmpPath), .text(status), .text(now), .text(now)])
    let deliveryId = db.lastInsertRowid
    _ = try db.prepare("""
        INSERT INTO delivery_items (delivery_id, photo_id, module, status, created_at, updated_at)
        VALUES (?, 'p1', 'culling', 'pending', ?, ?)
    """).run([.int(deliveryId), .text(now), .text(now)])
    _ = try db.prepare("""
        INSERT INTO delivery_sessions (delivery_id, session_id, created_at)
        VALUES (?, ?, ?)
    """).run([.int(deliveryId), .text(sessionId), .text(now)])
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

    // 真实库：sessions + photos + deliveries → 概览计数正确（workspace status 加载）。
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
        try insertDeliveryRow(db, sessionId: "s1", xmpPath: "a.xmp", status: "pending")
        try insertDeliveryRow(db, sessionId: "s1", xmpPath: "b.xmp", status: "conflict")

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
    // 侧栏轻量加载：只更新 sessions，不加载 workspace status / jobs。
    @Test func refreshSidebarSessionsLoadsListWithoutStatuses() async {
        let stub = StubDashboardProvider()
        stub.sessions = [
            StubDashboardProvider.session(id: "s1", name: "甲", sourcePath: "/tmp/a"),
            StubDashboardProvider.session(id: "s2", name: "乙", sourcePath: "/tmp/b"),
        ]
        let viewModel = DashboardViewModel(provider: stub)
        await viewModel.refreshSidebarSessions()
        #expect(viewModel.sessions.map(\.id) == ["s1", "s2"])
        #expect(viewModel.statuses.isEmpty)
        #expect(viewModel.jobs.isEmpty)
    }

    // 侧栏是辅助导航：查询失败时保留上一份列表，不闪空、不覆盖页面错误。
    @Test func refreshSidebarSessionsKeepsPreviousListOnFailure() async {
        let stub = StubDashboardProvider()
        stub.sessions = [StubDashboardProvider.session(id: "s1", name: "甲")]
        let viewModel = DashboardViewModel(provider: stub)
        await viewModel.refreshSidebarSessions()
        stub.listError = "boom"
        stub.sessions = [StubDashboardProvider.session(id: "s2", name: "乙")]
        await viewModel.refreshSidebarSessions()
        #expect(viewModel.sessions.map(\.id) == ["s1"])
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
    // P1-1：生产路径由 SessionAPI.create 内部入队一次；Dashboard 只消费结果，
    // 不得再调 JobAPI.start（同 dedupeKey 会被静默去重，从而掩盖重复副作用）。
    @Test func directoryCreateScanUsesDirectoryScope() async throws {
        // 生产路径（LiveSessionAPI）：create 内部入队一次；JobAPI.start 零调用。
        let db = try makeTestDB()
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let sessionAPI = LiveSessionAPI(
            sessionService: SessionService(
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                faceRepo: FaceRepo(connection: db),
                connection: db
            ),
            workspaceStatusService: WorkspaceStatusService(
                connection: db,
                sessionRepo: sessionRepo,
                photoRepo: photoRepo
            ),
            jobService: jobService
        )
        let jobStub = B5bJobAPIStub()
        let provider = LiveDashboardDataProvider(
            sessionAPI: sessionAPI,
            jobAPI: jobStub
        )
        let apiViewModel = DashboardViewModel(provider: provider)
        let directory = NSTemporaryDirectory() + "/gather-dir-create-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let apiCreated = await apiViewModel.createSession(
            name: "API 目录", sourcePath: directory, with: L10n(language: .zhCN))
        let session = try #require(apiCreated)
        #expect(jobStub.startRequests.isEmpty, "Dashboard 不得在 API 路径二次入队")

        let scans = try AnalysisJobRepo(connection: db).list().filter {
            $0.type == .metadataScan && $0.scopeId == session.id
        }
        #expect(scans.count == 1, "目录创建只允许一条 metadata.scan")
        #expect(scans.first?.dedupeKey == "metadata.scan:\(session.id)")
        #expect(
            scans.first?.checkpoint[JobCreateParams.metadataScanRequestedPathsKey] == nil,
            "目录全树作用域不得携带 requestedPaths"
        )
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

    // R1 P1-3：JobAPI 路径的 retry 必须原样使用协议层工厂（dedupeKey/checkpoint
    // 不得在 Dashboard 复刻）。捕获 start 请求与工厂产出做整值比较。
    @Test func retryScanUsesMetadataScanFactoryThroughJobAPI() async {
        let jobs = B5bJobAPIStub()
        let provider = LiveDashboardDataProvider(
            sessionAPI: B8SessionAPIStub(),
            jobAPI: jobs
        )
        let viewModel = DashboardViewModel(provider: provider)

        await viewModel.retryScan(sessionId: "s1")

        #expect(
            jobs.startRequests == [JobCreateParams.metadataScan(sessionId: "s1", requestedPaths: nil)],
            "Dashboard retry 必须走协议层 metadata.scan 工厂"
        )
        #expect(viewModel.actionError == nil)
    }

    // WP4b：Host 的 async provider 也必须是工厂产出（不得在适配层复刻
    // dedupeKey/checkpoint）；直接调用 provider 的 retry 端口做整值比较。
    @Test func providerRetryIndexScanUsesMetadataScanFactory() async throws {
        let jobs = B5bJobAPIStub()
        let provider = LiveDashboardDataProvider(
            sessionAPI: B8SessionAPIStub(),
            jobAPI: jobs
        )

        try await provider.retryIndexScan(sessionId: "s1")

        #expect(
            jobs.startRequests == [JobCreateParams.metadataScan(sessionId: "s1", requestedPaths: nil)],
            "provider.retryIndexScan 必须走协议层 metadata.scan 工厂"
        )
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

        let outcome = try await provider.createSessionFromFiles(
            name: "C1", source: "capture-one", filepaths: [a, b])
        #expect(outcome.session.sourcePath == "", "文件导入不得把公共父目录落成 source_path")
        let listed = try await provider.listSessions().first { $0.id == outcome.session.id }
        #expect(listed?.sourcePath == "", "落库的 source_path 也必须为空")

        // Live provider 的 createSessionFromFiles 已在 API 内入队一次；契约断言
        // 需要完整 checkpoint（Dashboard 运行时走轻投影）。
        let selected = normalizeImportFilepaths([a, b])
        let jobs = try await provider.listJobs(includeCheckpoint: true)
        let scan = try #require(jobs.first {
            $0.type == .metadataScan && $0.scopeId == outcome.session.id
        })
        #expect(scan.checkpoint[JobCreateParams.metadataScanRequestedPathsKey] != nil,
                "契约键名必须与 GatherApp.importFiles 一致")
        let requested = scan.checkpoint[JobCreateParams.metadataScanRequestedPathsKey]?
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
        let remaining = try await provider.listJobs(includeCheckpoint: true)
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
        // 渲染期语言：同一快照在 en 下输出英文（VM 不读全局语言）。
        #expect(L10n(language: .en).resolve(viewModel.photoCountLabel(for: truncated)) == "≥12 photos")
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
        let created = await viewModel.createSession(
            name: "新", sourcePath: "/tmp/新", with: L10n(language: .zhCN))
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
    // 未确认路径在 VM 入口显式失败，**根本不触达 provider**（视图只在确认分支传 true）。
    @Test func deletePassesConfirmationThrough() async throws {
        let (viewModel, stub) = makeStubVM()
        let single = await viewModel.deleteSession("s1", confirmed: false)
        #expect(single == false)
        let batch = await viewModel.deleteSessions(["s2", "s3"], confirmed: false)
        #expect(batch == false)
        #expect(stub.deleteConfirmedFlags.isEmpty, "未确认不得把 false 当成已确认去调用 provider")
        #expect(viewModel.actionError?.code == "SESSION_DELETE_NOT_CONFIRMED")

        viewModel.actionError = nil
        _ = await viewModel.deleteSession("s4", confirmed: true)
        #expect(stub.deleteConfirmedFlags == [true], "确认分支必须原样透传 true")
    }

    // R4 P1-3：删除成功后逐 id 交接宿主（RootView 注入 SessionStore.endSession，
    // 由 store 清 active/pinned/lastSessionId 并 close workspace）。
    @Test func deleteNotifiesHostForEachDeletedSession() async {
        let (viewModel, stub) = makeStubVM()
        #expect(viewModel.onSessionDeleted == nil, "未注入时不得回调（单测/Preview 默认静默）")

        var deleted: [String] = []
        viewModel.onSessionDeleted = { deleted.append($0) }

        stub.sessions = [
            StubDashboardProvider.session(id: "s1"),
            StubDashboardProvider.session(id: "s2"),
        ]
        await viewModel.loadAll()
        // 单删：只交接被删 id。
        let single = await viewModel.deleteSession("s1", confirmed: true)
        #expect(single)
        #expect(deleted == ["s1"])

        // 批量成功：入参每个 id 各交接一次（顺序 = 入参顺序）。
        stub.sessions = [
            StubDashboardProvider.session(id: "s2"),
            StubDashboardProvider.session(id: "s3"),
        ]
        await viewModel.loadAll()
        let batch = await viewModel.deleteSessions(["s2", "s3"], confirmed: true)
        #expect(batch)
        #expect(deleted == ["s1", "s2", "s3"])

        // 空批量：没有删除就没有交接（也不报错）。
        let empty = await viewModel.deleteSessions([], confirmed: true)
        #expect(empty)
        #expect(deleted == ["s1", "s2", "s3"], "空批量不得产生交接")
    }

    // 类型化 API 路径（单事务）：成功 → 每个 id 交接；查询层确认真的删掉了。
    @Test func apiDeleteNotifiesEveryDeletedId() async throws {
        let (provider, db) = try makeLiveProvider()
        try insertSession(db, "s1")
        try insertSession(db, "s2")
        try insertSession(db, "s3")
        let viewModel = DashboardViewModel(provider: provider)
        await viewModel.loadAll()

        var deleted: [String] = []
        viewModel.onSessionDeleted = { deleted.append($0) }

        let batch = await viewModel.deleteSessions(["s1", "s2"], confirmed: true)
        #expect(batch)
        #expect(deleted == ["s1", "s2"])
        #expect(try await provider.listSessions().map(\.id) == ["s3"])

        let single = await viewModel.deleteSession("s3", confirmed: true)
        #expect(single)
        #expect(deleted == ["s1", "s2", "s3"])
        #expect(try await provider.listSessions().isEmpty)
    }

    // 端口契约：批量删除是原子的；即便实现内部已部分执行，VM 也不得用失败后的
    // 列表反推「已删 id」（查询失败/空表会把存活会话误判成已删，误清 workspace）。
    @Test func failedBatchDeleteNeverNotifiesPartialDeletions() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [
            StubDashboardProvider.session(id: "s1"),
            StubDashboardProvider.session(id: "s2"),
            StubDashboardProvider.session(id: "s3"),
        ]
        await viewModel.loadAll()
        var deleted: [String] = []
        viewModel.onSessionDeleted = { deleted.append($0) }

        stub.deleteFailureAfter = 1
        let ok = await viewModel.deleteSessions(["s1", "s2", "s3"], confirmed: true)
        #expect(ok == false)
        #expect(stub.deleteSucceededIds == ["s1"], "夹具确实已部分执行，用来证明 VM 不据此交接")
        #expect(deleted.isEmpty, "抛错 = 未确认成功，一个都不交接")
        #expect(viewModel.actionError != nil)
        #expect(stub.sessions.map(\.id) == ["s2", "s3"], "未删的会话仍在服务端")
    }

    // 类型化 API 的批量删除是单事务：失败即整体回滚，一个都不交接。
    @Test func apiDeleteFailureNotifiesNothing() async {
        let provider = LiveDashboardDataProvider(
            sessionAPI: B8SessionAPIStub(),
            jobAPI: B5bJobAPIStub()
        )
        let viewModel = DashboardViewModel(provider: provider)
        var deleted: [String] = []
        viewModel.onSessionDeleted = { deleted.append($0) }

        let ok = await viewModel.deleteSessions(["s1", "s2"], confirmed: true)
        #expect(ok == false)
        #expect(deleted.isEmpty, "事务回滚 = 一个都没删，不得清任何 workspace")
        #expect(viewModel.actionError != nil)
    }

    // ── 错误态 ──

    @Test func loadFailureSetsFailedPhase() async throws {
        let (viewModel, stub) = makeStubVM()
        stub.listError = "DB 不可用"
        await viewModel.loadAll()
        // Cut 4 / 4a-3b-2b：API/系统散文只进 diagnostic，不上屏（policy）。
        let error = try #require(viewModel.phase.error)
        #expect(error.code.isEmpty)
        #expect(error.diagnostic == "DB 不可用")
        #expect(CommandErrorText.resolve(error, with: L10n(language: .zhCN)) == L10n(language: .zhCN).errorText("NOT_A_CODE"))
    }

    @Test func jobListFailureShowsJobsErrorState() async {
        let (viewModel, stub) = makeStubVM()
        stub.sessions = [StubDashboardProvider.session(id: "s1")]
        stub.jobListError = "任务读取失败"
        await viewModel.loadAll()
        // sessions 已加载但 jobs 失败 → 任务中心错误态（区别于「暂无后台任务」空态）。
        #expect(viewModel.phase == .loaded)
        AppLanguageLock.withStableCopy {
            let error = viewModel.jobsError
            #expect(error?.code.isEmpty == true)
            #expect(error?.diagnostic == "任务读取失败")
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == L10n(language: .zhCN).errorText("任务读取失败"))
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
        let created = await viewModel.createSession(
            name: "x", sourcePath: "/", with: L10n(language: .zhCN))
        #expect(created == nil)
        // 错误码必须经漏斗翻译成可本地化文案，不得显示裸码。
        AppLanguageLock.withStableCopy {
            let error = viewModel.createError
            #expect(error?.code == "SESSION_SOURCE_ROOT_FORBIDDEN")
            #expect(CommandErrorText.resolve(error!, with: L10n(language: .zhCN)) == L10n(language: .zhCN).errorText("SESSION_SOURCE_ROOT_FORBIDDEN"))
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
