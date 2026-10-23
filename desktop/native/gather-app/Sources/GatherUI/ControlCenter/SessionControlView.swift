// Phase 3.1/3.6：工作区控制中心（对齐 Electron ControlCenter）。
// 派生逻辑对齐 renderer/pages/SessionDetail/ControlCenter/workspace-view.ts：
// - Action Inbox 7 类固定优先级聚合（L70-169）
// - 三硬阶段进度条（L187-199，未完成阶段实线描边）
// - 推荐下一步 6 种 action 中文映射（L210-276）
// - 头部索引进度/失败重试（indexProgress.ts / deriveWorkspaceHeaderCopy 语义，
//   截断导入在精确总数落定前保留 "≥" 前缀）
// 数据源：SessionAPI.get/status / JobAPI.list / CullingAPI.syncStatus（B8.2a 起
// 全部走类型化 API，不再派发字符串命令）；
// 事件：GatherEventCenter.jobTerminal + c1SyncStatus，另设兜底轮询
// （索引活跃期 3s，其余 15s，对齐 useWorkspaceStatus.ts 3s/30s 双档）。
//
// Cut 4 / 4c-2e：1,276 行单文件拆为「壳 + 段落 View 文件 + VM/模型文件」，
// 纯搬移、行为不变。本文件只留页面壳：3 个 @State 身份、装配 init、body 的
// 分块顺序与 .task/.onAppear/.onDisappear/.onReceive 接线（轮询启停仍由 VM 的
// setVisible 负责）。段落实现见同目录：+IndexHeader / +Stages / +Inbox /
// +Recommendation / +Toolbox / +Sync / +Jobs / +Toolbar / +Actions；
// 任务行叶子 View 在 SessionControlJobRow。

import SwiftUI
import GatherProtocol

public struct SessionControlView: View {
    @State var viewModel: SessionControlViewModel
    /// 所属会话工作区（R4 P1-2）：页面级可见性经 workspace 路由，进入会话
    /// 不再由 workspace 把 7 个 VM 一起置真。
    private let workspace: SessionWorkspace
    /// C1 状态胶囊的 syncStatus 入口（B8.2e）。
    let culling: any CullingAPI
    let onBack: () -> Void
    let onOpenSimilarity: (String) -> Void
    let onOpenTab: (String, SessionTab) -> Void
    let onOpenGallery: (String) -> Void
    let onOpenSettings: () -> Void
    /// 导出入口专用回调（N05）：携带入口意图，决定导出页的默认范围。
    let onOpenExportTab: (String, ExportRangeIntent) -> Void
    /// D10：XMP 冲突待办专用回调——进入挑片并只看冲突（未注入时退回普通挑片页）。
    let onReviewXmpConflicts: (String) -> Void
    /// D10：离线照片待办——进入图库并只看离线（未注入时退回普通图库）。
    let onReviewOfflinePhotos: (String) -> Void
    /// D10：分析过期待办——进入人脸页并直达分析步骤（未注入时退回人脸页）。
    let onReviewStaleAnalysis: (String) -> Void
    @State var scrollToStagesRequested = false
    /// 已完成任务历史默认折叠（F07：历史不占首屏）。
    @State var showJobHistory = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（workspace.control）。
    /// 旧实现每次 View init 新建 VM（无缓存）；现在控制中心的会话/任务/同步态
    /// 随 workspace 跨页签保留，轮询启停仍由 VM 的 setVisible 负责。
    package init(
        workspace: SessionWorkspace,
        culling: any CullingAPI,
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
        _viewModel = State(initialValue: workspace.control)
        self.workspace = workspace
        self.culling = culling
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

    // Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView / SessionTabHost）。
    @Environment(\.languageStore) private var languageStore
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if let error = viewModel.errorMessage {
                    NativeBanner(
                        text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                        color: GatherTheme.error
                    )
                        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                        .padding(.top, 12)
                }
                if let notice = viewModel.notice {
                    NativeBanner(text: l10n.resolve(notice), color: GatherTheme.success)
                        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                        .padding(.top, 12)
                }
                ScrollView {
                    if viewModel.isLoading {
                        ProgressView(l10n("加载中…"))
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(GatherMetrics.Layout.pageGutter)
                    } else if viewModel.workspaceStatus != nil {
                        VStack(alignment: .leading, spacing: GatherMetrics.Space.l) {
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
                                    ? l10n("暂无工作区状态")
                                    : l10n("加载失败"),
                                systemImage: "tray"
                            )
                        } description: {
                            Text(viewModel.errorMessage.map { CommandErrorText.resolve($0, with: l10n) }
                                ?? l10n("无法读取该工作区的状态，请刷新后重试。"))
                        } actions: {
                            Button(l10n("刷新"), systemImage: "arrow.clockwise") {
                                Task { await viewModel.load() }
                            }
                            .help(l10n("重新读取工作区状态"))
                        }
                    }
                }
            }
            .background(GatherTheme.windowBackground)
            // 窗口 chrome：副标题 + 工具栏 principal 位置的分段子导航。
            .sessionPageChrome(
                subtitle: l10n("工作区控制中心"),
                onBack: onBack,
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
            // B8.2a：load() 已 async（SessionAPI.get/status + CullingAPI.syncStatus）。
            // Cut 4 / 4a-2b：兜底轮询已迁入 VM（startPolling/stopPolling），
            // View 只负责首次加载与可见性钩子（task/onAppear 双入口，start 幂等）。
            // R4 P1-2：页面级路由到 control，进入会话不再由 workspace 全量置真。
            workspace.setPageVisible(.control, true)
            await viewModel.load()
        }
        .onAppear {
            workspace.setPageVisible(.control, true)
        }
        .onDisappear {
            workspace.setPageVisible(.control, false)
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobTerminal)) { notification in
            guard let event = notification.object as? GatherJobEvent,
                  event.job.scopeType == "session",
                  event.job.scopeId == viewModel.sessionId else { return }
            Task { await viewModel.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            Task { await viewModel.load() }
        }
        // 写路径广播（XMP/同步队列、重复处置、人脸簇变化）：按会话命中后刷新
        // 控制中心的相应域，不再只靠轮询/任务终态。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherApplicationChange,
                  change.matches(sessionId: viewModel.sessionId),
                  [.metadata, .duplicates, .faceKeywording].contains(change.domain) else { return }
            Task { await viewModel.load() }
        }
    }
}

#if DEBUG
#Preview("SessionControl · 控制中心") {
    PreviewFactory.controlPage()
}
#endif
