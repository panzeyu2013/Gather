// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityView.swift
// Phase 3.3 Similarity（相似度分析）：SwiftUI 页面（宿主内经 GatherProtocol 端口访问）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析控制 +
//       KeywordWritebackPanel 写回面板 + GroupGrid 分组卡片网格 + stats）
//       + components/WritebackReport/WritebackReport.tsx（三色统计卡 + 失败项）
//       + utils/c1-sync-controls.ts（三按钮状态机门控 + 禁用提示）
//
// 原生化（B1/B3/B4/B5）：
// - 页头（返回 + 26pt 大标题 + 手绘页签 + C1 胶囊）→ 会话页骨架：
//   GatherSessionPage（7 段页签 / 返回 / 画布背景 / navigationSubtitle）+
//   工具栏 C1/刷新；
// - 手绘「模式卡」「pill 预设」→ 原生 Picker(.segmented)；
// - 手绘卡片背景/描边 → .gatherCard()（语义底色 + 系统分隔线）；
// - 手绘分组网格（列数公式 + 行高估算 + 内嵌 ScrollView）→ LazyVGrid + 原生
//   DisclosureGroup（自然高度，去掉嵌套滚动与手工高度估算）；
// - 空态/错误态 → ContentUnavailableView；分隔线 → Divider()；
// - 排版：内容语义升到 .callout/.headline，去掉 10pt 承载计数/文件名。
//
// Cut 4 / 4c-2h：1010 行 -> 8 文件（行为不变）。本文件只留外壳：4 个 Pending
// @State、装配 init、页面接线（task(id:) / onChange(sessionId) / onReceive(c1) /
// onChange(writebackKeywords) / 4 个连续确认弹窗）与 #Preview；
// 页面内容在 SimilarityView+Content，分析控制在 +Analysis，写回面板在
// +Writeback，工具栏在 +Toolbar，分组卡在 SimilarityGroupCardView，
// 成员卡在 SimilarityMemberCellView，四个 Pending 在 SimilarityConfirmations。
import SwiftUI
import AppKit
import GatherProtocol

package struct SimilarityView: View {
    @Bindable var viewModel: SimilarityViewModel
    /// 所属会话工作区（R4 P1-2）：页面级可见性经 workspace 路由到 similarity，
    /// 进入会话时不再由 workspace 把 7 个 VM 一起置真。
    private let workspace: SessionWorkspace
    let culling: any CullingAPI

    /// 展开/「显示全部」状态在 **VM** 上（C-1 审计 5）：
    /// 页面按目的地条件构建，离开即销毁；放在 @State 会让「从其它页签回来保留
    /// 展开态」名不副实（VM 的结果留着，展开态却被重置）。
    var expandedIds: Set<Int> { viewModel.expandedGroupIds }
    var showAllIds: Set<Int> { viewModel.showAllMemberGroupIds }

    /// 分组网格顶部锚点：新结果采纳（recluster / 阈值档切换）时滚动复位。
    static let groupsTopAnchor = "sim-groups-top"
    /// 破坏性动作的待确认上下文：非空即弹确认框；命令只在确认分支发出。
    @State var pendingWriteback: PendingSimilarityWriteback?
    @State var pendingRetry: PendingSimilarityRetry?
    @State var pendingCleanup: PendingSimilarityCleanup?
    @State var pendingConfirmSync: PendingSimilarityConfirmSync?

    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（workspace.similarity），
    /// 外壳不再维护 similarity 单槽；轮询仍由 VM 的 setVisible 启停。
    ///
    /// Cut 4 / 4a-2c：删除 isActive 参数与兼容 init——页面按目的地条件构建，
    /// 存在即可见。
    /// 会话页迁移：导航闭包（onBack/onOpenGallery/onOpenTab/onOpenSettings/
    /// onOpenPhoto）全部删除——返回与 7 段页签由 `GatherSessionPage` 承担，
    /// 设置走 `\.openSettings`，成员照片走 `navigator?.openGallery(_:photoPath:)`。
    package init(workspace: SessionWorkspace, culling: any CullingAPI) {
        self._viewModel = Bindable(workspace.similarity)
        self.workspace = workspace
        self.culling = culling
    }

    // Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView）。
    @Environment(\.languageStore) private var languageStore
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 会话页骨架统一提供返回与 7 段页签；页面自己只从环境取路由能力。
    @Environment(\.navigator) var navigator: RootNavigation?
    /// 设置入口（C1 胶囊）：直接打开系统设置窗，不再收导航闭包。
    @Environment(\.openSettings) var openSettings

    /// 打开成员照片（第三轮审计 E）：(filepath) → 该照片的图库查看器（按路径匹配）。
    ///
    /// environment 里没有 navigator（预览/布局测试脱离 RootView）时返回 nil，
    /// 成员卡不渲染该入口——与旧的可选闭包语义一致，不新增「点了没反应」的按钮。
    var openPhotoAction: ((String) -> Void)? {
        guard navigator != nil else { return nil }
        return { path in
            navigator?.openGallery(viewModel.sessionId, photoPath: path)
        }
    }

    package var body: some View {
        // F09：窗口标题是工作区身份，不能被功能名顶掉。
        // 功能名由 GatherSessionPage 的副标题 + 页签行共同承载；骨架同时负责
        // 返回 / 画布背景 / 页面级可见性（workspace.setPageVisible(.similarity,…)）。
        GatherSessionPage(page: .similarity, workspace: workspace, subtitle: l10n("相似度分析")) {
            page
        }
        .toolbar { toolbarItems }
        // 外壳以条件构建承载本页，视图身份不随 VM 替换改变：
        // .task 以 sessionId 为 id，换会话（VM 替换）时重新加载。
        .task(id: viewModel.sessionId) {
            // Cut 4 / 4a-2b：轮询生命周期收进 VM。
            // 页面级可见性由 GatherSessionPage 的 onAppear/onDisappear 接管
            //（先置可见再跑到这里，轮询的恢复与隐藏期门控语义不变）；
            // 本任务只负责取数。
            await viewModel.load()
        }
        // 兜底：sessionId 变化（外壳 onChange 替换 VM）同样触发加载。
        .onChange(of: viewModel.sessionId) { _, _ in
            Task { await viewModel.load() }
        }
        // 写回协调器 emitSummary 后刷新同步状态视图（TS useEvent('culling:sync-status')）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            viewModel.refreshSyncState()
        }
        // 关键词变化 → 清空旧预览/旧写回结果（TS effect [keywordInput, ...]）。
        .onChange(of: viewModel.writebackKeywords) { _, _ in
            viewModel.markWritebackDraftChanged()
        }
        // 破坏性命令统一门控：确认后才带 confirmed: true，取消只写可见文案。
        .gatherDestructiveConfirm(
            pending: $pendingWriteback,
            title: l10n("确认写入 XMP？"),
            confirmLabel: { _ in l10n("写入 XMP") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.executeKeywordWriteback(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("写入 XMP")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingRetry,
            title: l10n("确认重试失败项？"),
            confirmLabel: { _ in l10n("重试写入") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.retryKeywordWriteback(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("重试失败写入项")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingCleanup,
            title: l10n("确认清理 XMP 临时变更？"),
            confirmLabel: { _ in l10n("清理") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.cleanupKeywordWriteback(confirmed: true) } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("清理 XMP 临时变更")) }
        )
        .gatherDestructiveConfirm(
            pending: $pendingConfirmSync,
            title: l10n("确认同步 Capture One？"),
            confirmLabel: { _ in l10n("确认同步") },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { _ in Task { await viewModel.confirmSync() } },
            onCancel: { _ in viewModel.reportCancellation(LocalizedText("确认同步 Capture One")) }
        )
    }
}

#if DEBUG
#Preview("Similarity · 相似度分组") {
    PreviewFactory.similarityPage()
}
#endif
