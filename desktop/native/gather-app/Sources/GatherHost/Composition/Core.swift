// desktop/native/gather-app/Sources/GatherHost/Composition/Core.swift
// WP4c / 组合根阶段 1：DB / Repo / Service 图（不含运行时与 Live API 适配）。
//
// 本文件是 AppComposition 唯一的服务图构造点，按拆分前 make 的逐行顺序构造：
// 共享 DB 连接、全部 Repo、Metadata/Delivery 写回链与 Application 服务。
// 闭包捕获、deliveryEventSink、XMPFileLock 单实例语义保持不变（R5：由本文件构造）；
// 运行时见 Composition/Runtime.swift，API 适配见 FeatureAPIs.swift / Root.swift。
import Foundation
import AppKit
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherDelivery
import GatherUI

/// 组合根服务图：构造后只读共享；AppComposition 逐字段转发（同一指针）。
struct CompositionCore {
    private static func otherInstanceRunning() -> Bool {
        // 只在 .app 包内判定；xctest / 裸二进制没有单实例语义。
        guard Bundle.main.bundleURL.pathExtension == "app",
              let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
            return false
        }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .count > 1
    }

    /// 宿主已打开的共享 SQLite 连接（停机时由 runtime 关闭）。
    let db: DBConnection
    /// 生产入口的库门面（open/close 不变量；测试夹具为 nil）。
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
    let qualityService: QualityService
    let indexerService: IndexerService
    let metadataService: MetadataService
    /// 交付仓储（LiveMetadataAPI 的 conflicts/orphans 读入口，同库同键）。
    let deliveryRepo: DeliveryRepo
    /// 手动元数据队列（rating/label/keywords → delivery_items，module=.metadata）。
    let metadataMutationService: MetadataMutationService
    let writebackService: WritebackService
    let smartAlbumRepo: SmartAlbumRepo
    let cullingService: CullingService
    /// P0 / T0：技术质量初筛（只写建议与决策，不写 XMP）。
    let triageService: TriageService
    /// P0 / B0：备份/恢复/诊断。
    let maintenanceService: MaintenanceService
    let exportService: ExportService
    let imagePreloadService: ImagePreloadService
    /// XMP 宿主实现（LiveMetadataAPI 冲突 remote 读 / 孤儿 restore 用）。
    let xmpProvider: any XMPProvider
    /// 唯一交付编排器（四域共用；AppRuntime.start 的启动回放执行者）。
    let deliveryCoordinator: DeliveryCoordinator
    /// 唯一 XMP 文件锁：cleanup/finalize/replay、WritebackService 写盘与
    /// LiveMetadataAPI 的 orphan restore/remove 共用（同一归一化 xmpPath 串行）。
    let xmpFileLock: XMPFileLock

    /// 构造全部共享服务；参数与拆分前 AppComposition.make 逐字一致。
    /// - metadataWriteDebounceMs：过渡保留参数（交付模型无定时器，不参与调度）。
    static func make(
        db: DBConnection,
        database: Database? = nil,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> CompositionCore {
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let similarityResultRepo = SimilarityResultRepo(connection: db)
        let assetRepo = AssetRepo(connection: db)
        // 元数据写回链：XMP provider → MetadataMutationService（入队）→
        // WritebackService（执行器直写）→ DeliveryCoordinator（confirm/cleanup/
        // finalize/replay）。旧 outbox 仓储与协调器已删除，手动队列直接落
        // delivery_items（module=.metadata）。
        _ = metadataWriteDebounceMs
        let xmp = xmpProvider ?? SidecarXMPProvider()
        let metadataCacheRepo = MetadataCacheRepo(connection: db)
        let assetResolver = PhotoAssetResolver(connection: db, getSetting: { key, defaultValue in
            settingsService.get(key, defaultValue: defaultValue)
        })
        let deliveryRepo = DeliveryRepo(connection: db)
        // 交付状态变化 → 宿主事件（旧 coordinator.start(eventSink:) 的等价物）：
        // 每次推进状态后广播 c1-sync-status，驱动 SimilarityView / C1StatusCapsule。
        let deliveryEventSink: @Sendable (String) -> Void = { sessionId in
            Task { @MainActor in
                GatherEventCenter.shared.postC1SyncStatusChange(sessionId: sessionId)
            }
        }
        // P0-1 收口：cleanup/finalize/replay、writeback 与 metadata.orphans 的
        // orphan restore 共用同一把按 xmpPath 的文件锁（组合根唯一实例）。
        let xmpFileLock = XMPFileLock()
        let deliveryCoordinator = DeliveryCoordinator(
            connection: db, xmp: xmp, fileLock: xmpFileLock, eventSink: deliveryEventSink)
        let metadataMutationService = MetadataMutationService(
            deliveryRepo: deliveryRepo, xmp: xmp, assetResolver: assetResolver)
        let writebackService = WritebackService(
            deliveryRepo: deliveryRepo, xmp: xmp, photoRepo: photoRepo,
            metadataCacheRepo: metadataCacheRepo, connection: db,
            keywordOrigins: MetadataKeywordOriginRepo(connection: db),
            assetResolver: assetResolver, delivery: deliveryCoordinator,
            fileLock: xmpFileLock, eventSink: deliveryEventSink)
        // P1-9：构造顺序 MetadataMutationService → WritebackService →
        // MetadataService（无环）；关键词 apply/retry 成功后经闭包立即写盘。
        let metadataService = MetadataService(
            metadataCacheRepo: metadataCacheRepo, xmp: xmp, photoRepo: photoRepo,
            transactions: db, mutations: metadataMutationService,
            flushPending: { sessionId in
                try await writebackService.executePending(
                    sessionId: sessionId, module: "metadata")
            },
            retryFlush: { sessionId in
                try await writebackService.executePending(
                    sessionId: sessionId, module: "metadata", includeFailed: true)
            },
            assetResolver: assetResolver, exif: ImageIOExifProvider(),
            dimensions: ImageIODimensionsProvider(),
            origins: MetadataKeywordOriginRepo(connection: db))
        let similarityService = SimilarityService(
            photoRepo: photoRepo, sessionRepo: sessionRepo,
            similarityResultRepo: similarityResultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            // WP3b-2：hash/run/交付项读取经 Persistence 端口，事务经 TransactionRunner。
            hashes: SimilarityHashRepo(connection: db),
            analysisRuns: AnalysisRunRepo(connection: db),
            deliveryItems: deliveryRepo, transactions: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            // 审计 P0-1：与 DuplicateService 共用同一 RAWDecoder 9x8 灰度管线。
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            },
            writebackProvider: SimilarityWritebackBridge(writebackService: writebackService),
            delivery: deliveryCoordinator.adapter(for: .similarity))
        let personRepo = PersonRepo(connection: db)
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let exportService = ExportService(
            photoRepo: photoRepo, sessionRepo: sessionRepo,
            reports: ExportReportRepo(connection: db))
        let imagePreloadService = ImagePreloadService()
        let resolvedFaceKwService = faceKwService ?? FaceKwService(
            photoRepo: photoRepo, sessionRepo: sessionRepo,
            faceRepo: FaceRepo(connection: db), personRepo: personRepo,
            feedback: FaceFeedbackRepo(connection: db),
            analysisRuns: AnalysisRunRepo(connection: db),
            deliveryItems: deliveryRepo, transactions: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            getString: { key, defaultValue in
                settingsService.get(key, defaultValue: defaultValue)
            },
            writebackProvider: FaceKwWritebackBridge(writebackService: writebackService),
            delivery: deliveryCoordinator.adapter(for: .faceKeyword))
        let triageService = TriageService(
            repository: TriageRepo(connection: db),
            decisions: CullingDecisionRepo(connection: db),
            history: CullingHistoryRepo(connection: db),
            transactions: db,
            policyProvider: { TriagePolicy.fromSettings(settingsService) },
            enabledProvider: {
                settingsService.get("triage_enabled", defaultValue: "0") == "1"
            })
        // 3.4 CullingService：写回执行器走 WritebackService（CullingWritebackPort），
        // confirm/cleanup/syncStatus 走交付模型（不再注入旧 outbox 仓储）。
        let cullingService = CullingService(
            photoRepo: photoRepo, cullingDecisionRepo: CullingDecisionRepo(connection: db),
            similarityResultRepo: similarityResultRepo,
            metadataCacheRepo: metadataCacheRepo,
            // WP3b-2：分页/计数/富查询 SQL 在 Persistence，交付行与事务走端口。
            pageQuery: CullingAssetPageQuery(connection: db),
            richQuery: CullingReadQuery(connection: db),
            deliveryItems: deliveryRepo, transactions: db,
            metadataMutations: metadataMutationService, writeback: writebackService,
            cullingHistoryRepo: CullingHistoryRepo(connection: db),
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            // T0 门控由 TriageService 单点产出：关闭即不展示，开启只展示指纹匹配行。
            triageDisplayPolicy: { sessionId in
                guard let gate = try triageService.cachedGate(sessionId: sessionId) else {
                    return .hidden
                }
                return .matching(gate)
            },
            // rating/label 与 applyHistory 入队后立即写盘（否则 metadata item 停在 pending，
            // 看起来“改了但 XMP 没写”）。
            flushMetadata: { sessionId in
                _ = try await writebackService.executePending(
                    sessionId: sessionId, module: "metadata")
            },
            delivery: deliveryCoordinator.adapter(for: .culling))
        let sessionService = SessionService(
            sessionRepo: sessionRepo, photoRepo: photoRepo,
            faceRepo: FaceRepo(connection: db), personRepo: PersonRepo(connection: db),
            metadataCacheRepo: metadataCacheRepo,
            jobRepo: AnalysisJobRepo(connection: db), assetRepo: assetRepo,
            deliverySummary: DeliverySummaryQuery(connection: db), transactions: db,
            dimensionsProvider: { path in
                let dims = try RAWDecoder.getDimensions(path: path)
                return (dims.width, dims.height)
            })
        let workspaceStatusService = WorkspaceStatusService(
            sessionRepo: sessionRepo, photoRepo: photoRepo,
            jobRepo: AnalysisJobRepo(connection: db),
            deliverySummary: DeliverySummaryQuery(connection: db))
        let filterEngine = FilterEngine(query: PhotoFilterQuery(connection: db))
        let navigationService = NavigationService(navigationRepo: NavigationRepo(connection: db))
        let duplicateService = DuplicateService(
            // WP3b-3：扫描/分组重建与组/成员读取下沉到 DuplicateRepo /
            // DuplicateGroupQuery，hash 表共用 SimilarityHashRepo。
            duplicateRepo: DuplicateRepo(connection: db),
            groupQuery: DuplicateGroupQuery(connection: db),
            hashes: SimilarityHashRepo(connection: db), transactions: db,
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            },
            // Cut 5 / 5b-2a：与 DuplicateService 默认 provider 同一 ClusterGraphPipeline。
            clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
                try ClusterGraphPipeline.run(
                    entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                    mode: mode, onProgress: onProgress
                ).result
            })
        let qualityService = QualityService(
            photoRepo: photoRepo, qualityRepo: QualityRepo(connection: db),
            imageProvider: QualityService.defaultImageProvider,
            statProvider: QualityService.defaultStat)
        let indexerService = IndexerService(
            // WP3b-2：扫描写路径/派生失效 SQL 在 IndexerRepo，事务经 TransactionRunner。
            indexer: IndexerRepo(connection: db), transactions: db,
            sessionRepo: sessionRepo, photoRepo: photoRepo, assetRepo: assetRepo,
            // 照片内容/路径变化只失效命中 photoIds 的派生人脸结果。
            faceRepo: FaceRepo(connection: db),
            getDimensions: { path in
                try RAWDecoder.getDimensions(path: path)
            },
            getSetting: { key, defaultValue in
                settingsService.get(key, defaultValue: defaultValue)
            },
            // 每批新插入的 photo id 交给元数据链路预热；失败不阻断索引主流程。
            warmMetadata: { photoIds in
                guard !photoIds.isEmpty else { return }
                _ = try? await metadataService.getMetadata(photoIds: photoIds)
            })
        let smartAlbumRepo = SmartAlbumRepo(connection: db)
        let appDir: URL
        if let path = database?.path {
            appDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        } else if let path = db.storagePath {
            appDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        } else {
            appDir = FileManager.default.temporaryDirectory.appendingPathComponent("Gather", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let maintenanceService = MaintenanceService(
            database: database, settings: settingsService, appDir: appDir,
            // 生产单实例检测：同 bundle id 的另一个 Gather 进程存在时，
            // restore/backup 走 RESTORE_BUSY/BACKUP_BUSY，避免跨实例 swap。
            isOtherInstanceRunning: Self.otherInstanceRunning
        )
        return CompositionCore(
            db: db, database: database, sessionService: sessionService,
            workspaceStatusService: workspaceStatusService, jobService: jobService,
            photoRepo: photoRepo, settingsService: settingsService,
            filterEngine: filterEngine, navigationService: navigationService,
            similarityService: similarityService, duplicateService: duplicateService,
            assetRepo: assetRepo, faceKwService: resolvedFaceKwService,
            personRepo: personRepo,
            qualityService: qualityService, indexerService: indexerService,
            metadataService: metadataService, deliveryRepo: deliveryRepo,
            metadataMutationService: metadataMutationService,
            writebackService: writebackService, smartAlbumRepo: smartAlbumRepo,
            cullingService: cullingService, triageService: triageService,
            maintenanceService: maintenanceService,
            exportService: exportService,
            imagePreloadService: imagePreloadService, xmpProvider: xmp,
            deliveryCoordinator: deliveryCoordinator, xmpFileLock: xmpFileLock)
    }
}
