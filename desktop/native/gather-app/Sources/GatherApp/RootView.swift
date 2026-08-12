// Gather 原生导航壳：所有主页面和工作区页签均由 SwiftUI 承载。
// 领域操作统一经过 SessionCommandRouter，保持既有命令契约的参数校验
// 和服务边界；页面不创建浏览器或 JavaScript 路由状态。
import SwiftUI
import AppKit
import GatherCore

@MainActor
@Observable
final class RootNavigation {
    enum WebPage: String, CaseIterable, Identifiable {
        case persons
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .persons: return GatherLocalization.l("人脸库", "Persons")
            case .settings: return GatherLocalization.l("设置", "Settings")
            }
        }
    }

    enum Destination: Equatable {
        case dashboard
        case persons
        case page(WebPage)
        case library
        case gallery(String)
        case similarity(String)
        case sessionTab(String, SessionTab)
    }

    private(set) var destination: Destination = .dashboard

    var selectedWebPage: WebPage? {
        if case .page(let page) = destination { return page }
        if case .persons = destination { return .persons }
        return nil
    }

    var isDashboard: Bool { if case .dashboard = destination { return true }; return false }
    var isLibrary: Bool { if case .library = destination { return true }; return false }
    var isPersons: Bool { if case .persons = destination { return true }; return false }
    var isSettings: Bool {
        if case .page(.settings) = destination { return true }
        return false
    }

    var gallerySessionId: String? {
        if case .gallery(let id) = destination { return id }
        return nil
    }

    var similaritySessionId: String? {
        if case .similarity(let id) = destination { return id }
        return nil
    }

    var sessionTabDestination: (sessionId: String, tab: SessionTab)? {
        if case .sessionTab(let id, let tab) = destination { return (id, tab) }
        return nil
    }

    /// 当前打开的会话 id（对齐旧版 sessionStore.currentSessionId 驱动的
    /// 侧栏"当前会话"项）：gallery / similarity / 任一工作区页签均算。
    var currentSessionId: String? {
        if let id = gallerySessionId { return id }
        if let id = similaritySessionId { return id }
        if let tab = sessionTabDestination { return tab.sessionId }
        return nil
    }

    func selectDashboard() { destination = .dashboard }
    func selectLibrary() { destination = .library }

    func selectWeb(_ page: WebPage) {
        destination = page == .persons ? .persons : .page(page)
    }

    /// 工作区入口与 TS /sessions/:id 一致：先进入控制中心。
    func openSession(_ sessionId: String) { destination = .sessionTab(sessionId, .control) }
    func openGallery(_ sessionId: String) { destination = .gallery(sessionId) }
    func openSimilarity(_ sessionId: String) { destination = .similarity(sessionId) }
    func openSessionTab(_ sessionId: String, _ tab: SessionTab) {
        destination = .sessionTab(sessionId, tab)
    }
}

struct RootView: View {
    let router: SessionCommandRouter
    let provider: DashboardDataProvider
    let libraryProvider: LibraryDataProvider
    let galleryProvider: GalleryDataProvider
    let similarityProvider: SimilarityDataProvider
    let personsProvider: PersonsDataProvider?

    @State private var navigation: RootNavigation
    @State private var viewModel: DashboardViewModel
    @State private var libraryViewModel: LibraryViewModel
    @State private var galleryViewModel: GalleryViewModel?
    @State private var similarityViewModel: SimilarityViewModel?
    @State private var personsViewModel: PersonsViewModel?
    @State private var sidebarVisible = true
    /// 人脸审核深链的角色预筛选（Persons 详情「复核人脸」注入；切换目的地后清空）。
    @State private var faceKwInitialRole: String?
    /// 界面语言版本号：languageChanged 通知递增，驱动外壳层双语文案重渲染。
    @State private var languageVersion = 0

    @MainActor
    init(
        router: SessionCommandRouter,
        provider: DashboardDataProvider,
        libraryProvider: LibraryDataProvider,
        galleryProvider: GalleryDataProvider,
        similarityProvider: SimilarityDataProvider,
        navigation: RootNavigation? = nil,
        personsProvider: PersonsDataProvider? = nil
    ) {
        self.router = router
        self.provider = provider
        self.libraryProvider = libraryProvider
        self.galleryProvider = galleryProvider
        self.similarityProvider = similarityProvider
        self.personsProvider = personsProvider
        let navigation = navigation ?? RootNavigation()
        _navigation = State(initialValue: navigation)
        // 可见性钩子初值：启动即非 dashboard 时（opacity 常驻下 DashboardView
        // 的 .task 仍会执行），用 isVisible 挡掉隐藏期间的 startAutoRefresh。
        let dashboardViewModel = DashboardViewModel(provider: provider)
        dashboardViewModel.isVisible = navigation.isDashboard
        _viewModel = State(initialValue: dashboardViewModel)
        _libraryViewModel = State(initialValue: LibraryViewModel(provider: libraryProvider))
        if case .gallery(let id) = navigation.destination {
            _galleryViewModel = State(initialValue: GalleryViewModel(sessionId: id, provider: galleryProvider))
        }
        if case .similarity(let id) = navigation.destination {
            _similarityViewModel = State(initialValue: SimilarityViewModel(
                sessionId: id,
                provider: similarityProvider,
                captureOne: CaptureOneBridge(router: router)
            ))
        }
        if let personsProvider {
            _personsViewModel = State(initialValue: PersonsViewModel(provider: personsProvider))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(navigation: navigation)
            }
            ZStack {
                DashboardView(viewModel: viewModel) { sessionId in
                    navigation.openSession(sessionId)
                }
                .opacity(navigation.isDashboard ? 1 : 0)
                .allowsHitTesting(navigation.isDashboard)
                .accessibilityHidden(!navigation.isDashboard)

                LibraryView(viewModel: libraryViewModel) { sessionId in
                    navigation.openSession(sessionId)
                }
                .opacity(navigation.isLibrary ? 1 : 0)
                .allowsHitTesting(navigation.isLibrary)
                .accessibilityHidden(!navigation.isLibrary)

                if let personsViewModel {
                    PersonsView(
                        viewModel: personsViewModel,
                        onReview: { sessionId in navigation.openSessionTab(sessionId, .faceKw) },
                        onReviewFaceRole: { role, sessionId in
                            faceKwInitialRole = role
                            navigation.openSessionTab(sessionId, .faceKw)
                        }
                    )
                        .opacity(navigation.isPersons ? 1 : 0)
                        .allowsHitTesting(navigation.isPersons)
                        .accessibilityHidden(!navigation.isPersons)
                }

                if navigation.isSettings {
                    SettingsView(router: router)
                }

                if let galleryViewModel {
                    GalleryView(
                        viewModel: galleryViewModel,
                        router: router,
                        onBack: { navigation.selectDashboard() },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { navigation.openSessionTab($0, $1) },
                        onOpenSettings: { navigation.selectWeb(.settings) },
                        isActive: navigation.gallerySessionId != nil
                    )
                    .opacity(navigation.gallerySessionId != nil ? 1 : 0)
                    .allowsHitTesting(navigation.gallerySessionId != nil)
                    .accessibilityHidden(navigation.gallerySessionId == nil)
                }

                if let similarityViewModel {
                    SimilarityView(
                        viewModel: similarityViewModel,
                        router: router,
                        onBack: {
                            if let sessionId = navigation.similaritySessionId {
                                navigation.openGallery(sessionId)
                            } else {
                                navigation.selectDashboard()
                            }
                        },
                        onOpenGallery: { navigation.openGallery($0) },
                        onOpenTab: { navigation.openSessionTab($0, $1) },
                        onOpenSettings: { navigation.selectWeb(.settings) },
                        isActive: navigation.similaritySessionId != nil
                    )
                    .opacity(navigation.similaritySessionId != nil ? 1 : 0)
                    .allowsHitTesting(navigation.similaritySessionId != nil)
                    .accessibilityHidden(navigation.similaritySessionId == nil)
                }

                sessionTabView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .tint(GatherTheme.primary)
        .background(Color.gatherBackground)
        .id(languageVersion)
        // 设置页切换语言后：刷新外壳层双语文案（侧栏/页签/胶囊/toast）。
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.languageChanged)) { notification in
            if let language = notification.object as? String {
                GatherLocalization.setAppLanguage(language)
            }
            languageVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuToggleSidebar)) { _ in
            sidebarVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuNewWorkspace)) { _ in
            navigation.selectDashboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuImportFolder)) { _ in
            // 对齐 Cmd+N 的"先切页再开 sheet"：切到工作台后
            // DashboardView 自己的订阅才会打开导入 sheet。
            navigation.selectDashboard()
        }
        // 菜单/深链/C1 导入完成：跳转到新工作区并提示失败文件数。
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.importCompleted)) { notification in
            guard let userInfo = notification.userInfo,
                  let sessionId = userInfo[GatherAppImportUserInfoKey.sessionId] as? String,
                  !sessionId.isEmpty else { return }
            let failedCount = (userInfo[GatherAppImportUserInfoKey.failedCount] as? Int) ?? 0
            if failedCount > 0 {
                // 对齐旧版 importFailureMessage（session-paths.ts:26-45）：
                // 「N 张照片已导入；来源读取失败：示例文件、… 等 N 个」。
                let addedCount = (userInfo[GatherAppImportUserInfoKey.addedCount] as? Int) ?? 0
                let sourceLabel = (userInfo[GatherAppImportUserInfoKey.sourceLabel] as? String)
                    ?? GatherLocalization.l("文件", "files")
                let examples = (userInfo[GatherAppImportUserInfoKey.examples] as? String) ?? ""
                let remaining = failedCount > 3
                    ? GatherLocalization.l(" 等 \(failedCount) 个", " and \(failedCount) more")
                    : ""
                GatherToastCenter.shared.show(
                    type: .warning,
                    message: "\(addedCount) 张照片已导入；\(sourceLabel)读取失败：\(examples)\(remaining)"
                )
            }
            // 深链/导入完成语义对齐旧版 App.tsx:34-64：落点浏览页（图库），
            // 而非控制中心页。
            navigation.openGallery(sessionId)
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.captureOneError)) { notification in
            guard let code = notification.object as? String else { return }
            GatherToastCenter.shared.show(type: .error, message: GatherLocalization.errorText(code))
        }
        .overlay(alignment: .topTrailing) {
            ToastView()
        }
        .onChange(of: navigation.destination) { previous, destination in
            // 人脸审核深链角色预筛选为一次性播种：离开人脸页即清空，
            // 避免后续普通进入带出旧角色。
            if case .sessionTab(_, .faceKw) = destination {} else {
                faceKwInitialRole = nil
            }
            // 隐藏页轮询门控：页面以 opacity 常驻（不触发 onDisappear/
            // onAppear），离开时显式停止、回到时显式恢复，避免隐藏期间
            // 后台空转（审计 2/4）。
            if case .dashboard = previous {
                viewModel.isVisible = false
                viewModel.stopAutoRefresh()
            }
            if case .similarity = previous {
                similarityViewModel?.stopProgressPolling()
                similarityViewModel?.stopResultPolling()
            }

            if case .dashboard = destination {
                viewModel.isVisible = true
                viewModel.startAutoRefresh()
            }
            if case .gallery(let id) = destination,
               galleryViewModel?.sessionId != id {
                galleryViewModel = GalleryViewModel(sessionId: id, provider: galleryProvider)
            }
            if case .similarity(let id) = destination {
                if similarityViewModel?.sessionId != id {
                    similarityViewModel?.stopProgressPolling()
                    similarityViewModel?.stopResultPolling()
                    similarityViewModel = SimilarityViewModel(
                        sessionId: id,
                        provider: similarityProvider,
                        captureOne: CaptureOneBridge(router: router)
                    )
                } else {
                    // 回到同一 similarity：恢复因隐藏而停止的轮询（按当前
                    // 状态裁剪：仅活跃分析/无结果才需要）。
                    if similarityViewModel?.isAnalyzing == true {
                        similarityViewModel?.startProgressPolling()
                    }
                    if similarityViewModel?.result == nil {
                        similarityViewModel?.startResultPolling()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionTabView: some View {
        if let destination = navigation.sessionTabDestination {
            let onOpenSettings = { navigation.selectWeb(.settings) }
            Group {
                switch destination.tab {
                case .control:
                    SessionControlView(
                        sessionId: destination.sessionId,
                        router: router,
                        onBack: { navigation.openGallery(destination.sessionId) },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { sessionId, tab in navigation.openSessionTab(sessionId, tab) },
                        onOpenGallery: { navigation.openGallery($0) },
                        onOpenSettings: onOpenSettings
                    )
                case .faceKw:
                    FaceKeywordingView(
                        sessionId: destination.sessionId,
                        router: router,
                        onBack: { navigation.openGallery(destination.sessionId) },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { sessionId, tab in navigation.openSessionTab(sessionId, tab) },
                        onOpenGallery: { navigation.openGallery($0) },
                        onOpenSettings: onOpenSettings,
                        initialRoleFilter: faceKwInitialRole
                    )
                case .duplicates:
                    DuplicatesView(
                        sessionId: destination.sessionId,
                        router: router,
                        onBack: { navigation.openGallery(destination.sessionId) },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { sessionId, tab in navigation.openSessionTab(sessionId, tab) },
                        onOpenGallery: { navigation.openGallery($0) },
                        onOpenSettings: onOpenSettings
                    )
                case .culling:
                    CullingView(
                        sessionId: destination.sessionId,
                        router: router,
                        onBack: { navigation.openGallery(destination.sessionId) },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { sessionId, tab in navigation.openSessionTab(sessionId, tab) },
                        onOpenGallery: { navigation.openGallery($0) },
                        onOpenSettings: onOpenSettings
                    )
                case .export:
                    ExportView(
                        sessionId: destination.sessionId,
                        router: router,
                        onBack: { navigation.openGallery(destination.sessionId) },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { sessionId, tab in navigation.openSessionTab(sessionId, tab) },
                        onOpenGallery: { navigation.openGallery($0) },
                        onOpenSettings: onOpenSettings
                    )
                }
            }
            // 会话切换守卫：页面 @State VM 以 init 时的 sessionId 初始化，
            // 直接 control(A)→control(B) 跳转也必须强制重建（对齐旧版
            // 路由参数变更即重新查询的语义）。
            .id("session-tab-\(destination.sessionId)-\(destination.tab)")
        }
    }
}

private struct SidebarView: View {
    @Bindable var navigation: RootNavigation

    /// 当前 hover 项标识（对齐旧版 hover primary 5% 背景 + 文字加深）。
    @State private var hoveredItem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("G")
                    .font(.system(size: 16, weight: .bold))
                    // 暗色模式 primary 为亮橙 #D98964，白字对比不足 → 深棕。
                    .foregroundStyle(Color(red: 61 / 255, green: 56 / 255, blue: 51 / 255))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [GatherTheme.primary, GatherTheme.primaryHover],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                Text("Gather").font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(spacing: 2) {
                sidebarButton(
                    id: "dashboard",
                    title: GatherLocalization.l("工作台", "Dashboard"),
                    systemImage: "house",
                    isActive: navigation.isDashboard
                ) {
                    navigation.selectDashboard()
                }
                if let sessionId = navigation.currentSessionId {
                    sidebarButton(
                        id: "session-\(sessionId)",
                        title: GatherLocalization.l("当前会话", "Current Session"),
                        systemImage: "square.grid.2x2",
                        isActive: navigation.sessionTabDestination?.tab == .control
                            && navigation.gallerySessionId == nil
                    ) {
                        navigation.openSession(sessionId)
                    }
                }
                sidebarButton(
                    id: "library",
                    title: GatherLocalization.l("全局图库", "Library"),
                    systemImage: "books.vertical",
                    isActive: navigation.isLibrary
                ) {
                    navigation.selectLibrary()
                }
                ForEach(RootNavigation.WebPage.allCases) { page in
                    sidebarButton(
                        id: page.rawValue,
                        title: page.title,
                        systemImage: Self.icon(for: page),
                        isActive: navigation.selectedWebPage == page
                    ) {
                        navigation.selectWeb(page)
                    }
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(width: 200)
        .background(Color.gatherSurface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.gatherBorder.opacity(0.7)).frame(width: 1)
        }
    }

    private func sidebarButton(
        id: String,
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(textColor(isActive: isActive))
            .font(.system(size: 13, weight: isActive ? .semibold : .regular))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isActive: isActive, id: id))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovering in
            hoveredItem = hovering ? id : (hoveredItem == id ? nil : hoveredItem)
        }
        .overlay(alignment: .leading) {
            // 选中指示条（旧版 4px 竖条，左侧外凸）。
            if isActive {
                RoundedRectangle(cornerRadius: 3)
                    .fill(GatherTheme.primary)
                    .frame(width: 4)
                    .padding(.leading, 2)
            }
        }
        .help(title)
    }

    private func textColor(isActive: Bool) -> Color {
        if isActive { return Color.gatherPrimary }
        // 修复旧实现"任一 item hover 全部文字降透明"：hover 只影响
        // 背景（backgroundColor 按 id 判定），文字恒为正文色。
        return Color.gatherTextPrimary
    }

    private func backgroundColor(isActive: Bool, id: String) -> Color {
        if isActive { return GatherTheme.primarySoft }
        if hoveredItem == id { return GatherTheme.primarySoft.opacity(0.4) }
        return Color.clear
    }

    private static func icon(for page: RootNavigation.WebPage) -> String {
        switch page {
        case .persons: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - 共享横幅（原 Jobs/JobsView.swift 定义；任务中心并入 Dashboard 后迁入壳层）

public struct NativeBanner: View {
    let text: String
    let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 9)
            .background(color.opacity(0.1))
    }
}
