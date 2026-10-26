// desktop/native/gather-app/Sources/GatherUI/Support/RootShellDependencies.swift
// Cut 4 / 4a-0：壳层依赖包（§4.6 / D-017）。
//
// 目的：RootView 现在 import 了 GatherPersistence/Analysis/Domain，只因为
// AppServices 是 Host 类型。迁移后壳层只认这份"协议 + 端口"集合，由 Host 的
// AppBootstrap.SceneState 装配注入；GatherUI 仍只依赖 GatherProtocol，
// layering 门禁不变。
//
// dashboardProvider 仍是 package 端口（协议与 VM 均未提升为 public）；生产实现
// 已随 WP4b 移到 GatherHost，这里只保留字段形状与 package 可见性。
import Foundation
import GatherProtocol

/// 菜单「导入文件夹」的用户选择结果：宿主负责 NSOpenPanel，UI 只做分支
///（有可导入文件 → 导入；空目录 → 新建工作台表单）。
public enum ImportFolderSelection: Sendable {
    case cancelled
    case files([String])
    case directory(URL)
}

public struct RootShellDependencies {
    public let session: any SessionAPI
    public let job: any JobAPI
    public let settings: any SettingsAPI
    public let culling: any CullingAPI
    public let navigation: any NavigationAPI
    public let metadata: any MetadataAPI
    /// P0/K0：关键词自动补全；可选，预览/测试壳可为 nil（面板退化为本地建议）。
    public let photo: (any PhotoAPI)?
    public let quality: any QualityAPI
    public let face: any FaceAPI
    public let similarity: any SimilarityAPI
    public let duplicate: any DuplicateAPI
    public let export: any ExportAPI
    public let person: any PersonAPI
    public let captureOne: any CaptureOneBridging

    public let libraryProvider: any LibraryDataProvider
    public let galleryProvider: any GalleryDataProvider
    package let dashboardProvider: any DashboardDataProvider

    /// 菜单命令的宿主动作（Phase 4 收口：命令不再经 Notification 转发）。
    public let importFiles: @MainActor ([String]) -> Void
    public let chooseImportFolder: @MainActor () async -> ImportFolderSelection
    public let captureOneImport: @MainActor () async -> Void

    package init(
        session: any SessionAPI,
        job: any JobAPI,
        settings: any SettingsAPI,
        culling: any CullingAPI,
        navigation: any NavigationAPI,
        metadata: any MetadataAPI,
        photo: (any PhotoAPI)? = nil,
        quality: any QualityAPI,
        face: any FaceAPI,
        similarity: any SimilarityAPI,
        duplicate: any DuplicateAPI,
        export: any ExportAPI,
        person: any PersonAPI,
        captureOne: any CaptureOneBridging,
        libraryProvider: any LibraryDataProvider,
        galleryProvider: any GalleryDataProvider,
        dashboardProvider: any DashboardDataProvider,
        importFiles: @escaping @MainActor ([String]) -> Void = { _ in },
        chooseImportFolder: @escaping @MainActor () async -> ImportFolderSelection = { .cancelled },
        captureOneImport: @escaping @MainActor () async -> Void = {}
    ) {
        self.session = session
        self.job = job
        self.settings = settings
        self.culling = culling
        self.navigation = navigation
        self.metadata = metadata
        self.photo = photo
        self.quality = quality
        self.face = face
        self.similarity = similarity
        self.duplicate = duplicate
        self.export = export
        self.person = person
        self.captureOne = captureOne
        self.libraryProvider = libraryProvider
        self.galleryProvider = galleryProvider
        self.dashboardProvider = dashboardProvider
        self.importFiles = importFiles
        self.chooseImportFolder = chooseImportFolder
        self.captureOneImport = captureOneImport
    }
}
