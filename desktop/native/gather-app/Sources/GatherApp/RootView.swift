// desktop/native/gather-app/Sources/GatherApp/RootView.swift
// Phase 3.1 宿主导航壳：逐页替换的最小机制（Strangler Fig）。
// TS 源: desktop/src/renderer/components/Layout/Sidebar.tsx（导航项）
//       + App.tsx（路由表）。
//
// 路由映射：
//   工作台（/）                → SwiftUI DashboardView（本阶段已迁移）
//   全局图库（/library）       → WKWebView（残余 React，路由由 React 内部管理）
//   人脸库（/persons）         → WKWebView
//   任务中心（/jobs）          → WKWebView
//   设置（/settings）          → WKWebView
//   工作区详情（/sessions/:id）→ WKWebView（Dashboard 卡片「进入」跳转）
// 「当前会话」项为 SessionDetail 内部语义（React sessionStore 持有），
// SwiftUI 壳不复制。
//
// WebViewHost 常驻 ZStack（opacity 显隐切换），WKWebView 状态跨页保留；
// 切到 Web 页时经 WebViewHost.navigate 驱动 React HashRouter。
import SwiftUI
import AppKit
import GatherCore

/// 导航状态模型（独立于视图，可单测）。
@MainActor
@Observable
final class RootNavigation {
    /// 未迁移页面（Web 侧路由，React HashRouter 路径）。
    enum WebPage: String, CaseIterable, Identifiable {
        case library
        case persons
        case jobs
        case settings

        var id: String { rawValue }

        /// 侧栏文案（TS nav.* 中文键值）。
        var title: String {
            switch self {
            case .library: return "全局图库"
            case .persons: return "人脸库"
            case .jobs: return "任务中心"
            case .settings: return "设置"
            }
        }

        /// React HashRouter 路径（不含 '#'）。
        var route: String { "/" + rawValue }
    }

    enum Destination: Equatable {
        case dashboard
        case web(WebPage)
        case session(String)
    }

    private(set) var destination: Destination = .dashboard

    /// 当前高亮的侧栏页（工作区详情页无对应项）。
    var selectedWebPage: WebPage? {
        if case .web(let page) = destination { return page }
        return nil
    }

    /// 是否显示 SwiftUI Dashboard。
    var isDashboard: Bool {
        if case .dashboard = destination { return true }
        return false
    }

    /// WebView 目标路由（location.hash = "#<route>"）。
    var webRoute: String {
        switch destination {
        case .dashboard: return "/"
        case .web(let page): return page.route
        case .session(let id): return "/sessions/\(id)"
        }
    }

    func selectDashboard() {
        destination = .dashboard
    }

    func selectWeb(_ page: WebPage) {
        destination = .web(page)
    }

    func openSession(_ sessionId: String) {
        destination = .session(sessionId)
    }
}

struct RootView: View {
    let host: WebViewHost
    let provider: DashboardDataProvider

    @State private var navigation: RootNavigation
    @State private var viewModel: DashboardViewModel

    @MainActor
    init(host: WebViewHost, provider: DashboardDataProvider, navigation: RootNavigation? = nil) {
        self.host = host
        self.provider = provider
        _navigation = State(initialValue: navigation ?? RootNavigation())
        _viewModel = State(initialValue: DashboardViewModel(provider: provider))
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(navigation: navigation)
            ZStack {
                DashboardView(viewModel: viewModel) { session in
                    navigation.openSession(session.id)
                }
                .opacity(navigation.isDashboard ? 1 : 0)
                .allowsHitTesting(navigation.isDashboard)

                WebViewContainer(host: host)
                    .opacity(navigation.isDashboard ? 0 : 1)
                    .allowsHitTesting(!navigation.isDashboard)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .onChange(of: navigation.destination) { _, _ in
            // 切到 Web 托管页时把 React HashRouter 带到目标路由。
            if !navigation.isDashboard {
                host.navigate(to: navigation.webRoute)
            }
        }
    }
}

// MARK: - 侧栏（TS Sidebar 导航项）

private struct SidebarView: View {
    @Bindable var navigation: RootNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌（TS Sidebar brand：G 徽标 + Gather）。
            HStack(spacing: 8) {
                Text("G")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
                Text("Gather")
                    .font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(spacing: 2) {
                sidebarButton(
                    title: "工作台",
                    systemImage: "house",
                    isActive: navigation.isDashboard
                ) {
                    navigation.selectDashboard()
                }
                ForEach(RootNavigation.WebPage.allCases) { page in
                    sidebarButton(
                        title: page.title,
                        systemImage: Self.icon(for: page),
                        isActive: navigation.selectedWebPage == page
                    ) {
                        navigation.selectWeb(page)
                    }
                }
            }

            Spacer()

            // 底部导航（TS Sidebar bottomNav：设置）。
            sidebarButton(
                title: "设置",
                systemImage: "gearshape",
                isActive: navigation.selectedWebPage == .settings
            ) {
                navigation.selectWeb(.settings)
            }
            .padding(.bottom, 10)
        }
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sidebarButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private static func icon(for page: RootNavigation.WebPage) -> String {
        switch page {
        case .library: return "books.vertical"
        case .persons: return "person.2"
        case .jobs: return "clock"
        case .settings: return "gearshape"
        }
    }
}

/// 残余 React 页容器（WebViewHost 单实例常驻，ZStack 显隐切换保留状态）。
private struct WebViewContainer: NSViewControllerRepresentable {
    let host: WebViewHost

    func makeNSViewController(context: Context) -> WebViewHost {
        host
    }

    func updateNSViewController(_ nsViewController: WebViewHost, context: Context) {}
}
