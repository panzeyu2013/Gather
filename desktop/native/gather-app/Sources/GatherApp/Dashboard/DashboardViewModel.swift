// desktop/native/gather-app/Sources/GatherApp/Dashboard/DashboardViewModel.swift
// Phase 3.1 Dashboard：视图模型（服务可注入，同进程直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Dashboard/index.tsx（scanJobs 种子/卡片计数文案）
//       + pages/Jobs/index.tsx（任务面板交互）+ hooks/useWorkspaceStatus.ts（状态聚合）
//
// 差异说明（有意）：
// - TS 的 react-query 轮询 + jobs:progress 事件 → startAutoRefresh 轮询
//   （活跃期 2s / 常驻 30s）+ applyJobEvent 逐帧事件接线（metadata.scan
//   快照与任务中心行实时更新，终态帧整页刷新）；
// - 工作区概览（工作区数/照片数/待写回/冲突/离线）为 SwiftUI 侧聚合，
//   数据源与 useWorkspaceStatus 相同（workspace.status）。
import Foundation
import GatherCore

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态）或
/// 真实服务（LiveDashboardDataProvider + 临时 SQLite）。
protocol DashboardDataProvider {
    func listSessions() throws -> [SessionData]
    func createSession(name: String, source: String, sourcePath: String) throws -> SessionData
    /// TS session.create：以文件列表建库（Capture One 导入），返回含
    /// failedFiles 计数的结果，供截断导入横幅提示（TS Toast L208-219）。
    /// source_path 恒为空：作用域由 metadata.scan 的 requestedPaths 承担。
    func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String]
    ) throws -> CreateSessionOutcome
    /// 删除会话。confirmed 是显式参数：只允许 UI 确认分支传 true，
    /// Provider/VM 不得自证确认（与 Library/Similarity/FaceKeywording 同一防线）。
    func deleteSession(_ sessionId: String, confirmed: Bool) throws
    func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws
    func workspaceStatus(sessionId: String) throws -> WorkspaceStatus?
    func listJobs() throws -> [AnalysisJobData]
    func cancelJob(_ jobId: String) throws -> Bool
    func retryJob(_ jobId: String) throws -> Bool
    func clearCompletedJobs() throws -> Int
    /// 入队 metadata.scan。requestedPaths 非空 = 显式集合作用域（写入
    /// checkpoint["requestedPaths"]，与 GatherApp.importFiles 同键名）；
    /// nil = 目录作用域（扫 session.source_path 全树，仅目录导入/目录会话）。
    func enqueueIndexScan(sessionId: String, requestedPaths: [String]?) throws
}

extension DashboardDataProvider {
    /// 测试 provider 不需要启动后台 worker；真实 provider 在这里接入
    /// metadata.scan，保证“创建工作区”是创建 + 索引的一跳流程。
    func enqueueIndexScan(sessionId: String, requestedPaths: [String]?) throws {}

    /// 默认实现（stub 用）：退化为 createSession（无目录作用域），无失败文件统计。
    func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String]
    ) throws -> CreateSessionOutcome {
        let session = try createSession(name: name, source: source, sourcePath: "")
        return CreateSessionOutcome(session: session, failedFiles: [], added: 0)
    }

    /// 默认实现（stub 用）：逐个删除，confirmed 原样透传。
    func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws {
        for sessionId in sessionIds {
            try deleteSession(sessionId, confirmed: confirmed)
        }
    }
}

/// TS: session.create 响应 —— session 数据 + 加照片结果计数。
struct CreateSessionOutcome: Equatable, Sendable {
    var session: SessionData
    var failedFiles: [String]
    var added: Int
}

/// 真实实现：同进程直连已移植 GatherCore 服务（与 SessionCommandRouter
/// makeDefault 共用装配，见 GatherApp.bootstrap）。
final class LiveDashboardDataProvider: DashboardDataProvider {
    private let sessionService: SessionService
    private let workspaceStatusService: WorkspaceStatusService
    private let jobService: JobService

    init(
        sessionService: SessionService,
        workspaceStatusService: WorkspaceStatusService,
        jobService: JobService
    ) {
        self.sessionService = sessionService
        self.workspaceStatusService = workspaceStatusService
        self.jobService = jobService
    }

    func listSessions() throws -> [SessionData] {
        try sessionService.listSessions()
    }

    func createSession(name: String, source: String, sourcePath: String) throws -> SessionData {
        try sessionService.createFromDirectory(name: name, sourcePath: sourcePath)
    }

    /// TS session.create：文件列表建库 + addPhotos（source 透传，C1 为
    /// "capture_one"），返回会话与失败文件计数；与 createFromDirectory
    /// 不同，照片在创建时写入，索引 job 随后补齐元数据。
    ///
    /// source_path 恒为空：文件导入的作用域由 metadata.scan job 的
    /// checkpoint["requestedPaths"] 显式携带（与 GatherApp.importFiles 同一
    /// 契约）。公共父目录只允许用于取名——落库会让全量扫描（requestedPaths=nil）
    /// 重新递归该目录，重新引入「导入范围失控」。
    func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String]
    ) throws -> CreateSessionOutcome {
        let created = try sessionService.createSession(name: name, source: source)
        let result = try sessionService.addPhotos(
            sessionId: created.id,
            filepaths: filepaths,
            source: source
        )
        // TS 在 addPhotos 后重取 session（状态/photoCount 已更新）。
        let session = try sessionService.getSession(created.id) ?? created
        return CreateSessionOutcome(session: session, failedFiles: result.failedFiles, added: result.added)
    }

    func deleteSession(_ sessionId: String, confirmed: Bool) throws {
        // confirmed 显式透传（对齐 TS ConfirmDialog → sessionApi.delete）。
        try sessionService.deleteSession(sessionId, confirmed: confirmed)
    }

    func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws {
        // confirmed 显式透传（对齐 TS ConfirmDialog → sessionApi.deleteMany）。
        _ = try sessionService.deleteSessions(sessionIds, confirmed: confirmed)
    }

    func workspaceStatus(sessionId: String) throws -> WorkspaceStatus? {
        try workspaceStatusService.getStatus(sessionId: sessionId)
    }

    func listJobs() throws -> [AnalysisJobData] {
        try jobService.list()
    }

    func cancelJob(_ jobId: String) throws -> Bool {
        try jobService.cancel(jobId)
    }

    func retryJob(_ jobId: String) throws -> Bool {
        try jobService.retry(jobId)
    }

    func clearCompletedJobs() throws -> Int {
        try jobService.clearCompleted()
    }

    func enqueueIndexScan(sessionId: String, requestedPaths: [String]?) throws {
        _ = try jobService.create(JobCreateParams(
            type: .metadataScan,
            scopeType: "session",
            scopeId: sessionId,
            dedupeKey: "metadata.scan:\(sessionId)",
            checkpoint: GatherApp.scanScopeCheckpoint(requestedPaths: requestedPaths)
        ))
    }
}

/// TS: Dashboard/index.tsx DashboardScanJob（每 session 最近 metadata.scan 快照）。
struct DashboardScanJob: Equatable, Sendable {
    var status: String?
    var current: Int
    var total: Int
}

/// TS: DashboardCardIndexKind（卡片计数文案决策，design_improvements.md 3.3.3/3.3.4）。
enum DashboardCardIndexKind: Equatable {
    case failed
    case active
    case count
}

/// TS: deriveCardIndexKind（Dashboard/index.tsx:52-61）。
func deriveCardIndexKind(_ job: DashboardScanJob?) -> DashboardCardIndexKind {
    if let job {
        if job.status == "failed" { return .failed }
        if job.status == "succeeded" { return .count }
        if job.status == nil || ["queued", "running", "cancelling"].contains(job.status!) {
            return .active
        }
    }
    return .count
}

/// 工作区概览聚合（SwiftUI 侧新增；数据源与 useWorkspaceStatus 一致）。
struct DashboardSummary: Equatable {
    var sessionCount: Int
    var photoCount: Int
    var pendingXmp: Int
    var conflictXmp: Int
    var offlinePhotos: Int
}

// MARK: - Capture One 导入预检门控（TS utils/c1-preflight.ts）

/// TS C1PreflightCheck：预检单格检查。
struct C1PreflightCheckItem: Equatable, Identifiable, Sendable {
    var key: String
    var label: String
    var passed: Bool
    var id: String { key }
}

/// TS C1PreflightResult：passed + checks + 引导文案。
struct C1PreflightResult: Equatable, Sendable {
    var passed: Bool
    var checks: [C1PreflightCheckItem]
    var guidance: String?

    /// TS evaluateC1Preflight：检查清单固定四层（超时额外加一格）。
    static func build(from status: C1PreflightStatus) -> C1PreflightResult {
        var items: [(key: String, label: String, passed: Bool)] = [
            ("reachable", GatherLocalization.l("可连接 Capture One（AppleScript）"), status.reachable),
            ("appRunning", GatherLocalization.l("Capture One 正在运行"), status.appRunning),
            ("documentOpen", GatherLocalization.l("Capture One 已打开文档"), status.documentOpen),
            ("automationAuthorized", GatherLocalization.l("自动化权限已授权"), status.automationAuthorized),
        ]
        if status.timedOut {
            items.append(("timeout", GatherLocalization.l("检测超时"), false))
        }
        let checks = items.map { C1PreflightCheckItem(key: $0.key, label: $0.label, passed: $0.passed) }
        let failedKeys = checks.filter { !$0.passed }.map(\.key)
        return C1PreflightResult(
            passed: failedKeys.isEmpty,
            checks: checks,
            guidance: guidance(for: failedKeys)
        )
    }

    /// 预检调用整体失败（桥不可用）时的兜底：四层全失败（TS failedC1Preflight）。
    static func failed() -> C1PreflightResult {
        build(from: C1PreflightStatus(
            reachable: false,
            appRunning: false,
            automationAuthorized: false,
            documentOpen: false,
            timedOut: false
        ))
    }

    /// TS c1PreflightGuidance 优先级：timeout > reachable > automationAuthorized
    /// > appRunning > documentOpen。
    private static func guidance(for failedKeys: [String]) -> String? {
        if failedKeys.isEmpty { return nil }
        if failedKeys.contains("timeout") {
            return GatherLocalization.l("检测超时，请重试")
        }
        if failedKeys.contains("reachable") {
            return GatherLocalization.l("无法通过 AppleScript 访问 Capture One。请确认系统环境正常，然后重新检查。")
        }
        if failedKeys.contains("automationAuthorized") {
            return GatherLocalization.l("自动化权限未授权：请在 系统设置 → 隐私与安全性 → 自动化 中允许 Gather 控制 Capture One，然后重新检查。")
        }
        if failedKeys.contains("appRunning") {
            return GatherLocalization.l("未检测到 Capture One 正在运行。请先启动 Capture One，然后重新检查。")
        }
        if failedKeys.contains("documentOpen") {
            return GatherLocalization.l("Capture One 未打开任何文档。请先打开一个目录（Document），然后重新检查。")
        }
        return nil
    }
}

/// Dashboard 视图模型：加载/轮询/动作（创建、删除、任务 cancel/retry/clear）。
@MainActor
@Observable
final class DashboardViewModel {
    /// 新建工作区来源（TS SOURCE_OPTIONS）。
    enum SessionSource: String, Equatable, CaseIterable, Identifiable {
        case local
        case captureOne = "capture-one"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .local: return GatherLocalization.l("本地文件夹")
            case .captureOne: return "Capture One"
            }
        }
    }

    /// C1 预检展示相位（TS c1Preflight { checking, result }）。
    enum C1PreflightPhase: Equatable {
        case idle
        case checking
        case finished(C1PreflightResult)
    }

    private let provider: DashboardDataProvider
    private var autoRefreshTask: Task<Void, Never>?
    private var lastFullRefreshAt = Date.distantPast
    private var lastSessionsRefreshAt = Date.distantPast
    /// 页面可见性（RootView 驱动，审计 4 的可见性钩子）：opacity 常驻方案
    /// 下 onAppear/onDisappear 不触发，由导航切换显式置位；隐藏期间
    /// startAutoRefresh 拒绝启动轮询（DashboardView 的 .task 初次必执行，
    /// 需以此兜底启动即隐藏的深链场景）。
    var isVisible = true

    private(set) var phase: LoadPhase = .loading
    private(set) var sessions: [SessionData] = []
    private(set) var statuses: [String: WorkspaceStatus] = [:]
    private(set) var scanJobs: [String: DashboardScanJob] = [:]
    private(set) var jobs: [AnalysisJobData] = []
    private(set) var isCreating = false
    /// 新建工作区表单错误（sheet 内展示）。
    private(set) var createError: String?
    /// 删除/任务操作错误（页面级横幅）。
    private(set) var actionError: String?
    /// jobs.list 加载失败（任务中心错误态；区别于「暂无后台任务」空态）。
    private(set) var jobsError: String?
    /// C1 预检相位（sheet 内展示）。
    private(set) var c1Preflight: C1PreflightPhase = .idle
    /// C1 桥：测试可注入；默认取 CaptureOneBridge.shared（bootstrap 注册）。
    var captureOne: CaptureOneBridge?

    init(provider: DashboardDataProvider) {
        self.provider = provider
    }

    // MARK: 加载

    func loadAll() async {
        phase = .loading
        await refreshAll()
    }

    func refreshSessions() async {
        lastSessionsRefreshAt = Date()
        do {
            let sessions = try provider.listSessions()
            self.sessions = sessions
            // workspace.status：单 session 失败跳过，不影响整体刷新。
            var statuses: [String: WorkspaceStatus] = [:]
            for session in sessions {
                if let status = try? provider.workspaceStatus(sessionId: session.id) {
                    statuses[session.id] = status
                }
            }
            self.statuses = statuses
            settlePhase()
        } catch {
            if sessions.isEmpty {
                phase = .failed(Self.message(for: error))
            } else {
                actionError = Self.message(for: error)
            }
        }
    }

    func refreshJobs() async {
        do {
            let jobs = try provider.listJobs()
            self.jobs = jobs
            self.scanJobs = Self.seedScanJobs(from: jobs)
            self.jobsError = nil
            settlePhase()
        } catch {
            if sessions.isEmpty {
                phase = .failed(Self.message(for: error))
            } else {
                jobsError = Self.message(for: error)
            }
        }
    }

    /// 刷新成功只提升 loading → loaded；已失败（首屏错误）不被后续刷新覆盖。
    private func settlePhase() {
        if phase == .loading { phase = .loaded }
    }

    /// TS: Dashboard/index.tsx:96-116 scanJobs 种子逻辑：jobs.list 中
    /// type == 'metadata.scan' 按 scopeId 取 updatedAt 最新者。
    static func seedScanJobs(from jobs: [AnalysisJobData]) -> [String: DashboardScanJob] {
        var latest: [String: (snapshot: DashboardScanJob, updatedAt: String)] = [:]
        for job in jobs where job.type == .metadataScan {
            let snapshot = DashboardScanJob(
                status: job.status.rawValue,
                current: job.progressCurrent,
                total: job.progressTotal
            )
            if let previous = latest[job.scopeId], job.updatedAt <= previous.updatedAt {
                continue
            }
            latest[job.scopeId] = (snapshot, job.updatedAt)
        }
        return latest.mapValues { $0.snapshot }
    }

    // MARK: 动作

    /// 新建工作区：校验目录、创建 session 并立即入队 metadata.scan，
    /// 让用户一次点击完成建库与索引启动。
    func createSession(name: String, sourcePath: String) async -> SessionData? {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let session = try provider.createSession(name: name, source: "local", sourcePath: sourcePath)
            do {
                // 目录导入：唯一允许递归 source_path 全树的作用域。
                try provider.enqueueIndexScan(sessionId: session.id, requestedPaths: nil)
            } catch {
                // TS session.ipc.ts L52-62：入队失败回滚已建 session，避免
                // 工作区列表出现照片永不索引的半成品。补偿删除（刚创建的空
                // 工作区，非用户确认路径）显式带 true 以满足 SessionService 门禁。
                try? provider.deleteSession(session.id, confirmed: true)
                throw error
            }
            setImportNotice(session: session)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return session
        } catch {
            createError = Self.message(for: error)
            return nil
        }
    }

    /// TS handleCreate（capture-one 分支）：创建前再跑一次四层预检，全部通过
    /// 才读取选中照片；未选中 → "请先在 Capture One 中选择照片"（L192-194）；
    /// 创建成功带 failedFiles 计数横幅。
    func createSessionFromCaptureOne(name: String) async -> SessionData? {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        guard let bridge = captureOne ?? CaptureOneBridge.shared else {
            createError = GatherLocalization.l("Capture One 导入不可用，请稍后重试")
            return nil
        }
        let status = await bridge.preflight()
        let preflightResult = C1PreflightResult.build(from: status)
        c1Preflight = .finished(preflightResult)
        guard preflightResult.passed else { return nil }
        do {
            let files = try await bridge.selectedPhotoPaths()
            if files.isEmpty {
                createError = GatherLocalization.l("请先在 Capture One 中选择至少一张照片")
                return nil
            }
            // 导入范围 = 本次选中集合（与 GatherApp.importFiles 同一契约）：
            // 公共父目录只用于取名，绝不落库为 source_path，否则监听器与
            // 「全量兜底」扫描会重新递归整个父目录树（历史 P0：选 3 张照片
            // 等于扫描整棵目录树，最坏上溯到主目录）。
            let selectedPaths = normalizeImportFilepaths(files)
            let parentDirectory = commonParentDirectory(filepaths: selectedPaths)
            let sessionName = name.isEmpty
                ? (parentDirectory.isEmpty ? GatherLocalization.l("Capture One 导入") : TSPath.basename(parentDirectory))
                : name
            let outcome = try provider.createSessionFromFiles(
                name: sessionName,
                source: SessionSource.captureOne.rawValue,
                filepaths: selectedPaths
            )
            do {
                try provider.enqueueIndexScan(sessionId: outcome.session.id, requestedPaths: selectedPaths)
            } catch {
                // TS session.ipc.ts L52-62：入队失败回滚已建 session（含已
                // 写入照片），避免半成品工作区残留在列表。补偿删除同上传 true。
                try? provider.deleteSession(outcome.session.id, confirmed: true)
                throw error
            }
            setImportNotice(session: outcome.session, failedFiles: outcome.failedFiles, added: outcome.added)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return outcome.session
        } catch {
            createError = Self.c1Message(for: error)
            return nil
        }
    }

    /// TS handleCreate：打开对话框且来源为 Capture One 时自动预检；
    /// 切换来源时同样触发。
    func runC1Preflight() async {
        c1Preflight = .checking
        guard let bridge = captureOne ?? CaptureOneBridge.shared else {
            c1Preflight = .finished(C1PreflightResult.failed())
            return
        }
        c1Preflight = .finished(C1PreflightResult.build(from: await bridge.preflight()))
    }

    /// 预检进行中（禁用创建按钮，对齐 TS createMutation 未完成时 disabled）。
    var isC1PreflightChecking: Bool {
        if case .checking = c1Preflight { return true }
        return false
    }

    /// 索引失败卡片重试：重新入队 metadata.scan（dedupeKey 复用终态行，
    /// TS retryScan L361-371）。
    func retryScan(sessionId: String) async {
        do {
            // requestedPaths 传 nil：JobService 的 checkpoint 继承会保留原扫描
            // 作用域（文件/C1 导入的 requestedPaths 随重跑续用，重跑=续跑）；
            // 目录会话终态 checkpoint 无该键，仍按目录全树重扫。
            try provider.enqueueIndexScan(sessionId: sessionId, requestedPaths: nil)
            scanJobs[sessionId] = DashboardScanJob(status: "queued", current: 0, total: 0)
            await refreshJobs()
        } catch {
            // TS retryScan L364-370：失败把快照回退为 failed（卡片保留重试
            // 入口），而不是停留在 queued 假象。
            scanJobs[sessionId] = DashboardScanJob(status: "failed", current: 0, total: 0)
            actionError = Self.message(for: error)
        }
    }

    @discardableResult
    func deleteSession(_ sessionId: String, confirmed: Bool) async -> Bool {
        do {
            try provider.deleteSession(sessionId, confirmed: confirmed)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    /// 批量删除（TS deleteManyMutation → sessionApi.deleteMany 带 confirmed）。
    @discardableResult
    func deleteSessions(_ sessionIds: [String], confirmed: Bool) async -> Bool {
        do {
            try provider.deleteSessions(sessionIds, confirmed: confirmed)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return true
        } catch {
            actionError = Self.message(for: error)
            return false
        }
    }

    func cancelJob(_ jobId: String) async {
        do {
            _ = try provider.cancelJob(jobId)
            await refreshJobs()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    func retryJob(_ jobId: String) async {
        do {
            _ = try provider.retryJob(jobId)
            await refreshJobs()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    func clearCompletedJobs() async {
        do {
            _ = try provider.clearCompletedJobs()
            await refreshJobs()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    // MARK: 轮询（TS: Jobs 页 2s 活跃轮询 + useWorkspaceStatus 30s 兜底）

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        guard isVisible else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.autoRefreshTick()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func autoRefreshTick() async {
        // 有 queued/running 任务时增量刷新：jobs 每 2s 单查询（进度跟手），
        // sessions + N×workspace.status 降到 15s 档；无活跃任务 30s 全量兜底。
        let active = jobs.contains { $0.status == .queued || $0.status == .running }
        if active {
            await refreshJobs()
            let due = Date().timeIntervalSince(lastSessionsRefreshAt) >= 15
            if due {
                await refreshSessions()
            }
            return
        }
        let due = Date().timeIntervalSince(lastFullRefreshAt) >= 30
        guard due else { return }
        lastFullRefreshAt = Date()
        await refreshAll()
    }

    /// TS jobs:progress 事件订阅（Dashboard/index.tsx useEvent('jobs:progress')）：
    /// 逐帧更新任务中心行（jobs 快照）与 metadata.scan 卡片快照（「正在索引
    /// N…」毫秒级实时，替代仅 jobTerminal 的滞后刷新）；终态帧再整页刷新，
    /// 让索引写回的权威计数立即落定（对齐 TS 终态 invalidate sessions）。
    func applyJobEvent(_ event: GatherJobEvent) {
        let job = event.job
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        }
        guard job.type == .metadataScan else { return }
        let snapshot = DashboardScanJob(
            status: job.status.rawValue,
            current: job.progressCurrent,
            total: job.progressTotal
        )
        if event.isTerminal {
            switch job.status {
            case .failed, .succeeded:
                // 保留终态快照：failed → 卡片「索引失败 + 重试」；succeeded →
                // 截断导入的 ≥ 前缀去除（TS jobs:progress 终态分支）。
                scanJobs[job.scopeId] = snapshot
            case .queued, .running, .cancelling, .cancelled, .interrupted:
                scanJobs[job.scopeId] = nil
            }
            lastFullRefreshAt = Date()
            Task { await refreshAll() }
        } else {
            scanJobs[job.scopeId] = snapshot
        }
    }

    func refreshAll() async {
        await refreshSessions()
        await refreshJobs()
    }

    // MARK: 派生展示

    /// TS: Dashboard/index.tsx photoCountLabel（344-359 行，文案硬编码中文）。
    func photoCountLabel(for session: SessionData) -> String {
        let job = scanJobs[session.id]
        switch deriveCardIndexKind(job) {
        case .failed:
            return GatherLocalization.l("索引失败")
        case .active:
            if let job, job.current > 0 { return String(format: GatherLocalization.l("正在索引 %lld…"), job.current) }
            return GatherLocalization.l("扫描中…")
        case .count:
            if session.truncatedImport && job?.status != "succeeded" {
                return String(format: GatherLocalization.l("≥%lld 张照片"), session.photoCount)
            }
            return String(format: GatherLocalization.l("%lld 张照片"), session.photoCount)
        }
    }

    /// 工作区概览聚合。
    func summary() -> DashboardSummary {
        DashboardSummary(
            sessionCount: sessions.count,
            photoCount: sessions.reduce(0) { $0 + $1.photoCount },
            pendingXmp: statuses.values.reduce(0) { $0 + $1.xmp.pending },
            conflictXmp: statuses.values.reduce(0) { $0 + $1.xmp.conflict },
            offlinePhotos: statuses.values.reduce(0) { $0 + $1.offlinePhotos }
        )
    }

    /// 进行中与需要处理（TS Jobs 页 attentionJobs：status != succeeded）。
    var attentionJobs: [AnalysisJobData] {
        jobs.filter { $0.status != .succeeded }
    }

    /// 已完成历史（TS Jobs 页 historyJobs）。
    var historyJobs: [AnalysisJobData] {
        jobs.filter { $0.status == .succeeded }
    }

    /// 清理按钮的可见性 = 真的会被清掉的行：仅成功终态且非阶段证据类型。
    /// 失败/中断/取消行保留错误原因（显式点名 statuses 才允许删除），
    /// 因此不能作为「有可清理内容」的依据，否则按钮会静默无事发生。
    var hasClearableJobs: Bool {
        jobs.contains { job in
            job.status == .succeeded
                && job.type != .metadataScan && job.type != .exportExecute
        }
    }

    /// TS Jobs 页进度百分比（progressTotal > 0 时 Math.round）。
    static func progressPercent(of job: AnalysisJobData) -> Int {
        job.progressTotal > 0
            ? Int((Double(job.progressCurrent) / Double(job.progressTotal) * 100).rounded())
            : 0
    }

    /// 错误 message 的唯一漏斗：只允许「可本地化的错误码文案」出 UI。
    /// 原始诊断（NSError/底层描述）只写日志，未知错误一律回退通用文案。
    static func message(for error: Error) -> String {
        GatherLogger.log("dashboard error diagnostic: \(error)", level: .warn)
        return NativeCommandClient.userFacingMessage(for: error)
    }

    /// TS handleCreate 成功路径的 Toast（truncatedToast L208-213 /
    /// importFailureMessage L214-219）：走全局 Toast 系统 5s 自动消退。
    private func setImportNotice(session: SessionData, failedFiles: [String] = [], added: Int = 0) {
        if session.truncatedImport {
            GatherToastCenter.shared.show(
                type: .warning,
                message: GatherLocalization.l("目录超过 50,000 张照片，已导入前 50,000 张，剩余照片将在后台索引中补齐")
            )
        }
        if !failedFiles.isEmpty {
            GatherToastCenter.shared.show(
                type: .warning,
                message: Self.importFailureMessage(added: added, failedFiles: failedFiles)
            )
        }
    }

    /// TS importFailureMessage：{{added}} 张照片已导入；文件读取失败：
    /// 前 3 个文件名 + 超出的 " 等 N 个"（对齐 sessionImportFailure 文案）。
    static func importFailureMessage(added: Int, failedFiles: [String]) -> String {
        let examples = failedFiles.prefix(3)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .joined(separator: "、")
        let remaining = failedFiles.count > 3 ? String(format: GatherLocalization.l(" 等 %lld 个"), failedFiles.count) : ""
        return String(format: GatherLocalization.l("%lld 张照片已导入；文件读取失败：%@%@"), added, examples, remaining)
    }

    /// C1 流程错误文案：错误码经 GatherLocalization.errorText 转引导文案，
    /// 原始诊断只写日志（未知一律回退通用文案，绝不直显）。
    private static func c1Message(for error: Error) -> String {
        GatherLogger.log("capture one import error diagnostic: \(error)", level: .warn)
        if let bridgeError = error as? CaptureOneBridgeError {
            return GatherLocalization.errorText(bridgeError.description)
        }
        return GatherLocalization.errorText((error as NSError).localizedDescription)
    }
}
