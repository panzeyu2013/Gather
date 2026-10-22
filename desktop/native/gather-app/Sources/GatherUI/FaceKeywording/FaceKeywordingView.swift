// Phase 3.5：人脸分析、簇绑定、成员修订和安全写回流程。
// TS 源：desktop/src/renderer/pages/FaceKeywording/* + face-kw.ipc.ts。
//
// Cut 4 / 4c-2b：2,177 行单文件拆为壳 + 步骤 View + 叶子 View + VM extension
// （纯搬移，行为不变）。本文件只留壳：11 个 @State 的身份、init、body 与
// .task/.onReceive/.onChange 的挂载层级和顺序；步骤骨架在 +Steps，
// Step1/2/3 在 FaceAnalyzeStep / FaceReviewStep / FaceWritebackStep，
// 确认弹窗在 +Confirmations，工具栏/簇卡片/成员行各自成文件。
import Combine
import SwiftUI
import GatherProtocol

public struct FaceKeywordingView: View {
    @State var viewModel: FaceKeywordingViewModel
    /// 所属会话工作区（Cut 4 / 4a-2c）：`.faceRole` / `.faceAnalyze` 意图在
    /// .task 里 take（取出即清）。页面按目的地条件构建，存在即可见。
    private let workspace: SessionWorkspace
    let culling: any CullingAPI
    let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    /// 前往设置回调：可选（RootView 由外部接线）；nil 时页面内按钮禁用。
    let onOpenSettings: (() -> Void)?
    /// 破坏性动作的待确认上下文：非空即弹确认框；命令只在确认分支发出。
    @State var pendingWriteback: PendingFaceWriteback?
    @State var pendingRetry: PendingFaceRetry?
    @State var pendingUnbind: PendingFaceUnbind?
    @State var pendingCleanup: PendingFaceCleanup?
    @State var pendingConfirmSync: PendingFaceConfirmSync?
    @State var pendingMemberRemoval: PendingFaceMemberRemoval?
    @State var pendingMerge: PendingFaceMerge?
    @State var pendingRecluster: PendingFaceRecluster?
    @State var visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
    @State var hoveredClusterId: Int?
    /// 被门控拒绝的步骤切换提示（分段控件不能逐段禁用）。
    /// Cut 4 / 4b-2b：只存 key，渲染期解析（切语言即换文案）。
    @State var stepGateHint: LocalizedText?
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（workspace.face）。
    /// 人脸页的步骤、选中簇、编辑中的角色名/关键字都挂在 VM 上；切换页签
    /// 重建视图但仍复用 workspace 里的同一 VM。
    ///
    /// Cut 4 / 4a-2c：删除 analyzeIntent / pendingRoleFilter / 兼容 init；
    /// 深链角色与分析意图均从 workspace take（`WorkspaceIntent`）。
    package init(
        workspace: SessionWorkspace,
        culling: any CullingAPI,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.workspace = workspace
        _viewModel = State(initialValue: workspace.face)
        self.culling = culling
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
        confirmationChrome(shell)
    }

    /// 页面骨架：原 body 的 VStack 与生命周期修饰符（挂载层级/顺序逐字不变）；
    /// 破坏性命令的 8 个 confirm 在 +Confirmations（应用顺序不变）。
    private var shell: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepPicker
            bannerStack
            stepContent
        }
        .task {
            // 深链角色过滤：在这里（而不是 body 里）写入 VM；取出即清。
            if case let .faceRole(role)? = workspace.take(.faceRole) {
                viewModel.applyRoleFilterFromDeepLink(role)
            }
        }
        .background(GatherTheme.windowBackground)
        // 窗口 chrome：副标题 + 工具栏 principal 位置的分段子导航。
        .sessionPageChrome(
            subtitle: l10n("人脸检测与聚类"),
            selection: .tab(.faceKw),
            onBrowse: { onOpenGallery(viewModel.sessionId) },
            onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
            onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
        )
        .toolbar { toolbarItems }
        .task {
            await viewModel.reload()
            visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
            // A5（审计 4）：分析意图必须在 load() **之后**写 step。
            // load() 里的 seedInitialStep() 见 analysisDone 为真就把 step 改回
            // .review；旧实现在另一个 .task 里先写 step，两个 .task 的启动顺序无保证，
            // 「首次进入该工作区人脸页」（最常见场景）会静默失效。
            // 4a-2c：分析意图同样 take 后消费（取出即清），只在本次进入生效。
            if case .faceAnalyze? = workspace.take(.faceAnalyze) {
                viewModel.step = .analyze
            }
        }
        // R4 P1-2：页面级可见性只由本页 onAppear/onDisappear 驱动（经 workspace
        // 路由到 face VM）；人脸页没有轮询，钩子与其他 6 页同形。
        .onAppear {
            workspace.setPageVisible(.faceKw, true)
        }
        .onDisappear {
            workspace.setPageVisible(.faceKw, false)
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .onChange(of: viewModel.roleFilter) { _, _ in
            visibleClusterCount = FaceKeywordingViewModel.clusterPageSize
        }
        // 步骤真正切换后清掉门控提示（提示只针对被拒绝的那次选择）。
        .onChange(of: viewModel.step) { _, _ in
            stepGateHint = nil
        }
    }
}

#if DEBUG
#Preview("FaceKeywording · 人脸审核") {
    PreviewFactory.facePage()
}
#endif
