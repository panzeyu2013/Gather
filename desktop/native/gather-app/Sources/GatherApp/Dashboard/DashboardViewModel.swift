// desktop/native/gather-app/Sources/GatherApp/Dashboard/DashboardViewModel.swift
// Phase 3.1 Dashboard：视图模型（服务可注入，同进程直连 GatherCore，不走 WKWebView）。
// TS 源: desktop/src/renderer/pages/Dashboard/index.tsx（scanJobs 种子/卡片计数文案）
//       + pages/Jobs/index.tsx（任务面板交互）+ hooks/useWorkspaceStatus.ts（状态聚合）
//
// 差异说明（有意）：
// - TS 的 react-query 轮询 + jobs:progress 事件 → startAutoRefresh 轮询
//   （活跃期 2s / 常驻 30s；事件推送通道后续阶段接线）；
// - 工作区概览（工作区数/照片数/待写回/冲突/离线）为 SwiftUI 侧聚合，
//   数据源与 useWorkspaceStatus 相同（workspace.status）。
import Foundation
import GatherCore

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态）或
/// 真实服务（LiveDashboardDataProvider + 临时 SQLite）。
protocol DashboardDataProvider {
    func listSessions() throws -> [SessionData]
    func createSession(name: String, source: String, sourcePath: String) throws -> SessionData
    func deleteSession(_ sessionId: String) throws
    func workspaceStatus(sessionId: String) throws -> WorkspaceStatus?
    func listJobs() throws -> [AnalysisJobData]
    func cancelJob(_ jobId: String) throws -> Bool
    func retryJob(_ jobId: String) throws -> Bool
    func clearCompletedJobs() throws -> Int
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
        try sessionService.createSession(name: name, source: source, sourcePath: sourcePath)
    }

    func deleteSession(_ sessionId: String) throws {
        // UI 层已确认（对齐 TS ConfirmDialog → sessionApi.delete 带 confirmed）。
        try sessionService.deleteSession(sessionId, confirmed: true)
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

/// Dashboard 视图模型：加载/轮询/动作（创建、删除、任务 cancel/retry/clear）。
@MainActor
@Observable
final class DashboardViewModel {
    /// 首屏加载阶段。
    enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private let provider: DashboardDataProvider
    private var autoRefreshTask: Task<Void, Never>?
    private var lastFullRefreshAt = Date.distantPast

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

    init(provider: DashboardDataProvider) {
        self.provider = provider
    }

    // MARK: 加载

    func loadAll() async {
        phase = .loading
        await refreshAll()
    }

    func refreshSessions() async {
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
            settlePhase()
        } catch {
            if sessions.isEmpty {
                phase = .failed(Self.message(for: error))
            } else {
                actionError = Self.message(for: error)
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

    /// 新建工作区：本地文件夹路径建 session 行（TS 一跳导入
    /// create_from_directory 与后台索引 index.scan 后续阶段接线）。
    func createSession(name: String, sourcePath: String) async -> SessionData? {
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let session = try provider.createSession(name: name, source: "local", sourcePath: sourcePath)
            lastFullRefreshAt = .distantPast
            await refreshAll()
            return session
        } catch {
            createError = Self.message(for: error)
            return nil
        }
    }

    @discardableResult
    func deleteSession(_ sessionId: String) async -> Bool {
        do {
            try provider.deleteSession(sessionId)
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
        // 有 queued/running 任务时每 2s 全量刷新；否则 30s 兜底。
        let active = jobs.contains { $0.status == .queued || $0.status == .running }
        let due = Date().timeIntervalSince(lastFullRefreshAt) >= 30
        guard active || due else { return }
        lastFullRefreshAt = Date()
        await refreshAll()
    }

    private func refreshAll() async {
        await refreshSessions()
        await refreshJobs()
    }

    // MARK: 派生展示

    /// TS: Dashboard/index.tsx photoCountLabel（344-359 行，文案硬编码中文）。
    func photoCountLabel(for session: SessionData) -> String {
        let job = scanJobs[session.id]
        switch deriveCardIndexKind(job) {
        case .failed:
            return "索引失败"
        case .active:
            if let job, job.current > 0 { return "正在索引 \(job.current)…" }
            return "扫描中…"
        case .count:
            if session.truncatedImport && job?.status != "succeeded" {
                return "≥\(session.photoCount) 张照片"
            }
            return "\(session.photoCount) 张照片"
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

    /// TS utils/jobs.ts isAnalysisJobClearable（含阶段证据类型排除）。
    var hasClearableJobs: Bool {
        jobs.contains { job in
            ["succeeded", "failed", "cancelled", "interrupted"].contains(job.status.rawValue)
                && job.type != .metadataScan && job.type != .exportExecute
        }
    }

    /// TS Jobs 页进度百分比（progressTotal > 0 时 Math.round）。
    static func progressPercent(of job: AnalysisJobData) -> Int {
        job.progressTotal > 0
            ? Int((Double(job.progressCurrent) / Double(job.progressTotal) * 100).rounded())
            : 0
    }

    /// 错误 message：优先 GatherErrorCode 字符串（对齐 SessionCommandRouter.errorMessage）。
    static func message(for error: Error) -> String {
        if let sessionError = error as? SessionServiceError {
            return sessionError.gatherCode.rawValue
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }
}
