// Gather 原生导航壳。
//
// 原生化要点（取代旧版自绘外壳）：
// - 侧栏改用 NavigationSplitView + List(selection:).listStyle(.sidebar)，
//   由系统负责玻璃材质、选中高亮、⌘⌥S 显隐与列宽拖拽；
// - 删除手搓的侧栏、6pt 拖拽手柄、NSCursor.push/pop 与不透明色块背景；
// - 页面改为**按目的地条件构建**（不再用 .opacity(0) 常驻），
//   消除隐藏页的状态泄漏与跨页快捷键污染；
// - 窗口标题 / 副标题交给 .navigationTitle / .navigationSubtitle。
//
// Cut 4 / 4a-2c（本文件收口）：
// - 4 个 pending 容器 + pendingGalleryPhotoId/Path 已迁 WorkspaceIntent；
//   lastSessionId 由 SessionStore 唯一持有；
// - 窗口标题读 SessionWorkspace.sessionName（异步 SessionAPI.get 缓存），
//   删除每次导航同步 listSessions 查库；
// - SessionPageHost / environment key / navigator 已迁 GatherUI/Interaction；
// - 删除 isActive 常量、SessionDraftCache 与所有页面兼容 init。
//
// Cut 4 / 4a-3a：删除 @State languageVersion、languageChanged 自增写点与
// .id(languageVersion)；外壳文案改由 LanguageStore.l10n 驱动（Observation
// 重渲染，不再整树重建）。会话页的 .id("session-tab-…") 是身份 id，保留。
//
// Cut 4 / 4c-2k（RootView 拆分，行为不变；单文件 ≤600，本壳 ≤300）：
// - RootShellNavigation.swift  RootNavigation（原 27-224 行，逐字）；
// - RootShellSidebar.swift     侧栏 + 选中语义 + lastSessionId 回退；
// - RootShellToolbar.swift     工具栏 / 窗口标题缓存 / 尺寸预算 / 外壳文案；
// - RootShellDetail.swift      详情区条件构建 + SessionPageHost 装配；
// - RootShellOverlay.swift     6 个通知入口 + 导入/错误 Toast；
// - RootShellWorkspace.swift   入口动作 / 意图失效 / workspace 生命周期。
// 本文件只保留依赖、@State、init 与 modifier 接线；层级/顺序/动画/焦点不变。
import SwiftUI
import AppKit
import GatherProtocol

package struct RootView: View {
    /// Cut 4 / 4a-2a-2：壳层只认 UI-owned 的依赖包（§4.6 / D-017）：
    /// 不再 import GatherPersistence/Analysis/Domain，也不再持有 Host 的 AppServices。
    let deps: RootShellDependencies
    /// Cut 4 / 4a-2a-2：活动工作区表（7 个 VM 的唯一来源，每会话一套 + LRU）。
    let sessionStore: SessionStore
    /// Cut 4 / 4a-3a：界面语言的唯一写入口 / 唯一读取源（审计 §1.6）。
    /// 外壳文案经 `l10n` 读它建立 Observation 依赖：切换语言只重渲染，不再
    /// 用 `.id(languageVersion)` 重建整棵 detail（那会丢页面选择/草稿）。
    let languageStore: LanguageStore
    /// Phase 4：菜单/快捷键的唯一命令通道（由 SceneState 注入）。
    let commandCenter: AppCommandCenter

    // 4c-2k：@State 留在壳内；拆出的 extension 需要读写，故 private → internal。
    @State var navigation: RootNavigation
    @State var viewModel: DashboardViewModel
    @State var libraryViewModel: LibraryViewModel
    @State var personsViewModel: PersonsViewModel
    @State var columnVisibility: NavigationSplitViewVisibility = .all
    /// 工作台新建/导入请求（非空 = 工作台应立即打开新建表单）。
    /// 由外壳暂存而不是 DashboardView 自己订阅通知：条件构建下页面的 @State
    /// 随目的地切换销毁，跨页触发的请求必须由外壳代收（F02 / ⌘N 竞态）。
    @State var newWorkspaceRequest: NewWorkspaceRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 打开原生设置窗口（macOS 14+ 的公开 API；showSettingsWindow: 是
    /// SwiftUI 私有 selector，不在 AppKit SDK 里，不能依赖）。
    @Environment(\.openSettings) var openSettings

    @MainActor
    package init(
        deps: RootShellDependencies,
        sessionStore: SessionStore,
        languageStore: LanguageStore,
        commandCenter: AppCommandCenter,
        navigation: RootNavigation? = nil
    ) {
        self.deps = deps
        self.sessionStore = sessionStore
        self.languageStore = languageStore
        self.commandCenter = commandCenter
        let navigation = navigation ?? RootNavigation()
        #if DEBUG
        Self.applyDebugPage(to: navigation)
        #endif
        _navigation = State(initialValue: navigation)
        // 入口意图的写入点：页面只调 navigator，navigator 把 intent 转给
        // 对应 workspace；不把 SessionStore 塞进每个页面。
        navigation.enqueueIntent = { [sessionStore] sessionId, intent in
            sessionStore.workspace(for: sessionId).enqueue(intent)
        }
        navigation.clearIntent = { [sessionStore] sessionId, kind in
            _ = sessionStore.workspace(for: sessionId).take(kind)
        }
        // Cut 3 / 3b-3（E-17）：Dashboard 的 C1 桥显式注入（不再回退 shared）。
        let dashboardViewModel = DashboardViewModel(provider: deps.dashboardProvider)
        dashboardViewModel.captureOne = deps.captureOne
        // R4 P1-3：删除会话成功后把 id 交给状态层——endSession 清 active/
        // pinned/lastSessionId 并 close() 对应 workspace，侧栏不再回退到
        // 已删会话（幽灵会话），被删会话的 7 个 VM 也不会继续存活/轮询。
        dashboardViewModel.onSessionDeleted = { [sessionStore] sessionId in
            sessionStore.endSession(sessionId)
        }
        _viewModel = State(initialValue: dashboardViewModel)
        _libraryViewModel = State(initialValue: LibraryViewModel(provider: deps.libraryProvider))
        // Cut 1 / B8.2d：人物域只有 AppPerson（any PersonAPI，8 个 async 方法）
        // 这一条生产路径；legacy provider / personsProvider 参数已删除。
        _personsViewModel = State(initialValue: PersonsViewModel(person: deps.person))
        // 初始目的地本身可能是会话页（预览/测试直接注入 navigation）：
        // 先登记工作区，首帧即可从 environment 拿到 workspace。
        // 生产从工作台起步，工作区由 .task(id: navigation.route) 建立。
        if let sessionId = Self.workspaceSessionId(for: navigation.route) {
            // activate 内部会 setVisible(true)（7 个 VM 扇出）；标题异步缓存。
            sessionStore.activate(sessionId)?.loadSessionNameIfNeeded(using: deps.session)
        }
    }

    package var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: RootShellMetrics.sidebarMinWidth, ideal: RootShellMetrics.sidebarIdealWidth, max: RootShellMetrics.sidebarMaxWidth)
        } detail: {
            detail
                // 4a-3b-2b：会话页/全局页从 environment 取语言源（不再读
                // GatherLocalization.appLanguage 进程全局）。设置页另有显式注入。
                .environment(\.languageStore, languageStore)
                // 4a-3a：语言切换走 Observation（外壳文案读
                // LanguageStore.l10n），不再 .id 重建整棵 detail 子树。
                // 窗口标题：会话页（控制中心/人脸/重复/挑片/导出）用会话名，
                // 页面型目的地（工作台/图库/人脸库/设置）由页面自己的
                // navigationTitle 覆盖（内层优先）。
                .navigationTitle(windowTitle)
                // 品牌 tint 只作用于内容区：侧栏保持系统中性色。
                .tint(GatherTheme.accent)
                // 页面从 environment 取路由能力，不再逐页注入导航闭包。
                .environment(\.navigator, navigation)
        }
        .frame(minWidth: RootShellMetrics.windowMinWidth, minHeight: RootShellMetrics.windowMinHeight)
        // 菜单「显示/隐藏侧栏」跟随真实列可见性（focused-scope，单窗口）。
        .focusedSceneValue(\.sidebarExpanded, columnVisibility != .detailOnly)
        // 命令可执行性随 handler 安装/清理更新（Commands 读 focused-scope，
        // 不依赖 Scene body 的启动时快照）。
        .focusedSceneValue(\.commandAvailability, commandCenter.installed)
        // 4a-3a：删除 languageChanged 的本地自增写入点——语言状态由
        // LanguageStore 唯一持有/广播，外壳只读 languageStore.l10n。
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.importFolderRequest)) { _ in
            // 页面/工具栏的「导入文件夹」入口统一落到外壳：宿主面板 → 导入或
            // 新建工作台表单（不再经 Delegate 通知转发）。
            Task { await handleImportFolderRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.importCompleted)) { notification in
            handleImportCompleted(notification)
            // 菜单/C1/文件拖入都会在这里完成建库；侧栏立即补一条。
            Task { await viewModel.refreshSidebarSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.captureOneError)) { notification in
            handleCaptureOneError(notification)
        }
        .overlay(alignment: .topTrailing) {
            ToastView()
        }
        .onAppear {
            // 初始目的地（含预览/测试直接注入的 navigation）也要登记工作区。
            switchWorkspace(for: navigation.route)
            installCommandHandlers()
            #if DEBUG
            if let raw = DebugLaunchOptions.languageCode {
                _ = languageStore.set(rawLanguage: raw)
            }
            if DebugLaunchOptions.activateWindow {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
                }
            }
            if let appearance = DebugLaunchOptions.appearance {
                let name: NSAppearance.Name
                switch appearance {
                case "dark": name = .darkAqua
                case "high-contrast": name = .accessibilityHighContrastAqua
                case "high-contrast-dark": name = .accessibilityHighContrastDarkAqua
                default: name = .aqua
                }
                NSApp.appearance = NSAppearance(named: name)
            }
            if let width = DebugLaunchOptions.windowWidth,
               let height = DebugLaunchOptions.windowHeight {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }
                    window.setContentSize(NSSize(width: width, height: height))
                    window.center()
                }
            }
            if DebugLaunchOptions.page == "settings" {
                openSettings()
            }
            #endif
        }
        .onChange(of: navigation.route) { previous, destination in
            handleDestinationChange(previous: previous, destination: destination)
        }
        .onDisappear {
            commandCenter.clearHandlers()
        }
        // 目的地驱动的 workspace 生命周期：条件构建下页面每次进入都重建，
        // 但 7 个 VM 由 SessionStore 按下 sessionId 持有，跨导航保留（LRU 淘汰）。
        .task(id: navigation.route) {
            switchWorkspace(for: navigation.route)
        }
        // 侧栏最近工作区：工作台自己会 loadAll；从深链/图库/会话页启动时，
        // 由外壳补一次轻量会话列表，避免侧栏首帧为空。
        .task {
            guard !navigation.isDashboard, viewModel.sessions.isEmpty else { return }
            await viewModel.refreshSidebarSessions()
        }
    }
}

extension RootView {
    /// 菜单命令 -> 当前窗口动作。RootView 是唯一知道这些动作如何落地的地方。
    func installCommandHandlers() {
        let request = $newWorkspaceRequest
        let visibility = $columnVisibility
        commandCenter.install(.newWorkspace) { [navigation] in
            navigation.selectDashboard()
            request.wrappedValue = NewWorkspaceRequest()
        }
        commandCenter.install(.importFolder) { [deps] in
            Task { @MainActor in
                await handleImportFolderRequest(deps: deps)
            }
        }
        commandCenter.install(.captureOneImport) { [deps] in
            Task { @MainActor in await deps.captureOneImport() }
        }
        commandCenter.install(.toggleSidebar) {
            visibility.wrappedValue = visibility.wrappedValue == .detailOnly ? .all : .detailOnly
        }
    }
}

#if DEBUG
private extension RootView {
    static func applyDebugPage(to navigation: RootNavigation) {
        if let sessionId = DebugLaunchOptions.sessionId {
            if let raw = DebugLaunchOptions.page,
               let page = SessionPage(rawValue: raw) {
                navigation.open(page, in: sessionId)
            } else {
                navigation.openSession(sessionId)
            }
            return
        }
        switch DebugLaunchOptions.page {
        case "library":
            navigation.selectLibrary()
        case "persons":
            navigation.selectWeb(.persons)
        default:
            break
        }
    }
}
#endif
