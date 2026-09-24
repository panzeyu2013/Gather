// desktop/native/gather-app/Sources/GatherApp/Shell/AppShellView.swift
// R6 步骤一：UI Shell 骨架（只新建 app 侧文件；不改 Host 路由层文件，不碰 core）。
// R6 步骤二：接入选中的特性视图——左侧 Feature 列表选择，右侧按所选 case
// 渲染；设置与人脸库两个 case 指向真实视图，其余仍为占位 Text。依赖由 init
// 以可选形式注入，壳层不自行构造路由或数据层。
// R6 步骤三：工作台与全局图库也指向真实视图（DashboardView / LibraryView），
// 数据提供者同样以可选参数注入；未注入（nil）或未接线的 case 一律回退占位。
// R6 步骤四：5 个工作区特性指向会话宿主视图（SessionShellView），会话与页签由
// 壳层导航状态承载；未选中会话或依赖未注入时回退占位。
// R6 步骤五：浏览与相似度两个 case 也接真实视图（GalleryView /
// SimilarityView）；两者为会话级页面，按壳层导航状态的当前会话构造视图模型，
// 会话切换时重建、离开页面时停轮询。本视图已作为根视图在 GatherApp.swift
// 装配（会话出口接到壳层导航状态的 openSession）。
//
// 11 个特性全部接线：依赖未注入或未选中会话时回退占位，壳层不自行构造
// 路由或数据层。
import SwiftUI
import GatherCore

/// 壳层根视图：左侧列出 app 目录中的 11 个特性，右侧渲染所选 Case。
/// 「工作台/全局图库/设置/人脸库」接真实视图；5 个工作区特性按当前会话接
/// 会话宿主；浏览/相似度按当前会话接各自页面（未选中会话或依赖缺失时占位）。
public struct AppShellView: View {
    /// app 目录枚举出的 11 个特性（顺序即建议的 R6 迁移顺序）。
    public enum Feature: String, CaseIterable, Identifiable, Sendable {
        // Sources/GatherApp/Dashboard -> 已接入 DashboardView。
        case dashboard
        // Sources/GatherApp/Library -> 已接入 LibraryView。
        case library
        // Sources/GatherApp/Gallery -> 已接入 GalleryView。
        case gallery
        // Sources/GatherApp/Similarity -> 已接入 SimilarityView。
        case similarity
        // Sources/GatherApp/Persons -> 将替换为 PersonsView。
        case persons
        // Settings -> 将替换为 SettingsView。
        case settings
        // ControlCenter -> 将替换为 SessionControlView（工作区页签）。
        case controlCenter
        // FaceKeywording -> 将替换为 FaceKeywordingView（工作区页签）。
        case faceKeywording
        // Duplicates -> 将替换为 DuplicatesView（工作区页签）。
        case duplicates
        // Culling -> 将替换为 CullingView（工作区页签）。
        case culling
        // Export -> 将替换为 ExportView（工作区页签）。
        case export

        public var id: String { rawValue }

        /// 特性目录名（app 目录名，与 Package.swift 的 sources 一致）。
        public var directoryName: String {
            switch self {
            case .dashboard: return "Sources/GatherApp/Dashboard"
            case .library: return "Sources/GatherApp/Library"
            case .gallery: return "Sources/GatherApp/Gallery"
            case .similarity: return "Sources/GatherApp/Similarity"
            case .persons: return "Sources/GatherApp/Persons"
            case .settings: return "Settings"
            case .controlCenter: return "ControlCenter"
            case .faceKeywording: return "FaceKeywording"
            case .duplicates: return "Duplicates"
            case .culling: return "Culling"
            case .export: return "Export"
            }
        }

        /// 将替换本占位项的现有特性视图名（骨架期仅展示，不实例化）。
        public var replacementViewName: String {
            switch self {
            case .dashboard: return "DashboardView"
            case .library: return "LibraryView"
            case .gallery: return "GalleryView"
            case .similarity: return "SimilarityView"
            case .persons: return "PersonsView"
            case .settings: return "SettingsView"
            case .controlCenter: return "SessionControlView"
            case .faceKeywording: return "FaceKeywordingView"
            case .duplicates: return "DuplicatesView"
            case .culling: return "CullingView"
            case .export: return "ExportView"
            }
        }

        /// 壳层显示名：沿用侧栏/页签既有文案，不新造术语。
        public var displayName: String {
            switch self {
            case .dashboard: return GatherLocalization.l("工作台")
            case .library: return GatherLocalization.l("全局图库")
            case .gallery: return GatherLocalization.l("浏览")
            case .similarity: return GatherLocalization.l("相似度")
            case .persons: return GatherLocalization.l("人脸库")
            case .settings: return GatherLocalization.l("设置")
            case .controlCenter: return GatherLocalization.l("控制中心")
            case .faceKeywording: return GatherLocalization.l("人脸")
            case .duplicates: return GatherLocalization.l("重复")
            case .culling: return GatherLocalization.l("挑片")
            case .export: return GatherLocalization.l("导出")
            }
        }

        /// 工作区页签映射：5 个工作区特性各对应一个页签，其余特性返回 nil。
        var sessionTab: SessionTab? {
            switch self {
            case .controlCenter: return .control
            case .faceKeywording: return .faceKw
            case .duplicates: return .duplicates
            case .culling: return .culling
            case .export: return .export
            default: return nil
            }
        }

        /// 反向映射：页签 → 侧栏特性（页签切换时保持侧栏高亮一致）。
        static func forTab(_ tab: SessionTab) -> Feature {
            switch tab {
            case .control: return .controlCenter
            case .faceKw: return .faceKeywording
            case .duplicates: return .duplicates
            case .culling: return .culling
            case .export: return .export
            }
        }
    }

    /// 类型化命令面（可选：未注入时依赖命令的页面回退占位）。
    private let commands: CommandSurface?
    /// 人脸库需要的数据提供者（可选：未注入时该特性回退占位）。
    private let personsProvider: PersonsDataProvider?
    /// 全局图库需要的数据提供者（可选：未注入时该特性回退占位）。
    private let libraryProvider: LibraryDataProvider?
    /// Capture One 桥（注入给会话级视图模型；未注入时用空实现）。
    private let captureOneBridge: CaptureOneBridge?
    /// 壳层导航状态：当前会话与当前页签；未注入时内部新建（无选中会话）。
    private let navigation: AppNavigationState
    /// 打开工作区回调：工作台与全局图库共用，壳层只透传不解释。
    private let onOpenSession: (String) -> Void
    /// 壳层职责协调器：菜单通知、窗口标题、拖放、语言版本、会话级视图模型。
    @State private var coordinator: ShellCoordinator
    /// 全局图库视图模型：仅在注入数据提供者时创建，壳层不自行取数。
    @State private var libraryViewModel: LibraryViewModel?
    /// 人脸库视图模型：仅在注入数据提供者时创建，壳层不自行取数。
    @State private var personsViewModel: PersonsViewModel?

    /// 依赖经 init 以可选形式传入；全部参数都有默认值，既有调用点不受影响。
    /// 注：工作台的数据提供者协议为模块内可见，public init 无法引用内部类型，
    /// 故本 init 与结构体保持同模块可见；调用点在 app 目标内部（GatherApp
    /// 装配处传入 provider 与壳层导航状态）。
    @MainActor
    init(
        commands: CommandSurface? = nil,
        personsProvider: PersonsDataProvider? = nil,
        dashboardProvider: DashboardDataProvider? = nil,
        libraryProvider: LibraryDataProvider? = nil,
        galleryProvider: GalleryDataProvider? = nil,
        similarityProvider: SimilarityDataProvider? = nil,
        captureOneBridge: CaptureOneBridge? = nil,
        navigation: AppNavigationState? = nil,
        onOpenSession: @escaping (String) -> Void = { _ in }
    ) {
        self.commands = commands
        self.personsProvider = personsProvider
        self.libraryProvider = libraryProvider
        self.captureOneBridge = captureOneBridge
        let navigation = navigation ?? AppNavigationState()
        self.navigation = navigation
        self.onOpenSession = onOpenSession
        // 壳层职责（菜单/通知/标题/拖放/语言版本/会话级视图模型）集中在协调器。
        _coordinator = State(initialValue: ShellCoordinator(
            navigation: navigation,
            dashboardProvider: dashboardProvider,
            galleryProvider: galleryProvider,
            isGalleryWired: commands != nil,
            similarityProvider: similarityProvider,
            captureOneBridge: captureOneBridge
        ))
        if let libraryProvider {
            _libraryViewModel = State(initialValue: LibraryViewModel(provider: libraryProvider))
        }
        if let personsProvider {
            _personsViewModel = State(initialValue: PersonsViewModel(provider: personsProvider))
        }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if coordinator.isSidebarVisible {
                featureList
                Divider()
            }
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 480, alignment: .topLeading)
        // 壳级职责（菜单/通知/标题/拖放/语言版本）随壳层常驻。
        .navigationTitle(coordinator.windowTitle)
        .id(coordinator.languageVersion)
        .overlay(alignment: .topTrailing) {
            ToastView()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = ShellCoordinator.firstDirectoryURL(in: urls) else { return false }
            NotificationCenter.default.post(name: GatherAppNotification.menuImportFolder, object: url)
            return true
        }
        .task {
            coordinator.startObserving()
            await coordinator.refreshWindowTitle()
        }
        .onDisappear { coordinator.stopObserving() }
        // 装配处选中会话后：侧栏自动落到当前工作区页签（未选中时保持原选择）。
        .onChange(of: navigation.currentSessionId) { _, _ in
            coordinator.navigationSessionDidChange()
        }
        // 外部（装配处/页签栏）切换页签时同步侧栏高亮。
        .onChange(of: navigation.selectedTab) { _, _ in
            coordinator.navigationTabDidChange()
        }
    }

    /// 左侧特性列表：点击切换当前特性，已接真实视图的项在右侧直接打开。
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gather")
                .font(.title2.weight(.semibold))
            Text(GatherLocalization.l("壳层骨架：11 个特性，已接真实视图的项可直接打开"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Feature.allCases) { feature in
                        featureRow(feature)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    private func featureRow(_ feature: Feature) -> some View {
        let isSelected = coordinator.selectedFeature == feature
        return Button {
            coordinator.selectFeature(feature)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(feature.displayName)
                    .font(.body.weight(isSelected ? .semibold : .medium))
                Text(feature.directoryName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(isWired(feature) ? feature.replacementViewName : "-")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 是否已接真实视图：11 个特性全部接线，依赖齐备（会话级另需已选中会话）。
    private func isWired(_ feature: Feature) -> Bool {
        switch feature {
        case .dashboard: return coordinator.dashboardViewModel != nil
        case .library: return libraryViewModel != nil
        case .gallery: return coordinator.galleryViewModel != nil && commands != nil
        case .similarity: return coordinator.similarityViewModel != nil && commands != nil
        case .settings: return commands != nil
        case .persons: return personsViewModel != nil
        case .controlCenter, .faceKeywording, .duplicates, .culling, .export:
            return navigation.currentSessionId != nil && commands != nil
        }
    }

    /// 右侧详情：工作台常驻（其菜单/进度订阅随壳层存活，隐藏期间停轮询），
    /// 其余特性按当前选择 switch；浏览/相似度按当前会话构造的视图模型渲染，
    /// 会话级页面依赖缺失或未选中会话时回退占位，保持可编译。
    @ViewBuilder
    private var detailView: some View {
        ZStack {
            if let dashboardViewModel = coordinator.dashboardViewModel {
                DashboardView(viewModel: dashboardViewModel, onOpenSession: onOpenSession)
                    .opacity(coordinator.selectedFeature == .dashboard ? 1 : 0)
                    .allowsHitTesting(coordinator.selectedFeature == .dashboard)
                    .accessibilityHidden(coordinator.selectedFeature != .dashboard)
            }
            if coordinator.selectedFeature != .dashboard {
                featureDetail(for: coordinator.selectedFeature)
            }
        }
    }

    /// 非工作台特性的详情：按特性渲染对应真实视图（依赖缺失回退占位）。
    @ViewBuilder
    private func featureDetail(for feature: Feature) -> some View {
        switch feature {
        case .dashboard:
            // 工作台由 detailView 常驻渲染，这里不重复。
            EmptyView()
        case .library:
            if let libraryViewModel {
                LibraryView(viewModel: libraryViewModel, onOpenSession: onOpenSession)
            } else {
                placeholderView(for: feature)
            }
        case .settings:
            if let commands {
                SettingsView(commands: commands)
            } else {
                placeholderView(for: feature)
            }
        case .persons:
            if let personsViewModel {
                PersonsView(viewModel: personsViewModel)
            } else {
                placeholderView(for: feature)
            }
        case .controlCenter, .faceKeywording, .duplicates, .culling, .export:
            if let sessionId = navigation.currentSessionId, let tab = feature.sessionTab {
                SessionShellView(
                    sessionId: sessionId,
                    tab: tab,
                    commands: commands,
                    onBack: { coordinator.openGalleryFeature(sessionId) },
                    onOpenTab: { coordinator.openSessionTab($0, $1) },
                    onOpenSimilarity: { coordinator.openSimilarityFeature($0) },
                    onOpenGallery: { coordinator.openGalleryFeature($0) },
                    onOpenSettings: { coordinator.openSettingsFeature() }
                )
                // 会话或页签变化时强制造型重建：页签内状态以 init 时的会话初始化。
                .id("session-shell-\(sessionId)-\(tab.rawValue)")
            } else {
                sessionPlaceholder(for: feature)
            }
        case .gallery:
            if let sessionId = navigation.currentSessionId,
               let galleryViewModel = coordinator.galleryViewModel,
               let commands {
                GalleryView(
                    viewModel: galleryViewModel,
                    commands: commands,
                    onBack: { coordinator.openDashboardFeature() },
                    onOpenSimilarity: { coordinator.openSimilarityFeature($0) },
                    onOpenTab: { coordinator.openSessionTab($0, $1) },
                    onOpenSettings: { coordinator.openSettingsFeature() }
                )
                // 会话变化时强制造型重建：视图模型以 init 时的会话初始化。
                .id("gallery-\(sessionId)")
                // 本壳按特性切换视图：离开浏览页停索引状态轮询。
                .onDisappear { galleryViewModel.stopIndexStatusPolling() }
            } else {
                sessionPlaceholder(for: feature)
            }
        case .similarity:
            if let sessionId = navigation.currentSessionId,
               let similarityViewModel = coordinator.similarityViewModel,
               let commands {
                SimilarityView(
                    viewModel: similarityViewModel,
                    commands: commands,
                    onBack: { coordinator.openGalleryFeature(sessionId) },
                    onOpenGallery: { coordinator.openGalleryFeature($0) },
                    onOpenTab: { coordinator.openSessionTab($0, $1) },
                    onOpenSettings: { coordinator.openSettingsFeature() }
                )
                // 会话变化时强制造型重建：视图模型以 init 时的会话初始化。
                .id("similarity-\(sessionId)")
                // 本壳按特性切换视图：离开相似度页停进度/结果两条轮询。
                .onDisappear {
                    similarityViewModel.stopProgressPolling()
                    similarityViewModel.stopResultPolling()
                }
            } else {
                sessionPlaceholder(for: feature)
            }
        }
    }

    /// 会话未选中时的占位：提示先打开会话，避免页签视图拿到空 id。
    private func sessionPlaceholder(for feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.displayName)
                .font(.title3.weight(.semibold))
            Text(feature.replacementViewName)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Text(GatherLocalization.l("未选中会话：请先在工作台或全局图库打开一个会话。"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private func placeholderView(for feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.displayName)
                .font(.title3.weight(.semibold))
            Text(String(format: GatherLocalization.l("占位：待接入 %@"), feature.replacementViewName))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}
