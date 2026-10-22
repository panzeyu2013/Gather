// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel.swift
// Cut 4 / 4c-2a：从 CullingView.swift 第 83-538 行移出（VM 主体/状态/生命周期/同步状态机）。
// 拆分口径：状态与生命周期留本文件；整页加载 -> +Load，导航 -> +Navigation，
// 挑片决策/历史 -> +Actions，写回/同步/冲突 -> +Writeback。
//
// 跨文件 extension 只能访问 internal 成员：原 `private` 依赖/可写状态改为 internal
// （`public internal(set)` 保留只读对外语义），行为与访问路径不变。
import Foundation
import SwiftUI
import GatherProtocol

@MainActor
@Observable
public final class CullingViewModel {
    /// 组合筛选状态：对齐 TS CullingFilters + FilterControls（Culling.tsx:1720-1817）——
    /// 未审/状态/星级/颜色/质量/冲突 六个维度可任意叠加，全部关闭即"全部"。
    public struct FilterState: Equatable {
        public var unreviewedOnly = false
        public var pickState: PickState?
        public var rating: Int?
        public var colorLabel: CaptureOneColorLabel?
        public var qualityStatus: CullingFilterQualityStatus?
        public var metadataConflictOnly = false

        public init() {}

        public var isActive: Bool {
            unreviewedOnly || pickState != nil || rating != nil || colorLabel != nil
                || qualityStatus != nil || metadataConflictOnly
        }
    }

    public enum ScopeMode: String, CaseIterable, Equatable {
        case all
        case filtered
        case similarityGroup

        /// Cut 4 / 4b-2a：只存 key，渲染期由 View 的 l10n 解析（切语言即换文案）。
        var title: LocalizedText {
            switch self {
            case .all: return LocalizedText("全部照片")
            case .filtered: return LocalizedText("按筛选")
            case .similarityGroup: return LocalizedText("相似度分组")
            }
        }
    }

    /// 同步状态机（对齐旧版 c1-sync-controls.ts C1SyncState 语义，从
    /// MetadataSyncSummary 推导）：syncing=正在写入、c1Read=已写入待 C1 确认、
    /// safeToCleanup=全部行终态（synced>0）、synced=无行。
    public enum SyncFlowState: Equatable {
        case disconnected
        case conflict
        case failed
        case syncing
        case c1Read
        case safeToCleanup
        case synced
    }

    /// 纯函数版按钮可用性矩阵：对齐 TS deriveSyncControls({ syncState, hasWritten, acked })
    /// （tests/unit/renderer/c1-sync-controls.test.ts 的 8 组门控用例）。
    /// internal：CullingViewModelTests 直测。
    struct SyncFlowControls: Equatable {
        let canLoadMetadata: Bool
        let canConfirmSync: Bool
        let canCleanup: Bool
    }

    enum CullingSyncFlow {
        static func deriveControls(
            syncState: SyncFlowState,
            hasWritten: Bool,
            acked: Bool
        ) -> SyncFlowControls {
            switch syncState {
            case .syncing, .c1Read, .safeToCleanup:
                // syncing：可重载（无需 ack）；c1Read/safeToCleanup 同左。
                let canLoad = true
                let canConfirm: Bool
                switch syncState {
                case .safeToCleanup: canConfirm = true
                case .c1Read: canConfirm = acked && hasWritten
                default: canConfirm = false
                }
                return SyncFlowControls(
                    canLoadMetadata: canLoad,
                    canConfirmSync: canConfirm,
                    canCleanup: syncState == .safeToCleanup
                )
            case .disconnected, .conflict, .failed, .synced:
                // 保守：全部禁用。
                return SyncFlowControls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false)
            }
        }
    }

    // Cut 1 / B3b：挑片域依赖（19 条 culling.* 命令 / 17 个方法）。
    let cullingAPI: any CullingAPI
    // Cut 1 / B3b：navigation.* 已迁移到 NavigationAPI。
    let navigationAPI: any NavigationAPI
    // Cut 1 / B6b：元数据冲突走类型化 API（conflicts / resolve_conflict）。
    let metadataAPI: any MetadataAPI
    // Cut 1 / B8.2b：质量分析建任务与轮询/取消走类型化 API。
    let jobAPI: any JobAPI
    let qualityAPI: any QualityAPI
    /// Cut 3 / 3b-3（E-17）：只持 Protocol 能力面（CaptureOneBridging）。
    let captureOne: any CaptureOneBridging
    public let sessionId: String
    public internal(set) var page: CullingPage?
    public internal(set) var summary: CullingSummary?
    public internal(set) var syncStatus: MetadataSyncSummary?
    public internal(set) var history: [CullingHistoryOperation] = []
    public internal(set) var conflicts: [MetadataConflict] = []
    public internal(set) var isLoading = false
    private(set) public var isQualityBusy = false
    private(set) public var qualityJob: AnalysisJobData?
    public internal(set) var errorMessage: CommandError?
    /// Cut 4 / 4b-2a：延迟提示文案（key/计数，渲染期解析；见 CullingNotice）。
    public internal(set) var notice: CullingNotice?
    /// 隐藏期间收到领域变更只登记，回可见再补刷（外壳约定：隐藏页不发命令）。
    private(set) public var pendingDomainRefresh = false
    /// 同步状态/辅助查询（groups/sync_status/history/conflicts）失败时记录，
    /// 用于 UI 提示"同步状态加载失败"（业务查询失败不阻断主列表）。
    public internal(set) var lastSyncError: CommandError?
    /// reloadMetadata() 成功后才置位（对齐旧版"reload 成功才写 durable ack"语义）；
    /// confirm 按钮需 ack + written 才可用（deriveSyncControls 保守策略）。
    public internal(set) var reloadAcked = false
    public var filterState = FilterState()
    public var autoAdvance = true
    /// 审计 P1-并发：可见性门控——画质分析 500ms 轮询在页面离开
    /// （条件渲染销毁）后停止，避免隐藏期后台空转。
    ///
    /// Cut 4 / 4a-2b：唯一写入口是 `setVisible(_:)`（View 不再直接写），
    /// 字段本身保留（审计 §1.4 / 4a-2 验收）。
    public private(set) var isActive = true
    /// 关闭终态：shutdown() 之后 setVisible(true) 明确 no-op，轮询不得复活。
    /// 4a-2c：对外只读，供 SessionWorkspace.close 的扇出测试断言。
    public private(set) var isShutdown = false
    /// 画质分析 500ms 轮询任务（可随可见性启停；旧实现把循环内联在
    /// analyzeQuality 里，隐藏即永久退出）。
    private var qualityPollTask: Task<Void, Never>?
    public internal(set) var currentPhotoId: String?
    public var currentAsset: CullingAsset? {
        guard let currentPhotoId else { return page?.assets.first }
        return page?.assets.first { $0.photo.id == currentPhotoId } ?? page?.assets.first
    }
    public internal(set) var selectedPhotoIds: Set<String> = []
    /// 本次会话已加载的全部 photoIds（loadMore 累加、整页刷新重置），
    /// 用于刷新时与选择集取交，避免跨页选择被静默清除。
    var loadedPhotoIds: Set<String> = []
    public internal(set) var navigationGroups: [NavigationGroup] = []
    public internal(set) var isNavigationBusy = false
    public internal(set) var selectedNavigationGroupId = ""
    public internal(set) var selectedNavigationGroupIds: Set<String> = []
    public internal(set) var similarityGroups: [CullingGroup] = []
    public var scopeMode: ScopeMode = .all
    public internal(set) var selectedSimilarityGroupId = ""
    var pageVersion = 0
    /// 整页加载的 latest-wins 代数：旧请求返回后不得覆盖新筛选/新会话的结果。
    var loadGeneration = 0
    /// refreshSyncStatus 的 latest-wins 代数（事件风暴下只落最后一次）。
    private var syncStatusRequestID = 0
    var refreshTask: Task<Void, Never>?

    /// 生产装配（RootView）：挑片 / 导航 / 元数据 / 任务 / 画质全部走
    /// AppServices 的类型化 API；captureOne 必传（组合根构造，reload ack 写
    /// 唯一 AppRuntime）。E-17：删除默认自建 CaptureOneBridge() 的兜底。
    public init(
        sessionId: String,
        culling: any CullingAPI,
        navigation: any NavigationAPI,
        metadata: any MetadataAPI,
        jobs: any JobAPI,
        quality: any QualityAPI,
        captureOne: any CaptureOneBridging
    ) {
        self.sessionId = sessionId
        self.cullingAPI = culling
        self.navigationAPI = navigation
        self.metadataAPI = metadata
        self.jobAPI = jobs
        self.qualityAPI = quality
        self.captureOne = captureOne
    }

    /// 首次 / 重试加载：导航组与主列表保持旧顺序（先导航、再整页）。
    public func load() async {
        guard !sessionId.isEmpty else { return }
        await loadNavigation()
        await loadPage(reset: true)
    }
    /// 从 MetadataSyncSummary 推导同步状态机（优先级对齐旧版 syncLabel：
    /// 冲突 > 失败 > 写入中 > 已写入 > 已载入 > 空）。
    public func syncFlowState() -> SyncFlowState {
        guard let syncStatus else { return .disconnected }
        if syncStatus.conflict > 0 { return .conflict }
        if syncStatus.failed > 0 { return .failed }
        if syncStatus.pending + syncStatus.writing > 0 { return .syncing }
        if syncStatus.written > 0 { return .c1Read }
        if syncStatus.synced > 0 { return .safeToCleanup }
        return .synced
    }

    /// 对齐 deriveSyncControls：syncing/c1Read/safeToCleanup 才可重载元数据。
    public var canLoadMetadata: Bool {
        CullingSyncFlow.deriveControls(
            syncState: syncFlowState(),
            hasWritten: (syncStatus?.written ?? 0) > 0,
            acked: reloadAcked
        ).canLoadMetadata
    }

    /// 对齐 deriveSyncControls：确认需（c1Read + 存在 written 行 + ack）或 safeToCleanup。
    public var canConfirmSync: Bool {
        CullingSyncFlow.deriveControls(
            syncState: syncFlowState(),
            hasWritten: (syncStatus?.written ?? 0) > 0,
            acked: reloadAcked
        ).canConfirmSync
    }

    /// 对齐 deriveSyncControls：清理仅 safeToCleanup 可用。
    public var canCleanup: Bool {
        CullingSyncFlow.deriveControls(
            syncState: syncFlowState(),
            hasWritten: (syncStatus?.written ?? 0) > 0,
            acked: reloadAcked
        ).canCleanup
    }
    // Cut 4 / 4a-3b-1：删除 VM 内的文案漏斗（`Self.message(for:)`）——
    // 错误只以 `CommandError`（码/参数/诊断）落地，文案统一在 View 渲染期
    // 经 `L10n` 解析；原始诊断只进日志。
    /// 领域广播标识：监听端跳过自己发出的事件（GatherDomainChange.origin）。
    static let changeOrigin = "culling"

    /// 挑片决策写入成功后广播（图库/画廊的星级与色标消费）。
    func postCullingChange() {
        GatherEventCenter.postDomainChange(.culling, sessionId: sessionId, origin: Self.changeOrigin)
    }

    /// 写回/结清/同步队列变化后广播（设置页/C1 胶囊/控制中心消费）。
    func postMetadataChange() {
        GatherEventCenter.postDomainChange(.metadata, sessionId: sessionId, origin: Self.changeOrigin)
    }

    /// 跨页领域变更：命中本会话的挑片/元数据/图库变更时刷新自己的数据源；
    /// 隐藏或正忙时只登记，回可见/空闲后由 flushDeferredDomainRefresh 补刷
    ///（隐藏页不发命令是外壳既有约定）。自身 origin 跳过，避免自触发重查。
    public func handleDomainChange(_ change: GatherDomainChange) {
        guard change.matches(sessionId: sessionId),
              change.origin != Self.changeOrigin,
              [.culling, .metadata, .library].contains(change.domain) else { return }
        guard isActive, !isLoading else {
            pendingDomainRefresh = true
            return
        }
        refreshSilently()
    }

    /// 页面重新可见 / 当前刷新结束后的补刷出口（幂等）。
    public func flushDeferredDomainRefresh() {
        guard pendingDomainRefresh, isActive, !isLoading else { return }
        pendingDomainRefresh = false
        refreshSilently()
    }

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2b）

    /// 可见性唯一入口：View 的 onAppear/onDisappear 只调这里。
    /// - visible=false：置 isActive=false，画质 500ms 轮询在下一拍退出/暂停；
    /// - visible=true：置 isActive=true，补刷隐藏期登记的领域变更并恢复轮询；
    /// - shutdown 之后明确 no-op（关闭是终态）。
    public func setVisible(_ visible: Bool) {
        guard !isShutdown else { return }
        isActive = visible
        guard visible else {
            qualityPollTask?.cancel()
            qualityPollTask = nil
            return
        }
        flushDeferredDomainRefresh()
        if let qualityJob, Self.isQualityJobActive(qualityJob.status) {
            startQualityPolling(job: qualityJob)
        }
    }

    /// 关闭：取消本 VM 持有的长生命周期 Task（刷新 + 画质轮询）。
    /// 关闭后 setVisible(true) 不重启，避免会话结束/淘汰后隐藏页空转。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isActive = false
        refreshTask?.cancel()
        refreshTask = nil
        qualityPollTask?.cancel()
        qualityPollTask = nil
    }

    private static func isQualityJobActive(_ status: AnalysisJobStatus) -> Bool {
        [.queued, .running, .cancelling].contains(status)
    }

    /// 已记过的质量失败诊断（去重；超过上限清空，避免无限增长）。
    private var loggedQualityDiagnostics: Set<String> = []

    /// 同步摘要统一入口：状态赋值 + 把失败/冲突行的**原始诊断**写日志
    ///（UI 只展示漏斗后的文案，见 CullingView.displayedReason）。
    func applySyncStatus(_ summary: MetadataSyncSummary?) {
        syncStatus = summary
        guard let summary else { return }
        for item in summary.items where item.status == .failed || item.status == .conflict {
            guard !item.errorMessage.isEmpty else { continue }
            GatherLogger.log(
                "culling sync \(item.status.rawValue) \(item.xmpPath): \(item.errorMessage)",
                level: .warn
            )
        }
    }

    /// 质量分析失败行的原始诊断写日志（每次页面落地一次；UI 只显示漏斗文案，
    /// 见 qualityHelpText / CullingViewModel.funnelErrorText）。
    func logQualityFailures(_ page: CullingPage) {
        for asset in page.assets {
            guard let quality = asset.quality, quality.status == .failed,
                  let raw = quality.errorMessage, !raw.isEmpty else { continue }
            // 去重：页面每次落地都会走这里，同一照片的同一条诊断只记一次。
            if loggedQualityDiagnostics.count > 200 { loggedQualityDiagnostics.removeAll() }
            let key = "\(asset.photo.id)|\(raw)"
            guard loggedQualityDiagnostics.insert(key).inserted else { continue }
            GatherLogger.log("culling quality failed \(asset.photo.id): \(raw)", level: .warn)
        }
    }

    /// c1SyncStatus 事件（GatherEventCenter.c1SyncStatus，object 为 sessionId）的轻量刷新。
    public func refreshSyncStatus() async {
        syncStatusRequestID &+= 1
        let requestID = syncStatusRequestID
        var failure: CommandError?
        do {
            let status = try await cullingAPI.syncStatus(sessionId)
            guard requestID == syncStatusRequestID else { return }
            applySyncStatus(status.summary)
            reloadAcked = status.reloadAckedAt != nil
        } catch {
            guard requestID == syncStatusRequestID else { return }
            failure = CommandError(error)
        }
        do {
            let summary = try await cullingAPI.summary(sessionId)
            guard requestID == syncStatusRequestID else { return }
            self.summary = summary
        } catch {
            guard requestID == syncStatusRequestID else { return }
            failure = failure ?? CommandError(error)
        }
        lastSyncError = failure
    }
    /// 失败写回行（coordinator 写入的真实原因；UI 必须展示，不允许只报计数）。
    public var failedSyncItems: [MetadataSyncItem] {
        (syncStatus?.items ?? []).filter { $0.status == .failed }
    }

    /// 某个 xmp 行的失败/冲突原因（空串视为无原因）；上屏前走错误码漏斗。
    public func syncFailureReason(xmpPath: String, with l10n: L10n) -> String? {
        guard let item = syncStatus?.items.first(where: { $0.xmpPath == xmpPath }),
              !item.errorMessage.isEmpty else { return nil }
        return Self.funnelErrorText(item.errorMessage, with: l10n)
    }

    /// 已决策（keep/reject）照片数：破坏性写回确认弹窗展示影响范围用。
    public var decidedPhotoCount: Int {
        guard let summary else { return 0 }
        return summary.kept + summary.rejected
    }

    /// 测试注入：直接设置同步摘要，绕开命令层（CullingSyncFlowTests 直测状态机推导）。
    func applySyncSummaryForTesting(_ summary: MetadataSyncSummary?) {
        syncStatus = summary
    }

    /// 测试注入：直接设置质量任务，绕开建单（取消通道/文案的纯逻辑测试用）。
    func applyQualityJobForTesting(_ job: AnalysisJobData?) {
        qualityJob = job
    }

    /// TS: qualityApi.analyze + jobs.list 轮询。这里仅接入技术质量任务；
    /// 人脸推理质量按用户要求不作为本轮验收门。
    /// B8.2b：建单走 QualityAPI.analyze（返回 AnalysisJobData）；轮询走
    /// JobAPI.list(includeCheckpoint:false)（与旧 jobs.list 参数逐字一致，
    /// 避免把每个任务的 checkpoint 解析到主线程）。
    public func analyzeQuality() async {
        guard !isQualityBusy else { return }
        isQualityBusy = true
        defer { isQualityBusy = false }
        do {
            let job = try await qualityAPI.analyze(
                try QualityAnalyzeInput(sessionId: sessionId)
            )
            qualityJob = job
            notice = CullingNotice("技术质量分析已排队")
            startQualityPolling(job: job)
            // 可见时保持旧的“analyzeQuality 等到轮询终态才返回”语义；
            // 隐藏时 setVisible(false) 取消轮询，这里立即返回（不再空转）。
            await qualityPollTask?.value
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 500ms 画质任务轮询：由 analyzeQuality 启动，setVisible(false)/shutdown()
    /// 取消，setVisible(true) 对仍在排队的任务重新启动（进度不丢）。
    private func startQualityPolling(job: AnalysisJobData) {
        guard !isShutdown, isActive else { return }
        qualityPollTask?.cancel()
        qualityPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isActive {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isActive else { return }
                do {
                    let jobs = try await self.jobAPI.list(JobListFilter(includeCheckpoint: false))
                    guard let latest = jobs.first(where: { $0.id == job.id }) else { return }
                    self.qualityJob = latest
                    switch latest.status {
                    case .queued, .running, .cancelling:
                        continue
                    case .succeeded:
                        self.notice = CullingNotice("技术质量分析已完成")
                        await self.loadPage(reset: true)
                        return
                    case .failed, .interrupted:
                        self.errorMessage = CommandError(apiText: latest.errorMessage ?? "")
                        await self.loadPage(reset: true)
                        return
                    case .cancelled:
                        self.notice = CullingNotice("质量分析已取消")
                        await self.loadPage(reset: true)
                        return
                    }
                } catch {
                    self.errorMessage = CommandError(error)
                    return
                }
            }
        }
    }

    /// 取消技术质量分析任务（B8.2b：jobs.cancel -> JobAPI.cancel）。
    /// 入口保持同步签名（工具栏按钮直接回调）；请求在内部 Task 发出，
    /// 成功/失败文案与旧的同步路径一致。
    public func cancelQualityAnalysis() {
        guard let job = qualityJob else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.jobAPI.cancel(job.id)
                self.notice = CullingNotice("已请求取消质量分析")
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }
}
