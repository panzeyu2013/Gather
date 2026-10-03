// Phase 3.1/3.6：工作区控制中心（对齐 Electron ControlCenter）。
// 派生逻辑对齐 renderer/pages/SessionDetail/ControlCenter/workspace-view.ts：
// - Action Inbox 7 类固定优先级聚合（L70-169）
// - 三硬阶段进度条（L187-199，未完成阶段实线描边）
// - 推荐下一步 6 种 action 中文映射（L210-276）
// - 头部索引进度/失败重试（indexProgress.ts / deriveWorkspaceHeaderCopy 语义，
//   截断导入在精确总数落定前保留 "≥" 前缀）
// 数据源：workspace.status / jobs.list / culling.sync_status；
// 事件：GatherEventCenter.jobTerminal + c1SyncStatus，另设兜底轮询
// （索引活跃期 3s，其余 15s，对齐 useWorkspaceStatus.ts 3s/30s 双档）。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class SessionControlViewModel {
    private let client: NativeCommandClient
    public let sessionId: String
    private(set) public var session: SessionData?
    private(set) public var workspaceStatus: WorkspaceStatus?
    private(set) public var jobs: [AnalysisJobData] = []
    private(set) public var syncStatus: MetadataSyncSummary?
    private(set) public var isWorking = false
    /// 初始为 true：首帧即渲染加载态，避免 load() 完成前卡片空白。
    private(set) public var isLoading = true
    private(set) public var errorMessage: String?
    private(set) public var notice: String?

    /// 索引进度活跃判定（对齐 OLD useWorkspaceStatus.ts:26-42 的 indexActive）：
    /// stage == created（一跳化导入窗口）或 indexing == active（含 queued/running
    /// 语义）时为 true；终态（idle/failed）回落常规轮询间隔。
    public var isIndexingActive: Bool {
        guard let status = workspaceStatus else { return false }
        return status.stage == .created || status.indexing.status == .active
    }

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
    }

    public func load() {
        isLoading = true
        defer { isLoading = false }
        do {
            session = try client.execute("session.get", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: SessionData.self)
            workspaceStatus = try client.execute("workspace.status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: WorkspaceStatus.self)
            jobs = try client.execute("jobs.list", params: ["includeCheckpoint": .bool(false)]).decoded(as: [AnalysisJobData].self)
                .filter { $0.scopeId == sessionId }
            syncStatus = try? client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: MetadataSyncSummary.self)
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
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

    public func scanIndex() async {
        await enqueue("index.scan", message: GatherLocalization.l("索引扫描已入队"))
    }

    public func analyzeQuality() async {
        await enqueue("quality.analyze", message: GatherLocalization.l("技术质量分析已入队"))
    }

    /// 索引失败重试：重新入队 metadata.scan（对齐 TS retryIndex → indexerApi.scan）。
    public func retryIndex() async {
        await enqueue("index.scan", message: GatherLocalization.l("索引扫描已入队"))
    }

    public func retry(jobId: String) {
        do {
            _ = try client.execute("jobs.retry", params: ["jobId": .string(jobId)])
            notice = GatherLocalization.l("已重试任务")
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func retry(_ job: AnalysisJobData) {
        guard [.failed, .interrupted, .cancelled].contains(job.status) else { return }
        retry(jobId: job.id)
    }

    /// recommendedNext.retry_jobs 动作：重试全部失败任务（TS 跳转 /jobs；
    /// 原生无任务中心页，等价改为逐个 jobs.retry）。
    public func retryFailedJobs() {
        let failed = workspaceStatus?.failedJobs ?? []
        guard !failed.isEmpty else { return }
        var retried = 0
        var firstFailure: String?
        for job in failed {
            do {
                _ = try client.execute("jobs.retry", params: ["jobId": .string(job.id)])
                retried += 1
            } catch {
                if firstFailure == nil {
                    firstFailure = NativeCommandClient.message(for: error)
                }
            }
        }
        if retried > 0 {
            notice = String(format: GatherLocalization.l("已重试 %lld 个失败任务"), retried)
            load()
        }
        if retried == 0 {
            errorMessage = firstFailure ?? GatherLocalization.l("重试任务失败")
        }
    }

    private func enqueue(_ command: String, message: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await client.executeAsync(command, params: ["sessionId": .string(sessionId)])
            notice = message
            load()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }
}

// MARK: - Action Inbox 模型（对齐 workspace-view.ts InboxItem / InboxKind）
// internal（非 private）：InboxItemsTests 直测 deriveInboxItems 优先级。

enum InboxKind: Equatable {
    case scanIncomplete
    case xmpConflict
    case analysisStale
    case xmpPending
    case offlinePhotos
    case jobFailed
    case exportPending
}

enum InboxAction: Equatable {
    case none
    case showStages
    /// D10：进入挑片并只看 XMP 冲突（待办指向的是「某类问题」，不是「某个页面」）。
    case reviewXmpConflicts
    /// D10：进入图库并只看离线照片。
    case reviewOfflinePhotos
    /// D10：进入人脸页并直达分析步骤（分析已过期）。
    case reviewStaleAnalysis
    case navigateTab(SessionTab)
    case navigateSimilarity
    case navigateGallery
    case retryJob(String)
    case retryFailedJobs
}

struct InboxItem: Identifiable, Equatable {
    let id: String
    let kind: InboxKind
    let label: String
    let detail: String?
    let actionLabel: String
    let action: InboxAction
}

// MARK: - 推荐下一步模型（对齐 workspace-view.ts RecommendedNextView）

private struct RecommendedNextView {
    let title: String
    let detail: String
    let actionLabel: String
    let action: InboxAction?
}

// MARK: - 头部索引文案模型（对齐 indexProgress.ts IndexHeaderCopy）

/// 索引进度头文案模式（internal：IndexProgressTests 直测纯推导）。
enum IndexHeaderMode: Equatable {
    case scanning
    case error
    case count
}

struct IndexHeaderCopy: Equatable {
    let mode: IndexHeaderMode
    let text: String
    let percent: Double?
    let done: Int
    let total: Int
}

public struct SessionControlView: View {
    @State private var viewModel: SessionControlViewModel
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void
    /// 导出入口专用回调（N05）：携带入口意图，决定导出页的默认范围。
    private let onOpenExportTab: (String, ExportRangeIntent) -> Void
    /// D10：XMP 冲突待办专用回调——进入挑片并只看冲突（未注入时退回普通挑片页）。
    private let onReviewXmpConflicts: (String) -> Void
    /// D10：离线照片待办——进入图库并只看离线（未注入时退回普通图库）。
    private let onReviewOfflinePhotos: (String) -> Void
    /// D10：分析过期待办——进入人脸页并直达分析步骤（未注入时退回人脸页）。
    private let onReviewStaleAnalysis: (String) -> Void
    @State private var scrollToStagesRequested = false
    /// 已完成任务历史默认折叠（F07：历史不占首屏）。
    @State private var showJobHistory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// TS: MAX_FAILED_JOB_ROWS —— 失败任务最多显示 3 行。
    private static let maxFailedJobRows = 3
    /// 兜底轮询常规间隔（10-30s 区间内；事件驱动为主，轮询仅兜底）。
    private static let pollInterval: Duration = .seconds(15)
    /// 索引活跃期快速轮询间隔（对齐 TS POLL_INTERVAL_ACTIVE_MS=3s：
    /// 索引进度条及时推进；useWorkspaceStatus.ts:10-11 3s/30s 双档）。
    private static let pollIntervalActive: Duration = .seconds(3)

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        onOpenExportTab: ((String, ExportRangeIntent) -> Void)? = nil,
        onReviewXmpConflicts: ((String) -> Void)? = nil,
        onReviewOfflinePhotos: ((String) -> Void)? = nil,
        onReviewStaleAnalysis: ((String) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: SessionControlViewModel(sessionId: sessionId, router: router))
        self.router = router
        self.onOpenExportTab = onOpenExportTab ?? { id, _ in onOpenTab(id, .export) }
        self.onReviewXmpConflicts = onReviewXmpConflicts ?? { id in onOpenTab(id, .culling) }
        self.onReviewOfflinePhotos = onReviewOfflinePhotos ?? { id in onOpenGallery(id) }
        self.onReviewStaleAnalysis = onReviewStaleAnalysis ?? { id in onOpenTab(id, .faceKw) }
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if let error = viewModel.errorMessage {
                    NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                }
                if let notice = viewModel.notice {
                    NativeBanner(text: notice, color: GatherTheme.success)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                }
                ScrollView {
                    if viewModel.isLoading {
                        ProgressView(GatherLocalization.l("加载中…"))
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(24)
                    } else if viewModel.workspaceStatus != nil {
                        VStack(alignment: .leading, spacing: 18) {
                            // 分块顺序按「现在该做什么」（F07）：
                            // 索引状态（内容，不是假标题栏）→ 阶段条 → 当前任务
                            // →（与任务不重复的）待办与推荐 → 分析工具箱 → 同步详情。
                            // 旧顺序把「当前任务」放在最后一张卡，首屏只能看到重复引导。
                            indexRow
                            stagesCard.id("stages")
                            jobsCard
                            inboxCard
                            recommendationCard
                            actionCard
                            syncCard
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    } else {
                        // 加载失败必须给出口（不再渲染空面板）。
                        ContentUnavailableView {
                            Label(
                                viewModel.errorMessage == nil
                                    ? GatherLocalization.l("暂无工作区状态")
                                    : GatherLocalization.l("加载失败"),
                                systemImage: "tray"
                            )
                        } description: {
                            Text(viewModel.errorMessage ?? GatherLocalization.l("无法读取该工作区的状态，请刷新后重试。"))
                        } actions: {
                            Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") { viewModel.load() }
                                .help(GatherLocalization.l("重新读取工作区状态"))
                        }
                    }
                }
            }
            .background(GatherTheme.windowBackground)
            // 窗口 chrome：副标题 + 工具栏 principal 位置的分段子导航。
            .sessionPageChrome(
                subtitle: GatherLocalization.l("工作区控制中心"),
                selection: .tab(.control),
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
            .toolbar { toolbarItems }
            .onChange(of: scrollToStagesRequested) { _, requested in
                guard requested else { return }
                if reduceMotion {
                    proxy.scrollTo("stages", anchor: .top)
                } else {
                    withAnimation { proxy.scrollTo("stages", anchor: .top) }
                }
                scrollToStagesRequested = false
            }
        }
        .task {
            viewModel.load()
            // 兜底轮询：jobTerminal / c1SyncStatus 事件驱动为主，无事件时按状态
            // 动态调整间隔——索引进度活跃期（isIndexingActive）每 3s 刷新一次，
            // 其余情况 15s（对齐 OLD useWorkspaceStatus.ts 的 3s/30s 双档）。
            // 每次 sleep 前读取最新 status，因此索引开始/结束会自动切换档位。
            while !Task.isCancelled {
                let interval = viewModel.isIndexingActive ? Self.pollIntervalActive : Self.pollInterval
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                viewModel.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.scopeType == "session",
                  event.job.scopeId == viewModel.sessionId else { return }
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            viewModel.load()
        }
        // 写路径广播（XMP/同步队列、重复处置、人脸簇变化）：按会话命中后刷新
        // 控制中心的相应域，不再只靠轮询/任务终态。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherDomainChange,
                  change.matches(sessionId: viewModel.sessionId),
                  [.metadata, .duplicates, .faceKeywording].contains(change.domain) else { return }
            viewModel.load()
        }
    }

    // MARK: 工具栏（窗口 chrome：返回 / 状态胶囊 / 刷新）

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                onBack()
            } label: {
                Label(GatherLocalization.l("返回"), systemImage: "chevron.backward")
            }
            .help(GatherLocalization.l("返回到上一页"))
            .keyboardShortcut("[", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            C1StatusCapsuleHost(
                sessionId: viewModel.sessionId,
                router: router,
                onOpenSettings: onOpenSettings
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.load()
            } label: {
                Label(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise")
            }
            .help(GatherLocalization.l("刷新工作区状态"))
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: 索引进度（对齐 deriveWorkspaceHeaderCopy；内容行，不是页头）

    @ViewBuilder
    private var indexRow: some View {
        if let status = viewModel.workspaceStatus {
            let copy = indexHeaderCopy(status, session: viewModel.session)
            HStack(spacing: 10) {
                switch copy.mode {
                case .scanning:
                    Text(copy.text).font(.callout)
                    if copy.total > 0 {
                        ProgressView(value: Double(copy.done), total: Double(copy.total))
                            .progressViewStyle(.linear)
                        if let percent = copy.percent {
                            Text(String(format: GatherLocalization.l("已索引 %lld%%"), Int(percent.rounded())))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .error:
                    // 状态色只落在图标上，正文保持系统前景色（彩色正文对比度不足）。
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GatherTheme.error)
                            .accessibilityHidden(true)
                        Text(copy.text).font(.callout)
                    }
                    Button(GatherLocalization.l("重试")) { Task { await viewModel.retryIndex() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(GatherLocalization.l("重新排队索引扫描"))
                case .count:
                    Text(copy.text).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// deriveWorkspaceHeaderCopy（workspace-view.ts L289-322）：索引活跃/失败期间
    /// 绝不把阶段计数当权威数据展示；截断导入在索引成功（精确总数落定）前保留 "≥"。
    /// internal（非 private）：IndexProgressTests 直接测纯推导（对齐 index-progress.test.ts）。
    func indexHeaderCopy(_ status: WorkspaceStatus, session: SessionData?) -> IndexHeaderCopy {
        if status.stage == .created || status.indexing.status == .active {
            if status.indexing.total > 0 {
                return IndexHeaderCopy(
                    mode: .scanning,
                    text: String(format: GatherLocalization.l("正在索引 %lld / %lld"), status.indexing.done, status.indexing.total),
                    // 对齐 index-progress.test.ts：percent 钳制 0...100（防御服务端越界）。
                    percent: min(max(status.indexing.percent, 0), 100),
                    done: status.indexing.done,
                    total: status.indexing.total
                )
            }
            return IndexHeaderCopy(mode: .scanning, text: GatherLocalization.l("扫描中…"), percent: nil, done: 0, total: 0)
        }
        if status.indexing.status == .failed {
            return IndexHeaderCopy(mode: .error, text: GatherLocalization.l("索引失败"), percent: nil, done: 0, total: 0)
        }
        let photoCount = session?.photoCount ?? 0
        if photoCount == 0 {
            return IndexHeaderCopy(mode: .count, text: GatherLocalization.l("暂无照片"), percent: nil, done: 0, total: 0)
        }
        if (session?.truncatedImport ?? false) && status.stage != .indexed {
            return IndexHeaderCopy(mode: .count, text: String(format: GatherLocalization.l("已索引 ≥%lld 张照片"), photoCount), percent: nil, done: 0, total: 0)
        }
        return IndexHeaderCopy(mode: .count, text: String(format: GatherLocalization.l("已索引 %lld 张照片"), photoCount), percent: nil, done: 0, total: 0)
    }

    // MARK: 三硬阶段进度条（对齐 deriveStageMarks + index.tsx stageBar）

    private var stagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("阶段进度")).font(.title3.weight(.semibold))
            if let status = viewModel.workspaceStatus {
                stageTrack(stageMarks(status.stage))
                if status.softFlags.culled || status.softFlags.exported {
                    HStack(spacing: 8) {
                        if status.softFlags.culled { GatherBadge(GatherLocalization.l("已挑片"), tone: .accent) }
                        if status.softFlags.exported { GatherBadge(GatherLocalization.l("已导出"), tone: .accent) }
                    }
                }
            }
        }
        .gatherCard()
    }

    /// 阶段标记（internal：WorkspaceStageMarksTests 直测 deriveStageMarks）。
    struct StageMark: Identifiable, Equatable {
        let id: String
        let label: String
        let reached: Bool
        let current: Bool
    }

    /// deriveStageMarks（workspace-view.ts L187-199）：created 窗口（一跳化导入后
    /// 0 张照片）时高亮第一个硬阶段；未达阶段以实线描边标记呈现。
    func stageMarks(_ stage: WorkspaceStage) -> [StageMark] {
        let order = ["imported", "indexed", "analyzed"]
        let labels: [String: String] = [
            "imported": GatherLocalization.l("已导入"),
            "indexed": GatherLocalization.l("已索引"),
            "analyzed": GatherLocalization.l("已分析"),
        ]
        let reachedIndex = stage == .created ? -1 : (order.firstIndex(of: stage.rawValue) ?? -1)
        return order.enumerated().map { index, id in
            StageMark(
                id: id,
                label: labels[id] ?? id,
                reached: index <= reachedIndex,
                current: stage == .created ? index == 0 : index == reachedIndex
            )
        }
    }

    /// 三阶段轨迹：等宽列 + 列内左右两段连接线，圆点与连接线共用同一垂直中心。
    /// 旧实现把连接线放在列之间并各占 `maxWidth: .infinity`，连接线被拉伸后
    /// 圆点位置取决于相邻标题宽度，标题与圆点必然错位；等宽列 + 列内线段
    /// 让三个圆点等距、线段与圆点中心严格对齐（也去掉了手绘底色/发光）。
    private func stageTrack(_ marks: [StageMark]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                VStack(spacing: 6) {
                    ZStack {
                        HStack(spacing: 0) {
                            connectorSegment(filled: mark.reached, hidden: index == 0)
                            Color.clear.frame(width: stageDotDiameter)
                            connectorSegment(
                                filled: marks.indices.contains(index + 1) ? marks[index + 1].reached : false,
                                hidden: index == marks.count - 1
                            )
                        }
                        stageDot(mark)
                    }
                    Text(mark.label)
                        .font(.callout)
                        .fontWeight(mark.current ? .semibold : .regular)
                        .foregroundStyle(mark.reached || mark.current ? GatherTheme.primaryText : GatherTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityValue(stageAccessibilityValue(mark))
            }
        }
        .padding(.vertical, 2)
    }

    private var stageDotDiameter: CGFloat { 20 }

    private func connectorSegment(filled: Bool, hidden: Bool) -> some View {
        Capsule()
            .fill(filled ? GatherTheme.accent : GatherTheme.separator)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .opacity(hidden ? 0 : 1)
    }

    private func stageDot(_ mark: StageMark) -> some View {
        Group {
            if mark.reached {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GatherTheme.success)
            } else if mark.current {
                Image(systemName: "circle.inset.filled")
                    .foregroundStyle(GatherTheme.accent)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(GatherTheme.secondaryText)
            }
        }
        .font(.title3)
        .frame(width: stageDotDiameter, height: stageDotDiameter)
        .accessibilityHidden(true)
    }

    private func stageAccessibilityValue(_ mark: StageMark) -> String {
        if mark.reached { return GatherLocalization.l("已完成") }
        if mark.current { return GatherLocalization.l("进行中") }
        return GatherLocalization.l("未开始")
    }

    // MARK: Action Inbox（对齐 deriveInboxItems：固定优先级序列表）

    private var inboxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(GatherLocalization.l("待处理事项")).font(.title3.weight(.semibold))
                Text(GatherLocalization.l("按优先级排序")).font(.footnote).foregroundStyle(.secondary)
            }
            if let status = viewModel.workspaceStatus {
                let items = inboxItems(status, truncatedImport: viewModel.session?.truncatedImport ?? false)
                    .filter { $0.kind != .scanIncomplete }
                if items.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(GatherTheme.success)
                            .accessibilityHidden(true)
                        Text(GatherLocalization.l("全部正常")).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        inboxRow(item)
                    }
                }
            }
        }
        .gatherCard()
    }

    private func inboxRow(_ item: InboxItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            let icon = inboxIcon(item.kind)
            Image(systemName: icon.name).foregroundStyle(icon.color).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                if let detail = item.detail {
                    // 错误明细是内容语义：用 .callout 而不是 .footnote。
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(item.actionLabel) { perform(item.action) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// deriveInboxItems（workspace-view.ts L70-169）：7 类固定优先级聚合，
    /// 失败任务最多 3 行；错误码仅展示可翻译文案，原始诊断不落 UI。
    func inboxItems(_ status: WorkspaceStatus, truncatedImport: Bool) -> [InboxItem] {
        var items: [InboxItem] = []
        let truncatedImport = truncatedImport

        let indexingActive = status.stage == .created || status.indexing.status == .active
        let scanIncomplete = indexingActive
            || status.indexing.status == .failed
            || (truncatedImport && status.stage == .imported)
        if scanIncomplete {
            items.append(InboxItem(
                id: "scan_incomplete", kind: .scanIncomplete,
                label: GatherLocalization.l("索引未完成，照片数量暂不精确"), detail: nil,
                actionLabel: GatherLocalization.l("查看进度"), action: .showStages
            ))
        }

        if status.xmp.conflict > 0 {
            items.append(InboxItem(
                id: "xmp_conflict", kind: .xmpConflict,
                label: String(format: GatherLocalization.l("%lld 个 XMP 冲突待裁决"), status.xmp.conflict), detail: nil,
                actionLabel: GatherLocalization.l("逐条裁决"), action: .reviewXmpConflicts
            ))
        }

        if !status.staleAnalyses.isEmpty {
            let faceOnly = status.staleAnalyses.allSatisfy { $0.kind == .face }
            let names = status.staleAnalyses
                .map { $0.kind == .similarity ? GatherLocalization.l("相似度") : GatherLocalization.l("人脸") }
                .joined(separator: "、")
            items.append(InboxItem(
                id: "analysis_stale", kind: .analysisStale,
                label: String(format: GatherLocalization.l("%@分析已过期，新增照片未参与分析"), names), detail: nil,
                actionLabel: GatherLocalization.l("重新分析"),
                // D10：人脸过期要直达**分析步骤**（旧实现只切页，用户还得自己找入口）；
                // 相似度过期仍走相似度页（其分析入口就在页首）。
                action: faceOnly ? .reviewStaleAnalysis : .navigateSimilarity
            ))
        }

        if status.xmp.pending > 0 {
            items.append(InboxItem(
                id: "xmp_pending", kind: .xmpPending,
                label: String(format: GatherLocalization.l("%lld 个 XMP 待写入"), status.xmp.pending), detail: nil,
                actionLabel: GatherLocalization.l("检查"), action: .navigateTab(.culling)
            ))
        }

        if status.offlinePhotos > 0 {
            items.append(InboxItem(
                id: "offline_photos", kind: .offlinePhotos,
                label: String(format: GatherLocalization.l("%lld 张照片离线（源文件不可读）"), status.offlinePhotos), detail: nil,
                actionLabel: GatherLocalization.l("查看"), action: .reviewOfflinePhotos
            ))
        }

        for (index, job) in status.failedJobs.prefix(Self.maxFailedJobRows).enumerated() {
            // 错误码不在翻译表时 detail 置 nil 不渲染（对齐 TS L148-150：
            // 原始诊断不落 UI 文案）。
            let detail = GatherLocalization.errorMessages[job.code]
            items.append(InboxItem(
                id: "job_failed-\(index)", kind: .jobFailed,
                label: String(format: GatherLocalization.l("%@任务失败"), Self.jobTypeLabel(job.type)), detail: detail,
                actionLabel: GatherLocalization.l("重试"), action: .retryJob(job.id)
            ))
        }

        if status.softFlags.culled && !status.softFlags.exported {
            items.append(InboxItem(
                id: "export_pending", kind: .exportPending,
                label: GatherLocalization.l("已挑片但尚未导出"), detail: nil,
                actionLabel: GatherLocalization.l("去导出"), action: .navigateTab(.export)
            ))
        }

        return items
    }

    /// JOB_TYPE_KEYS（workspace-view.ts L43-53）：未知类型回退原始字符串。
    private static func jobTypeLabel(_ type: String) -> String {
        switch type {
        case "metadata.scan": GatherLocalization.l("索引")
        case "similarity.analyze": GatherLocalization.l("相似度分析")
        case "fkw.analyze", "face.analyze": GatherLocalization.l("人脸分析")
        case "dup.scan", "duplicate.scan": GatherLocalization.l("重复扫描")
        case "export.execute": GatherLocalization.l("导出")
        case "quality.analyze", "quality.score": GatherLocalization.l("技术分析")
        case "navigation.analyze": GatherLocalization.l("导航分析")
        case "culling.writeback": GatherLocalization.l("挑片写回")
        case "sim.writeback": GatherLocalization.l("相似组写回")
        default: type
        }
    }

    private func inboxIcon(_ kind: InboxKind) -> (name: String, color: Color) {
        switch kind {
        case .scanIncomplete: return ("magnifyingglass", GatherTheme.accent)
        case .xmpConflict: return ("exclamationmark.triangle.fill", GatherTheme.error)
        case .analysisStale: return ("clock.arrow.circlepath", GatherTheme.warning)
        case .xmpPending: return ("arrow.up.doc", GatherTheme.accent)
        case .offlinePhotos: return ("photo", .secondary)
        case .jobFailed: return ("xmark.circle.fill", GatherTheme.error)
        case .exportPending: return ("square.and.arrow.up", GatherTheme.accent)
        }
    }

    // MARK: 推荐下一步（对齐 deriveRecommendedNextView）

    /// 推荐下一步只在**不与「待处理事项」重复**时渲染（F07）。
    ///
    /// 旧实现让「待处理事项 · 已挑片但尚未导出」和「推荐下一步 · 导出成品」
    /// 同时出现，两张卡都在说「去导出」；XMP 冲突、分析过期、失败任务同样成对
    /// 出现。同一动作只保留优先级列表里的那一行，推荐卡专注它独有的建议
    ///（例如「开始挑片」）。
    private func isDuplicateRecommendation(_ next: RecommendedNextView, status: WorkspaceStatus) -> Bool {
        // action == nil（一切正常）时也不重复渲染：inbox 已经给出「全部正常」。
        guard let action = next.action else { return true }
        let inbox = inboxItems(status, truncatedImport: viewModel.session?.truncatedImport ?? false)
            .filter { $0.kind != .scanIncomplete }
        return inbox.contains { $0.action == action }
    }

    @ViewBuilder
    private var recommendationCard: some View {
        Group {
            if let status = viewModel.workspaceStatus {
                let view = recommendedNextView(status)
                if !isDuplicateRecommendation(view, status: status) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb").foregroundStyle(GatherTheme.warning)
                            .accessibilityHidden(true)
                        Text(GatherLocalization.l("推荐下一步")).font(.title3.weight(.semibold))
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(view.title).font(.callout.weight(.semibold))
                            Text(view.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let action = view.action {
                            Button(view.actionLabel) { perform(action) }
                                .gatherPrimaryActionButton().controlSize(.small)
                        }
                    }
                }
                }
            }
        }
        .gatherCard()
    }

    /// deriveRecommendedNextView（workspace-view.ts L210-276）：6 种 action 映射为
    /// 中文标题/详情/按钮文案；未知 action 兜底为 done（一切正常）而非裸枚举字符串
    /// （对齐 TS L273-274 return done）。
    private func recommendedNextView(_ status: WorkspaceStatus) -> RecommendedNextView {
        guard let next = status.recommendedNext else {
            return RecommendedNextView(
                title: GatherLocalization.l("一切正常"), detail: GatherLocalization.l("工作区状态良好，无待办事项"),
                actionLabel: "", action: nil
            )
        }
        switch next.action {
        case "scan_incomplete":
            return RecommendedNextView(
                title: GatherLocalization.l("等待索引完成"), detail: GatherLocalization.l("后台索引正在进行，完成后照片数量将精确显示"),
                actionLabel: GatherLocalization.l("查看进度"), action: .showStages
            )
        case "resolve_conflicts":
            // G-1（审计 5）：推荐动作必须与待办**同一个枚举**，否则
            // isDuplicateRecommendation 的「动作相等」判据失效 → 同屏两张同义卡，
            // 两个按钮都叫「逐条裁决」，一个带筛选一个不带（D10 + F07 的合流回归）。
            return RecommendedNextView(
                title: GatherLocalization.l("裁决 XMP 冲突"), detail: GatherLocalization.l("冲突会阻塞写回同步，先逐条裁决再继续"),
                actionLabel: GatherLocalization.l("逐条裁决"), action: .reviewXmpConflicts
            )
        case "re_analyze":
            let faceOnly = status.staleAnalyses.allSatisfy { $0.kind == .face }
            return RecommendedNextView(
                // 标题按真实落点生成：人脸过期时点的是「重新分析人脸」，
                // 旧实现标题写死「重新分析相似度」而动作却去人脸页。
                title: faceOnly ? GatherLocalization.l("重新分析人脸") : GatherLocalization.l("重新分析相似度"),
                detail: GatherLocalization.l("新增照片未参与分组，重新分析可合并剩余重复项"),
                actionLabel: GatherLocalization.l("重新分析"),
                action: faceOnly ? .reviewStaleAnalysis : .navigateSimilarity
            )
        case "retry_jobs":
            return RecommendedNextView(
                title: GatherLocalization.l("重试失败任务"), detail: GatherLocalization.l("存在失败的后台任务，先重试再继续"),
                actionLabel: GatherLocalization.l("重试失败任务"), action: .retryFailedJobs
            )
        case "start_culling":
            return RecommendedNextView(
                title: GatherLocalization.l("开始挑片"), detail: GatherLocalization.l("工作区已就绪，从挑片开始整理"),
                actionLabel: GatherLocalization.l("去挑片"), action: .navigateTab(.culling)
            )
        case "export":
            return RecommendedNextView(
                title: GatherLocalization.l("导出成品"), detail: GatherLocalization.l("挑片已完成，导出最终成品"),
                actionLabel: GatherLocalization.l("去导出"), action: .navigateTab(.export)
            )
        default:
            return RecommendedNextView(
                title: GatherLocalization.l("一切正常"), detail: GatherLocalization.l("工作区状态良好，无待办事项"),
                actionLabel: "", action: nil
            )
        }
    }

    // MARK: 动作执行

    private func perform(_ action: InboxAction) {
        switch action {
        case .none:
            break
        case .showStages:
            scrollToStagesRequested = true
        case .reviewXmpConflicts:
            // D10：待办指向「某类问题」——进入挑片时必须同时带上「只看冲突」，
            // 否则用户到达的只是一个普通挑片页，还得自己再找一遍。
            onReviewXmpConflicts(viewModel.sessionId)
        case .reviewOfflinePhotos:
            onReviewOfflinePhotos(viewModel.sessionId)
        case .reviewStaleAnalysis:
            onReviewStaleAnalysis(viewModel.sessionId)
        case .navigateTab(let tab):
            if tab == .export {
                // N05：控制中心的导出引导语义是「导出挑片成果」——默认范围必须
                // 是保留片，而不是退回「工作区全部照片」。
                onOpenExportTab(viewModel.sessionId, .picks)
            } else {
                onOpenTab(viewModel.sessionId, tab)
            }
        case .navigateSimilarity:
            onOpenSimilarity(viewModel.sessionId)
        case .navigateGallery:
            // 对齐 OLD workspace-view.ts:135：offline_photos “查看”进入画廊
            // （/sessions/:id/gallery），而非 onBack 返回上一页。onOpenGallery
            // 在 RootView 已接线 navigation.openGallery；默认闭包保证独立编译。
            onOpenGallery(viewModel.sessionId)
        case .retryJob(let jobId):
            viewModel.retry(jobId: jobId)
        case .retryFailedJobs:
            viewModel.retryFailedJobs()
        }
    }

    // MARK: 工具箱（原生保留入口）

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("分析与索引")).font(.title3.weight(.semibold))
            // 文案只说真实存在的操作（旧版承诺「查看/取消」但界面没有这两个入口）。
            Text(GatherLocalization.l("扫描索引与质量分析会入队后台任务，进度显示在「当前任务」中；失败的任务可重试。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(GatherLocalization.l("扫描索引"), systemImage: "magnifyingglass") { Task { await viewModel.scanIndex() } }
                    .disabled(viewModel.isWorking)
                    .help(GatherLocalization.l("重新扫描工作区，让索引保持最新"))
                Button(GatherLocalization.l("分析质量"), systemImage: "wand.and.stars") { Task { await viewModel.analyzeQuality() } }
                    .disabled(viewModel.isWorking)
                    .help(GatherLocalization.l("为照片计算技术质量评分"))
                Button(GatherLocalization.l("打开挑片")) { onOpenTab(viewModel.sessionId, .culling) }
                    .help(GatherLocalization.l("切换到挑片页面"))
                Button(GatherLocalization.l("打开人脸")) { onOpenTab(viewModel.sessionId, .faceKw) }
                    .help(GatherLocalization.l("切换到人脸关键词页面"))
            }
        }
        .gatherCard()
    }

    // MARK: 元数据同步（保留计数 + 中文状态说明）

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GatherLocalization.l("元数据同步")).font(.title3.weight(.semibold))
            if let sync = viewModel.syncStatus {
                HStack(spacing: 16) {
                    syncCount(GatherLocalization.l("待处理"), sync.pending)
                    syncCount(GatherLocalization.l("写入中"), sync.writing)
                    syncCount(GatherLocalization.l("已写入"), sync.written)
                    syncCount(GatherLocalization.l("失败"), sync.failed, emphasized: sync.failed > 0)
                    syncCount(GatherLocalization.l("冲突"), sync.conflict, emphasized: sync.conflict > 0)
                    Spacer()
                }
                // 状态色只落在图标上；正文保持系统前景色（彩色正文对比度不足）。
                HStack(spacing: 6) {
                    // 只有「全部确认」才是绿色勾；待写入/写入中/待 C1 读取都是进行中
                    //（黄色），与胶囊的四色调映射一致（F08）。
                    if sync.failed + sync.conflict > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GatherTheme.error)
                            .accessibilityHidden(true)
                    } else if sync.pending + sync.writing + sync.written > 0 {
                        Image(systemName: "clock")
                            .foregroundStyle(GatherTheme.warning)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(GatherTheme.success)
                            .accessibilityHidden(true)
                    }
                    Text(syncStatusText(sync)).font(.callout)
                }
            } else {
                Text(GatherLocalization.l("暂无同步状态")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .gatherCard()
    }

    private func syncCount(_ title: String, _ value: Int, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text("\(value)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? GatherTheme.error : GatherTheme.primaryText)
        }
        .accessibilityElement(children: .combine)
    }

    /// 同步状态文案（F08）：与 C1 状态胶囊同一套阶梯，同一屏不再出现互相矛盾的结论。
    ///
    /// 阶梯：待写入 → Gather 正在写入 → 已写入待读取（等 C1 读取）→ 已同步。
    /// 旧实现只看 failed/conflict/pending/writing，written > 0（Gather 已写入但
    /// Capture One 还没读回）时正文已经说「元数据已全部同步」，而同一屏顶部的
    /// 胶囊写着「已写入待读取 1」。
    /// internal（非 private）：SyncStatusCopyTests 直测状态阶梯。
    func syncStatusText(_ sync: MetadataSyncSummary) -> String {
        if sync.conflict > 0 { return GatherLocalization.l("存在 XMP 冲突，请先裁决") }
        if sync.failed > 0 { return GatherLocalization.l("有写入失败项，请先重试") }
        if sync.writing > 0 { return GatherLocalization.l("Gather 正在写入 XMP…") }
        if sync.pending > 0 {
            return String(format: GatherLocalization.l("待写入 %lld 项：Gather 尚未写入 XMP"), sync.pending)
        }
        if sync.written > 0 { return GatherLocalization.l("已写入待读取：等待 Capture One 读取元数据") }
        if sync.synced > 0 { return GatherLocalization.l("已同步：Capture One 已读取") }
        return GatherLocalization.l("没有待同步的元数据")
    }

    // MARK: 当前任务（本地化状态/类型/进度文案）

    /// 当前任务（F07）：只列活跃任务与失败/中断任务；已完成历史默认折叠。
    /// 没有活跃任务时只给一行说明，不再用大卡片承载一段历史。
    private var jobsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GatherLocalization.l("当前任务")).font(.title3.weight(.semibold))
            if viewModel.activeJobs.isEmpty && viewModel.attentionJobs.isEmpty {
                Text(GatherLocalization.l("没有进行中的任务。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.activeJobs, id: \.id) { job in
                    jobRow(job)
                }
                // 失败任务最多 3 行（TS MAX_FAILED_JOB_ROWS 语义），其余在历史里。
                ForEach(Array(viewModel.attentionJobs.prefix(Self.maxFailedJobRows)), id: \.id) { job in
                    jobRow(job)
                }
            }
            if !viewModel.historyJobs.isEmpty {
                DisclosureGroup(isExpanded: $showJobHistory) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.historyJobs, id: \.id) { job in
                            jobRow(job)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(String(format: GatherLocalization.l("已完成任务（%lld）"), viewModel.historyJobs.count))
                        .font(.callout)
                }
            }
        }
        .gatherCard()
    }

    /// 任务行：状态图标逐态区分（旧实现除 succeeded 外全是 circle.dotted，
    /// queued/running/cancelling/cancelled 视觉上不可分辨）+ 原生线性进度条。
    private func jobRow(_ job: AnalysisJobData) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: jobStatusSymbol(job.status))
                .foregroundStyle(jobStatusColor(job.status))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(GatherLocalization.jobTypeText(job.type.rawValue))
                    GatherBadge(status: job.status)
                    Spacer(minLength: 0)
                }
                if job.progressTotal > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(job.progressCurrent), total: Double(job.progressTotal))
                            .progressViewStyle(.linear)
                        Text("\(job.progressCurrent)/\(job.progressTotal)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(GatherLocalization.progressPhaseText(job.progressMessage))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if [.failed, .interrupted, .cancelled].contains(job.status) {
                Button(GatherLocalization.l("重试")) { viewModel.retry(job) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(GatherLocalization.l("重新排队该任务"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func jobStatusSymbol(_ status: AnalysisJobStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        case .interrupted: return "pause.circle"
        case .cancelling: return "stop.circle"
        }
    }

    private func jobStatusColor(_ status: AnalysisJobStatus) -> Color {
        switch status {
        case .queued, .cancelled: return GatherTheme.secondaryText
        case .running, .cancelling: return GatherTheme.accent
        case .succeeded: return GatherTheme.success
        case .failed: return GatherTheme.error
        case .interrupted: return GatherTheme.warning
        }
    }
}
