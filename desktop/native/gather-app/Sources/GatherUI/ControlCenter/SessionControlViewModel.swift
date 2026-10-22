// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlViewModel.swift
// Cut 4 / 4c-2e：控制中心 VM 从 SessionControlView.swift 拆出（原 15-203 行）。
// 口径：状态 / 可见性 / 兜底轮询 / load / 任务快照留本文件；动作（扫描 / 质量 /
// 重试 / 建任务）在 SessionControlViewModel+Actions.swift。
//
// 跨文件 extension 只能访问 internal 成员：jobAPI / qualityAPI 由 private 改
// internal；jobs / isWorking / errorMessage / notice 由 private(set) 改
// public internal(set)（只读对外语义不变）。

import SwiftUI
import GatherProtocol

@MainActor
@Observable
public final class SessionControlViewModel {
    // Cut 1 / B8.2a：session.get / workspace.status → SessionAPI，
    // culling.sync_status → CullingAPI（原同步字符串命令已删除；
    // C1 状态胶囊同样使用该 CullingAPI，不再经过字符串命令）。
    private let sessionAPI: any SessionAPI
    private let cullingAPI: any CullingAPI
    // Cut 1 / B5b：任务列表/取消/重试/建任务走 JobAPI，画质分析走 QualityAPI。
    let jobAPI: any JobAPI
    let qualityAPI: any QualityAPI
    /// 兜底轮询间隔（事件驱动为主，轮询仅兜底；默认 15s / 活跃 3s）。
    private let pollInterval: Duration
    private let activePollInterval: Duration
    public let sessionId: String
    private(set) public var session: SessionData?
    private(set) public var workspaceStatus: WorkspaceStatus?
    public internal(set) var jobs: [AnalysisJobData] = []
    private(set) public var syncStatus: MetadataSyncSummary?
    public internal(set) var isWorking = false
    /// 初始为 true：首帧即渲染加载态，避免 load() 完成前卡片空白。
    private(set) public var isLoading = true
    public internal(set) var errorMessage: CommandError?
    public internal(set) var notice: LocalizedText?
    /// jobs.list 的异步请求代次：3s 轮询/事件可能重叠触发 load()，只接受最新
    /// 一次结果，避免旧响应覆盖新快照。
    private var jobsGeneration = 0
    /// load() 的代次（B8.2a）：session/status/sync 迁到 async API 后，轮询与
    /// 事件可能让两次 load 交错；只允许最新一次写状态（含 isLoading/errorMessage），
    /// 否则旧响应的错误条或旧快照会覆盖新数据。
    private var loadGeneration = 0
    /// 兜底轮询任务（Cut 4 / 4a-2b：从 View 的 while 迁入；setVisible 启停）。
    private var pollTask: Task<Void, Never>?
    /// refreshJobs 的异步任务（shutdown 时取消，避免关闭后仍写任务快照）。
    private var jobsTask: Task<Void, Never>?
    /// 可见性真相（默认不可见；View onAppear/.task 显式置 true）。
    private var isVisible = false
    /// 关闭终态：shutdown() 之后 setVisible(true) 明确 no-op。
    /// 4a-2c：对外只读，供 SessionWorkspace.close 的扇出测试断言。
    public private(set) var isShutdown = false

    /// 索引进度活跃判定（对齐 OLD useWorkspaceStatus.ts:26-42 的 indexActive）：
    /// stage == created（一跳化导入窗口）或 indexing == active（含 queued/running
    /// 语义）时为 true；终态（idle/failed）回落常规轮询间隔。
    public var isIndexingActive: Bool {
        guard let status = workspaceStatus else { return false }
        return status.stage == .created || status.indexing.status == .active
    }

    /// 生产装配（RootView）：session/workspace/sync 与 job/quality 全部是
    /// AppServices 的类型化 API。
    public init(
        sessionId: String,
        session: any SessionAPI,
        culling: any CullingAPI,
        jobAPI: any JobAPI,
        qualityAPI: any QualityAPI,
        pollInterval: Duration = .seconds(15),
        activePollInterval: Duration = .seconds(3)
    ) {
        self.sessionId = sessionId
        self.sessionAPI = session
        self.cullingAPI = culling
        self.jobAPI = jobAPI
        self.qualityAPI = qualityAPI
        self.pollInterval = pollInterval
        self.activePollInterval = activePollInterval
    }

    // MARK: - 可见性 / 轮询 / 关闭（Cut 4 / 4a-2b）

    /// 可见性唯一入口：把旧 SessionControlView 的 .task 里的 while 轮询迁进来。
    /// - visible=true：启动兜底轮询（幂等，已在跑则不重复建 Task）；
    /// - visible=false：停轮询；
    /// - shutdown 之后明确 no-op（关闭是终态）。
    public func setVisible(_ visible: Bool) {
        guard !isShutdown else { return }
        isVisible = visible
        if visible {
            startPolling()
        } else {
            stopPolling()
        }
    }

    /// 启动兜底轮询：每次 sleep 前读取最新 status，索引进度活跃期 3s、
    /// 其余 15s（对齐旧 View 的 while 语义）。幂等：已有任务直接复用。
    public func startPolling() {
        guard !isShutdown, isVisible, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.isIndexingActive ? self.activePollInterval : self.pollInterval
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.load()
            }
        }
    }

    /// 停止轮询（幂等）。
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 关闭：取消轮询与任务快照查询；关闭后 setVisible(true) 不重启。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isVisible = false
        stopPolling()
        jobsTask?.cancel()
        jobsTask = nil
    }

    /// 读取会话 + 工作区状态 + 同步摘要（B8.2a：三处均已 typed/async）。
    ///
    /// 失败语义与旧同步实现逐条对齐：
    /// - session.get 失败 → 只写错误条，保留旧快照；
    /// - workspace.status 失败 → session 已更新（旧实现同样按顺序赋值）；
    /// - culling.sync_status 失败 → syncStatus 置 nil（旧实现 try? 语义），不报错；
    /// - 任一步失败都不刷新任务列表。
    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            // 只由最新一轮收尾：旧一轮的 defer 不得提前清掉加载态。
            if generation == loadGeneration { isLoading = false }
        }
        do {
            // 赋值一律放在代次校验之后：旧一轮 await 返回时不得覆盖新快照。
            let fetchedSession = try await sessionAPI.get(sessionId)
            guard generation == loadGeneration else { return }
            session = fetchedSession
            let fetchedStatus = try await sessionAPI.status(sessionId)
            guard generation == loadGeneration else { return }
            workspaceStatus = fetchedStatus
            let fetchedSync = try? await cullingAPI.syncStatus(sessionId)
            guard generation == loadGeneration else { return }
            syncStatus = fetchedSync?.summary
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = CommandError(error)
            return
        }
        // 任务快照异步取（3s/15s 轮询与事件回流可能重叠）：代次保证旧响应
        // 不覆盖新快照。
        jobsGeneration += 1
        let jobsRequest = jobsGeneration
        jobsTask?.cancel()
        jobsTask = Task { [weak self] in
            await self?.refreshJobs(generation: jobsRequest)
        }
    }

    private func refreshJobs(generation: Int) async {
        do {
            let all = try await jobAPI.list(JobListFilter(includeCheckpoint: false))
            guard generation == jobsGeneration else { return }
            jobs = all.filter { $0.scopeId == sessionId }
        } catch {
            guard generation == jobsGeneration else { return }
            errorMessage = CommandError(error)
        }
    }

    /// 活跃任务（排队 / 进行中 / 取消中）：控制中心的「当前任务」只列这些（F07）。
    /// 旧实现把 jobs.list 的结果（含全部历史）直接铺开，22 条已完成任务把
    /// 真正在进行的工作推出首屏。
    public var activeJobs: [AnalysisJobData] {
        jobs.filter { [.queued, .running, .cancelling].contains($0.status) }
    }

    /// 需要用户处理的任务（失败 / 中断）：失败必须留在首屏可见，不能藏进历史。
    public var attentionJobs: [AnalysisJobData] {
        jobs.filter { [.failed, .interrupted].contains($0.status) }
    }

    /// 已完成历史（成功 / 取消）：默认折叠（与工作台的完成历史同一规则）。
    public var historyJobs: [AnalysisJobData] {
        jobs.filter { [.succeeded, .cancelled].contains($0.status) }
    }
}
