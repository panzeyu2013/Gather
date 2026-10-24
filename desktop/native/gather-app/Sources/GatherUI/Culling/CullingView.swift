// Phase 3.4：挑片、状态写回和同步控制 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Culling.tsx + culling.ipc.ts。
//
// Cut 4 / 4c-2a：3,732 行单文件拆为壳 + 叶子 View + VM extension（纯搬移，行为不变）。
// - 本文件只留壳：@State/@SceneStorage 身份、init、body、窗口 chrome（工具栏 /
//   .inspector）、破坏性确认弹窗接线；数据驱动主体在 CullingView+Content。
// - 生命周期/通知（.task / .onReceive）仍挂在同一个 VStack 上、顺序不变，只是写在
//   shellContent 计算属性里；页面级 setPageVisible 收归 GatherSessionPage。
// - 段落 View：Workbench（层级组合）/ Toolbar / Inspector / InfoBar / Filmstrip /
//   ConflictPanel / WorkbenchViewer；破坏性动作在 CullingView+DestructiveActions。
//
// appearance 会话页骨架迁移：frame / canvas 底色 / navigationSubtitle / 返回按钮 /
// 7 段页签 / 页面级可见性统一交给 `GatherSessionPage`（返回与页签切换它自己走
// `\.navigator`）；页面内只剩「打开设置」一个外部能力，改从 `\.openSettings` 取。
// 不再接收 onBack / onOpenTab / onOpenGallery / onOpenSimilarity / onOpenSettings 闭包；
// 挑片业务（VM / 叶子 View / 布局）不变。
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
    /// appearance：init 收敛为 (workspace, culling)——返回/7 段页签/图库/相似度都由
    /// `GatherSessionPage` 走 `\.navigator` 承担，「打开设置」由 `\.openSettings` 提供，
    /// 页面不再持有任何导航闭包。
    package init(workspace: SessionWorkspace, culling: any CullingAPI) {
        self.workspace = workspace
        _viewModel = State(initialValue: workspace.culling)
        self.culling = culling
    }

    /// Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView / SessionPageHost）。
    @Environment(\.languageStore) private var languageStore
    /// C1 状态胶囊的「打开设置」入口：原生 Settings 场景由 environment 提供
    ///（不再由外壳逐页注入 onOpenSettings 闭包）。
    @Environment(\.openSettings) private var openSettings
    var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public var body: some View {
        GatherSessionPage(page: .culling, workspace: workspace, subtitle: l10n("挑片与写回")) {
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
        }
        .toolbar {
            GatherSessionToolbar(
                sessionId: viewModel.sessionId,
                culling: culling,
                onOpenSettings: { openSettings() },
                refreshTitle: l10n("刷新"),
                refreshHelp: l10n("重新载入挑片工作台"),
                refreshDisabled: viewModel.isLoading,
                onRefresh: { Task { await viewModel.load() } }
            )
        }
        // Bridge / Capture One 式：图片保持居中，选项面板交给系统 .inspector
        // （工具栏开关由系统自动提供，不自绘按钮）。
        .inspector(isPresented: $showInspector) {
            CullingInspector(viewModel: viewModel, isBusy: isBusy, faceAlign: $faceAlign)
                // 约束循环修复（N01）：SwiftUI 把**理想列宽**计入承载视图的最小宽度
                //（实测 min 260 / ideal 300 时贡献 300pt）。收窄到 ideal 260，
                // 让最小窗口下「页签行 + 内容 + 检查器」仍能装进内容区。
                .inspectorColumnWidth(min: GatherChromeMetrics.inspectorMinWidth, ideal: GatherChromeMetrics.inspectorIdealWidth, max: GatherChromeMetrics.inspectorMaxWidth)
        }
        // Phase 4 收口：挑片历史进 focused-scope。页面可见时 Edit 菜单的
        // 撤销/重做改由这份动作承载（页面无文本输入框，不抢系统文本撤销）。
        .focusedSceneValue(\.cullingHistory, CullingHistoryActions(
            canUndo: viewModel.undoOperation != nil && !isBusy,
            canRedo: viewModel.redoOperation != nil && !isBusy,
            undo: { Task { await viewModel.undo() } },
            redo: { Task { await viewModel.redo() } }
        ))
    }

    /// 页面级忙碌（原 CullingView.isBusy，逐字保留）：壳持有，向下传给工具栏 /
    /// 检查器 / infoBar；拆分只挪定义位置，判定式不变。
    var isBusy: Bool {
        viewModel.isLoading || viewModel.isNavigationBusy || viewModel.isQualityBusy
    }
}

#if DEBUG
#Preview("Culling · 挑片工作台") {
    PreviewFactory.cullingPage()
}
#endif
