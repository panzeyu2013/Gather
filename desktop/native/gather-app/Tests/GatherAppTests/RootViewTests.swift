// desktop/native/gather-app/Tests/GatherAppTests/RootViewTests.swift
// Phase 3.1 宿主导航壳行为测试（3.2/3.3 扩展：全局图库/工作区页签）。
// 覆盖：
// - RootNavigation 状态机（Dashboard ↔ Web 页 ↔ 全局图库 ↔ 工作区详情 ↔
//   工作区页签切换、路由映射、侧栏高亮）——「切换时显示对应视图」的决策层；
// - 真实 WKWebView 端到端：RootView 挂到真实窗口后注入导航模型，切到残余
//   Web 页时宿主把 React HashRouter 带到目标路由（location.hash 轮询断言）。
// 前置：desktop/ 下 `npm run build` 产出 dist/renderer（与冒烟测试同前置）。

import Foundation
import Testing
import AppKit
import SwiftUI
@testable import GatherApp
@testable import GatherCore

// MARK: - 导航状态机

@MainActor
@Suite("RootNavigation")
struct RootNavigationTests {
    @Test func defaultDestinationIsDashboard() {
        let navigation = RootNavigation()
        #expect(navigation.destination == .dashboard)
        #expect(navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.webHostRoute == nil)
    }

    // 切换 Dashboard → Web：显示 Web 页（isDashboard=false）+ 侧栏高亮 + 路由映射。
    @Test func selectingWebPageMapsRouteAndHighlight() {
        let navigation = RootNavigation()
        navigation.selectWeb(.jobs)
        #expect(navigation.destination == .web(.jobs))
        #expect(!navigation.isDashboard)
        #expect(navigation.selectedWebPage == .jobs)
        #expect(navigation.webHostRoute == "/jobs")
    }

    // 「进入」工作区 → 工作区详情（SwiftUI Gallery），侧栏无高亮、不驱动 Web 路由。
    @Test func openingSessionRoutesToSwiftUIGallery() {
        let navigation = RootNavigation()
        navigation.openSession("s1")
        #expect(navigation.destination == .gallery("s1"))
        #expect(!navigation.isDashboard)
        #expect(navigation.gallerySessionId == "s1")
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.webHostRoute == nil)
    }

    // 全局图库（SwiftUI）→ 侧栏高亮、不驱动 Web 路由。
    @Test func selectingLibraryHighlightsWithoutWebRoute() {
        let navigation = RootNavigation()
        navigation.selectLibrary()
        #expect(navigation.destination == .library)
        #expect(navigation.isLibrary)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.webHostRoute == nil)
    }

    // 工作区相似度（SwiftUI Similarity）。
    @Test func openingSimilarityRoutesToSwiftUIPage() {
        let navigation = RootNavigation()
        navigation.openSimilarity("s1")
        #expect(navigation.destination == .similarity("s1"))
        #expect(navigation.similaritySessionId == "s1")
        #expect(navigation.webHostRoute == nil)
    }

    // 工作区残余页签（Culling/重复/导出/人脸）→ WKWebView + 子路由。
    @Test func sessionTabRoutesToWebView() {
        let navigation = RootNavigation()
        navigation.openSessionTab("s1", .culling)
        #expect(navigation.destination == .sessionTab("s1", .culling))
        #expect(navigation.webTabDestination?.sessionId == "s1")
        #expect(navigation.webTabDestination?.tab == .culling)
        #expect(navigation.webHostRoute == "/sessions/s1/culling")
        #expect(SessionWebTab.allCases.map(\.rawValue) == ["face-kw", "duplicates", "culling", "export"])
    }

    // 切换 Web → Dashboard：回到 SwiftUI 页并清空高亮。
    @Test func backToDashboardClearsSelection() {
        let navigation = RootNavigation()
        navigation.selectWeb(.jobs)
        navigation.selectDashboard()
        #expect(navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.webHostRoute == nil)
    }

    // 导航项与路由映射对齐 TS Sidebar/App.tsx。
    @Test func webPageCasesMatchTSSidebar() {
        #expect(RootNavigation.WebPage.allCases.map(\.rawValue) == ["persons", "jobs", "settings"])
        #expect(RootNavigation.WebPage.persons.title == "人脸库")
        #expect(RootNavigation.WebPage.persons.route == "/persons")
        #expect(RootNavigation.WebPage.settings.route == "/settings")
    }
}

// MARK: - RootView 端到端（真实 WKWebView + 真实桥）

@MainActor
@Suite("RootViewNavigation")
struct RootViewNavigationTests {
    private static func rendererDir() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("dist/renderer")
    }

    private func makeLoadedHost() async throws -> WebViewHost {
        let dir = Self.rendererDir()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.html").path) else {
            throw SmokeError.missingRenderer
        }
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-root-nav-\(UUID().uuidString).sqlite")
        let db = try DBConnection(path: dbURL.path)
        try MigrationRunner().migrate(db)
        let router = SessionCommandRouter.makeDefault(db: db)
        let host = WebViewHost(rendererDir: dir, router: router)
        host.viewDidLoad()
        return host
    }

    private func waitForBridge(_ host: WebViewHost) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = await host.webViewForEvaluation()?.evalSync("typeof window.gather")
            if value == "object" { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// 等待 location.hash 到达目标值（期间泵主 RunLoop 驱动 SwiftUI 更新）。
    private func waitForHash(_ host: WebViewHost, _ target: String) async -> String? {
        let deadline = Date().addingTimeInterval(5)
        var hash: String?
        while Date() < deadline {
            pumpMainRunLoop()
            hash = await host.webViewForEvaluation()?.evalSync("location.hash")
            if hash == target { break }
        }
        return hash
    }

    // 切换 Dashboard → 残余 Web：RootView 的 onChange 驱动宿主 navigate，
    // React HashRouter 到达目标路由（#/jobs → #/sessions/s1/culling）。
    @Test func switchingToWebNavigatesHostHash() async throws {
        let host = try await makeLoadedHost()
        guard await waitForBridge(host) else { throw SmokeError.missingRenderer }

        let navigation = RootNavigation()
        let root = RootView(
            host: host,
            provider: NoopDashboardProvider(),
            libraryProvider: NoopLibraryProvider(),
            galleryProvider: NoopGalleryProvider(),
            similarityProvider: NoopSimilarityProvider(),
            navigation: navigation
        )
        // 挂到真实窗口：SwiftUI 视图更新由主 RunLoop 驱动，测试进程无事件
        // 循环，故用窗口 + 手动泵（见 pumpMainRunLoop）。
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        navigation.selectWeb(.jobs)
        let hash = await waitForHash(host, "#/jobs")
        #expect(hash == "#/jobs", "实际: \(hash ?? "nil")")

        // 工作区残余页签路由同样可达（Culling 挑片）。
        navigation.openSessionTab("s1", .culling)
        let cullingHash = await waitForHash(host, "#/sessions/s1/culling")
        #expect(cullingHash == "#/sessions/s1/culling", "实际: \(cullingHash ?? "nil")")

        // 切回 Dashboard：不再驱动导航（hash 保持原值）。
        navigation.selectDashboard()
        pumpMainRunLoop()
        let finalHash = await host.webViewForEvaluation()?.evalSync("location.hash")
        #expect(finalHash == "#/sessions/s1/culling")
    }

    // SwiftUI 页（工作区详情/全局图库）不驱动 Web 路由；工作区详情装配
    // GalleryViewModel（init 时已定位到工作区的导航模型）。
    @Test func swiftUIPagesDoNotNavigateWebHost() async throws {
        let host = try await makeLoadedHost()
        guard await waitForBridge(host) else { throw SmokeError.missingRenderer }

        let navigation = RootNavigation()
        let root = RootView(
            host: host,
            provider: NoopDashboardProvider(),
            libraryProvider: NoopLibraryProvider(),
            galleryProvider: NoopGalleryProvider(),
            similarityProvider: NoopSimilarityProvider(),
            navigation: navigation
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        navigation.selectLibrary()
        pumpMainRunLoop()
        #expect(navigation.isLibrary)

        navigation.openSession("s1")
        pumpMainRunLoop()
        #expect(navigation.gallerySessionId == "s1")

        // SwiftUI 页切换不得驱动 Web 路由：hash 保持 Web 页最后状态（未加载
        // 时为空串，等价"未导航"）。等一帧再读，避免加载中空串误判。
        try? await Task.sleep(for: .milliseconds(50))
        let hash = await host.webViewForEvaluation()?.evalSync("location.hash")
        let allowed: Set<String> = ["", "#/"]
        #expect(allowed.contains(hash ?? "nil"), "SwiftUI 页不应驱动 Web 路由，实际: \(hash ?? "nil")")
    }
}

// MARK: - 空实现 provider（渲染测试不需要数据）

private final class NoopDashboardProvider: DashboardDataProvider {
    func listSessions() throws -> [SessionData] { [] }
    func createSession(name: String, source: String, sourcePath: String) throws -> SessionData {
        throw SessionServiceError.deleteNotConfirmed
    }
    func deleteSession(_ sessionId: String) throws {}
    func workspaceStatus(sessionId: String) throws -> WorkspaceStatus? { nil }
    func listJobs() throws -> [AnalysisJobData] { [] }
    func cancelJob(_ jobId: String) throws -> Bool { true }
    func retryJob(_ jobId: String) throws -> Bool { true }
    func clearCompletedJobs() throws -> Int { 0 }
}

private final class NoopLibraryProvider: LibraryDataProvider {
    func listSessions() throws -> [SessionData] { [] }
    func globalPhotos(criteria: FilterGroup, sessionId: String?, limit: Int, offset: Int) throws -> (photos: [GlobalPhotoResult], total: Int) {
        ([], 0)
    }
}

private final class NoopGalleryProvider: GalleryDataProvider {
    func getSession(_ sessionId: String) throws -> SessionData? { nil }
    func photoPage(sessionId: String, afterFirstRowid: Int64?, limit: Int, expandVariants: Bool) throws -> (rows: [GalleryPhotoData], cursor: Int64?) {
        ([], nil)
    }
}

private final class NoopSimilarityProvider: SimilarityDataProvider {
    func getResult(sessionId: String, threshold: Int?) throws -> SimilarityResult? { nil }
    func analyze(sessionId: String, threshold: Int?, minGroupSize: Int?, groupingMode: SimilarityGroupingMode) async throws {}
    func cancelAnalysis(sessionId: String) async throws -> Bool { true }
    func recluster(sessionId: String, threshold: Int, minGroupSize: Int, groupingMode: SimilarityGroupingMode) async throws -> SimilarityResult {
        SimilarityResult(groups: [], ungrouped: [], stats: SimilarityResultStats(totalGroups: 0, totalUngrouped: 0, threshold: Double(threshold), minGroupSize: minGroupSize, groupingMode: groupingMode))
    }
    func listSimilarityJobs(sessionId: String) throws -> [AnalysisJobData] { [] }
}

/// 泵主 RunLoop（测试进程无 AppKit 事件循环，SwiftUI 视图更新依赖它被驱动；
/// CFRunLoopRunInMode 在 async 上下文不可用，包一层同步函数）。
private func pumpMainRunLoop(seconds: TimeInterval = 0.05) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}
