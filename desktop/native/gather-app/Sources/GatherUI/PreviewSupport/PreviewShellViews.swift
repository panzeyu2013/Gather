#if DEBUG
import SwiftUI
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewShellViews.swift
// Cut 4 / 4c-1：Root / Shell / SessionTab 三个"壳层"预览（只在 DEBUG 编译）。
//
// 为什么 Root 不是 RootView 本身：RootView 已按 D-017 迁到 GatherHost，
// 依赖 AppBootstrap.SceneState/AppServices（16 个 API + DB），而 GatherUI 不能
// import Host。这里用 RootShellDependencies（§4.6）组装一个**结构等价的最小外壳**：
// NavigationSplitView + 侧栏 + 详情，详情页复用真实页面与同一份 Preview API 依赖。
// 它验证的是"依赖包形状 + 页面可独立装配"，不是 RootView 的逐像素还原。
//
// Shell 预览展示所有会话页共用的 chrome（SessionPageTabStrip）+ 占位内容；
// SessionTab 预览验证 SessionTabHost 从 environment 取 workspace 后分发到页面。

// MARK: - Root 外壳

struct PreviewRootShell: View {
    let deps: RootShellDependencies
    let store: LanguageStore

    @State private var selection = "dashboard"
    @State private var dashboard: DashboardViewModel
    @State private var library: LibraryViewModel
    @State private var persons: PersonsViewModel

    private var l10n: L10n { store.l10n }

    init(deps: RootShellDependencies, store: LanguageStore) {
        self.deps = deps
        self.store = store
        let dashboard = DashboardViewModel(provider: deps.dashboardProvider)
        dashboard.captureOne = deps.captureOne
        dashboard.isVisible = false
        _dashboard = State(initialValue: dashboard)
        _library = State(initialValue: LibraryViewModel(provider: deps.libraryProvider, debounceDelay: .seconds(3600)))
        _persons = State(initialValue: PersonsViewModel(person: deps.person))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(l10n("工作台"), systemImage: "rectangle.grid.2x2")
                    .tag("dashboard")
                Section(l10n("当前会话")) {
                    Label(PreviewData.sessionOneName, systemImage: "camera")
                        .tag("session")
                }
                Label(l10n("全局图库"), systemImage: "photo.on.rectangle")
                    .tag("library")
                Label(l10n("人脸库"), systemImage: "person.2")
                    .tag("persons")
                Label(l10n("设置"), systemImage: "gearshape")
                    .tag("settings")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.languageStore, store)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case "session":
            sessionDetail
        case "library":
            LibraryView(
                viewModel: library,
                onOpenSession: { _ in },
                onOpenPhoto: { _, _ in }
            )
        case "persons":
            PersonsView(
                viewModel: persons,
                onReview: { _ in },
                onReviewFaceRole: { _, _ in },
                onOpenPhoto: { _, _ in },
                currentSessionId: PreviewData.sessionOneId
            )
        case "settings":
            SettingsView(
                session: deps.session,
                settings: deps.settings,
                culling: deps.culling,
                captureOne: deps.captureOne,
                languageStore: store
            )
        default:
            DashboardView(
                viewModel: dashboard,
                newWorkspaceRequest: .constant(nil as NewWorkspaceRequest?)
            )
        }
    }

    private var sessionDetail: some View {
        let workspace = PreviewFactory.workspace()
        return SessionTabHost(
            tab: .control,
            culling: deps.culling,
            router: PreviewFactory.router(),
            onOpenPhoto: { _ in }
        )
        .environment(\.sessionWorkspace, workspace)
        .environment(\.languageStore, store)
        .navigationTitle(PreviewData.sessionOneName)
    }
}

// MARK: - 会话页 chrome

struct PreviewShellChrome: View {
    let store: LanguageStore

    var body: some View {
        VStack(spacing: 0) {
            SessionPageTabStrip(
                selection: .browse,
                onBrowse: {},
                onSimilarity: {},
                onSelectTab: { _ in }
            )
            Divider()
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Shared session chrome")
                    .font(.title3.weight(.semibold))
                Text("Browse / Similarity / Control / Face / Duplicates / Culling / Export")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GatherTheme.windowBackground)
        .environment(\.languageStore, store)
    }
}

// MARK: - 三个壳层 Preview

#Preview("SessionTab · 会话页宿主") {
    PreviewFactory.sessionTabPage()
}

#Preview("Root · 外壳与侧栏") {
    PreviewFactory.rootPage()
}

#Preview("Shell · 会话页 Chrome") {
    PreviewFactory.shellPage()
}
#endif
