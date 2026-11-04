// desktop/native/gather-app/Sources/GatherHost/Composition/Core.swift
// WP4c / 组合根阶段 1：DB / Repo / Service 图（不含运行时与 Live API 适配）。
//
// 本文件是 AppComposition 唯一的服务图构造点，按拆分前 make 的逐行顺序构造：
// 共享 DB 连接、全部 Repo、Metadata/Delivery 写回链与 Application 服务。
// 闭包捕获、deliveryEventSink、XMPFileLock 单实例语义保持不变（R5：由本文件构造）；
// 运行时见 Composition/Runtime.swift，API 适配见 FeatureAPIs.swift / Root.swift。
import Foundation
import AppKit
import os
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
import GatherMetadataIO
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
    /// 模型级初审信号（人脸几何/采集质量/合焦/审美），quality.score 第二段执行。
    let modelReviewService: ModelReviewService
    let indexerService: IndexerService
    let metadataService: MetadataService
    /// 交付仓储（LiveMetadataAPI 的 conflicts/orphans 读入口，同库同键）。
    let deliveryRepo: DeliveryRepo
    /// 手动元数据队列（rating/label/keywords → delivery_items，module=.metadata）。
    let metadataMutationService: MetadataMutationService
    let writebackService: WritebackService
    let smartAlbumRepo: SmartAlbumRepo
    /// P1：手动集合/堆栈/跨工作区重复（AlbumAPI/DuplicateAPI 共用）。
    let curationService: CurationService
    let cullingService: CullingService
    /// P0 / T0：技术质量初筛（只写建议与决策，不写 XMP）。
    let triageService: TriageService
    /// P0 / B0：备份/恢复/诊断。
    let maintenanceService: MaintenanceService
    let exportService: ExportService
    /// W3：整套交付（多配方 + 联系表 + manifest）。
    let outputService: OutputService
    let imagePreloadService: ImagePreloadService
    /// XMP 宿主实现（LiveMetadataAPI 冲突 remote 读 / 孤儿 restore 用）。
    let xmpProvider: any XMPProvider
    /// 唯一交付编排器（四域共用；AppRuntime.start 的启动回放执行者）。
    let deliveryCoordinator: DeliveryCoordinator
    /// P1：元数据交付生命周期（自动确认/结束/备份统计）。
    let metadataDeliveryService: MetadataDeliveryService
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
        // 写目标路由：默认 auto —— 独立 JPEG 直接写内嵌 XMP+IPTC；
        // 有 .xmp / RAW / 有 RAW 兄弟的照片走 sidecar（一份真相）。
        // metadata_write_mode=sidecar 可强制回到全 sidecar（旧行为）。
        let keywordStyle = KeywordDCSubjectStyle(
            rawValue: settingsService.string(.keywordDCSubjectStyle)) ?? .leaf
        // #1：写盘实现搬到 GatherMetadataIO 后，宿主不再下转具体类型——要么用注入的
        // provider（此时目标恒为 sidecar，与旧实现的 as? 失败回退逐字一致），要么用
        // 工厂给出的「provider + 两个解析闭包」。
        let xmp: any XMPProvider
        let targetWritePath: @Sendable (String) -> String
        let targetKind: @Sendable (String) -> MetadataTargetKind
        if let xmpProvider {
            xmp = xmpProvider
            targetWritePath = { SidecarXMPProvider.resolveSidecarPath($0) }
            targetKind = { _ in .sidecar }
        } else {
            let wiring = MetadataIOWiring.makeRouter(
                dcSubjectStyle: keywordStyle,
                modeProvider: {
                    settingsService.string(.metadataWriteMode)
                })
            xmp = wiring.xmp
            targetWritePath = wiring.writePath
            targetKind = wiring.kind
        }
        // 交付层只知道"目标是个文件"：由路由器回答是 sidecar 还是照片自身。
        let targetResolver = MetadataTargetResolver(
            path: { targetWritePath($0) },
            kind: { targetKind($0) })
        let metadataCacheRepo = MetadataCacheRepo(connection: db)
        let assetResolver = PhotoAssetResolver(connection: db, settings: settingsService)
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
        // P1：reload-ack 门禁只在"本机确实装了 Capture One"时启用。旧实现
        // 默认常开，没装 C1 的用户连 confirm 都过不去（cleanup/finalize 死路）。
        //
        // P1-11：原实现就地做两次 `NSWorkspace.urlForApplication`，而这个闭包落在
        // **同步门禁路径**上（DeliveryCoordinator.confirm 每模块一次、
        // isAwaitingReloadAck、state() 被状态条轮询）——每次都问 LaunchServices。
        // 现在改为读 `C1Installation` 的进程级快照：纯内存同步读，重算在后台按
        // TTL 进行（同一份判定也注入 C1 往返协调器，见 AppBootstrap 的 P1-10）。
        C1Installation.warmUp()
        let c1Required: @Sendable () -> Bool = { C1Installation.isInstalled() }
        let deliveryCoordinator = DeliveryCoordinator(
            connection: db, xmp: xmp, fileLock: xmpFileLock, target: targetResolver,
            c1Required: c1Required, eventSink: deliveryEventSink)
        let metadataDeliveryService = MetadataDeliveryService(
            lifecycle: MetadataLifecycleRepo(connection: db),
            coordinator: deliveryCoordinator,
            settings: settingsService)
        let metadataMutationService = MetadataMutationService(
            deliveryRepo: deliveryRepo, xmp: xmp, assetResolver: assetResolver,
            target: targetResolver)
        // P1：内嵌 JPEG 的"一次打开、顺序遍历"会话（embedded_fast_path=0 回旧路径）。
        let rewriteSessions: (any MetadataRewriteSessionFactory)? =
            settingsService.string(.embeddedFastPath) == "0"
            ? nil
            : EmbeddedJPEGSessionFactory(
                isEmbeddedTarget: { photoPath in targetKind(photoPath) == .embedded },
                dcSubjectStyle: keywordStyle)
        let writebackService = WritebackService(
            deliveryRepo: deliveryRepo, xmp: xmp, photoRepo: photoRepo,
            metadataCacheRepo: metadataCacheRepo, connection: db,
            keywordOrigins: MetadataKeywordOriginRepo(connection: db),
            assetResolver: assetResolver, delivery: deliveryCoordinator,
            fileLock: xmpFileLock, target: targetResolver,
            eventSink: deliveryEventSink, rewriteSessions: rewriteSessions)
        // P1-9：构造顺序 MetadataMutationService → WritebackService →
        // MetadataService（无环）；关键词 apply/retry 成功后经闭包立即写盘。
        let keywordIndexSync = KeywordIndexSync(
            index: KeywordRepo(connection: db), metadata: metadataCacheRepo)
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
            origins: MetadataKeywordOriginRepo(connection: db),
            writeTarget: { photoPath in
                MetadataTarget(
                    photoPath: photoPath,
                    kind: targetResolver.kind(photoPath),
                    writePath: targetResolver.path(photoPath))
            },
            keywordIndex: { photoId in
                do {
                    _ = try keywordIndexSync.syncFromCache(photoId: photoId)
                } catch {
                    GatherLogger.log(
                        "keyword index sync failed for \(TSPath.basename(photoId)): \(error)",
                        level: .debug)
                }
            })
        let similarityService = SimilarityService(
            photoRepo: photoRepo, sessionRepo: sessionRepo,
            similarityResultRepo: similarityResultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            // WP3b-2：hash/run/交付项读取经 Persistence 端口，事务经 TransactionRunner。
            hashes: SimilarityHashRepo(connection: db),
            analysisRuns: AnalysisRunRepo(connection: db),
            deliveryItems: deliveryRepo, transactions: db,
            settings: settingsService,
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
        let outputService = OutputService(
            exportService: exportService,
            presentationSource: DatabaseOutputPresentationSource(
                repo: OutputPresentationRepo(connection: db)))
        let imagePreloadService = ImagePreloadService()
        let resolvedFaceKwService = faceKwService ?? FaceKwService(
            photoRepo: photoRepo, sessionRepo: sessionRepo,
            faceRepo: FaceRepo(connection: db), personRepo: personRepo,
            feedback: FaceFeedbackRepo(connection: db),
            analysisRuns: AnalysisRunRepo(connection: db),
            deliveryItems: deliveryRepo, transactions: db,
            settings: settingsService,
            writebackProvider: FaceKwWritebackBridge(writebackService: writebackService),
            delivery: deliveryCoordinator.adapter(for: .faceKeyword))
        let triageService = TriageService(
            repository: TriageRepo(connection: db),
            decisions: CullingDecisionRepo(connection: db),
            history: CullingHistoryRepo(connection: db),
            transactions: db,
            policyProvider: { TriagePolicy.fromSettings(settingsService) },
            enabledProvider: {
                settingsService.bool(.triageEnabled)
            },
            feedback: TriageFeedbackRepo(connection: db))
        // 3.4 CullingService：写回执行器走 WritebackService（CullingWritebackPort），
        // confirm/cleanup/syncStatus 走交付模型（不再注入旧 outbox 仓储）。
        let cullingService = CullingService.make(
            photoRepo: photoRepo, cullingDecisionRepo: CullingDecisionRepo(connection: db),
            similarityResultRepo: similarityResultRepo,
            metadataCacheRepo: metadataCacheRepo,
            // WP3b-2：分页/计数/富查询 SQL 在 Persistence，交付行与事务走端口。
            pageQuery: CullingAssetPageQuery(connection: db),
            richQuery: CullingReadQuery(connection: db),
            deliveryItems: deliveryRepo, transactions: db,
            metadataMutations: metadataMutationService, writeback: writebackService,
            cullingHistoryRepo: CullingHistoryRepo(connection: db),
            settings: settingsService,
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
                // 挑片 rating/label 也落 module=.metadata：写完立即自动确认，
                // 否则这些行永远停在 written，cleanup/finalize 都收不到。
                _ = metadataDeliveryService.autoConfirmAfterWrite(sessionId: sessionId)
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
        let faceRepo = FaceRepo(connection: db)
        let modelReviewService = ModelReviewService(
            photoRepo: photoRepo,
            modelReviewRepo: ModelReviewRepo(connection: db),
            faceBoxes: { sessionId, photoIds in
                try faceRepo.faceBoxes(sessionId: sessionId, photoIds: photoIds).map {
                    ModelReviewFaceBox(
                        photoId: $0.photoId, x: $0.x, y: $0.y,
                        width: $0.width, height: $0.height, quality: $0.quality)
                }
            },
            // P1：语义索引采集（默认关；开启后在 quality.score 的同一次预览解码上写向量）。
            semantics: PhotoSemanticsRepo(connection: db),
            semanticsEnabled: {
                settingsService.bool(.semanticIndexEnabled)
            })
        let indexerService = IndexerService(
            // WP3b-2：扫描写路径/派生失效 SQL 在 IndexerRepo，事务经 TransactionRunner。
            indexer: IndexerRepo(connection: db), transactions: db,
            sessionRepo: sessionRepo, photoRepo: photoRepo, assetRepo: assetRepo,
            // 照片内容/路径变化只失效命中 photoIds 的派生人脸结果。
            faceRepo: FaceRepo(connection: db),
            getDimensions: { path in
                try RAWDecoder.getDimensions(path: path)
            },
            settings: settingsService,
            // 每批新插入的 photo id 交给元数据链路预热；失败不阻断索引主流程。
            warmMetadata: { photoIds in
                guard !photoIds.isEmpty else { return }
                _ = try? await metadataService.getMetadata(photoIds: photoIds)
            })
        let smartAlbumRepo = SmartAlbumRepo(connection: db)
        // #8：四个依赖必须同源（同一个 db），否则嵌套事务退化成两个独立事务。
        let curationService = CurationService(
            collections: CollectionRepo(connection: db),
            stacks: StackRepo(connection: db),
            duplicates: GlobalDuplicateQuery(connection: db),
            transactions: db)
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
            qualityService: qualityService, modelReviewService: modelReviewService,
            indexerService: indexerService,
            metadataService: metadataService, deliveryRepo: deliveryRepo,
            metadataMutationService: metadataMutationService,
            writebackService: writebackService, smartAlbumRepo: smartAlbumRepo,
            curationService: curationService,
            cullingService: cullingService, triageService: triageService,
            maintenanceService: maintenanceService,
            exportService: exportService, outputService: outputService,
            imagePreloadService: imagePreloadService, xmpProvider: xmp,
            deliveryCoordinator: deliveryCoordinator,
            metadataDeliveryService: metadataDeliveryService,
            xmpFileLock: xmpFileLock)
    }
}

// MARK: - 本机是否装了 Capture One（P1-11 / P1-10 共用的唯一判定）

/// "本机是否装了 Capture One"的**全进程唯一判定点**：交付门禁的 `c1Required`
/// 与 C1 往返协调器的 `isC1Installed` 都读它（原先两处各自判定，现在只有这一份）。
///
/// 为什么必须缓存（P1-11）：原实现对每次调用都做两遍
/// `NSWorkspace.urlForApplication(withBundleIdentifier:)`（LaunchServices 查询），
/// 而调用点全在**同步门禁路径**上 —— DeliveryCoordinator 的 confirm（每模块一次）、
/// `isAwaitingReloadAck`、`state()`（UI 状态条轮询）。门禁路径必须是廉价同步读，
/// 所以这里的约定是：
///   · `isInstalled()` 只读下面这把锁里的快照，**不做任何 IO**；
///   · 快照超过 `ttlSeconds` 后仍然返回旧值，把重算交给后台任务
///     （stale-while-revalidate）——绝不把 LaunchServices 查询压在调用者栈上；
///   · 同一时刻最多一个重算在飞（`refreshing`），轮询不会把后台任务堆起来。
/// 有意的副作用：运行中装/卸 C1 后门禁语义最多延迟 `ttlSeconds` 才翻转，
/// 不再"同一进程里时开时关"。
///
/// 为什么不用 NSWorkspace 的 didLaunchApplication / didTerminate 失鲜：只有
/// 运行/退出会发通知，**装/卸载不会**（DMG 拖拽、卸载器删目录都不产生通知），
/// 而门禁关心的是"装没装"；两种机制叠加也只能覆盖一半，不如 TTL 一种机制，
/// 也就不需要长期持有 observer token 的静态存储。
enum C1Installation {
    /// 已知 bundle id。Capture One 16 实机是 **com.captureone.captureone16**
    /// （不是 com.captureone.captureone）；17 预期同形。更早的 21+ / Phase One 品牌保留。
    static let bundleIdentifiers = [
        "com.captureone.captureone15",
        "com.captureone.captureone16",
        "com.captureone.captureone17",
        "com.captureone.captureone",
        "com.phaseone.captureone",
    ]

    /// 标准安装路径兜底：未来版本换 bundle id 时，装在 /Applications 的 C1 仍能被识别。
    /// 为什么不枚举所有 LaunchServices 应用：NSWorkspace 没有"按前缀找 bundle id"的 API，
    /// 逐个版本号穷举会漏掉未来版本；路径兜底覆盖绝大多数安装。
    static let fallbackApplicationPaths = [
        "/Applications/Capture One.app",
        "/Applications/Capture One 16.app",
        "/Applications/Capture One 17.app",
    ]

    /// 快照有效期（秒）：到期后先返回旧值，再后台重算。
    static let ttlSeconds: TimeInterval = 60

    /// 锁内状态：全是值类型，可安全交给锁保管。
    private struct State: Sendable {
        /// nil = 进程内还没算出过结果（warmUp 的首次探测尚未回来）。
        var installed: Bool? = nil
        /// 写入快照的时刻（Date.timeIntervalSinceReferenceDate）。
        var recordedAt: TimeInterval = 0
        /// 是否已有后台重算在飞。
        var refreshing = false
    }

    /// 同步读的结果：快照值 + 是否已过期（过期只触发后台重算，不影响返回值）。
    /// Sendable 是 OSAllocatedUnfairLock.withLock 对返回值的要求（R: Sendable）。
    private struct Reading: Sendable {
        let installed: Bool
        let needsRefresh: Bool
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// 门禁/协调器的同步读入口：纯内存，绝不触发 LaunchServices 查询。
    ///
    /// 快照为空时返回 false（"当作没装"）并触发一次后台重算。方向是刻意的：
    /// 判错成"装了"会让 confirm 走进 reload-ack 死路（P1 的原始 bug），判错成
    /// "没装"最多少拦一次确认。生产里 `warmUp()` 在组合根构造时已发起探测，
    /// 那时还没有任何写回批次可收敛，实际不会命中空快照。
    static func isInstalled() -> Bool {
        let reading = currentReading(now: Date().timeIntervalSinceReferenceDate)
        if reading.needsRefresh { refreshInBackground() }
        return reading.installed
    }

    /// 组合根构造时预热一次：把首次 LaunchServices 探测挪出门禁路径。
    static func warmUp() { refreshInBackground() }

    /// 真正的 LaunchServices 查询（本类型唯一的 IO 点，只在后台任务里跑）。
    /// internal：验收测试可直接断言，不必依赖跑测机器装没装 C1。
    static func probeInstalled(
        bundleIDExists: (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        },
        fileExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> Bool {
        if bundleIdentifiers.contains(where: bundleIDExists) { return true }
        return fallbackApplicationPaths.contains(where: fileExists)
    }

    private static func currentReading(now: TimeInterval) -> Reading {
        state.withLock { current in
            guard let installed = current.installed else {
                return Reading(installed: false, needsRefresh: true)
            }
            return Reading(
                installed: installed,
                needsRefresh: now - current.recordedAt >= ttlSeconds)
        }
    }

    private static func refreshInBackground() {
        let started = state.withLock { current -> Bool in
            guard !current.refreshing else { return false }
            current.refreshing = true
            return true
        }
        guard started else { return }
        Task.detached(priority: .utility) {
            let installed = probeInstalled()
            let now = Date().timeIntervalSinceReferenceDate
            state.withLock { current in
                current.installed = installed
                current.recordedAt = now
                current.refreshing = false
            }
        }
    }
}
