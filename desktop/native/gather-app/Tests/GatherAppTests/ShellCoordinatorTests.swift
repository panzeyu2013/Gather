// desktop/native/gather-app/Tests/GatherAppTests/ShellCoordinatorTests.swift
// R6 收尾：壳层职责测试。覆盖壳层导航状态流转、页签与特性联动、会话级
// 浏览/相似度视图模型构造与重建、菜单通知触发动作、窗口标题与拖放目录判定。
// 等价承接随死树删除的根导航测试（会话入口/页签/清空语义）。
import Foundation
import Testing
@testable import GatherApp
@testable import GatherCore

// MARK: - 测试替身

/// 轮询等待（壳级通知经 main queue + MainActor 两跳投递，非同步断言）。
@discardableResult
private func waitUntil(
    timeout: TimeInterval = 3,
    interval: TimeInterval = 0.01,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(interval * 1000))
    }
    return condition()
}

private enum ShellStubError: Error {
    case unused
}

/// 工作台数据源：仅 listSessions 供壳层标题测试使用，其余方法不被壳层调用。
private final class ShellStubDashboardProvider: DashboardDataProvider {
    var sessions: [SessionData] = []

    func listSessions() async throws -> [SessionData] { sessions }
    func createSession(name: String, source: String, sourcePath: String) async throws -> SessionData {
        throw ShellStubError.unused
    }
    func createSessionFromFiles(
        name: String,
        source: String,
        filepaths: [String],
        sourcePath: String
    ) async throws -> CreateSessionOutcome {
        throw ShellStubError.unused
    }
    func deleteSession(_ sessionId: String) async throws { throw ShellStubError.unused }
    func deleteSessions(_ sessionIds: [String]) async throws { throw ShellStubError.unused }
    func workspaceStatus(sessionId: String) async throws -> WorkspaceStatus? { nil }
    func listJobs() async throws -> [AnalysisJobData] { [] }
    func cancelJob(_ jobId: String) async throws -> Bool { false }
    func retryJob(_ jobId: String) async throws -> Bool { false }
    func clearCompletedJobs() async throws -> Int { 0 }
}

/// 浏览数据源：协议必需方法返回空会话（视图模型构造即止，不取真实数据）。
private final class ShellStubGalleryProvider: GalleryDataProvider {
    func getSession(_ sessionId: String) async throws -> SessionData? { nil }
    func photoPage(
        sessionId: String,
        afterFirstRowid: Int64?,
        limit: Int,
        expandVariants: Bool
    ) async throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }
}

/// 相似度数据源：协议必需方法返回空结果（视图模型构造即止）。
private final class ShellStubSimilarityProvider: SimilarityDataProvider {
    func getResult(sessionId: String, threshold: Int?) async throws -> SimilarityResult? { nil }
    func analyze(
        sessionId: String,
        threshold: Int?,
        minGroupSize: Int?,
        groupingMode: SimilarityGroupingMode
    ) async throws {}
    func cancelAnalysis(sessionId: String) async throws -> Bool { false }
    func recluster(
        sessionId: String,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode
    ) async throws -> SimilarityResult {
        SimilarityResult(
            groups: [],
            ungrouped: [],
            stats: SimilarityResultStats(
                totalGroups: 0,
                totalUngrouped: 0,
                threshold: Double(threshold),
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
        )
    }
    func listSimilarityJobs(sessionId: String) async throws -> [AnalysisJobData] { [] }
    func previewWriteback(
        sessionId: String,
        assignments: [SimilarityKeywordAssignment],
        threshold: Int?
    ) async throws -> WritebackPreview {
        WritebackPreview(items: [], totalCount: 0, affectedPhotos: 0)
    }
    func writeback(sessionId: String, itemIds: [Int], threshold: Int?) async throws -> WritebackResult {
        Self.emptyResult
    }
    func retryFailedWriteback(sessionId: String) async throws -> WritebackResult { Self.emptyResult }
    func confirmSync(sessionId: String) async throws {}
    func cleanupWriteback(sessionId: String) async throws -> CleanupResult {
        CleanupResult(deletedCount: 0, errors: [])
    }

    private static var emptyResult: WritebackResult {
        WritebackResult(
            totalAffected: 0,
            written: 0,
            failed: 0,
            skipped: 0,
            errors: [],
            failedItems: [],
            report: ""
        )
    }
}

/// 命令路由替身：相似度视图模型构造只需可注入的路由依赖，不执行命令。
private final class ShellStubRouter: CommandRouter {
    func execute(_ command: String, params: [String: JSONValue]) throws -> JSONValue { .null }
    func executeAsync(
        _ command: String,
        params: [String: JSONValue],
        completion: @escaping (WebResponse) -> Void
    ) {
        completion(WebResponse(ok: true, data: .null))
    }
}

private func makeSessionData(id: String, name: String) -> SessionData {
    SessionData(
        id: id,
        name: name,
        status: .draft,
        photoCount: 0,
        analysisStatus: .idle,
        writebackStatus: .idle,
        importSource: "local",
        sourcePath: "",
        failedWritebackCount: 0,
        truncatedImport: false,
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z"
    )
}

// MARK: - 壳层测试

@MainActor
@Suite("AppShell 壳层", .serialized)
struct ShellCoordinatorTests {
    private static func makeCoordinator(
        navigation: AppNavigationState,
        dashboard: ShellStubDashboardProvider? = nil,
        gallery: ShellStubGalleryProvider? = nil,
        galleryWired: Bool = false,
        similarity: ShellStubSimilarityProvider? = nil,
        router: CommandRouter? = nil
    ) -> ShellCoordinator {
        ShellCoordinator(
            navigation: navigation,
            dashboardProvider: dashboard,
            galleryProvider: gallery,
            isGalleryRouterWired: galleryWired,
            similarityProvider: similarity,
            sessionRouter: router
        )
    }

    // MARK: 导航状态流转（等价承接已删根导航测试）

    @Test("导航默认无会话、控制中心页签")
    func navigationDefaults() {
        let navigation = AppNavigationState()
        #expect(navigation.currentSessionId == nil)
        #expect(navigation.selectedTab == .control)
        #expect(!navigation.hasSelectedSession)
    }

    @Test("打开会话统一落控制中心并转发出口")
    func openSessionRoutesToControlCenterAndForwards() {
        var forwarded: [String] = []
        let navigation = AppNavigationState(onOpenSession: { forwarded.append($0) })
        navigation.openSession("s1")
        #expect(navigation.currentSessionId == "s1")
        #expect(navigation.selectedTab == .control)
        #expect(navigation.hasSelectedSession)
        #expect(forwarded == ["s1"])
    }

    @Test("浏览/相似度/设置出口保留会话并转发")
    func galleryAndSimilarityForwardOutlets() {
        var gallery: [String] = []
        var similarity: [String] = []
        var settingsCalls = 0
        let navigation = AppNavigationState(
            onOpenGallery: { gallery.append($0) },
            onOpenSimilarity: { similarity.append($0) },
            onOpenSettings: { settingsCalls += 1 }
        )
        navigation.openGallery("s1")
        #expect(navigation.currentSessionId == "s1")
        #expect(gallery == ["s1"])
        navigation.openSimilarity("s2")
        #expect(navigation.currentSessionId == "s2")
        #expect(similarity == ["s2"])
        navigation.openSettings()
        #expect(navigation.currentSessionId == "s2")
        #expect(navigation.selectedTab == .control)
        #expect(settingsCalls == 1)
    }

    @Test("每个工作区页签都保留会话身份并转发")
    func openingEachTabKeepsSessionIdentity() {
        var tabs: [(String, SessionTab)] = []
        let navigation = AppNavigationState(onOpenTab: { tabs.append(($0, $1)) })
        for tab in SessionTab.allCases {
            navigation.openTab("s1", tab)
            #expect(navigation.currentSessionId == "s1")
            #expect(navigation.selectedTab == tab)
        }
        #expect(tabs.map(\.1) == SessionTab.allCases)
    }

    @Test("页签顺序与产品一致，selectTab 只改页签")
    func sessionTabsMatchProductOrder() {
        #expect(SessionTab.allCases.map(\.rawValue) == ["control", "face-kw", "duplicates", "culling", "export"])
        let navigation = AppNavigationState()
        navigation.selectTab(.culling)
        #expect(navigation.selectedTab == .culling)
        #expect(navigation.currentSessionId == nil)
    }

    @Test("清空会话回到未选中占位")
    func clearSessionReturnsToPlaceholder() {
        let navigation = AppNavigationState()
        navigation.openSession("s1")
        navigation.clearSession()
        #expect(navigation.currentSessionId == nil)
        #expect(!navigation.hasSelectedSession)
    }

    // MARK: 特性与页签联动

    @Test("特性元数据与页签映射稳定")
    func featureMetadataAndTabMapping() {
        #expect(AppShellView.Feature.allCases.count == 11)
        #expect(AppShellView.Feature.persons.displayName == "人脸库")
        #expect(AppShellView.Feature.settings.displayName == "设置")
        #expect(AppShellView.Feature.controlCenter.sessionTab == .control)
        #expect(AppShellView.Feature.forTab(.export) == .export)
        #expect(AppShellView.Feature.forTab(.faceKw) == .faceKeywording)
        #expect(AppShellView.Feature.dashboard.sessionTab == nil)
    }

    @Test("侧栏点击工作区特性同步页签、非工作区特性不动页签")
    func selectFeatureSyncsSessionTab() {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        coordinator.selectFeature(.settings)
        #expect(coordinator.selectedFeature == .settings)
        #expect(navigation.selectedTab == .control)
        coordinator.selectFeature(.culling)
        #expect(coordinator.selectedFeature == .culling)
        #expect(navigation.selectedTab == .culling)
    }

    @Test("外部页签切换仅在已选中会话时同步特性高亮")
    func externalTabChangeSyncsFeature() {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        navigation.selectTab(.duplicates)
        coordinator.navigationTabDidChange()
        #expect(coordinator.selectedFeature == .dashboard)
        navigation.openTab("s1", .duplicates)
        coordinator.navigationTabDidChange()
        #expect(coordinator.selectedFeature == .duplicates)
    }

    // MARK: 会话级视图模型构造与重建

    @Test("装配处预置会话时初始化即构造会话级视图模型")
    func initialSessionBuildsScopedViewModels() {
        let navigation = AppNavigationState(currentSessionId: "restored")
        let coordinator = Self.makeCoordinator(
            navigation: navigation,
            gallery: ShellStubGalleryProvider(),
            galleryWired: true,
            similarity: ShellStubSimilarityProvider(),
            router: ShellStubRouter()
        )
        #expect(coordinator.galleryViewModel?.sessionId == "restored")
        #expect(coordinator.similarityViewModel?.sessionId == "restored")
    }

    @Test("会话变化构造视图模型；同会话不重建、换会话重建、清空释放")
    func sessionScopedViewModelsRebuildAndRelease() {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(
            navigation: navigation,
            gallery: ShellStubGalleryProvider(),
            galleryWired: true,
            similarity: ShellStubSimilarityProvider(),
            router: ShellStubRouter()
        )
        coordinator.navigationSessionDidChange()
        #expect(coordinator.galleryViewModel == nil)
        #expect(coordinator.similarityViewModel == nil)

        navigation.openSession("s1")
        coordinator.navigationSessionDidChange()
        #expect(coordinator.galleryViewModel?.sessionId == "s1")
        #expect(coordinator.similarityViewModel?.sessionId == "s1")
        let firstGallery = coordinator.galleryViewModel
        let firstSimilarity = coordinator.similarityViewModel

        // 同会话不重建（避免打断页内状态）。
        coordinator.navigationSessionDidChange()
        #expect(coordinator.galleryViewModel === firstGallery)
        #expect(coordinator.similarityViewModel === firstSimilarity)

        // 换会话重建。
        navigation.openGallery("s2")
        coordinator.navigationSessionDidChange()
        #expect(coordinator.galleryViewModel?.sessionId == "s2")
        #expect(coordinator.similarityViewModel?.sessionId == "s2")
        #expect(coordinator.galleryViewModel !== firstGallery)
        #expect(coordinator.similarityViewModel !== firstSimilarity)

        // 清空会话释放两个视图模型。
        navigation.clearSession()
        coordinator.navigationSessionDidChange()
        #expect(coordinator.galleryViewModel == nil)
        #expect(coordinator.similarityViewModel == nil)
    }

    @Test("未注入会话级依赖时不构造视图模型")
    func missingProvidersLeaveViewModelsEmpty() {
        let navigation = AppNavigationState(currentSessionId: "s1")
        let coordinator = Self.makeCoordinator(navigation: navigation)
        #expect(coordinator.galleryViewModel == nil)
        #expect(coordinator.similarityViewModel == nil)
    }

    // MARK: 菜单通知触发动作

    @Test("Cmd+N 通知切到工作台")
    func menuNewWorkspaceSelectsDashboard() async {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        coordinator.selectFeature(.settings)
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(name: GatherAppNotification.menuNewWorkspace, object: nil)
        let ok = await waitUntil { coordinator.selectedFeature == .dashboard }
        #expect(ok)
    }

    @Test("Cmd+O 通知切到工作台（工作台常驻订阅打开导入 sheet）")
    func menuImportFolderSelectsDashboard() async {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        coordinator.selectFeature(.similarity)
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(
            name: GatherAppNotification.menuImportFolder,
            object: URL(fileURLWithPath: "/tmp/gather-import-probe", isDirectory: true)
        )
        let ok = await waitUntil { coordinator.selectedFeature == .dashboard }
        #expect(ok)
    }

    @Test("Cmd+, 通知切到设置页并转发出口")
    func menuOpenSettingsSelectsSettingsAndForwards() async {
        var settingsCalls = 0
        let navigation = AppNavigationState(onOpenSettings: { settingsCalls += 1 })
        let coordinator = Self.makeCoordinator(navigation: navigation)
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(name: GatherAppNotification.menuOpenSettings, object: nil)
        let ok = await waitUntil { coordinator.selectedFeature == .settings && settingsCalls == 1 }
        #expect(ok)
    }

    @Test("侧栏显隐菜单通知翻转壳层侧栏可见性")
    func menuToggleSidebarFlipsVisibility() async {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        let initial = coordinator.isSidebarVisible
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(name: GatherAppNotification.menuToggleSidebar, object: nil)
        let ok = await waitUntil { coordinator.isSidebarVisible == !initial }
        #expect(ok)
    }

    @Test("导入完成通知：失败计数 > 0 警告 Toast 并落浏览页")
    func importCompletedOpensGalleryAndWarns() async {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(
            navigation: navigation,
            gallery: ShellStubGalleryProvider(),
            galleryWired: true
        )
        let center = GatherToastCenter.shared
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(
            name: GatherAppNotification.importCompleted,
            object: nil,
            userInfo: [
                GatherAppImportUserInfoKey.sessionId: "s9",
                GatherAppImportUserInfoKey.failedCount: 2,
                GatherAppImportUserInfoKey.addedCount: 5,
                GatherAppImportUserInfoKey.sourceLabel: "文件",
                GatherAppImportUserInfoKey.examples: "a.raw、b.raw",
            ]
        )
        let ok = await waitUntil {
            coordinator.selectedFeature == .gallery
                && navigation.currentSessionId == "s9"
                && center.toasts.contains { $0.message.contains("张照片已导入") }
        }
        #expect(ok)
        if let shown = center.toasts.first(where: { $0.message.contains("张照片已导入") }) {
            switch shown.type {
            case .warning: break
            default: Issue.record("期望 warning Toast，实际 \(shown.type)")
            }
            center.dismiss(id: shown.id)
        }
    }

    @Test("导入完成无失败时只跳转、不弹 Toast")
    func importCompletedWithoutFailuresSkipsToast() async {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(
            navigation: navigation,
            gallery: ShellStubGalleryProvider(),
            galleryWired: true
        )
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(
            name: GatherAppNotification.importCompleted,
            object: nil,
            userInfo: [
                GatherAppImportUserInfoKey.sessionId: "s10",
                GatherAppImportUserInfoKey.failedCount: 0,
                GatherAppImportUserInfoKey.addedCount: 3,
            ]
        )
        let ok = await waitUntil {
            coordinator.selectedFeature == .gallery && navigation.currentSessionId == "s10"
        }
        #expect(ok)
        #expect(!GatherToastCenter.shared.toasts.contains { $0.message.contains("读取失败") })
    }

    @Test("Capture One 错误通知以错误 Toast 提示")
    func captureOneErrorShowsToast() async {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        let center = GatherToastCenter.shared
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(
            name: GatherAppNotification.captureOneError,
            object: "C1_NO_SELECTED_PHOTOS"
        )
        let ok = await waitUntil {
            center.toasts.contains { $0.message.contains("选择") }
        }
        #expect(ok)
        if let shown = center.toasts.first(where: { $0.message.contains("选择") }) {
            switch shown.type {
            case .error: break
            default: Issue.record("期望 error Toast，实际 \(shown.type)")
            }
            center.dismiss(id: shown.id)
        }
    }

    @Test("语言切换通知递增壳层语言版本并应用语言")
    func languageChangedBumpsVersionAndAppliesLanguage() async {
        let original = GatherLocalization.appLanguage
        defer { GatherLocalization.setAppLanguage(original) }
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation)
        coordinator.startObserving()
        defer { coordinator.stopObserving() }
        NotificationCenter.default.post(
            name: GatherAppNotification.languageChanged,
            object: "en"
        )
        let ok = await waitUntil {
            coordinator.languageVersion == 1 && GatherLocalization.appLanguage == "en"
        }
        #expect(ok)
    }

    // MARK: 窗口标题 / 拖放 / 工作台轮询门控

    @Test("窗口标题跟随会话名，无会话回退 Gather")
    func windowTitleFollowsSession() async {
        let navigation = AppNavigationState()
        let dashboard = ShellStubDashboardProvider()
        dashboard.sessions = [makeSessionData(id: "s1", name: "婚礼精选")]
        let coordinator = Self.makeCoordinator(navigation: navigation, dashboard: dashboard)
        await coordinator.refreshWindowTitle()
        #expect(coordinator.windowTitle == "Gather")
        navigation.openSession("s1")
        await coordinator.refreshWindowTitle()
        #expect(coordinator.windowTitle == "婚礼精选")
        navigation.clearSession()
        await coordinator.refreshWindowTitle()
        #expect(coordinator.windowTitle == "Gather")
    }

    @Test("拖放只接受目录 URL")
    func dropAcceptsDirectoriesOnly() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "gather-drop-probe.raw")
        #expect(ShellCoordinator.firstDirectoryURL(in: [file, dir]) == dir)
        #expect(ShellCoordinator.firstDirectoryURL(in: [file]) == nil)
        #expect(ShellCoordinator.firstDirectoryURL(in: []) == nil)
    }

    @Test("工作台常驻：切换特性只门控可见性，不销毁视图模型")
    func dashboardPollingGateFollowsFeature() {
        let navigation = AppNavigationState()
        let coordinator = Self.makeCoordinator(navigation: navigation, dashboard: ShellStubDashboardProvider())
        #expect(coordinator.dashboardViewModel?.isVisible == true)
        coordinator.selectFeature(.settings)
        #expect(coordinator.dashboardViewModel?.isVisible == false)
        coordinator.selectFeature(.dashboard)
        #expect(coordinator.dashboardViewModel?.isVisible == true)
        // 收尾：避免测试结束后台轮询继续。
        coordinator.selectFeature(.settings)
    }
}
