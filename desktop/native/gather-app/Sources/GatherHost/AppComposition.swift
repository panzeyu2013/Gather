// desktop/native/gather-app/Sources/GatherHost/AppComposition.swift
// WP4c：宿主组合根门面（Composition Root facade）。
//
// 原 390+ 行的单一 make 已按阶段拆到 Composition/：
// - Composition/Core.swift：DB / Repo / Service 图（含 Metadata/Delivery 写回链）；
// - Composition/Runtime.swift：executorDeps + AppRuntime，以及 CompositionRoot 入口；
// - Composition/FeatureAPIs.swift：16 个 Live API 工厂（AppServices 的装配单元）；
// - Composition/Root.swift：AppServices 装配（16 个 Live API + 唯一 runtime）。
//
// 本文件只做字段转发与主入口委托：不构造服务、不注册 executor、不开库。
// 构造顺序、单例（xmpFileLock/deliveryCoordinator/runtime）、deliveryEventSink
// 与依赖注入语义与拆分前完全一致；GatherApp 用同一个 composition 装配
// AppServices，任何地方都不得再构造第二套 db / JobService / executor 注册表。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherApplication
import GatherDelivery

/// 宿主组合根：一批共享服务 + 唯一运行时。
///
/// 所有字段都是引用类型，构造后只读共享；AppServices / AppRuntime 二者
/// 拿到的是同一批实例（尤其 db / jobService / deliveryCoordinator 只能有一份）。
public struct AppComposition {
    /// 唯一服务图（Composition/Core.swift 构造；本类型逐字段转发同一指针）。
    let core: CompositionCore

    // MARK: - 唯一运行时

    /// 运行时生命周期（executor 注册 + JobService 启动 / 优雅停机 / reload ack）。
    /// 与共享服务图用同一批实例；GatherApp / AppServices / AppRuntime 只持有这一个引用。
    public let runtime: AppRuntime

    // MARK: - 共享依赖（转发 CompositionCore，指针不变）

    /// 宿主已打开的共享 SQLite 连接（停机时由 runtime 关闭）。
    var db: DBConnection { core.db }
    /// 生产入口的库门面（持有 connection 的 open/close 不变量；测试夹具为 nil）。
    var database: Database? { core.database }
    var sessionService: SessionService { core.sessionService }
    var workspaceStatusService: WorkspaceStatusService { core.workspaceStatusService }
    var jobService: JobService { core.jobService }
    var photoRepo: PhotoRepo { core.photoRepo }
    var settingsService: SettingsService { core.settingsService }
    var filterEngine: FilterEngine { core.filterEngine }
    var navigationService: NavigationService { core.navigationService }
    var similarityService: SimilarityService { core.similarityService }
    var duplicateService: DuplicateService { core.duplicateService }
    var assetRepo: AssetRepo { core.assetRepo }
    var faceKwService: FaceKwService { core.faceKwService }
    var personRepo: PersonRepo { core.personRepo }
    var templateService: TemplateService { core.templateService }
    var qualityService: QualityService { core.qualityService }
    var indexerService: IndexerService { core.indexerService }
    var metadataService: MetadataService { core.metadataService }
    /// 交付仓储（LiveMetadataAPI 的 conflicts/orphans 读入口，与写回执行器同库同键）。
    var deliveryRepo: DeliveryRepo { core.deliveryRepo }
    /// 手动元数据队列（rating/label/keywords → delivery_items，module=.metadata）。
    var metadataMutationService: MetadataMutationService { core.metadataMutationService }
    var writebackService: WritebackService { core.writebackService }
    var smartAlbumRepo: SmartAlbumRepo { core.smartAlbumRepo }
    var cullingService: CullingService { core.cullingService }
    var exportService: ExportService { core.exportService }
    var imagePreloadService: ImagePreloadService { core.imagePreloadService }
    /// XMP 侧车宿主实现（LiveMetadataAPI 的冲突 remote 读 / 孤儿 restore 用）。
    var xmpProvider: any XMPProvider { core.xmpProvider }
    /// 唯一交付编排器（四域共用；AppRuntime.start 的启动回放执行者）。
    var deliveryCoordinator: DeliveryCoordinator { core.deliveryCoordinator }
    /// 唯一 XMP 文件锁（cleanup/finalize/replay、WritebackService、orphan
    /// restore/remove 共用同一实例）。
    var xmpFileLock: XMPFileLock { core.xmpFileLock }

    // MARK: - 唯一装配入口（委托 CompositionRoot，Composition/Runtime.swift）

    /// 生产装配：接收 `Database.open(at:)` 的门面，构造全部服务 + 运行时。
    public static func make(
        database: Database,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> AppComposition {
        CompositionRoot.make(
            database: database,
            xmpProvider: xmpProvider,
            metadataWriteDebounceMs: metadataWriteDebounceMs,
            faceKwService: faceKwService
        )
    }

    /// 测试接缝：只接收裸连接（测试夹具没有 Database 门面）。
    /// 生产不得调用——生产必须走 `make(database:)`，由 runtime 负责 close 门面。
    static func make(
        db: DBConnection,
        database: Database? = nil,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> AppComposition {
        CompositionRoot.make(
            db: db,
            database: database,
            xmpProvider: xmpProvider,
            metadataWriteDebounceMs: metadataWriteDebounceMs,
            faceKwService: faceKwService
        )
    }
}
