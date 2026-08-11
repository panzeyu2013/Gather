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
        case jobs
        case settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .persons: return "人脸库"
            case .jobs: return "任务中心"
            case .settings: return "设置"
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
    var isJobs: Bool {
        if case .page(.jobs) = destination { return true }
        return false
    }
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
        _viewModel = State(initialValue: DashboardViewModel(provider: provider))
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

                if let personsViewModel {
                    PersonsView(
                        viewModel: personsViewModel,
                        onReview: { sessionId in navigation.openSessionTab(sessionId, .faceKw) }
                    )
                        .opacity(navigation.isPersons ? 1 : 0)
                        .allowsHitTesting(navigation.isPersons)
                }

                if navigation.isJobs {
                    JobsView(jobService: router.jobService)
                }

                if navigation.isSettings {
                    SettingsView(router: router)
                }

                if let galleryViewModel {
                    GalleryView(
                        viewModel: galleryViewModel,
                        onBack: { navigation.selectDashboard() },
                        onOpenSimilarity: { navigation.openSimilarity($0) },
                        onOpenTab: { navigation.openSessionTab($0, $1) }
                    )
                    .opacity(navigation.gallerySessionId != nil ? 1 : 0)
                    .allowsHitTesting(navigation.gallerySessionId != nil)
                }

                if let similarityViewModel {
                    SimilarityView(
                        viewModel: similarityViewModel,
                        onBack: {
                            if let sessionId = navigation.similaritySessionId {
                                navigation.openGallery(sessionId)
                            } else {
                                navigation.selectDashboard()
                            }
                        }
                    )
                    .opacity(navigation.similaritySessionId != nil ? 1 : 0)
                    .allowsHitTesting(navigation.similaritySessionId != nil)
                }

                sessionTabView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuToggleSidebar)) { _ in
            sidebarVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherAppNotification.menuNewWorkspace)) { _ in
            navigation.selectDashboard()
        }
        .onChange(of: navigation.destination) { _, destination in
            if case .gallery(let id) = destination,
               galleryViewModel?.sessionId != id {
                galleryViewModel = GalleryViewModel(sessionId: id, provider: galleryProvider)
            }
            if case .similarity(let id) = destination,
                similarityViewModel?.sessionId != id {
                similarityViewModel = SimilarityViewModel(
                    sessionId: id,
                    provider: similarityProvider,
                    captureOne: CaptureOneBridge(router: router)
                )
            }
        }
    }

    @ViewBuilder
    private var sessionTabView: some View {
        if let destination = navigation.sessionTabDestination {
            switch destination.tab {
            case .control:
                SessionControlView(
                    sessionId: destination.sessionId,
                    router: router,
                    onBack: { navigation.openGallery(destination.sessionId) },
                    onOpenSimilarity: { navigation.openSimilarity($0) },
                    onOpenTab: { sessionId, tab in navigation.openSessionTab(sessionId, tab) }
                )
            case .faceKw:
                FaceKeywordingView(
                    sessionId: destination.sessionId,
                    router: router,
                    onBack: { navigation.openGallery(destination.sessionId) }
                )
            case .duplicates:
                DuplicatesView(
                    sessionId: destination.sessionId,
                    router: router,
                    onBack: { navigation.openGallery(destination.sessionId) }
                )
            case .culling:
                CullingView(
                    sessionId: destination.sessionId,
                    router: router,
                    onBack: { navigation.openGallery(destination.sessionId) }
                )
            case .export:
                ExportView(
                    sessionId: destination.sessionId,
                    router: router,
                    onBack: { navigation.openGallery(destination.sessionId) }
                )
            }
        }
    }
}

private struct SidebarView: View {
    @Bindable var navigation: RootNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("G")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
                Text("Gather").font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(spacing: 2) {
                sidebarButton(title: "工作台", systemImage: "house", isActive: navigation.isDashboard) {
                    navigation.selectDashboard()
                }
                sidebarButton(title: "全局图库", systemImage: "books.vertical", isActive: navigation.isLibrary) {
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
                Image(systemName: systemImage).frame(width: 18)
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
