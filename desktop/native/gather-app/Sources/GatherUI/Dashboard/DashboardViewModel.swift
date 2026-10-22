// desktop/native/gather-app/Sources/GatherUI/Dashboard/DashboardViewModel.swift
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
//
// Cut 4 / 4c-2i：Dashboard 拆分（行为不变）。本文件只保留模型/Provider/状态与
// init；行为按域拆到六个 extension：+Preflight / +Load / +API / +Actions /
// +Polling / +Derived。跨文件 extension 需要写回的属性 setter 由 private(set)
// 放宽为 internal setter，声明、默认值与文案逐字未动。
import Foundation
import GatherProtocol

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态）或
/// 真实服务（LiveDashboardDataProvider + 临时 SQLite）。
// Cut 3 / 3b-2：同包内跨 target 的接缝用 package（不扩大为公开 API）。
package protocol DashboardDataProvider {
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
    func listJobs(includeCheckpoint: Bool) throws -> [AnalysisJobData]
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
    package func enqueueIndexScan(sessionId: String, requestedPaths: [String]?) throws {}

    /// 默认实现（stub 用）：退化为 createSession（无目录作用域），无失败文件统计。
    package func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String]
    ) throws -> CreateSessionOutcome {
        let session = try createSession(name: name, source: source, sourcePath: "")
        return CreateSessionOutcome(session: session, failedFiles: [], added: 0)
    }

    /// 默认实现（stub 用）：逐个删除，confirmed 原样透传。
    package func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws {
        for sessionId in sessionIds {
            try deleteSession(sessionId, confirmed: confirmed)
        }
    }
}

/// TS: session.create 响应 —— session 数据 + 加照片结果计数。
package struct CreateSessionOutcome: Equatable, Sendable {
    var session: SessionData
    var failedFiles: [String]
    var added: Int
}

/// 真实实现：SessionAPI / JobAPI 的装配（B1 生产路径）。
///
/// 生产实例只持有类型化 API。DashboardDataProvider 是同步协议（View 与既有
/// 集成测试共用），其同步面在拆 target 后经 UI 侧端口 SessionSyncAPI /
/// JobSyncAPI 注入 —— 端口由 GatherHost 的 Live 适配器实现（E-18）；生产
/// AppServices 路径不注入端口，DashboardViewModel 优先走 async API。
package final class LiveDashboardDataProvider: DashboardDataProvider {
    package let sessionAPI: any SessionAPI
    package let jobAPI: any JobAPI
    /// 仅测试装配注入；生产实例为 nil（同步方法不应被生产调用）。
    private let syncSessionAPI: (any SessionSyncAPI)?
    private let syncJobAPI: (any JobSyncAPI)?

    package convenience init(sessionAPI: any SessionAPI, jobAPI: any JobAPI) {
        self.init(sessionAPI: sessionAPI, jobAPI: jobAPI, syncSession: nil, syncJob: nil)
    }

    /// 显式同步端口（既有集成测试：LiveSessionAPI / LiveJobAPI 已实现端口）。
    package init(
        sessionAPI: any SessionAPI,
        jobAPI: any JobAPI,
        syncSession: (any SessionSyncAPI)?,
        syncJob: (any JobSyncAPI)?
    ) {
        self.sessionAPI = sessionAPI
        self.jobAPI = jobAPI
        self.syncSessionAPI = syncSession
        self.syncJobAPI = syncJob
    }

    private func syncSession() throws -> any SessionSyncAPI {
        guard let syncSessionAPI else { throw DashboardProviderError.syncAPINotConfigured }
        return syncSessionAPI
    }

    private func syncJob() throws -> any JobSyncAPI {
        guard let syncJobAPI else { throw DashboardProviderError.syncAPINotConfigured }
        return syncJobAPI
    }

    package func listSessions() throws -> [SessionData] {
        try syncSession().listSessionsSync()
    }

    /// 注意：name 由调用方（DashboardViewModel）用显式 L10n 解析好再传入
    /// （4b-2l 起不再在本类读进程级语言；默认名是落库值，仍只在创建时解析一次）。
    package func createSession(name: String, source: String, sourcePath: String) throws -> SessionData {
        let input = try SessionCreateInput(
            name: name,
            source: source,
            sourcePath: sourcePath
        )
        return try syncSession().createSessionSync(input).session
    }

    /// TS session.create：文件列表建库 + addPhotos（source 透传，C1 为
    /// "capture-one"），返回会话与失败文件计数；照片在创建时写入，
    /// metadata.scan 由 LiveSessionAPI 的 filepaths 分支负责入队。
    ///
    /// source_path 恒为空：文件导入的作用域由 metadata.scan job 的
    /// checkpoint["requestedPaths"] 显式携带（与 GatherApp.importFiles 同一
    /// 契约）。公共父目录只允许用于取名——落库会让全量扫描（requestedPaths=nil）
    /// 重新递归该目录，重新引入「导入范围失控」。
    package func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String]
    ) throws -> CreateSessionOutcome {
        let input = try SessionCreateInput(name: name, source: source, filepaths: filepaths)
        let result = try syncSession().createSessionSync(input)
        return CreateSessionOutcome(
            session: result.session,
            failedFiles: result.failedFiles,
            added: result.added
        )
    }

    package func deleteSession(_ sessionId: String, confirmed: Bool) throws {
        guard confirmed else { throw GatherError(code: .SESSION_DELETE_NOT_CONFIRMED) }
        let input = try SessionDeleteInput(sessionIds: [sessionId])
        try syncSession().deleteSessionsSync(Confirmed(input, source: .userDialog))
    }

    package func deleteSessions(_ sessionIds: [String], confirmed: Bool) throws {
        guard confirmed else { throw GatherError(code: .SESSION_DELETE_NOT_CONFIRMED) }
        guard !sessionIds.isEmpty else { return }
        let input = try SessionDeleteInput(sessionIds: sessionIds)
        try syncSession().deleteSessionsSync(Confirmed(input, source: .userDialog))
    }

    package func workspaceStatus(sessionId: String) throws -> WorkspaceStatus? {
        try syncSession().workspaceStatusSync(sessionId)
    }

    package func listJobs(includeCheckpoint: Bool) throws -> [AnalysisJobData] {
        try syncJob().listJobsSync(JobListFilter(includeCheckpoint: includeCheckpoint))
    }

    package func cancelJob(_ jobId: String) throws -> Bool {
        try syncJob().cancelJobSync(jobId)
    }

    package func retryJob(_ jobId: String) throws -> Bool {
        try syncJob().retryJobSync(jobId)
    }

    package func clearCompletedJobs() throws -> Int {
        try syncJob().clearCompletedJobsSync()
    }

    package func enqueueIndexScan(sessionId: String, requestedPaths: [String]?) throws {
        // R1 P1-3：建任务规则只在协议层工厂定义（此前这里是第 5 份字面量副本）。
        _ = try syncJob().startJobSync(
            JobCreateParams.metadataScan(
                sessionId: sessionId, requestedPaths: requestedPaths))
    }

    /// 目录会话名规则：与 SessionService.createFromDirectory 一致（空名取目录
    /// basename）；API 输入要求 name 非空白，故在生产/测试接缝处提前补齐。
    ///
    /// Cut 4 / 4b-2l：空 basename 时的 "导入照片" 是**持久化默认会话名**，会写进
    /// sessions.name 并长期展示——它仍只在创建时解析一次（落库后再随语言变化会让
    /// 同一工作区在不同语言下显示不同名字）；但解析语言必须由调用方在渲染期显式
    /// 传入，不再读进程级 appLanguage（旧 4b-2e allowlist 已随本批撤销）。
    static func directorySessionName(name: String, sourcePath: String, with l10n: L10n) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let basename = URL(fileURLWithPath: sourcePath).standardizedFileURL.lastPathComponent
        return basename.isEmpty ? l10n("导入照片") : basename
    }
}

private enum DashboardProviderError: Error {
    case syncAPINotConfigured
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
    /// 文案模板 + 参数（4b-2e）：VM 不读进程全局语言，渲染期由 View 的 l10n 解析。
    var label: LocalizedText
    var passed: Bool
    var id: String { key }
}

/// TS C1PreflightResult：passed + checks + 引导文案。
struct C1PreflightResult: Equatable, Sendable {
    var passed: Bool
    var checks: [C1PreflightCheckItem]
    /// 引导文案模板（nil = 全部通过）；渲染期按当前语言解析。
    var guidance: LocalizedText?

    /// TS evaluateC1Preflight：检查清单固定四层（超时额外加一格）。
    static func build(from status: C1PreflightStatus) -> C1PreflightResult {
        var items: [(key: String, label: LocalizedText, passed: Bool)] = [
            ("reachable", LocalizedText("可连接 Capture One（AppleScript）"), status.reachable),
            ("appRunning", LocalizedText("Capture One 正在运行"), status.appRunning),
            ("documentOpen", LocalizedText("Capture One 已打开文档"), status.documentOpen),
            ("automationAuthorized", LocalizedText("自动化权限已授权"), status.automationAuthorized),
        ]
        if status.timedOut {
            items.append(("timeout", LocalizedText("检测超时"), false))
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
    private static func guidance(for failedKeys: [String]) -> LocalizedText? {
        if failedKeys.isEmpty { return nil }
        if failedKeys.contains("timeout") {
            return LocalizedText("检测超时，请重试")
        }
        if failedKeys.contains("reachable") {
            return LocalizedText("无法通过 AppleScript 访问 Capture One。请确认系统环境正常，然后重新检查。")
        }
        if failedKeys.contains("automationAuthorized") {
            return LocalizedText("自动化权限未授权：请在 系统设置 → 隐私与安全性 → 自动化 中允许 Gather 控制 Capture One，然后重新检查。")
        }
        if failedKeys.contains("appRunning") {
            return LocalizedText("未检测到 Capture One 正在运行。请先启动 Capture One，然后重新检查。")
        }
        if failedKeys.contains("documentOpen") {
            return LocalizedText("Capture One 未打开任何文档。请先打开一个目录（Document），然后重新检查。")
        }
        return nil
    }
}

/// Dashboard 视图模型：加载/轮询/动作（创建、删除、任务 cancel/retry/clear）。
@MainActor
@Observable
package final class DashboardViewModel {
    /// 新建工作区来源（TS SOURCE_OPTIONS）。
    enum SessionSource: String, Equatable, CaseIterable, Identifiable {
        case local
        case captureOne = "capture-one"

        var id: String { rawValue }

        /// 来源显示名：渲染期按当前语言解析。品牌名 "Capture One" 不翻译，
        /// 因此用 with l10n 而非 LocalizedText（后者会被 parity 扫描当成待译 key）。
        func label(with l10n: L10n) -> String {
            switch self {
            case .local: return l10n("本地文件夹")
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

    let provider: DashboardDataProvider
    /// B1：生产 provider 是 LiveDashboardDataProvider；非 nil 时所有动作走
    /// SessionAPI/JobAPI。stub provider（测试）没有 API，继续走同步协议。
    let sessionAPI: (any SessionAPI)?
    let jobAPI: (any JobAPI)?
    var autoRefreshTask: Task<Void, Never>?
    var lastFullRefreshAt = Date.distantPast
    var lastSessionsRefreshAt = Date.distantPast
    /// 页面可见性（RootView 驱动，审计 4 的可见性钩子）：opacity 常驻方案
    /// 下 onAppear/onDisappear 不触发，由导航切换显式置位；隐藏期间
    /// startAutoRefresh 拒绝启动轮询（DashboardView 的 .task 初次必执行，
    /// 需以此兜底启动即隐藏的深链场景）。
    package var isVisible = true

    var phase: LoadPhase = .loading
    var sessions: [SessionData] = []
    var statuses: [String: WorkspaceStatus] = [:]
    var scanJobs: [String: DashboardScanJob] = [:]
    var jobs: [AnalysisJobData] = []
    var isCreating = false
    /// 新建工作区表单错误（sheet 内展示）。
    var createError: CommandError?
    /// 删除/任务操作错误（页面级横幅）。
    var actionError: CommandError?
    /// jobs.list 加载失败（任务中心错误态；区别于「暂无后台任务」空态）。
    var jobsError: CommandError?
    /// C1 预检相位（sheet 内展示）。
    var c1Preflight: C1PreflightPhase = .idle
    /// C1 桥：必由宿主注入（RootView / 测试装配）。
    /// Cut 3 / 3b-3（E-17）：类型改为 Protocol 能力面，并删除
    /// CaptureOneBridge.shared 的全局兜底——未注入时 C1 导入显式不可用。
    package var captureOne: (any CaptureOneBridging)?
    /// 会话删除成功回调（宿主注入；默认 nil = 未接线，单测/Preview 保持静默）。
    /// 每个**真正被删掉**的会话 id 调用一次：外壳据此 `SessionStore.endSession`
    /// 清 active/pinned/lastSessionId 并 close 对应 workspace（R4 P1-3 幽灵会话）。
    /// 回调只做状态层交接，不参与删除决策（删除失败的 id 不会回调）。
    package var onSessionDeleted: ((String) -> Void)?

    package init(provider: DashboardDataProvider) {
        self.provider = provider
        if let live = provider as? LiveDashboardDataProvider {
            self.sessionAPI = live.sessionAPI
            self.jobAPI = live.jobAPI
        } else {
            self.sessionAPI = nil
            self.jobAPI = nil
        }
    }
}
