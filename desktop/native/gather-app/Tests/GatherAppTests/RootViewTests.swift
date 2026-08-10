// desktop/native/gather-app/Tests/GatherAppTests/RootViewTests.swift
// Phase 3.1 宿主导航壳行为测试。
// 覆盖：
// - RootNavigation 状态机（Dashboard ↔ Web 页 ↔ 工作区详情切换、路由映射、
//   侧栏高亮）——「切换时显示对应视图」的决策层（isDashboard/selectedWebPage
//   决定 ZStack 中显示 SwiftUI Dashboard 还是 WebViewHost）；
// - 真实 WKWebView 端到端：RootView 挂到真实窗口后注入导航模型，切到 Web 页
//   时宿主把 React HashRouter 带到目标路由（location.hash 轮询断言）。
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
        #expect(navigation.webRoute == "/")
    }

    // 切换 Dashboard → Web：显示 Web 页（isDashboard=false）+ 侧栏高亮 + 路由映射。
    @Test func selectingWebPageMapsRouteAndHighlight() {
        let navigation = RootNavigation()
        navigation.selectWeb(.library)
        #expect(navigation.destination == .web(.library))
        #expect(!navigation.isDashboard)
        #expect(navigation.selectedWebPage == .library)
        #expect(navigation.webRoute == "/library")
    }

    // 「进入」工作区 → 工作区详情（Web 侧），侧栏无高亮项。
    @Test func openingSessionRoutesToSessionDetail() {
        let navigation = RootNavigation()
        navigation.openSession("s1")
        #expect(navigation.destination == .session("s1"))
        #expect(!navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.webRoute == "/sessions/s1")
    }

    // 切换 Web → Dashboard：回到 SwiftUI 页并清空高亮。
    @Test func backToDashboardClearsSelection() {
        let navigation = RootNavigation()
        navigation.selectWeb(.jobs)
        navigation.selectDashboard()
        #expect(navigation.isDashboard)
        #expect(navigation.selectedWebPage == nil)
        #expect(navigation.webRoute == "/")
    }

    // 导航项与路由映射对齐 TS Sidebar/App.tsx。
    @Test func webPageCasesMatchTSSidebar() {
        #expect(RootNavigation.WebPage.allCases.map(\.rawValue) == ["library", "persons", "jobs", "settings"])
        #expect(RootNavigation.WebPage.library.title == "全局图库")
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

    // 切换 Dashboard → Web：RootView 的 onChange 驱动宿主 navigate，
    // React HashRouter 到达目标路由（#/library → #/sessions/s1）。
    @Test func switchingToWebNavigatesHostHash() async throws {
        let host = try await makeLoadedHost()
        guard await waitForBridge(host) else { throw SmokeError.missingRenderer }

        let navigation = RootNavigation()
        let root = RootView(host: host, provider: NoopDashboardProvider(), navigation: navigation)
        // 挂到真实窗口：SwiftUI 视图更新由主 RunLoop 驱动，测试进程无事件
        // 循环，故用窗口 + 手动泵（见 pumpMainRunLoop）。
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        navigation.selectWeb(.library)
        let hash = await waitForHash(host, "#/library")
        #expect(hash == "#/library", "实际: \(hash ?? "nil")")

        // 工作区详情路由同样可达。
        navigation.openSession("s1")
        let sessionHash = await waitForHash(host, "#/sessions/s1")
        #expect(sessionHash == "#/sessions/s1", "实际: \(sessionHash ?? "nil")")

        // 切回 Dashboard：不再驱动导航（hash 保持原值）。
        navigation.selectDashboard()
        pumpMainRunLoop()
        let finalHash = await host.webViewForEvaluation()?.evalSync("location.hash")
        #expect(finalHash == "#/sessions/s1")
    }

    // 空实现 provider（渲染测试不需要数据）。
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
}

/// 泵主 RunLoop（测试进程无 AppKit 事件循环，SwiftUI 视图更新依赖它被驱动；
/// CFRunLoopRunInMode 在 async 上下文不可用，包一层同步函数）。
private func pumpMainRunLoop(seconds: TimeInterval = 0.05) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}
