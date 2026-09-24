// API/CommandSurface.swift
// R5 命令面：19 个域协议的类型化聚合（组合根的产物）。
// 旧宿主以 [String: JSONValue] 命令分发；本类型是唯一替代形态：
// 每个域一个协议引用，调用方按类型调用，不存在命令名字符串与命令级 JSON 桥。
import Foundation

/// 19 域类型化命令面。
///
/// 组合根（app 侧 AppComposition）构造 19 个 `*CommandsImpl` 后装入本结构；
/// UI/ViewModel 只持有自己需要的域协议（`any CullingCommands` 等），
/// 不接触 Store/SQL/命令名。
public struct CommandSurface: Sendable {
    public let album: any AlbumCommands
    public let assets: any AssetsCommands
    public let culling: any CullingCommands
    public let duplicate: any DuplicateCommands
    public let export: any ExportCommands
    public let face: any FaceCommands
    public let filter: any FilterCommands
    public let index: any IndexCommands
    public let jobs: any JobsCommands
    public let metadata: any MetadataCommands
    public let navigation: any NavigationCommands
    public let person: any PersonCommands
    public let photo: any PhotoCommands
    public let quality: any QualityCommands
    public let session: any SessionCommands
    public let settings: any SettingsCommands
    public let similarity: any SimilarityCommands
    public let template: any TemplateCommands
    public let workspace: any WorkspaceCommands

    public init(
        album: any AlbumCommands,
        assets: any AssetsCommands,
        culling: any CullingCommands,
        duplicate: any DuplicateCommands,
        export: any ExportCommands,
        face: any FaceCommands,
        filter: any FilterCommands,
        index: any IndexCommands,
        jobs: any JobsCommands,
        metadata: any MetadataCommands,
        navigation: any NavigationCommands,
        person: any PersonCommands,
        photo: any PhotoCommands,
        quality: any QualityCommands,
        session: any SessionCommands,
        settings: any SettingsCommands,
        similarity: any SimilarityCommands,
        template: any TemplateCommands,
        workspace: any WorkspaceCommands
    ) {
        self.album = album
        self.assets = assets
        self.culling = culling
        self.duplicate = duplicate
        self.export = export
        self.face = face
        self.filter = filter
        self.index = index
        self.jobs = jobs
        self.metadata = metadata
        self.navigation = navigation
        self.person = person
        self.photo = photo
        self.quality = quality
        self.session = session
        self.settings = settings
        self.similarity = similarity
        self.template = template
        self.workspace = workspace
    }
}
