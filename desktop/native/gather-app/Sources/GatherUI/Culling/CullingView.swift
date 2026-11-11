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
import AppKit
import GatherProtocol

public struct CullingView: View {
    @State var viewModel: CullingViewModel
    private let culling: any CullingAPI
    /// 所属会话工作区（Cut 4 / 4a-2c）：「逐条裁决」意图在 .task 里 take。
    let workspace: SessionWorkspace
    /// 破坏性命令的唯一确认载体：命令层的 confirmed:true 只能从确认弹窗分支到达。
    @State var pendingAction: PendingCullingAction?
    @State var conflictChoices: [String: MetadataConflictChoice] = [:]
    @State var faceAlign = false
    /// 专注模式（P1 无干扰单图）：隐藏检查器 + 折叠胶片条 + 窗口全屏。
    /// F 裸键（查看器 onKeyPress）与「显示」菜单共用 toggleFocusMode 一个入口。
    @State var isFocusMode = false
    /// 胶片条展开态：从工作台内部上提到页面，专注模式才能程序化折叠并恢复。
    @State var filmstripExpanded = true
    /// 进入专注模式前的面板状态（退出时原样恢复，不假设用户之前是展开的）。
    @State private var inspectorBeforeFocus = true
    @State private var filmstripBeforeFocus = true
    /// 进入前的窗口全屏状态：原本就全屏时，退出专注模式不该把系统全屏一起退掉。
    @State private var wasFullScreenBeforeFocus = false
    /// internal：B3 的会话状态恢复在 CullingView+Content 里写回（页面 chrome 恢复同一来源）。
    @SceneStorage("culling.layout") var layoutRaw = CullingLayoutMode.single.rawValue
    /// 空串 = 本窗口未设置，回落到设置 grid_density（VM 默认值）。
    @SceneStorage("culling.gridDensity") var densityRaw = ""
    /// 排序跨页签/窗口保持；空串 = 用设置 grid_default_sort。
    @SceneStorage("culling.sort") var sortRaw = ""

    /// 当前布局（网格是第 4 种布局，不新增页签）。
    var layoutMode: CullingLayoutMode {
        CullingLayoutMode(rawValue: layoutRaw) ?? .single
    }

    /// B1 / 20-culling-viewer §2 P1：「作用于全部选中 N 张」开关（默认关）。
    ///
    /// 对比/Survey 里多选是**构造画面**的手段：默认只把决策写到当前照片；只有
    /// 用户显式打开这个开关才批量写选择集（信息条同时回显本次写入目标）。
    /// 状态挂在页面上而不是信息条里：切布局会销毁/重建信息条（网格没有信息条），
    /// 但「切布局不丢」是硬要求；也不进 SceneStorage——粘住的批量写比丢状态危险。
    @State var writesDecisionToSelection = false

    var layoutBinding: Binding<CullingLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { mode in
                layoutRaw = mode.rawValue
                // B2：页大小由布局单一决定（CullingLayoutMode.pageLimit）；setPageLimit
                // 内部按当前照片续页，不会因为页变小把用户踢回第一张。
                Task { await viewModel.setPageLimit(mode.pageLimit) }
            }
        )
    }

    var densityBinding: Binding<CullingGridDensity> {
        Binding(
            get: { CullingGridDensity(rawValue: densityRaw) ?? viewModel.defaultGridDensity },
            set: { densityRaw = $0.rawValue }
        )
    }
    /// 右侧检查器（系统 .inspector）的展开状态：Bridge/Capture One 式，
    /// 选项面板默认可见，工具栏开关由系统提供。可见性用 @SceneStorage 按页
    /// 记忆（跨导航重建 / 新窗口保持；参考 darktable 各视图独立存储面板可见性）。
    @SceneStorage("culling.inspectorVisible") var showInspector = true

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
    /// Wave3 / task-20：第二屏镜像桥（App 级注入；nil = 未启用，行为与旧版一致）。
    @Environment(\.cullingSecondDisplay) private var secondDisplay
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
                    secondaryLabel: { action in
                        guard case .crossPageBatch(let plan) = action,
                              plan.visibleCount < plan.totalCount else { return nil }
                        return l10n("仅当前可见")
                    },
                    onSecondary: { action in
                        guard case .crossPageBatch(let plan) = action else { return }
                        Task { await viewModel.performCrossPageBatch(plan, onlyVisible: true) }
                    },
                    message: { confirmationMessage($0) },
                    onConfirm: { perform($0) },
                    onCancel: { viewModel.noteCancelledAction($0.actionText) }
                )
        }
        .onChange(of: viewModel.sortMode) { _, newValue in
            sortRaw = newValue.rawValue
        }
        // Wave3 / task-20：把「当前会话 + 当前布局」发布给第二屏（只读镜像）。
        // 不在这里控制第二屏内容之外的东西：VM 可见性仍只由本页 onAppear/onDisappear
        // 经 SessionPage 生命周期驱动，避免两边 setVisible 导致轮询抖动。
        .onAppear {
            guard !viewModel.sessionId.isEmpty else { return }
            secondDisplay?.attach(sessionId: viewModel.sessionId, layoutRaw: layoutRaw)
        }
        .onChange(of: layoutRaw) { _, newValue in
            secondDisplay?.updateLayoutRaw(newValue)
            // 网格布局没有查看器：主窗口切网格后第二屏退回单图，
            // 缩放也归位，避免镜像到上一个查看器遗留的高倍率。
            if newValue == CullingLayoutMode.grid.rawValue {
                secondDisplay?.publishViewerTransform(zoom: 1, offset: .zero)
            }
        }
        .onChange(of: viewModel.pendingCrossPageBatch?.id) { _, _ in
            guard let plan = viewModel.pendingCrossPageBatch else { return }
            pendingAction = .crossPageBatch(plan)
            viewModel.pendingCrossPageBatch = nil
        }
        .toolbar {
            GatherSessionToolbar(
                sessionId: viewModel.sessionId,
                culling: culling,
                onOpenSettings: { openSettings() },
                refreshTitle: l10n("刷新"),
                refreshHelp: l10n("重新载入挑片工作台"),
                refreshDisabled: viewModel.isLoading,
                onRefresh: {
                    Task {
                        // 与图库同一口径：主动刷新 = 允许重取被外部修改过的缩略图。
                        PhotoThumbnailCache.invalidateAll()
                        await viewModel.load()
                    }
                }
            )
        }
        // Bridge / Capture One 式：图片保持居中，选项面板交给系统 .inspector
        // （工具栏开关由系统自动提供，不自绘按钮）。
        .inspector(isPresented: $showInspector) {
            CullingInspector(
                viewModel: viewModel,
                isBusy: isBusy,
                faceAlign: $faceAlign,
                gridDensity: densityBinding,
                layoutMode: layoutBinding,
                pendingAction: $pendingAction
            )
                // 约束循环修复（N01）：SwiftUI 把**理想列宽**计入承载视图的最小宽度
                //（实测 min 260 / ideal 300 时贡献 300pt）。收窄到 ideal 260，
                // 让最小窗口下「页签行 + 内容 + 检查器」仍能装进内容区。
                .inspectorColumnWidth(min: GatherChromeMetrics.inspectorMinWidth, ideal: GatherChromeMetrics.inspectorIdealWidth, max: GatherChromeMetrics.inspectorMaxWidth)
        }
        // Phase 4 收口：挑片历史进 focused-scope。页面可见时 Edit 菜单的
        // 撤销/重做改由这份动作承载（页面无文本输入框，不抢系统文本撤销）。
        .focusedSceneValue(\.cullingHistory, CullingHistoryActions(
            // 焦点可能在关键词 TextField：canUndo 不能只看挑片栈，否则文本撤销被禁用。
            canUndo: !isBusy,
            canRedo: !isBusy,
            undo: { routeHistory(redo: false) },
            redo: { routeHistory(redo: true) }
        ))
        // P1 无干扰单图：「显示」菜单的专注模式入口；F 裸键在查看器里同入口。
        .focusedSceneValue(\.cullingFocusMode, CullingFocusModeActions(
            isActive: isFocusMode,
            canToggle: layoutMode != .grid,
            toggle: { toggleFocusMode() }
        ))
        // 切到网格布局：专注模式没有单图语义，退出并恢复面板（不改网格既有行为）。
        .onChange(of: layoutMode) { _, mode in
            if mode == .grid, isFocusMode { exitFocusMode() }
        }
        // 用户用 ESC/绿灯自己退出系统全屏：专注模式面板必须同步恢复，
        // 否则会卡在「检查器/胶片条都消失，但又不是专注模式」的中间态。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            restorePanelsAfterFocus()
        }
        // 离开挑片页：专注模式必须收口（否则整窗全屏 + 面板隐藏会带到别的页面）。
        .onDisappear {
            if isFocusMode { exitFocusMode() }
        }
    }

    // MARK: - 专注模式（P1：全屏 / 无干扰单图）

    /// 专注模式切换：F 裸键（查看器）/「显示」菜单 / 查看器放大镜行的小按钮同一入口。
    func toggleFocusMode() {
        // 网格布局的"专注"没有意义；保持既有网格行为完全不变。
        guard layoutMode != .grid else { return }
        if isFocusMode {
            exitFocusMode()
        } else {
            enterFocusMode()
        }
    }

    /// 进入专注模式：记下面板状态 → 隐藏检查器 + 折叠胶片条 + 请求窗口全屏。
    private func enterFocusMode() {
        inspectorBeforeFocus = showInspector
        filmstripBeforeFocus = filmstripExpanded
        let window = NSApp.keyWindow
        wasFullScreenBeforeFocus = window?.styleMask.contains(.fullScreen) ?? false
        isFocusMode = true
        showInspector = false
        filmstripExpanded = false
        if !wasFullScreenBeforeFocus {
            window?.toggleFullScreen(nil)
        }
    }

    /// 退出专注模式：恢复面板；只有「本次进入时请求的全屏」才退回窗口模式。
    private func exitFocusMode() {
        guard isFocusMode else { return }
        restorePanelsAfterFocus()
        if !wasFullScreenBeforeFocus,
           let window = NSApp.keyWindow,
           window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    /// 只恢复面板（系统全屏被 ESC 退出时也走这里；不碰全屏状态，避免二次切换）。
    private func restorePanelsAfterFocus() {
        guard isFocusMode else { return }
        isFocusMode = false
        showInspector = inspectorBeforeFocus
        filmstripExpanded = filmstripBeforeFocus
    }

    /// 文本框聚焦时把 ⌘Z/⇧⌘Z 交还 field editor，避免误撤销挑片决策。
    private func routeHistory(redo: Bool) {
        let selector = redo ? Selector(("redo:")) : Selector(("undo:"))
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(selector, to: nil, from: nil)
            return
        }
        Task { redo ? await viewModel.redo() : await viewModel.undo() }
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
