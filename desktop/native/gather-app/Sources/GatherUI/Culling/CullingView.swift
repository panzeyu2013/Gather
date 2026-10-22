// Phase 3.4：挑片、状态写回和同步控制 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Culling.tsx + culling.ipc.ts。
//
// Cut 4 / 4c-2a：3,732 行单文件拆为壳 + 叶子 View + VM extension（纯搬移，行为不变）。
// - 本文件只留壳：@State/@SceneStorage 身份、init、body、窗口 chrome（工具栏 /
//   .inspector）、破坏性确认弹窗接线；数据驱动主体在 CullingView+Content。
// - 生命周期/通知（.task / .onAppear / .onDisappear / .onReceive）仍挂在同一个
//   VStack 上、顺序不变，只是写在 shellContent 计算属性里。
// - 段落 View：Workbench（层级组合）/ Toolbar / Inspector / InfoBar / Filmstrip /
//   ConflictPanel / WorkbenchViewer；破坏性动作在 CullingView+DestructiveActions。
//
// Cut 1 / B3b：CullingViewModel 的挑片与导航依赖已迁移到类型化 API（19 条
// culling.* -> CullingAPI；4 条 navigation.* -> NavigationAPI）。
// Cut 1 / B6b：冲突列表/裁决走 MetadataAPI（Confirmed<MetadataResolveConflictInput>）。
// Cut 1 / B8.2b：质量分析走 QualityAPI + JobAPI 轮询；取消走 JobAPI.cancel。
// Cut 1 / B8.4：旧命令适配器已删除；C1 状态胶囊经 View 持有的 CullingAPI 注入。
import SwiftUI
import GatherProtocol

public struct CullingView: View {
    @State var viewModel: CullingViewModel
    private let culling: any CullingAPI
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void
    /// 所属会话工作区（Cut 4 / 4a-2c）：「逐条裁决」意图在 .task 里 take。
    let workspace: SessionWorkspace
    /// 破坏性命令的唯一确认载体：命令层的 confirmed:true 只能从确认弹窗分支到达。
    @State var pendingAction: PendingCullingAction?
    @State var conflictChoices: [String: MetadataConflictChoice] = [:]
    @State var compareCount = 1
    @State var faceAlign = false
    /// 右侧检查器（系统 .inspector）的展开状态：Bridge/Capture One 式，
    /// 选项面板默认可见，工具栏开关由系统提供。可见性用 @SceneStorage 按页
    /// 记忆（跨导航重建 / 新窗口保持；参考 darktable 各视图独立存储面板可见性）。
    @SceneStorage("culling.inspectorVisible") private var showInspector = true

    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（`SessionStore.workspace(for:)`
    /// 的 `SessionWorkspace.culling`）。外壳不再缓存/替换 VM，页面也不接收
    /// 「外层单独持有的 VM」；范围/筛选/当前照片/多选/逐字段裁决草稿随 workspace 保留。
    /// Cut 4 / 4a-2c：删除 conflictsIntent / 兼容 init；入口意图由页面在 .task
    /// 里从 workspace.take(.cullingConflicts) 消费（取出即清）。
    package init(
        workspace: SessionWorkspace,
        culling: any CullingAPI,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.workspace = workspace
        _viewModel = State(initialValue: workspace.culling)
        self.culling = culling
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    /// Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView / SessionTabHost）。
    @Environment(\.languageStore) private var languageStore
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public var body: some View {
        shellContent
        // 破坏性命令（重置/清理/写回/重试失败项/结束同步/冲突裁决）一律先经真实
        // 确认弹窗，再由确认分支传 confirmed: true；不存在「无弹窗硬编码 true」。
        .gatherDestructiveConfirm(
            pending: $pendingAction,
            title: l10n("确认执行此操作？"),
            confirmLabel: { $0.actionLabel(with: l10n) },
            confirmRole: { action in
                if case .resolveConflict(_, let choices) = action,
                   !choices.isEmpty, choices.values.allSatisfy({ $0 == .useRemote }) {
                    return nil
                }
                return .destructive
            },
            message: { confirmationMessage($0) },
            onConfirm: { perform($0) },
            onCancel: { viewModel.noteCancelledAction($0.actionText) }
        )
        // 会话页窗口 chrome：标题副标题走系统，子导航分段控件在工具栏 principal 位置。
        .sessionPageChrome(
            subtitle: l10n("挑片与写回"),
            selection: .tab(.culling),
            onBrowse: { onOpenGallery(viewModel.sessionId) },
            onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
            onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBack()
                } label: {
                    Label(l10n("返回"), systemImage: "chevron.backward")
                }
                .help(l10n("返回到上一页"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, culling: culling, onOpenSettings: onOpenSettings)
                Button(l10n("刷新"), systemImage: "arrow.clockwise") {
                    Task { await viewModel.load() }
                }
                .disabled(viewModel.isLoading)
                .help(l10n("重新载入挑片工作台"))
            }
        }
        // Bridge / Capture One 式：图片保持居中，选项面板交给系统 .inspector
        // （工具栏开关由系统自动提供，不自绘按钮）。
        .inspector(isPresented: $showInspector) {
            CullingInspector(viewModel: viewModel, isBusy: isBusy)
                // 约束循环修复（N01）：SwiftUI 把**理想列宽**计入承载视图的最小宽度
                //（实测 min 260 / ideal 300 时贡献 300pt）。收窄到 ideal 260，
                // 让最小窗口下「页签行 + 内容 + 检查器」仍能装进内容区。
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
    }

    /// 页面级忙碌（原 CullingView.isBusy，逐字保留）：壳持有，向下传给工具栏 /
    /// 检查器 / infoBar；拆分只挪定义位置，判定式不变。
    var isBusy: Bool {
        viewModel.isLoading || viewModel.isNavigationBusy || viewModel.isQualityBusy
    }
}

extension Notification.Name {
    static let gatherMenuUndo = Notification.Name("gather.menu.undo")
    static let gatherMenuRedo = Notification.Name("gather.menu.redo")
}

#if DEBUG
#Preview("Culling · 挑片工作台") {
    PreviewFactory.cullingPage()
}
#endif
