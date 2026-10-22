#if DEBUG
import Foundation
import SwiftUI
import GatherProtocol

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFactory.swift
// Cut 4 / 4c-1：14 个 #Preview 的"最小依赖装配"（只在 DEBUG 编译）。
//
// 每个页面只拿到它自己的 VM / workspace / 协议依赖，不构造 AppServices、不建
// AppRuntime、不落库。页面 .task 会走只读加载路径（PreviewAPIs 返回固定 fixture），
// 命令方法一律抛错，所以 Preview 是静态的、没有真实副作用。
//
// 页面全部放进 NavigationStack：这些页面用 .navigationTitle/.toolbar 承载窗口
// chrome，裸放时 Preview 看不到工具栏；这不是业务装配，只是画布容器。

@MainActor
enum PreviewFactory {
    static let canvasSize = CGSize(width: 1280, height: 860)

    /// 每个 Preview 入口都调一次：安装纯色缩略图（幂等，不读盘/不写盘）。
    static func prepare() {
        PreviewThumbnailSeeder.seedOnce()
    }

    static func languageStore(_ language: L10n.Language = .zhCN) -> LanguageStore {
        LanguageStore(language: language)
    }

    // MARK: - ViewModel

    static func dashboardViewModel() -> DashboardViewModel {
        let viewModel = DashboardViewModel(provider: PreviewDashboardProvider())
        viewModel.captureOne = PreviewCaptureOne()
        // Preview 不轮询：数据已经在首次 loadAll 后固定。
        viewModel.isVisible = false
        return viewModel
    }

    static func libraryViewModel() -> LibraryViewModel {
        LibraryViewModel(provider: PreviewLibraryProvider(), debounceDelay: .seconds(3600))
    }

    static func personsViewModel() -> PersonsViewModel {
        PersonsViewModel(person: PreviewPersonAPI())
    }

    static func cullingViewModel() -> CullingViewModel {
        CullingViewModel(
            sessionId: PreviewData.sessionOneId,
            culling: PreviewCullingAPI(),
            navigation: PreviewNavigationAPI(),
            metadata: PreviewMetadataAPI(),
            jobs: PreviewJobAPI(),
            quality: PreviewQualityAPI(),
            captureOne: PreviewCaptureOne()
        )
    }

    static func faceViewModel() -> FaceKeywordingViewModel {
        let viewModel = FaceKeywordingViewModel(
            sessionId: PreviewData.sessionOneId,
            face: PreviewFaceAPI(),
            jobs: PreviewJobAPI(),
            captureOne: PreviewCaptureOne()
        )
        // 审核步：fixture 同时含已绑定（Mika/Ren）与未绑定簇。
        viewModel.step = .review
        return viewModel
    }

    static func exportViewModel() -> ExportViewModel {
        let viewModel = ExportViewModel(
            sessionId: PreviewData.sessionOneId,
            export: PreviewExportAPI(),
            session: PreviewSessionAPI()
        )
        viewModel.destination = PreviewData.exportDestination
        viewModel.scope = .selected
        viewModel.namingPattern = "{session}_{seq}"
        viewModel.includeXmp = true
        return viewModel
    }

    static func duplicatesViewModel() -> DuplicatesViewModel {
        DuplicatesViewModel(
            sessionId: PreviewData.sessionOneId,
            duplicate: PreviewDuplicateAPI(),
            jobs: PreviewJobAPI()
        )
    }

    static func controlViewModel() -> SessionControlViewModel {
        SessionControlViewModel(
            sessionId: PreviewData.sessionOneId,
            session: PreviewSessionAPI(),
            culling: PreviewCullingAPI(),
            jobAPI: PreviewJobAPI(),
            qualityAPI: PreviewQualityAPI(),
            pollInterval: .seconds(3600),
            activePollInterval: .seconds(3600)
        )
    }

    static func galleryViewModel() -> GalleryViewModel {
        GalleryViewModel(
            sessionId: PreviewData.sessionOneId,
            provider: PreviewGalleryProvider(),
            job: PreviewJobAPI(),
            debounceDelay: .seconds(3600),
            activeStatusPollInterval: .seconds(3600),
            idleStatusPollInterval: .seconds(3600)
        )
    }

    static func similarityViewModel() -> SimilarityViewModel {
        SimilarityViewModel(
            sessionId: PreviewData.sessionOneId,
            similarity: PreviewSimilarityAPI(),
            jobs: PreviewJobAPI(),
            pollInterval: .seconds(3600),
            resultPollInterval: .seconds(3600),
            tierDebounceDelay: .seconds(3600),
            captureOne: PreviewCaptureOne()
        )
    }

    // MARK: - Workspace / dependencies

    static func workspace() -> SessionWorkspace {
        SessionWorkspace(
            sessionId: PreviewData.sessionOneId,
            culling: cullingViewModel(),
            duplicates: duplicatesViewModel(),
            export: exportViewModel(),
            face: faceViewModel(),
            control: controlViewModel(),
            gallery: galleryViewModel(),
            similarity: similarityViewModel(),
            sessionName: PreviewData.sessionOneName
        )
    }

    static func dependencies() -> RootShellDependencies {
        RootShellDependencies(
            session: PreviewSessionAPI(),
            job: PreviewJobAPI(),
            settings: PreviewSettingsAPI(),
            culling: PreviewCullingAPI(),
            navigation: PreviewNavigationAPI(),
            metadata: PreviewMetadataAPI(),
            quality: PreviewQualityAPI(),
            face: PreviewFaceAPI(),
            similarity: PreviewSimilarityAPI(),
            duplicate: PreviewDuplicateAPI(),
            export: PreviewExportAPI(),
            person: PreviewPersonAPI(),
            captureOne: PreviewCaptureOne(),
            libraryProvider: PreviewLibraryProvider(),
            galleryProvider: PreviewGalleryProvider(),
            dashboardProvider: PreviewDashboardProvider()
        )
    }

    static func router() -> SessionTabRouter {
        SessionTabRouter(
            onBack: {},
            onOpenSimilarity: { _ in },
            onOpenTab: { _, _ in },
            onOpenGallery: { _ in },
            onOpenSettings: {},
            onOpenExportTab: { _, _ in },
            onReviewXmpConflicts: { _ in },
            onReviewOfflinePhotos: { _ in },
            onReviewStaleAnalysis: { _ in }
        )
    }

    // MARK: - 页面（11 个页面 Preview 的入口）

    static func dashboardPage() -> some View {
        prepare()
        let store = languageStore()
        let viewModel = dashboardViewModel()
        return NavigationStack {
            DashboardView(
                viewModel: viewModel,
                newWorkspaceRequest: .constant(nil as NewWorkspaceRequest?)
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func galleryPage() -> some View {
        prepare()
        let store = languageStore()
        let workspace = workspace()
        return NavigationStack {
            GalleryView(
                workspace: workspace,
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenSettings: {}
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func libraryPage() -> some View {
        prepare()
        let store = languageStore()
        let viewModel = libraryViewModel()
        return NavigationStack {
            LibraryView(
                viewModel: viewModel,
                onOpenSession: { _ in },
                onOpenPhoto: { _, _ in }
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func cullingPage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            CullingView(
                workspace: workspace(),
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenGallery: { _ in },
                onOpenSettings: {}
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func facePage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            FaceKeywordingView(
                workspace: workspace(),
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenGallery: { _ in },
                onOpenSettings: {}
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func similarityPage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            SimilarityView(
                workspace: workspace(),
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenGallery: { _ in },
                onOpenTab: { _, _ in },
                onOpenSettings: {},
                onOpenPhoto: { _ in }
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func settingsPage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            SettingsView(
                session: PreviewSessionAPI(),
                settings: PreviewSettingsAPI(),
                culling: PreviewCullingAPI(),
                captureOne: PreviewCaptureOne(),
                languageStore: store
            )
        }
        .environment(\.languageStore, store)
        .frame(width: 980, height: 900)
    }

    static func exportPage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            ExportView(
                workspace: workspace(),
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenGallery: { _ in },
                onOpenSettings: {}
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func duplicatesPage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            DuplicatesView(
                workspace: workspace(),
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenGallery: { _ in },
                onOpenSettings: {},
                onOpenPhoto: { _ in }
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func personsPage() -> some View {
        prepare()
        let store = languageStore()
        let viewModel = personsViewModel()
        return NavigationStack {
            PersonsView(
                viewModel: viewModel,
                onReview: { _ in },
                onReviewFaceRole: { _, _ in },
                onOpenPhoto: { _, _ in },
                currentSessionId: PreviewData.sessionOneId
            )
        }
        .environment(\.languageStore, store)
        .frame(width: 1180, height: 820)
    }

    static func controlPage() -> some View {
        prepare()
        let store = languageStore()
        return NavigationStack {
            SessionControlView(
                workspace: workspace(),
                culling: PreviewCullingAPI(),
                onBack: {},
                onOpenSimilarity: { _ in },
                onOpenTab: { _, _ in },
                onOpenGallery: { _ in },
                onOpenSettings: {}
            )
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    // MARK: - Shell / SessionTab / Root

    static func sessionTabPage() -> some View {
        prepare()
        let store = languageStore()
        let workspace = workspace()
        return NavigationStack {
            SessionTabHost(
                tab: .control,
                culling: PreviewCullingAPI(),
                router: router(),
                onOpenPhoto: { _ in }
            )
            .environment(\.sessionWorkspace, workspace)
            .environment(\.languageStore, store)
            .navigationTitle(PreviewData.sessionOneName)
            .navigationSubtitle("SessionTabHost · 控制中心")
        }
        .environment(\.languageStore, store)
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    static func shellPage() -> some View {
        prepare()
        let store = languageStore()
        return PreviewShellChrome(store: store)
            .frame(width: canvasSize.width, height: 260)
    }

    static func rootPage() -> some View {
        prepare()
        let store = languageStore()
        return PreviewRootShell(deps: dependencies(), store: store)
            .frame(width: canvasSize.width, height: canvasSize.height)
    }
}
#endif
