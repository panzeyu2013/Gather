// desktop/native/gather-app/Sources/GatherApp/RootView.swift
// Phase 3.1 宿主导航壳：逐页替换的最小机制（Strangler Fig），3.2/3.3 扩展。
// TS 源: desktop/src/renderer/components/Layout/Sidebar.tsx（导航项）
//       + App.tsx（路由表）+ pages/SessionDetail/index.tsx（工作区页签）。
//
// 路由映射：
//   工作台（/）                    → SwiftUI DashboardView（3.1 已迁移）
//   全局图库（/library）           → SwiftUI LibraryView（3.2 已迁移）
//   人脸库（/persons）             → WKWebView（残余 React，路由由 React 内部管理）
//   任务中心（/jobs）              → WKWebView
//   设置（/settings）              → WKWebView
//   工作区详情（/sessions/:id/gallery）→ SwiftUI GalleryView（3.2 已迁移）
//   工作区相似度（/sessions/:id/similarity）→ SwiftUI SimilarityView（3.3 已迁移）
//   工作区其余页签（face-kw/duplicates/culling/export）→ WKWebView
// 「当前会话」项为 SessionDetail 内部语义（React sessionStore 持有），
// SwiftUI 壳不复制。
//
// WebViewHost 常驻 ZStack（opacity 显隐切换），WKWebView 状态跨页保留；
// 切到残余 Web 页时经 WebViewHost.navigate 驱动 React HashRouter。
import SwiftUI
import AppKit
import GatherCore

/// 导航状态模型（独立于视图，可单测）。
@MainActor
@Observable
final class RootNavigation {
    /// 未迁移页面（Web 侧路由，React HashRouter 路径）。
    enum WebPage: String, CaseIterable, Identifiable {
        case persons
        case jobs
        case settings

        var id: String { rawValue }

        /// 侧栏文案（TS nav.* 中文键值）。
        var title: String {
            switch self {
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
        case library
        case gallery(String)
        case similarity(String)
        /// 工作区残余页签（face-kw/duplicates/culling/export → WKWebView）。
        case sessionTab(String, SessionWebTab)
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

    /// 是否显示 SwiftUI 全局图库。
    var isLibrary: Bool {
        if case .library = destination { return true }
        return false
    }

    /// 当前工作区详情（SwiftUI Gallery；nil 时隐藏）。
    var gallerySessionId: String? {
        if case .gallery(let id) = destination { return id }
        return nil
    }

    /// 当前工作区相似度（SwiftUI Similarity；nil 时隐藏）。
    var similaritySessionId: String? {
        if case .similarity(let id) = destination { return id }
        return nil
    }

    /// 当前工作区残余页签（WKWebView；nil 时隐藏）。
    var webTabDestination: (sessionId: String, tab: SessionWebTab)? {
        if case .sessionTab(let id, let tab) = destination { return (id, tab) }
        return nil
    }

    /// 需要驱动 WebViewHost 的残余 React 路由（location.hash = "#<route>"）。
    var webHostRoute: String? {
        switch destination {
        case .web(let page): return page.route
        case .sessionTab(let id, let tab): return "/sessions/\(id)/\(tab.rawValue)"
        case .dashboard, .library, .gallery, .similarity: return nil
        }
    }

    func selectDashboard() {
        destination = .dashboard
    }

    func selectLibrary() {
        destination = .library
    }

    func selectWeb(_ page: WebPage) {
        destination = .web(page)
    }

    /// 打开工作区详情（SwiftUI Gallery，对齐 Dashboard 卡片「进入」）。
    func openSession(_ sessionId: String) {
        destination = .gallery(sessionId)
    }

    /// 打开工作区相似度页（SwiftUI，对齐 Gallery 页签「相似度」）。
    func openSimilarity(_ sessionId: String) {
        destination = .similarity(sessionId)
    }

    /// 打开工作区残余页签（WKWebView）。
    func openSessionTab(_ sessionId: String, _ tab: SessionWebTab) {
        destination = .sessionTab(sessionId, tab)
    }
}

struct RootView: View {
    let host: WebViewHost
    let provider: DashboardDataProvider
    let libraryProvider: LibraryDataProvider
    let galleryProvider: GalleryDataProvider
    let similarityProvider: SimilarityDataProvider

    @State private var navigation: RootNavigation
    @State private var viewModel: DashboardViewModel
    @State private var libraryViewModel: LibraryViewModel
    /// 会话级视图模型（进入时创建；TS 页签切换同样 remount）。
    @State private var galleryViewModel: GalleryViewModel?
    @State private var similarityViewModel: SimilarityViewModel?

    @MainActor
    init(
        host: WebViewHost,
        provider: DashboardDataProvider,
        libraryProvider: LibraryDataProvider,
        galleryProvider: GalleryDataProvider,
        similarityProvider: SimilarityDataProvider,
        navigation: RootNavigation? = nil
    ) {
        self.host = host
        self.provider = provider
        self.libraryProvider = libraryProvider
        self.galleryProvider = galleryProvider
        self.similarityProvider = similarityProvider
        let navigation = navigation ?? RootNavigation()
        _navigation = State(initialValue: navigation)
        _viewModel = State(initialValue: DashboardViewModel(provider: provider))
        _libraryViewModel = State(initialValue: LibraryViewModel(provider: libraryProvider))
        // 测试可直接注入已定位到工作区的导航模型。
        if case .gallery(let id) = navigation.destination {
            _galleryViewModel = State(initialValue: GalleryViewModel(sessionId: id, provider: galleryProvider))
        }
        if case .similarity(let id) = navigation.destination {
            _similarityViewModel = State(initialValue: SimilarityViewModel(sessionId: id, provider: similarityProvider))
        }
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

                LibraryView(viewModel: libraryViewModel) { sessionId in
                    navigation.openSession(sessionId)
                }
                .opacity(navigation.isLibrary ? 1 : 0)
                .allowsHitTesting(navigation.isLibrary)

                if let viewModel = galleryViewModel {
                    GalleryView(
                        viewModel: viewModel,
                        onBack: { navigation.selectDashboard() },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenWebTab: { navigation.openSessionTab($0, $1) }
                    )
                    .opacity(navigation.gallerySessionId != nil ? 1 : 0)
                    .allowsHitTesting(navigation.gallerySessionId != nil)
                }

                if let viewModel = similarityViewModel {
                    SimilarityView(
                        viewModel: viewModel,
                        onBack: {
                            if let sessionId = navigation.similaritySessionId {
                                navigation.openSession(sessionId)
                            } else {
                                navigation.selectDashboard()
                            }
                        }
                    )
                    .opacity(navigation.similaritySessionId != nil ? 1 : 0)
                    .allowsHitTesting(navigation.similaritySessionId != nil)
                }

                WebViewContainer(host: host)
                    .opacity(navigation.webHostRoute != nil ? 1 : 0)
                    .allowsHitTesting(navigation.webHostRoute != nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .onChange(of: navigation.destination) { _, _ in
            // 进入会话级页面时装配对应视图模型（对齐 TS 页签 remount）。
            if case .gallery(let id) = navigation.destination {
                if galleryViewModel?.sessionId != id {
                    galleryViewModel = GalleryViewModel(sessionId: id, provider: galleryProvider)
                }
            }
            if case .similarity(let id) = navigation.destination {
                if similarityViewModel?.sessionId != id {
                    similarityViewModel = SimilarityViewModel(sessionId: id, provider: similarityProvider)
                }
            }
            // 切到残余 Web 托管页时把 React HashRouter 带到目标路由。
            if let route = navigation.webHostRoute {
                host.navigate(to: route)
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
                // 全局图库已迁移 SwiftUI（TS /library 路由不再由 Web 托管）。
                sidebarButton(
                    title: "全局图库",
                    systemImage: "books.vertical",
                    isActive: navigation.isLibrary
                ) {
                    navigation.selectLibrary()
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
