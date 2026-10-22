// desktop/native/gather-app/Sources/GatherHost/AppComposition.swift
// Cut 1 / B8.3b-2a：宿主组合根（Composition Root）。
//
// 本文件承接原组合根 makeDefault 的 24 个服务/Repo 构造，并在
// 这里构造唯一的 AppRuntime（executorDeps + 生命周期 + reload ack 写入面）。
// GatherApp 用同一个 composition 装配 AppServices；任何地方都不得再构造第二套
// db / JobService / executor 注册表。
//
// S5c-2b-3b-2b-2：MetadataSyncCoordinator 已从组合根删除（旧 outbox 队列与
// conflicts/orphans 全部迁到交付模型）。本文件保留的写回接线只有：
// - 唯一的 DeliveryCoordinator（confirm/cleanup/finalize/replay）——
//   culling/face/sim/writeback 共用同一实例，并携带 eventSink；
// - 唯一的 WritebackService（交付执行器，直写 XMP + 推进 deliveries/items）；
// - 唯一的 MetadataMutationService（手动 rating/label 队列，落 delivery_items）。
// eventSink 把交付状态变化广播成 c1-sync-status 事件（旧协调器 eventSink 的
// 等价物），SimilarityView / C1StatusCapsule 的刷新链路保持不变。
//
// B8.4：旧命令面构造器、测试专用工厂与扩展均已删除；本类型是
// AppServices / AppRuntime 的唯一依赖来源。
//
// 边界（S5c-2b-3b-2b-3 起）：
// - 数据库由宿主 GatherApp 用 `Database.open(at:)` 打开（SchemaV1，user_version=1）；
//   本文件经 `make(database:)` 接收门面，用 `database.connection` 构造 Repo/Service，
//   连接与建库只有 `Database.open(at:)` 单一入口。`make(db:)` 保留为测试接缝
//   （测试夹具只有裸连接），生产路径不得调用；
// - 服务构造参数（xmpProvider / metadataWriteDebounceMs / faceKwService）与旧
//   makeDefault 完全一致，闭包、默认实现、eventSink 语义不变；
// - executor 的注册入口仍是 AppRuntime（装配期自检语义不变）。
//
// B8.4 收口：字符串命令面与其 accessor 已删除，AppServices.live(composition:)
// 是唯一装配入口。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery
import GatherUI

/// 宿主组合根：一批共享服务 + 唯一运行时。
///
/// 所有字段都是引用类型，构造后只读共享；AppServices / AppRuntime 二者
/// 拿到的是同一批实例（尤其 db / jobService / deliveryCoordinator 只能有一份）。
public struct AppComposition {
    // MARK: - 24 个依赖（与旧组合根 init 的参数一一对应）

    /// 宿主已打开的共享 SQLite 连接（停机时由 runtime 关闭）。
    let db: DBConnection
    /// 生产入口的库门面（持有 connection 的 open/close 不变量；测试夹具为 nil）。
    let database: Database?
    let sessionService: SessionService
    let workspaceStatusService: WorkspaceStatusService
    let jobService: JobService
    let photoRepo: PhotoRepo
    let settingsService: SettingsService
    let filterEngine: FilterEngine
    let navigationService: NavigationService
    let similarityService: SimilarityService
    let duplicateService: DuplicateService
    let assetRepo: AssetRepo
    let faceKwService: FaceKwService
    let personRepo: PersonRepo
    let templateService: TemplateService
    let qualityService: QualityService
    let indexerService: IndexerService
    let metadataService: MetadataService
    /// 交付仓储（LiveMetadataAPI 的 conflicts/orphans 读入口，与写回执行器同库同键）。
    let deliveryRepo: DeliveryRepo
    /// 手动元数据队列（rating/label/keywords → delivery_items，module=.metadata）。
    let metadataMutationService: MetadataMutationService
    let writebackService: WritebackService
    let smartAlbumRepo: SmartAlbumRepo
    let cullingService: CullingService
    let exportService: ExportService
    let imagePreloadService: ImagePreloadService
    /// XMP 侧车宿主实现（LiveMetadataAPI 的冲突 remote 读 / 孤儿 restore 用）。
    let xmpProvider: any XMPProvider
    /// 唯一交付编排器（四域共用；AppRuntime.start 的启动回放执行者）。
    let deliveryCoordinator: DeliveryCoordinator
    /// 唯一 XMP 文件锁：cleanup/finalize/replay 的 restore/remove、WritebackService
    /// 的写盘与 LiveMetadataAPI 的 orphan restore/remove 共用这一实例（同一归一化
    /// xmpPath 串行），消除 P0-1 的 TOCTOU 窗口。
    let xmpFileLock: XMPFileLock

    // MARK: - 唯一运行时

    /// 运行时生命周期（executor 注册 + JobService 启动 / 优雅停机 / reload ack）。
    /// 与上面 24 个依赖共用同一批实例；GatherApp / AppServices / AppRuntime 都只持有
    /// 这一个引用。
    public let runtime: AppRuntime

    // MARK: - 唯一装配入口

    /// 生产装配：接收 `Database.open(at:)` 的门面，用其连接构造全部服务 + 运行时。
    ///
    /// 参数与旧组合根 makeDefault 逐字一致：
    /// - xmpProvider：XMP 侧车读写宿主实现（默认 SidecarXMPProvider；测试注入
    ///   内存假件）。
    /// - metadataWriteDebounceMs：**过渡保留参数**。旧协调器用它做写去抖
    ///   （TS 设置 metadata_write_debounce_ms）；交付模型没有定时器，该值不再
    ///   参与调度，仅为调用方签名不变而保留。
    /// - faceKwService：默认装配 Vision 推理 + RAWDecoder 解码；测试可注入
    ///   假推理/解码（对齐 gather-core FaceKeywordingServiceTests 模式）。
    public static func make(
        database: Database,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> AppComposition {
        make(
            db: database.connection,
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
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let similarityResultRepo = SimilarityResultRepo(connection: db)
        let assetRepo = AssetRepo(connection: db)
        // 元数据写回链（TS di/init.ts 组合根的交付模型版）：XMP provider →
        // MetadataMutationService（入队）→ WritebackService（执行器直写）→
        // DeliveryCoordinator（confirm/cleanup/finalize/replay）。
        // XMPProvider 是宿主接缝：3.4 前用 SidecarXMPProvider 保证端到端可用。
        //
        // S5c-2b-3b-2b-2：旧 outbox 仓储与协调器构造已整段移除；手动队列直接落
        // delivery_items（module=.metadata），写盘由 WritebackService 执行。
        // metadataWriteDebounceMs 参数保留以维持组合根签名（旧协调器的去抖设置），
        // 交付模型没有定时器，该值不再参与调度。
        _ = metadataWriteDebounceMs
        let xmp = xmpProvider ?? SidecarXMPProvider()
        let metadataCacheRepo = MetadataCacheRepo(connection: db)
        let assetResolver = PhotoAssetResolver(connection: db, getSetting: { key, defaultValue in
            settingsService.get(key, defaultValue: defaultValue)
        })
        let deliveryRepo = DeliveryRepo(connection: db)
        // 交付状态变化 → 宿主事件（旧 coordinator.start(eventSink:) 的等价物）：
        // 写回执行器 / 交付编排每次推进状态后广播 c1-sync-status，驱动
        // SimilarityView 与 C1StatusCapsule 即时刷新。
        let deliveryEventSink: @Sendable (String) -> Void = { sessionId in
            Task { @MainActor in
                GatherEventCenter.shared.postC1SyncStatusChange(sessionId: sessionId)
            }
        }
        // P0-1 收口：cleanup/finalize/replay、writeback 与 metadata.orphans 的
        // orphan restore 必须共用同一把按 xmpPath 的文件锁；否则守卫只能事后
        // 检测，旧备份仍可能覆盖新写入。
        // 用 .shared：LiveMetadataAPI 由 AppServices 构造且缺省同为 .shared，
        // 三方因此拿到同一实例；不得在本文件再 new 第二把锁。
        let xmpFileLock = XMPFileLock.shared
        let deliveryCoordinator = DeliveryCoordinator(
            connection: db,
            xmp: xmp,
            fileLock: xmpFileLock,
            eventSink: deliveryEventSink
        )
        let metadataMutationService = MetadataMutationService(
            deliveryRepo: deliveryRepo,
            xmp: xmp,
            assetResolver: assetResolver
        )
        // UI 对齐（§十一 11.9-1）：交付状态变化经 deliveryEventSink 广播
        // c1-sync-status（见上方 coordinator 构造），不再有 start()/恢复入口——
        // writing 租约的归位由 DeliveryCoordinator.replay()（2b-3 接 Database.open）
        // 与执行器的 beginDeliveryWrite 续租承担。
        // S5c-2b-3a：写回执行器的持久化层已是统一交付模型
        // （deliveries / delivery_items / delivery_sessions），不再需要
        // writebackRepo / outboxRepo / sessionRepo（旧表随 2b-3b 删除）。
        // S5c-2b-3b-2a：执行器不再注入 MetadataSyncPort——execute 直接用 xmp 写盘，
        // confirm/cleanup 走交付模型（cleanup 的 coordinator 由 connection+xmp 自建）。
        let writebackService = WritebackService(
            deliveryRepo: deliveryRepo,
            xmp: xmp,
            photoRepo: photoRepo,
            metadataCacheRepo: metadataCacheRepo,
            connection: db,
            keywordOrigins: MetadataKeywordOriginRepo(connection: db),
            assetResolver: assetResolver,
            delivery: deliveryCoordinator,
            fileLock: xmpFileLock,
            eventSink: deliveryEventSink
        )
        // P1-9：手动元数据队列的生产执行器接线。构造顺序必须是
        // MetadataMutationService → WritebackService → MetadataService（无环：
        // 执行器不依赖 MetadataService）；setMetadata/batchSet 入队成功后经该闭包
        // 调用 executePending(sessionId, module: "metadata") 立即写盘。
        // 宿主侧的 EXIF/尺寸读取实现（ImageIO）。此前这两个注入点是空的：
        // getMetadata 会直接跳过 EXIF，
        // 于是 date_taken/cameraModel 永远为空、"按日期自动合并"恒为 0。
        let metadataService = MetadataService(
            metadataCacheRepo: metadataCacheRepo,
            xmp: xmp,
            photoRepo: photoRepo,
            transactions: db,
            mutations: metadataMutationService,
            flushPending: { sessionId in
                try await writebackService.executePending(
                    sessionId: sessionId, module: "metadata")
            },
            assetResolver: assetResolver,
            exif: ImageIOExifProvider(),
            dimensions: ImageIODimensionsProvider()
        )
        // SimilarityService 在写回执行器之后构造：S5c-2b-3b-1 起写回经
        // SimilarityWritebackBridge 进入同一份 WritebackService（交付持久化层），
        // 生产路径不再有 writebackProviderMissing。
        let similarityService = SimilarityService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            similarityResultRepo: similarityResultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            // WP3b-2：hash/run/交付项读取经 Persistence 端口，事务经 TransactionRunner。
            hashes: SimilarityHashRepo(connection: db),
            analysisRuns: AnalysisRunRepo(connection: db),
            deliveryItems: deliveryRepo,
            transactions: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            // 修复（审计 P0-1）：此前未注入 thumbnailProvider（默认恒 nil），
            // 相似度分析全部哈希计算失败 → SIM_NO_HASH_DATA。与
            // DuplicateService 共用同一 RAWDecoder 9x8 灰度管线。
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            },
            writebackProvider: SimilarityWritebackBridge(writebackService: writebackService),
            delivery: deliveryCoordinator.adapter(for: .similarity)
        )
        let personRepo = PersonRepo(connection: db)
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let exportService = ExportService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            reports: ExportReportRepo(connection: db)
        )
        let imagePreloadService = ImagePreloadService()
        let resolvedFaceKwService = faceKwService ?? FaceKwService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            faceRepo: FaceRepo(connection: db),
            personRepo: personRepo,
            // WP3b-2：身份反馈 / 簇成员写 / run 记录 / 交付项读取经 Persistence 端口。
            feedback: FaceFeedbackRepo(connection: db),
            analysisRuns: AnalysisRunRepo(connection: db),
            deliveryItems: deliveryRepo,
            transactions: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            getString: { key, defaultValue in
                settingsService.get(key, defaultValue: defaultValue)
            },
            writebackProvider: FaceKwWritebackBridge(writebackService: writebackService),
            delivery: deliveryCoordinator.adapter(for: .faceKeyword)
        )
        // 3.4 CullingService：写回执行器走 WritebackService（CullingWritebackPort），
        // confirm/cleanup/syncStatus 走交付模型。S5c-2b-3b-2b-1 起不再注入旧
        // outbox 仓储（读点已删除）。
        let cullingService = CullingService(
            photoRepo: photoRepo,
            cullingDecisionRepo: CullingDecisionRepo(connection: db),
            similarityResultRepo: similarityResultRepo,
            metadataCacheRepo: metadataCacheRepo,
            // WP3b-2：分页/计数/富查询 SQL 在 Persistence，交付行与事务走端口。
            pageQuery: CullingAssetPageQuery(connection: db),
            richQuery: CullingReadQuery(connection: db),
            deliveryItems: deliveryRepo,
            transactions: db,
            metadataMutations: metadataMutationService,
            writeback: writebackService,
            cullingHistoryRepo: CullingHistoryRepo(connection: db),
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            delivery: deliveryCoordinator.adapter(for: .culling)
        )
        // 以下 9 个服务原先在旧组合根 init 的实参位置就地构造；
        // 这里按原实参求值顺序（从左到右）提升为局部变量，构造顺序与行为不变。
        let sessionService = SessionService(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            faceRepo: FaceRepo(connection: db),
            personRepo: PersonRepo(connection: db),
            metadataCacheRepo: metadataCacheRepo,
            jobRepo: AnalysisJobRepo(connection: db),
            assetRepo: assetRepo,
            deliverySummary: DeliverySummaryQuery(connection: db),
            transactions: db,
            dimensionsProvider: { path in
                let dims = try RAWDecoder.getDimensions(path: path)
                return (dims.width, dims.height)
            }
        )
        // 工作区计数读交付模型（DeliverySummaryQuery），不再注入旧 outbox 仓储。
        let workspaceStatusService = WorkspaceStatusService(
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            jobRepo: AnalysisJobRepo(connection: db),
            deliverySummary: DeliverySummaryQuery(connection: db)
        )
        let filterEngine = FilterEngine(query: PhotoFilterQuery(connection: db))
        let navigationService = NavigationService(navigationRepo: NavigationRepo(connection: db))
        let duplicateService = DuplicateService(
            connection: db,
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            },
            // Cut 5 / 5b-2a：与 DuplicateService 默认 provider 注入同一
            // ClusterGraphPipeline（global -> run，sequential -> runSequential）。
            clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
                try ClusterGraphPipeline.run(
                    entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                    mode: mode, onProgress: onProgress
                ).result
            }
        )
        let templateService = TemplateService(templates: TemplateRepo(connection: db), settings: settingsService)
        let qualityService = QualityService(
            photoRepo: photoRepo,
            qualityRepo: QualityRepo(connection: db),
            imageProvider: QualityService.defaultImageProvider,
            statProvider: QualityService.defaultStat
        )
        let indexerService = IndexerService(
            // WP3b-2：扫描写路径/派生失效 SQL 在 IndexerRepo，事务经 TransactionRunner。
            indexer: IndexerRepo(connection: db),
            transactions: db,
            sessionRepo: sessionRepo,
            photoRepo: photoRepo,
            assetRepo: assetRepo,
            // 照片内容/路径变化时只失效命中 photoIds 的派生人脸结果
            // （成员行与 role_bindings 保留）；不再整会话删除簇与绑定。
            faceRepo: FaceRepo(connection: db),
            getDimensions: { path in
                try RAWDecoder.getDimensions(path: path)
            },
            getSetting: { key, defaultValue in
                settingsService.get(key, defaultValue: defaultValue)
            },
            // 每批新插入的 photo id 交给元数据链路（EXIF/尺寸 → photo_metadata_cache）。
            // 只预热真正插入的行，重复扫描不重复提取；失败不阻断索引主流程。
            warmMetadata: { photoIds in
                guard !photoIds.isEmpty else { return }
                _ = try? await metadataService.getMetadata(photoIds: photoIds)
            }
        )
        let smartAlbumRepo = SmartAlbumRepo(connection: db)

        // executorDeps 与 runtime 的唯一构造点；组合根不再自行 new，
        // 否则会出现第二套生命周期状态机（同一批服务被两个 runtime 持有）。
        let executorDeps = ExecutorRegistry.Dependencies(
            similarityService: similarityService,
            duplicateService: duplicateService,
            faceKwService: resolvedFaceKwService,
            qualityService: qualityService,
            indexerService: indexerService,
            metadataService: metadataService,
            photoRepo: photoRepo,
            assetRepo: assetRepo,
            imagePreloadService: imagePreloadService,
            exportService: exportService
        )
        let runtime = AppRuntime(
            db: db,
            database: database,
            jobService: jobService,
            delivery: deliveryCoordinator,
            executorDeps: executorDeps
        )
        return AppComposition(
            db: db,
            database: database,
            sessionService: sessionService,
            workspaceStatusService: workspaceStatusService,
            jobService: jobService,
            photoRepo: photoRepo,
            settingsService: settingsService,
            filterEngine: filterEngine,
            navigationService: navigationService,
            similarityService: similarityService,
            duplicateService: duplicateService,
            assetRepo: assetRepo,
            faceKwService: resolvedFaceKwService,
            personRepo: personRepo,
            templateService: templateService,
            qualityService: qualityService,
            indexerService: indexerService,
            metadataService: metadataService,
            deliveryRepo: deliveryRepo,
            metadataMutationService: metadataMutationService,
            writebackService: writebackService,
            smartAlbumRepo: smartAlbumRepo,
            cullingService: cullingService,
            exportService: exportService,
            imagePreloadService: imagePreloadService,
            xmpProvider: xmp,
            deliveryCoordinator: deliveryCoordinator,
            xmpFileLock: xmpFileLock,
            runtime: runtime
        )
    }

}
