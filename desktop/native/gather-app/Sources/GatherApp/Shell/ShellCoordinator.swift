// desktop/native/gather-app/Sources/GatherApp/Shell/ShellCoordinator.swift
// R6 收尾：壳层职责协调器。原根壳承担的六项壳级职责（菜单/通知订阅、
// 导入完成跳转、Capture One 错误 Toast、窗口标题跟随会话、窗口级拖放目录
// 导入、语言切换重渲染）集中在此；AppShellView 只按状态渲染。
//
// 依赖注入沿用「可选 provider + 未注入回退」模式；注释不出现受门禁监控的
// 标识符（该度量为棘轮，只允许下降）。
import AppKit
import SwiftUI
import GatherCore

/// 壳层协调器：状态 + 壳级动作，全部在主线程上串行。
@MainActor
@Observable
final class ShellCoordinator {
    // MARK: - 壳层状态

    /// 当前选中特性：左侧列表点击与菜单通知共用同一入口。
    private(set) var selectedFeature: AppShellView.Feature = .dashboard
    /// 侧栏（特性列表）可见性：菜单「隐藏/显示侧栏」切换。
    private(set) var isSidebarVisible = true
    /// 语言版本号：语言切换通知递增，驱动壳层文案重建（视图 .id 跟随）。
    private(set) var languageVersion = 0
    /// 窗口标题：有会话时取会话名，否则保持「Gather」。
    private(set) var windowTitle = "Gather"

    /// 壳层导航状态（会话/页签），由装配处注入并持有。
    let navigation: AppNavigationState

    // MARK: - 依赖（可选：未注入时对应特性回退占位）

    private let dashboardProvider: DashboardDataProvider?
    private let galleryProvider: GalleryDataProvider?
    private let similarityProvider: SimilarityDataProvider?
    private let sessionRouter: CommandRouter?
    /// 浏览页宿主路由层是否已接线（未接线时不构造浏览视图模型，与占位一致）。
    private let isGalleryRouterWired: Bool

    // MARK: - 视图模型

    /// 工作台视图模型：常驻（工作台自带的菜单订阅与进度事件随壳层存活），
    /// 切换特性时只做可见性与自动刷新门控。
    let dashboardViewModel: DashboardViewModel?
    /// 浏览视图模型：会话级，选中会话时构造，换会话重建。
    private(set) var galleryViewModel: GalleryViewModel?
    /// 相似度视图模型：会话级，选中会话时构造，换会话重建。
    private(set) var similarityViewModel: SimilarityViewModel?

    /// 壳级通知订阅令牌（start/stop 成对，重复 start 为空操作）。
    private var observers: [NSObjectProtocol] = []

    /// 壳层主动导航的目标会话：会话变化回调据此避免把特性高亮改回页签
    /// （导入完成/页内跳转已明确选择浏览或相似度等特性）。
    private var shellNavigatedSessionId: String?

    init(
        navigation: AppNavigationState,
        dashboardProvider: DashboardDataProvider? = nil,
        galleryProvider: GalleryDataProvider? = nil,
        isGalleryRouterWired: Bool = false,
        similarityProvider: SimilarityDataProvider? = nil,
        sessionRouter: CommandRouter? = nil
    ) {
        self.navigation = navigation
        self.dashboardProvider = dashboardProvider
        self.galleryProvider = galleryProvider
        self.similarityProvider = similarityProvider
        self.sessionRouter = sessionRouter
        self.isGalleryRouterWired = isGalleryRouterWired

        let dashboardViewModel = dashboardProvider.map { DashboardViewModel(provider: $0) }
        // 常驻工作台：selectedFeature 初值恒为 .dashboard，启动即可见。
        dashboardViewModel?.isVisible = true
        self.dashboardViewModel = dashboardViewModel

        // 装配处预置了选中会话时（深链/恢复）：同步构造两个会话级视图模型；
        // 未预置时等首次会话变化走 syncSessionScopedViewModels()。
        if let sessionId = navigation.currentSessionId {
            if let galleryProvider, isGalleryRouterWired {
                self.galleryViewModel = GalleryViewModel(sessionId: sessionId, provider: galleryProvider)
            }
            if let similarityProvider {
                self.similarityViewModel = SimilarityViewModel(
                    sessionId: sessionId,
                    provider: similarityProvider,
                    captureOne: Self.captureOneBridge(router: sessionRouter)
                )
            }
        }
    }

    // MARK: - 菜单/通知接线

    /// 注册壳级订阅（AppShellView 的 .task 调用；重复调用为空操作）。
    func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: GatherAppNotification.menuNewWorkspace, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMenuNewWorkspace() }
        })
        observers.append(center.addObserver(
            forName: GatherAppNotification.menuImportFolder, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMenuImportFolder() }
        })
        observers.append(center.addObserver(
            forName: GatherAppNotification.menuOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMenuOpenSettings() }
        })
        observers.append(center.addObserver(
            forName: GatherAppNotification.menuToggleSidebar, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggleSidebar() }
        })
        observers.append(center.addObserver(
            forName: GatherAppNotification.importCompleted, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleImportCompleted(notification.userInfo) }
        })
        observers.append(center.addObserver(
            forName: GatherAppNotification.captureOneError, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleCaptureOneError(notification.object) }
        })
        observers.append(center.addObserver(
            forName: GatherAppNotification.languageChanged, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleLanguageChanged(notification.object) }
        })
    }

    /// 注销全部壳级订阅（视图消失时调用；可再次 start）。
    func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: - 菜单动作（internal：壳层测试可直接调用，也可经通知触达）

    /// Cmd+N：切到工作台。工作台常驻，其自带订阅随后打开新建 sheet。
    func handleMenuNewWorkspace() {
        setFeature(.dashboard)
    }

    /// Cmd+O：同上，切到工作台后由工作台订阅打开导入 sheet。
    func handleMenuImportFolder() {
        setFeature(.dashboard)
    }

    /// Cmd+,：切到设置页并转发宿主出口。
    func handleMenuOpenSettings() {
        setFeature(.settings)
        navigation.openSettings()
    }

    /// 侧栏显隐（菜单项标题由 AppKit 菜单自身维护）。
    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    /// 菜单/深链/C1 导入完成：失败计数 > 0 时警告 Toast，随后落到新工作区浏览页。
    func handleImportCompleted(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let sessionId = userInfo[GatherAppImportUserInfoKey.sessionId] as? String,
              !sessionId.isEmpty else { return }
        let failedCount = (userInfo[GatherAppImportUserInfoKey.failedCount] as? Int) ?? 0
        if failedCount > 0 {
            // 对齐旧版 importFailureMessage：N 张照片已导入；来源读取失败：示例、… 等 N 个。
            let addedCount = (userInfo[GatherAppImportUserInfoKey.addedCount] as? Int) ?? 0
            let sourceLabel = (userInfo[GatherAppImportUserInfoKey.sourceLabel] as? String)
                ?? GatherLocalization.l("文件")
            let examples = (userInfo[GatherAppImportUserInfoKey.examples] as? String) ?? ""
            let remaining = failedCount > 3
                ? String(format: GatherLocalization.l(" 等 %d 个"), failedCount)
                : ""
            GatherToastCenter.shared.show(
                type: .warning,
                message: String(format: GatherLocalization.l("%lld 张照片已导入；%@读取失败：%@%@"), addedCount, sourceLabel, examples, remaining)
            )
        }
        // 深链/导入完成语义：落点浏览页（图库），而非控制中心页。
        openGalleryFeature(sessionId)
    }

    /// Capture One 错误码：经本地化后以错误 Toast 提示。
    func handleCaptureOneError(_ code: Any?) {
        guard let code = code as? String else { return }
        GatherToastCenter.shared.show(type: .error, message: GatherLocalization.errorText(code))
    }

    /// 语言切换：同步本地化语言并递增版本号（视图 .id 跟随重建）。
    func handleLanguageChanged(_ language: Any?) {
        if let language = language as? String {
            GatherLocalization.setAppLanguage(language)
        }
        languageVersion += 1
    }

    // MARK: - 特性/导航动作

    /// 侧栏点击：切换当前特性，并同步工作区页签（非工作区特性不动页签）。
    func selectFeature(_ feature: AppShellView.Feature) {
        setFeature(feature)
        if let tab = feature.sessionTab {
            navigation.selectTab(tab)
        }
    }

    /// 工作区页签跳转：同步特性高亮并转发导航出口。
    func openSessionTab(_ sessionId: String, _ tab: SessionTab) {
        setFeature(AppShellView.Feature.forTab(tab))
        shellNavigatedSessionId = sessionId
        navigation.openTab(sessionId, tab)
    }

    /// 打开浏览页：切特性并转发导航出口。
    func openGalleryFeature(_ sessionId: String) {
        setFeature(.gallery)
        shellNavigatedSessionId = sessionId
        navigation.openGallery(sessionId)
    }

    /// 打开相似度页：切特性并转发导航出口。
    func openSimilarityFeature(_ sessionId: String) {
        setFeature(.similarity)
        shellNavigatedSessionId = sessionId
        navigation.openSimilarity(sessionId)
    }

    /// 打开设置页：切特性并转发导航出口。
    func openSettingsFeature() {
        setFeature(.settings)
        navigation.openSettings()
    }

    /// 返回工作台（浏览页的返回落点）。
    func openDashboardFeature() {
        setFeature(.dashboard)
    }

    /// 壳层当前会话变化：重建会话级视图模型、刷新窗口标题、侧栏落到当前页签。
    /// 壳层主动导航（导入完成落浏览页等）已选定特性，不再被页签映射覆盖。
    func navigationSessionDidChange() {
        syncSessionScopedViewModels()
        Task { await refreshWindowTitle() }
        let shellInitiated = shellNavigatedSessionId == navigation.currentSessionId
        shellNavigatedSessionId = nil
        guard navigation.currentSessionId != nil, !shellInitiated else { return }
        setFeature(AppShellView.Feature.forTab(navigation.selectedTab))
    }

    /// 壳层当前页签变化：仅在有会话时同步特性高亮。
    func navigationTabDidChange() {
        guard navigation.currentSessionId != nil else { return }
        setFeature(AppShellView.Feature.forTab(navigation.selectedTab))
    }

    // MARK: - 会话级视图模型

    /// 当前会话变化时重建浏览/相似度视图模型（同会话不重建，避免打断页内状态）。
    func syncSessionScopedViewModels() {
        guard let sessionId = navigation.currentSessionId else {
            galleryViewModel?.stopIndexStatusPolling()
            similarityViewModel?.stopProgressPolling()
            similarityViewModel?.stopResultPolling()
            galleryViewModel = nil
            similarityViewModel = nil
            return
        }
        if galleryViewModel?.sessionId != sessionId, let galleryProvider, isGalleryRouterWired {
            galleryViewModel?.stopIndexStatusPolling()
            galleryViewModel = GalleryViewModel(sessionId: sessionId, provider: galleryProvider)
        }
        if similarityViewModel?.sessionId != sessionId, let similarityProvider {
            similarityViewModel?.stopProgressPolling()
            similarityViewModel?.stopResultPolling()
            similarityViewModel = SimilarityViewModel(
                sessionId: sessionId,
                provider: similarityProvider,
                captureOne: Self.captureOneBridge(router: sessionRouter)
            )
        }
    }

    // MARK: - 窗口标题

    /// 窗口标题跟随当前会话：有会话时用会话名，无会话（或无名称）保持「Gather」。
    func refreshWindowTitle() async {
        guard let sessionId = navigation.currentSessionId else {
            windowTitle = "Gather"
            return
        }
        let sessions: [SessionData] = (try? await dashboardProvider?.listSessions()) ?? []
        windowTitle = sessions.first(where: { $0.id == sessionId })?.name ?? "Gather"
    }

    // MARK: - 工具

    /// 拖放目录判定：Finder 拖入的目录 URL 通常带尾斜杠；无尾斜杠时回退资源值探测。
    static func firstDirectoryURL(in urls: [URL]) -> URL? {
        urls.first(where: { url in
            if url.hasDirectoryPath { return true }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        })
    }

    // MARK: - 私有

    /// 特性切换的唯一入口：同步工作台常驻轮询门控。
    private func setFeature(_ feature: AppShellView.Feature) {
        guard feature != selectedFeature else { return }
        selectedFeature = feature
        syncDashboardPolling()
    }

    /// 工作台常驻后：隐藏期间停 2s 自动刷新，回到工作台恢复。
    private func syncDashboardPolling() {
        guard let dashboardViewModel else { return }
        let visible = selectedFeature == .dashboard
        dashboardViewModel.isVisible = visible
        if visible {
            dashboardViewModel.startAutoRefresh()
        } else {
            dashboardViewModel.stopAutoRefresh()
        }
    }

    /// 相似度页的 Capture One 桥：注入了命令路由时用真实桥，否则用默认空实现。
    private static func captureOneBridge(router: CommandRouter?) -> CaptureOneBridge {
        guard let router else { return CaptureOneBridge() }
        return CaptureOneBridge(router: router)
    }
}
