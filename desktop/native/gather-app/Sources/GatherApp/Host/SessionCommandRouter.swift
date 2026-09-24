// desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
// Phase 3/4 宿主与桥：纯 SwiftUI 同进程命令路由。
// 所有当前产品页面所需命令均在下方接入 GatherCore 服务；未知命令仍以
// NOT_IMPLEMENTED 明确失败，避免把协议遗漏伪装成成功。
//
// 接线清单（截至 2026-08-11，对应 NATIVE-DEVELOPMENT-ANALYSIS.md §10.4/§10.6）：
//   同步（execute）：
//     session.* / photo.list → SessionService + PhotoRepo（3.2 服务层）
//     workspace.status → WorkspaceStatusService（3.1 服务层）
//     jobs.list / jobs.cancel / jobs.retry / jobs.clear_completed → JobRunner
//     image.get_dimensions / image.prioritize_thumbnail / image.preload_* →
//       ImagePreloadService + RAWDecoder（2.1/3.6；缩略图任务走 JobRunner）
//     face.models_status → FaceInferenceConfig / Vision provider 状态（2.2）
//     settings.get_all / get / set / reset / set_language / get_ml_status
//       → SettingsService（3.6；TS 源 settings.ipc.ts）
//     filter.photos / photos_global / suggest → FilterEngine（3.6；
//       TS 源 filter.ipc.ts，limit/offset 钳制语义在 IPC 层）
//     navigation.list / split / merge → NavigationService（3.6；
//       TS 源 navigation.ipc.ts）
//     sim.result（同步查询）/ sim.cancel_analysis → SimilarityService（3.3；
//       TS 源 similarity.ipc.ts）
//     photo.list_page → PhotoRepo.getAssetPage + 资产装配（TS 源 photo.ipc.ts）
//     assets.candidates / accept_candidate / reject_candidate / volumes /
//       relink_root → AssetRepo（TS 源 assets.ipc.ts）
//     dup.groups / dup.resolve / dup.resolve_member → DuplicateService（3.6；
//       TS 源 duplicate.ipc.ts）
//     fkw.clusters / bind / merge / remove_member / cancel_analysis →
//       FaceKwService（TS 源 face-kw.ipc.ts；写回族 fkw.unbind / preview /
//       writeback / confirm_sync / cleanup / confirm_cleanup 经 FaceWritebackProvider
//       适配 WritebackService，TS 语义 await → awaitSync 信号量桥接）
//     person.* → PersonRepo（TS 源 person.ipc.ts）
//     template.* → TemplateService（TS 源 template.ipc.ts）
//     quality.get → QualityService（TS 源 quality.ipc.ts）
//     metadata.get / set / batch_set / conflicts / orphans →
//       MetadataService + MetadataSyncCoordinator（TS 源 metadata.ipc.ts；
//       set/batch_set/conflicts 的 TS await → awaitSync 桥接）
//     sim.preview_writeback / writeback / writeback_items /
//       retry_failed_writeback / confirm_sync / cleanup → WritebackService
//       （TS 源 similarity.ipc.ts 190-274 行）
//     album.* → SmartAlbumRepo + FilterEngine（TS 源 filter.ipc.ts
//       registerAlbumHandlers 段）
//     culling.* 同步面（TS 源 culling.ipc.ts）：list_page / history /
//       apply_history / update / batch_update / decide_group / sync_status /
//       finalize_sync（destructive）/ groups / decide / batch_decide / summary /
//       retry_failed_writeback（destructive）/ confirm_sync / cleanup
//       （destructive）/ reset（destructive）→ CullingService（Wave 2；
//       sync/writeback 端口注入真实 MetadataSyncCoordinator / WritebackService）
//   异步（executeAsync）：
//     navigation.analyze → NavigationService.analyze（TS 源 navigation.ipc.ts，
//       TS 侧为 async wrapper 内同步执行，Swift 同步直连）
//     sim.recluster → SimilarityService.recluster（TS 侧 await worker）
//     sim.analyze / dup.scan → JobRunner executor + waitForResult（TS 源
//       similarity.ipc.ts / duplicate.ipc.ts）
//     fkw.analyze → JobRunner executor（face.analyze）+ waitForResult；
//       job abort 经 signal handler 传播给 FaceKwService（TS 源 face-kw.ipc.ts）
//     fkw.recluster → FaceKwService.recluster（TS 源 face-kw.ipc.ts）
//     index.scan / quality.analyze → JobRunner executor（metadata.scan /
//       quality.score）创建即返回 job（TS 源 indexer.ipc.ts / quality.ipc.ts）
//     session.create_from_directory → SessionService.createFromDirectory +
//       metadata.scan job 入队（TS 源 session.ipc.ts）
//     metadata.resolve_conflict / resolve_orphan → MetadataSyncCoordinator
//       （TS 源 metadata.ipc.ts；destructive 二次兜底）
//     culling.writeback / flush / retry_sync → CullingService（TS 源
//       culling.ipc.ts；writeback destructive 二次兜底；bridge 白名单
//       asyncCommands 路由到 executeAsync）
//   export.* → ExportService（预览/原图复制/JPEG-TIFF 转换/XMP/断点续作/report）
import Foundation
import GatherCore

/// 路由实现：注入 GatherCore 服务。
public final class SessionCommandRouter: CommandRouter {
    /// 公开服务访问器（3.1 起供 RootView/DashboardViewModel 同进程直连）。
    public let sessionService: SessionService
    public let workspace: WorkspaceAPI
    public let jobRunner: JobRunner
    /// 设置快照（同步读：服务与命令处理不再触碰设置存储）。
    private let settings: SettingsSnapshot
    /// 设置写路径（异步唯一入口；R5：取代 SettingsService）。
    private let settingsAPI: SettingsAPI
    private let filterEngine: FilterEngine
    private let navigationService: NavigationService
    private let similarityService: SimilarityService
    private let duplicateService: DuplicateService
    private let assetStore: any AssetStore
    private let sessionStore: any SessionStore
    private let photoStore: any PhotoStore
    /// 3.0 接线扩展：人脸关键字 / 人物库 / 模板 / 质量 / 索引 / 元数据 / 写回 / 智能相册。
    private let faceKwService: FaceKwService
    private let persons: PersonsAPI
    private let templates: TemplatesAPI
    private let qualityService: QualityService
    private let indexerService: IndexerService
    private let metadataService: MetadataService
    private let metadataSyncCoordinator: MetadataSyncCoordinator
    private let metadataMutationService: MetadataMutationService
    private let writebackService: WritebackService
    private let albums: AlbumsAPI
    /// 3.4 Culling 模块（CullingRuntime：查询/写回端口注入真实协调器与写回服务）。
    private let culling: CullingRuntime
    public let exportService: ExportService
    private let imagePreloadService: ImagePreloadService

    public init(
        sessionService: SessionService,
        workspace: WorkspaceAPI,
        jobRunner: JobRunner,
        settings: SettingsSnapshot,
        settingsAPI: SettingsAPI,
        filterEngine: FilterEngine,
        navigationService: NavigationService,
        similarityService: SimilarityService,
        duplicateService: DuplicateService,
        assetStore: any AssetStore,
        faceKwService: FaceKwService,
        persons: PersonsAPI,
        templates: TemplatesAPI,
        qualityService: QualityService,
        indexerService: IndexerService,
        metadataService: MetadataService,
        metadataSyncCoordinator: MetadataSyncCoordinator,
        metadataMutationService: MetadataMutationService,
        writebackService: WritebackService,
        albums: AlbumsAPI,
        culling: CullingRuntime,
        exportService: ExportService,
        photoStore: any PhotoStore,
        sessionStore: any SessionStore,
        imagePreloadService: ImagePreloadService
    ) {
        self.sessionService = sessionService
        self.workspace = workspace
        self.jobRunner = jobRunner
        self.settings = settings
        self.settingsAPI = settingsAPI
        self.filterEngine = filterEngine
        self.navigationService = navigationService
        self.similarityService = similarityService
        self.duplicateService = duplicateService
        self.assetStore = assetStore
        self.sessionStore = sessionStore
        self.photoStore = photoStore
        self.faceKwService = faceKwService
        self.persons = persons
        self.templates = templates
        self.qualityService = qualityService
        self.indexerService = indexerService
        self.metadataService = metadataService
        self.metadataSyncCoordinator = metadataSyncCoordinator
        self.metadataMutationService = metadataMutationService
        self.writebackService = writebackService
        self.albums = albums
        self.culling = culling
        self.exportService = exportService
        self.imagePreloadService = imagePreloadService
        // executor 注册是 actor async：由 makeDefault 在装配期 await 完成，
        // 保证返回后立即 create 的作业不会命中 executorNotRegistered。
    }

    /// Capture One 脚本成功后由宿主调用，写入持久 reload ack；页面不得在
    /// AppleScript 失败时伪造该标记。
    public func recordCaptureOneReloadAck(sessionId: String) async throws {
        _ = try await sessionStore.setReloadAckedAt(
            sessionId: sessionId,
            iso: nowISOString()
        )
    }

    /// 优雅停机（applicationShouldTerminate → prepareForTermination，ADR-023）：
    /// 停任务调度器（后续不再发起写回）→ 排空 XMP 协调器在飞任务与计时器
    /// （outbox 行保持 recoverable，下次启动由 start() 恢复）→ 关闭 SQLite。
    public func prepareForTermination() async {
        await jobRunner.stop()
        await metadataSyncCoordinator.shutdown()
        // Store 连接由组合根（GatherApp）负责关闭。
    }

    /// 便捷装配：单 DB 连接构建全部已移植服务。
    /// - xmpProvider：XMP 侧车读写宿主实现（默认 SidecarXMPProvider；测试注入
    ///   内存假件）。
    /// - metadataWriteDebounceMs：协调器写去抖（TS 设置 metadata_write_debounce_ms，
    ///   默认 500；测试注入大值避免后台任务在用例窗口内落盘）。
    /// - faceKwService：默认装配 Vision 推理 + RAWDecoder 解码；测试可注入
    ///   假推理/解码（对齐 gather-core FaceKeywordingServiceTests 模式）。
    public static func makeDefault(
        database: SQLiteDatabase,
        settings: SettingsSnapshot,
        settingsAPI: SettingsAPI,
        templates: TemplatesAPI,
        albums: AlbumsAPI,
        workspace: WorkspaceAPI,
        persons: PersonsAPI,
        personStore: any PersonStore,
        faceStore: any FaceStore,
        metadataStore: any MetadataStore,
        cullingStore: any CullingStore,
        similarityStore: any SimilarityStore,
        writebackStore: any WritebackStore,
        jobStore: any JobStore,
        assetStore: any AssetStore,
        photoStore: any PhotoStore,
        sessionStore: any SessionStore,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) async -> SessionCommandRouter {
        let similarityService = SimilarityService(
            photoStore: photoStore,
            sessionStore: sessionStore,
            similarityStore: similarityStore,
            database: database,
            getNumber: { key, defaultValue in
                settings.number(key, default: defaultValue)
            },
            // 修复（审计 P0-1）：此前未注入 thumbnailProvider（默认恒 nil），
            // 相似度分析全部哈希计算失败 → SIM_NO_HASH_DATA。与
            // DuplicateService 共用同一 RAWDecoder 9x8 灰度管线。
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            }
        )
        // 元数据写回链（TS di/init.ts 组合根）：XMP provider → 协调器 →
        // 变更服务 → 元数据服务 / 写回服务（XMPProvider 为宿主接缝，3.4
        // 正式 exiftool/XML-DOM 桥落位前用 SidecarXMPProvider 保证端到端可用）。
        let xmp = xmpProvider ?? SidecarXMPProvider()
        let assetResolver = PhotoAssetResolver(database: database, getSetting: { key, defaultValue in
            settings.value(key, default: defaultValue)
        })
        let metadataSyncCoordinator = MetadataSyncCoordinator(
            writebackStore: writebackStore,
            xmp: xmp,
            database: database,
            getNumber: { key, defaultValue in
                if key == "metadata_write_debounce_ms", let metadataWriteDebounceMs {
                    return metadataWriteDebounceMs
                }
                return settings.number(key, default: defaultValue)
            }
        )
        let metadataMutationService = MetadataMutationService(
            writebackStore: writebackStore,
            xmp: xmp,
            sync: metadataSyncCoordinator,
            assetResolver: assetResolver
        )
        // UI 对齐（§十一 11.9-1）：写回协调器 emitSummary 后广播 c1-sync-status
        // 事件，驱动 Culling/ControlCenter/Similarity 的同步状态即时刷新。
        metadataSyncCoordinator.eventSink = { (summary: MetadataSyncSummary) in
            Task { @MainActor in
                GatherEventCenter.shared.postC1SyncStatusChange(sessionId: summary.sessionId)
            }
        }
        let metadataService = MetadataService(
            metadataStore: metadataStore,
            xmp: xmp,
            database: database,
            mutations: metadataMutationService,
            assetResolver: assetResolver
        )
        let writebackService = WritebackService(
            writebackStore: writebackStore,
            xmp: xmp,
            photoStore: photoStore,
            sessionStore: sessionStore,
            metadataSync: metadataSyncCoordinator,
            metadataMutations: metadataMutationService,
            metadataStore: metadataStore,
            assetResolver: assetResolver
        )
        let jobRunner = JobRunner(jobStore: jobStore)
        let exportService = ExportService(photoStore: photoStore, sessionStore: sessionStore, database: database)
        let imagePreloadService = ImagePreloadService()
        let resolvedFaceKwService = faceKwService ?? FaceKwService(
            photoStore: photoStore,
            sessionStore: sessionStore,
            faceStore: faceStore,
            personStore: personStore,
            database: database,
            getNumber: { key, defaultValue in
                settings.number(key, default: defaultValue)
            },
            getString: { key, defaultValue in
                settings.value(key, default: defaultValue)
            },
            writebackProvider: FaceKwWritebackBridge(writebackService: writebackService)
        )
        // 3.4 CullingRuntime：查询/写回端口注入真实
        // MetadataSyncCoordinator / WritebackService（CullingSyncPort /
        // CullingWritebackPort 扩展即上述类型，见 CullingService.swift）。
        // LookupLoader 由 Runtime init 内装配（cullingStore 可选），SessionCache
        // 显式传入以保证跨命令复用。
        let culling = CullingRuntime(
            dependencies: CullingRuntime.Dependencies(
                photoStore: photoStore,
                queryStore: SQLiteCullingQueryStore(database: database, photoStore: photoStore),
                cullingStore: cullingStore,
                metadataStore: metadataStore,
                similarityStore: similarityStore,
                writebackStore: writebackStore,
                sessionStore: sessionStore,
                jobStore: jobStore,
                faceStore: faceStore,
                personStore: personStore,
                metadataSync: metadataSyncCoordinator,
                metadataMutations: metadataMutationService,
                writeback: writebackService,
                getNumber: { key, defaultValue in
                    settings.number(key, default: defaultValue)
                }
            ),
            cache: CullingSessionCache()
        )
        let router = SessionCommandRouter(
            sessionService: SessionService(
                sessionStore: sessionStore,
                photoStore: photoStore,
                faceStore: faceStore,
                database: database,
                dimensionsProvider: { path in
                    let dims = try RAWDecoder.getDimensions(path: path)
                    return (dims.width, dims.height)
                },
                assetStore: assetStore
            ),
            workspace: workspace,
            jobRunner: jobRunner,
            settings: settings,
            settingsAPI: settingsAPI,
            filterEngine: FilterEngine(database: database),
            navigationService: NavigationService(database: database),
            similarityService: similarityService,
            duplicateService: DuplicateService(
                database: database,
                thumbnailProvider: { path, size in
                    RAWDecoder.pixels9x8(path: path, maxPixel: size)
                },
                clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
                    try ClusterEngine.clusterByHash(
                        entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                        mode: mode, onProgress: onProgress)
                }
            ),
            assetStore: assetStore,
            faceKwService: resolvedFaceKwService,
            persons: persons,
            templates: templates,
            qualityService: QualityService(
                photoStore: photoStore,
                database: database,
                imageProvider: QualityService.defaultImageProvider,
                statProvider: QualityService.defaultStat
            ),
            indexerService: IndexerService(
                database: database,
                sessionStore: sessionStore,
                photoStore: photoStore,
                assetStore: assetStore,
                getDimensions: { path in
                    try RAWDecoder.getDimensions(path: path)
                },
                getSetting: { key, defaultValue in
                    settings.value(key, default: defaultValue)
                }
            ),
            metadataService: metadataService,
            metadataSyncCoordinator: metadataSyncCoordinator,
            metadataMutationService: metadataMutationService,
            writebackService: writebackService,
            albums: albums,
            culling: culling,
            exportService: exportService,
            photoStore: photoStore,
            sessionStore: sessionStore,
            imagePreloadService: imagePreloadService
        )
        await router.registerExecutors()
        return router
    }

    /// TS di/init.ts 的 executor 注册段（similarity.analyze / duplicate.scan）。
    /// JobRunner 恢复 interrupted 任务时依赖 autoResume 注册表，故装配期
    /// 同步注册（autoResume 默认 true）。
    private func registerExecutors() async {
        await jobRunner.registerExecutor(type: .similarityAnalyze) { [similarityService] job, context in
            // TS similarity.ipc.ts:100-121：abort 时同步取消相似度占用
            // （session 列仅在真正持有者取消时写入，见 SimilarityService.cancel）。
            if context.signal.aborted {
                try? await similarityService.cancel(sessionId: job.scopeId, markStatus: false)
            }
            let checkpoint = job.checkpoint
            try await similarityService.analyze(
                sessionId: job.scopeId,
                threshold: checkpoint["threshold"]?.numberValue,
                minGroupSize: checkpoint["minGroupSize"]?.numberValue,
                groupingMode: checkpoint["groupingMode"]?.stringValue == "sequential" ? .sequential : .global,
                onProgress: { current, total, phase in
                    Task { await context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: checkpoint)) }
                }
            )
            return true
        }

        await jobRunner.registerExecutor(type: .duplicateScan) { [duplicateService] job, context in
            // TS duplicate.ipc.ts:11-20：checkpoint.visualThreshold 为 number
            // 时透传，否则 undefined。
            let result = try await duplicateService.scanDuplicates(
                sessionId: job.scopeId,
                visualThreshold: job.checkpoint["visualThreshold"]?.numberValue.map(Int.init),
                signal: context.signal,
                onProgress: { current, total, phase in
                    Task { await context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: job.checkpoint)) }
                }
            )
            return result
        }

        // TS 源: face-kw.ipc.ts:24-40 —— face.analyze executor。job abort 经
        // signal handler 传播给 FaceKwService 的自持 controller（TS
        // addEventListener('abort') 语义；JobAbortSignal.addHandler 即等价物）。
        await jobRunner.registerExecutor(type: .faceAnalyze) { [faceKwService] job, context in
            context.signal.addHandler {
                faceKwService.cancel(sessionId: job.scopeId)
            }
            let checkpoint = job.checkpoint
            let result = try await faceKwService.analyze(
                sessionId: job.scopeId,
                detectorPath: checkpoint["detectorPath"]?.stringValue ?? "models/face_detector.onnx",
                encoderPath: checkpoint["encoderPath"]?.stringValue ?? "models/face_encoder.onnx",
                eps: checkpoint["eps"]?.numberValue,
                minPts: checkpoint["minSamples"]?.numberValue,
                onProgress: { current, total, phase in
                    Task { await context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: checkpoint)) }
                }
            )
            return result
        }

        // TS 源: quality.ipc.ts:7-12 —— quality.score executor（photoIds 从
        // checkpoint 还原，TS 非数组过滤语义）。
        await jobRunner.registerExecutor(type: .qualityScore) { [qualityService] job, context in
            let photoIds = job.checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue)
            return try await qualityService.analyze(
                sessionId: job.scopeId,
                photoIds: photoIds,
                context: context
            )
        }

        // TS 源: indexer.ipc.ts:26-67 —— metadata.scan executor：扫描 →
        // 元数据提取 → 资产链接对账 → checkpoint 落结果（恢复语义），
        // 剩余待回填 checksum 时入队 checksum.backfill。
        await jobRunner.registerExecutor(type: .metadataScan) { [indexerService, metadataService, photoStore, assetStore, jobRunner] job, context in
            let result = try await indexerService.scanSession(
                sessionId: job.scopeId,
                context: context
            )
            try await context.throwIfCancelled()
            let photoIds = try await photoStore.getBySessionProjection(sessionId: job.scopeId)
                .filter { $0.status != "missing" }
                .map(\.id)
            await context.updateProgress(JobProgressUpdate(
                current: 0, total: photoIds.count, phase: "index.metadata-read"
            ))
            _ = try await metadataService.getMetadata(photoIds: photoIds)
            _ = try await assetStore.reconcileRawJpegLinks(sessionId: job.scopeId)
            await context.updateCheckpoint(["result": try JSONValue(from: result)])
            await context.updateProgress(JobProgressUpdate(
                current: photoIds.count, total: photoIds.count, phase: "index.metadata-done"
            ))
            if (try await indexerService.pendingChecksums(sessionId: job.scopeId)) > 0 {
                _ = try await jobRunner.create(JobCreateParams(
                    type: .checksumBackfill,
                    scopeType: "session",
                    scopeId: job.scopeId,
                    dedupeKey: "checksum.backfill:\(job.scopeId)"
                ))
            }
            return result
        }

        // TS 源: indexer.ipc.ts:26-32 —— checksum.backfill executor（后台回填
        // 懒索引留下的空 checksum）。
        await jobRunner.registerExecutor(type: .checksumBackfill) { [indexerService] job, context in
            let result = try await indexerService.backfillChecksums(
                sessionId: job.scopeId,
                context: context
            )
            return result
        }

        // TS image.ipc.ts：缩略图预加载是低优先级可恢复任务；ImageIO
        // 解码失败按单张跳过，JobRunner 仍负责取消/心跳/终态。
        await jobRunner.registerExecutor(type: .thumbnailBuild) { [imagePreloadService] job, context in
            let paths = job.checkpoint["paths"]?.arrayElements?.compactMap(\.stringValue) ?? []
            let size = Int(job.checkpoint["size"]?.numberValue ?? 1024)
            return try imagePreloadService.buildThumbnails(
                paths: paths,
                size: size,
                signal: context.signal,
                onProgress: { current, total in
                    Task { await context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: "thumbnail.building",
                        checkpoint: [
                            "paths": .array(paths.map(JSONValue.string)),
                            "size": .number(Double(size)),
                            "nextPathIndex": .number(Double(current)),
                        ])) }
                }
            )
        }

        // TS export.ipc.ts：断点状态以 checkpoint 为唯一持久化来源，
        // 避免导出中途退出后重新生成同名文件。
        await jobRunner.registerExecutor(type: .exportExecute) { [exportService] job, context in
            let options: ExportOptions = try self.decodeJSON(
                ExportOptions.self,
                from: job.checkpoint["options"] ?? .object([:])
            )
            var destinations = job.checkpoint["destinations"]?.objectValue?.reduce(into: [String: String]()) { result, item in
                if let value = item.value.stringValue { result[item.key] = value }
            } ?? [:]
            var completedIds = Set(job.checkpoint["completedPhotoIds"]?.arrayElements?.compactMap(\.stringValue) ?? [])
            var completedSnapshot = Array(completedIds)
            let checkpoint: () -> [String: JSONValue] = {
                [
                    "options": (try? JSONValue(from: options)) ?? .object([:]),
                    "destinations": .object(destinations.mapValues(JSONValue.string)),
                    "completedPhotoIds": .array(completedSnapshot.map(JSONValue.string)),
                ]
            }
            context.signal.addHandler { exportService.cancel(sessionId: job.scopeId) }
            let result = try await exportService.execute(
                sessionId: job.scopeId,
                options: options,
                onProgress: { progress in
                    Task { await context.updateProgress(JobProgressUpdate(
                        current: progress.current,
                        total: progress.total,
                        message: progress.status == "error" ? (progress.errorMessage ?? "export.error") : "export.processing",
                        checkpoint: checkpoint())) }
                },
                resume: NativeExportResumeState(
                    destinations: destinations,
                    completedPhotoIds: completedIds,
                    onPlanned: { photoId, destinationName in destinations[photoId] = destinationName },
                    onPlanReady: { Task { await context.updateCheckpoint(checkpoint()) } },
                    onCompleted: { photoId in
                        if completedIds.insert(photoId).inserted { completedSnapshot.append(photoId) }
                        Task { await context.updateProgress(JobProgressUpdate(checkpoint: checkpoint())) }
                    }
                )
            )
            await context.updateCheckpoint(checkpoint())
            return result
        }
    }

    // MARK: CommandRouter

    public func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue {
        switch command {
        // ── session.*（3.2 服务层）──



        case "settings.get_all":
            // settings.ipc.ts:11 —— ok(svc.getAll())：Record<string, string>。
            return .object(settings.values.mapValues(GatherCore.JSONValue.string))

        case "settings.get":
            // settings.ipc.ts:13-16 —— key 校验后 ok(svc.get(key))。
            let key = try validatedString(params, "key", maxLength: 256)
            return .string(settings.value(key))

        case "settings.get_ml_status":
            // settings.ipc.ts:48-79 —— 形状见 Protocol/Settings.swift MLStatusData。
            return try GatherCore.JSONValue(from: buildMLStatus())

        // ── filter.*（3.6 服务层；TS 源 filter.ipc.ts）──

        // ── sim.*（3.3 服务层；TS 源 similarity.ipc.ts）──

        case "sim.cancel_analysis":
            // similarity.ipc.ts:146-157 —— jobs.cancelScope + cancel(markStatus:false)，
            // 同步返回 ok(true)。
            let sessionId = try requiredString(params, "sessionId")
            // cancel 为异步语义：立即返回 ok(true)，取消在后台完成（对齐 TS）。
            Task { [jobRunner, similarityService] in
                _ = try? await jobRunner.cancelScope(type: .similarityAnalyze, scopeId: sessionId)
                try? await similarityService.cancel(sessionId: sessionId, markStatus: false)
            }
            return .bool(true)

        // ── assets.*（3.2 服务层；TS 源 assets.ipc.ts:9-14）──



        // TS: duplicate.ipc.ts:57-75 —— destructive（confirmed 由命令边界校验；
        // 直连路由时二次兜底）；resolution 仅 keep_one/keep_all（ADR-017）。

        // TS: duplicate.ipc.ts:77-92 —— destructive；isKept 缺省 true。

        // ── fkw.*（TS 源 face-kw.ipc.ts）──

        case "fkw.preview":
            // face-kw.ipc.ts:196-214 —— 写回预览（options ?? {}）。
            let sessionId = try requiredString(params, "sessionId")
            let options = try parseWritebackOptions(params["options"])
            let preview = try awaitSync {
                try await self.faceKwService.preview(sessionId: sessionId, options: options)
            }
            return try GatherCore.JSONValue(from: preview)

        case "fkw.writeback":
            // face-kw.ipc.ts:216-230 —— destructive；items 为 WritebackItem[]。
            guard confirmed(params) else {
                throw BridgeError.badParams("WRITEBACK_CONFIRM_REQUIRED")
            }
            let sessionId = try requiredString(params, "sessionId")
            let items = try parseFaceKwWritebackItems(params["items"])
            let result = try awaitSync {
                try await self.faceKwService.writeback(sessionId: sessionId, confirmed: true, items: items)
            }
            return try GatherCore.JSONValue(from: result)

        case "fkw.confirm_sync":
            // face-kw.ipc.ts:232-239 —— ok(true)。
            let sessionId = try requiredString(params, "sessionId")
            let ok = try awaitSync {
                try await self.faceKwService.confirmSync(sessionId: sessionId)
            }
            return .bool(ok)

        case "fkw.confirm_cleanup":
            // face-kw.ipc.ts:241-251 —— destructive；confirmed 非 true 拒绝。
            let sessionId = try requiredString(params, "sessionId")
            let confirmed = optionalBool(params, "confirmed") ?? false
            guard confirmed else {
                throw BridgeError.badParams("FKW_CLEANUP_CONFIRM_REQUIRED")
            }
            let result = try awaitSync {
                try await self.faceKwService.cleanup(sessionId: sessionId, confirmed: true)
            }
            return try GatherCore.JSONValue(from: result)

        case "fkw.cleanup":
            // face-kw.ipc.ts:253-262 —— destructive；同 confirm_cleanup 语义。
            guard confirmed(params) else {
                throw BridgeError.badParams("FKW_CLEANUP_CONFIRM_REQUIRED")
            }
            let sessionId = try requiredString(params, "sessionId")
            let result = try awaitSync {
                try await self.faceKwService.cleanup(sessionId: sessionId, confirmed: true)
            }
            return try GatherCore.JSONValue(from: result)

        case "fkw.cancel_analysis":
            // face-kw.ipc.ts:72-80 —— jobs.cancelScope + cancel，返回 {done:true}。
            let sessionId = try requiredString(params, "sessionId")
            Task { [jobRunner, faceKwService] in
                _ = try? await jobRunner.cancelScope(type: .faceAnalyze, scopeId: sessionId)
                faceKwService.cancel(sessionId: sessionId)
            }
            return .object(["done": .bool(true)])


        case "metadata.get":
            // metadata.ipc.ts:11-18 —— ok(Object.fromEntries(map))。
            let photoIds = try requiredStringArray(params, "photoIds")
            // TS validateStringArray：非空数组（空数组同样拒绝）。
            guard !photoIds.isEmpty else {
                throw BridgeError.badParams("INVALID_PARAM:photoIds")
            }
            let map = try awaitSync {
                try await self.metadataService.getMetadata(photoIds: photoIds)
            }
            var object: [String: GatherCore.JSONValue] = [:]
            for (photoId, tags) in map {
                object[photoId] = try GatherCore.JSONValue(from: tags)
            }
            return .object(object)

        case "metadata.set":
            // metadata.ipc.ts:20-31 —— destructive；tags 为对象。
            guard confirmed(params) else {
                throw BridgeError.badParams("METADATA_SET_CONFIRM_REQUIRED")
            }
            let photoId = try requiredString(params, "photoId")
            let tags = try parseMetadataTags(params["tags"])
            let result = try awaitSync {
                try await self.metadataService.setMetadata(photoId: photoId, tags: tags)
            }
            return try GatherCore.JSONValue(from: result)

        case "metadata.batch_set":
            // metadata.ipc.ts:33-52 —— destructive；updates 非空数组校验。
            guard confirmed(params) else {
                throw BridgeError.badParams("METADATA_BATCH_SET_CONFIRM_REQUIRED")
            }
            guard let updates = params["updates"]?.arrayElements, !updates.isEmpty else {
                throw BridgeError.badParams("Invalid updates: must be a non-empty array")
            }
            let parsed: [(photoId: String, tags: MetadataTags)] = try updates.map { item in
                let object = try requireObject(item, "updates[].photoId")
                let photoId = try requiredSubString(object, "photoId")
                let tags = try parseMetadataTags(object["tags"])
                return (photoId, tags)
            }
            let result = try awaitSync {
                try await self.metadataService.batchSet(updates: parsed)
            }
            return try GatherCore.JSONValue(from: result)

        case "metadata.conflicts":
            // metadata.ipc.ts:54-56 —— ok(getConflicts(sessionId))。
            let sessionId = try requiredString(params, "sessionId")
            let conflicts = try awaitSync {
                try await self.metadataSyncCoordinator.getConflicts(sessionId: sessionId)
            }
            return try GatherCore.JSONValue(from: conflicts)

        case "sim.preview_writeback":
            let sessionId = try requiredString(params, "sessionId")
            let assignments = try validateSimilarityAssignments(params["assignments"])
            let threshold = try optionalNumber(params, "threshold").map { Int($0) }
            return try awaitSync {
                try await self.buildSimilarityKeywordPreview(
                    sessionId: sessionId, assignments: assignments, threshold: threshold)
            }

        case "sim.confirm_sync":
            // similarity.ipc.ts:257-263 —— ok(true)。
            let sessionId = try requiredString(params, "sessionId")
            try awaitSync {
                try await self.writebackService.confirmSync(sessionId: sessionId, module: "similarity")
            }
            return .bool(true)

        case "sim.cleanup":
            // similarity.ipc.ts:265-274 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("WRITEBACK_CLEANUP_CONFIRM_REQUIRED")
            }
            let sessionId = try requiredString(params, "sessionId")
            let result = try awaitSync {
                try await self.writebackService.cleanup(sessionId: sessionId, module: "similarity")
            }
            return try GatherCore.JSONValue(from: result)

        // ── assets.*（TS 源 assets.ipc.ts）──








        case "export.cancel":
            let sessionId = try requiredString(params, "sessionId")
            Task { [jobRunner] in
                _ = try? await jobRunner.cancelScope(type: .exportExecute, scopeId: sessionId)
                exportService.cancel(sessionId: sessionId)
            }
            return .bool(true)


        case "face.models_status":
            // 2.2 决议：Vision 无需模型资产 → 恒 vision provider、无需下载。
            return .object([
                "provider": .string(FaceProvider.vision.rawValue),
                "fallbackToOnnxEnabled": .bool(FaceInferenceConfig().fallbackToOnnxEnabled),
                "modelsPresent": .bool(true),
                "downloading": .bool(false),
            ])

        default:
            throw BridgeError.notImplemented(command)
        }
    }

    public func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping (WebResponse) -> Void
    ) {
        switch command {

        case "dup.resolve_member":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED")); return
            }
            guard let memberId = try? requiredNumber(params, "memberId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:memberId")); return
            }
            let isKept = optionalBool(params, "isKept") ?? true
            Task {
                do {
                    try await duplicateService.resolveMember(memberId: Int(memberId), isKept: isKept)
                    completion(WebResponse(ok: true, data: .bool(true))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }


        case "dup.resolve":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "DUP_RESOLVE_CONFIRM_REQUIRED")); return
            }
            guard let groupId = try? requiredNumber(params, "groupId"),
                  let resolutionRaw = try? requiredString(params, "resolution"),
                  let resolution = DupResolution(rawValue: resolutionRaw) else {
                completion(WebResponse(ok: false, error: "Invalid resolution: must be keep_one or keep_all")); return
            }
            Task {
                do {
                    try await duplicateService.resolveGroup(groupId: Int(groupId), resolution: resolution)
                    completion(WebResponse(ok: true, data: .bool(true))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }


        case "navigation.list":
            Task {
                do {
                    let sessionId = try requiredString(params, "sessionId")
                    let groups = try await navigationService.list(sessionId: sessionId)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: groups))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "navigation.split":
            Task {
                do {
                    let sessionId = try requiredString(params, "sessionId")
                    let groupId = try requiredString(params, "groupId")
                    let beforePhotoId = try requiredString(params, "beforePhotoId")
                    let groups = try await navigationService.split(
                        sessionId: sessionId, groupId: groupId, beforePhotoId: beforePhotoId)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: groups))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "navigation.merge":
            Task {
                do {
                    // ADR-017：服务内部重校验（组数 ≥2 / 同类型），IPC 仅做数组解析。
                    let sessionId = try requiredString(params, "sessionId")
                    let groupIds = try requiredStringArray(params, "groupIds")
                    let groups = try await navigationService.merge(sessionId: sessionId, groupIds: groupIds)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: groups))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }


        case "export.report":
            Task {
                do {
                    let sessionId = try requiredString(params, "sessionId")
                    let reportType = try optionalString(params, "reportType") ?? "session_summary"
                    let format = try optionalString(params, "format")
                    let report = try await exportService.generateReport(
                        sessionId: sessionId, reportType: reportType, format: format)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: report))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }


        case "filter.photos":
            Task {
                do {
                    let sessionId = try requiredString(params, "sessionId")
                    let criteria = try parseFilterCriteria(params)
                    let sortBy = try optionalString(params, "sortBy")
                    let sortOrder = try optionalString(params, "sortOrder")
                    let limit = clampedLimit(params, default: 100, max: 500)
                    let offset = clampedOffset(params)
                    let photos = try await filterEngine.filterPhotos(
                        sessionId: sessionId,
                        criteria: criteria,
                        sortBy: sortBy,
                        sortOrder: sortOrder,
                        limit: limit,
                        offset: offset
                    )
                    completion(WebResponse(ok: true, data: .array(photos.map(filterPhotoDataJSON)))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "filter.photos_global":
            Task {
                do {
                    let criteria = try parseFilterCriteria(params)
                    let sessionId = try optionalString(params, "sessionId")
                    let limit = clampedLimit(params, default: 100, max: 500)
                    let offset = clampedOffset(params)
                    let photos = try await filterEngine.filterGlobally(
                        criteria: criteria,
                        limit: limit,
                        offset: offset,
                        sessionId: sessionId
                    )
                    let total = try await filterEngine.countGlobally(criteria: criteria, sessionId: sessionId)
                    completion(WebResponse(ok: true, data: .object([
                        "photos": try .array(photos.map { try GatherCore.JSONValue(from: $0) }),
                        "total": .number(Double(total)),
                    ]))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "filter.suggest":
            Task {
                do {
                    let sessionId = try requiredString(params, "sessionId")
                    let keyword = try optionalString(params, "keyword") ?? ""
                    let suggestions = try await filterEngine.suggest(sessionId, keyword: keyword)
                    completion(WebResponse(ok: true, data: try .array(suggestions.map { try GatherCore.JSONValue(from: $0) }))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "session.update":
            Task {
                do {
                let id = try requiredString(params, "sessionId")
                let name = try requiredString(params, "name")
                let session = try await sessionService.updateSession(sessionId: id, name: name)
                completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: session))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "session.list":
            Task {
                do {
                let sessions = try await sessionService.listSessions()
                completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: sessions))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "image.get_dimensions":
            Task {
                do {
                if let paths = params["paths"]?.arrayElements?.compactMap(\.stringValue) {
                    var results: [String: GatherCore.JSONValue] = [:]
                    for path in try await allowedPhotoPaths(paths) {
                        if let dims = try? RAWDecoder.getDimensions(path: path) {
                            results[path] = .object([
                                "width": .number(Double(dims.width)),
                                "height": .number(Double(dims.height)),
                            ])
                        }
                    }
                    completion(WebResponse(ok: true, data: .object(results))); return
                }
                let path = try requiredString(params, "path")
                try await requirePhotoPath(path)
                let dims = try RAWDecoder.getDimensions(path: path)
                completion(WebResponse(ok: true, data: .object([
                    "width": .number(Double(dims.width)), "height": .number(Double(dims.height)),
                ]))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "image.preload_previews":
            Task {
                do {
                let paths = try await allowedPhotoPaths(params["paths"]?.arrayElements?.compactMap(\.stringValue) ?? [])
                let maxDimension = Int((try? optionalNumber(params, "maxDimension")) ?? 2048)
                imagePreloadService.preloadPreviews(paths: paths, maxDimension: maxDimension)
                completion(WebResponse(ok: true, data: .null)); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "image.prioritize_thumbnail":
            Task {
                do {
                let path = try requiredString(params, "path")
                try await requirePhotoPath(path)
                let size = Int((try? optionalNumber(params, "size")) ?? settings.number("thumbnail_size", default: 1024))
                try imagePreloadService.prioritizeThumbnail(path: path, size: size)
                completion(WebResponse(ok: true, data: .null)); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "photo.list":
            Task {
                do {
                    let sessionId = try requiredString(params, "sessionId")
                    let photos = try await photoStore.getBySessionProjection(sessionId: sessionId)
                    // 轻投影列（列名与 TS PhotoProjection 逐字一致）。
                    let payload: [GatherCore.JSONValue] = photos.map { row in
                        .object([
                            "id": .string(row.id),
                            "session_id": .string(row.sessionId),
                            "filepath": .string(row.filepath),
                            "filename": .string(row.filename),
                            "checksum": .string(row.checksum),
                            "checksum_file_size": .number(Double(row.checksumFileSize)),
                            "checksum_file_mtime_ms": .number(row.checksumFileMtimeMs),
                            "status": .string(row.status),
                            "width": .number(Double(row.width)),
                            "height": .number(Double(row.height)),
                            "created_at": .string(row.createdAt),
                            "updated_at": .string(row.updatedAt),
                        ])
                    }
                    completion(WebResponse(ok: true, data: .array(payload))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "session.add_photos":
            Task {
                do {
                let id = try requiredString(params, "sessionId")
                let filepaths = try requiredStringArray(params, "filepaths")
                let source = try optionalString(params, "source") ?? "import"
                let result = try await sessionService.addPhotos(sessionId: id, filepaths: filepaths, source: source)
                completion(WebResponse(ok: true, data: .object([
                    "added": .number(Double(result.added)),
                    "skipped": .number(Double(result.skipped)),
                    "total": .number(Double(result.total)),
                    "failedFiles": .array(result.failedFiles.map(GatherCore.JSONValue.string)),
                ]))); return

            // ── photo.*（3.2 服务层）──
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "session.create":
            Task {
                do {
                // TS session.ipc.ts createSessionParams：source 缺省 "manual"（非 "folder"）。
                let name = try requiredString(params, "name")
                let source = try optionalString(params, "source") ?? "manual"
                let sourcePath = try optionalString(params, "sourcePath") ?? ""
                let truncatedImport = optionalBool(params, "truncatedImport") ?? false
                let session = try await sessionService.createSession(
                    name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
                // TS 契约：filepaths 传入时创建即导入（addPhotos），返回
                // {session, failedFiles, added, skipped}；照片落库后重取会话
                // （status/photoCount 已更新），对齐 DashboardViewModel
                // LiveDashboardDataProvider.createSessionFromFiles。
                if let filepaths = try optionalStringArray(params, "filepaths"), !filepaths.isEmpty {
                    let result = try await sessionService.addPhotos(
                        sessionId: session.id, filepaths: filepaths, source: source)
                    let refreshed = try await sessionService.getSession(session.id) ?? session
                    completion(WebResponse(ok: true, data: .object([
                        "session": try GatherCore.JSONValue(from: refreshed),
                        "failedFiles": .array(result.failedFiles.map(GatherCore.JSONValue.string)),
                        "added": .number(Double(result.added)),
                        "skipped": .number(Double(result.skipped)),
                    ]))); return
                }
                completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: session))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "session.get":
            Task {
                do {
                let id = try requiredString(params, "sessionId")
                guard let session = try await sessionService.getSession(id) else {
                    throw BridgeError.notFound("SESSION_NOT_FOUND")
                }
                completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: session))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "quality.get":
            Task {
                do {
                // quality.ipc.ts:25-30 —— photoIds 可选（validateStringArray 语义）。
                let sessionId = try requiredString(params, "sessionId")
                let photoIds = try optionalStringArray(params, "photoIds")
                let results = try await qualityService.get(sessionId: sessionId, photoIds: photoIds)
                completion(WebResponse(ok: true, data: try await GatherCore.JSONValue(from: results))); return

            // ── metadata.*（TS 源 metadata.ipc.ts）──
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "export.preview":
            Task {
                do {
                let sessionId = try requiredString(params, "sessionId")
                let options = try decodeExportOptions(params["options"] ?? .object([:]))
                completion(WebResponse(ok: true, data: try await GatherCore.JSONValue(from: exportService.preview(sessionId: sessionId, options: options)))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "assets.candidates":
            Task {
                do {
                let sessionId = try optionalString(params, "sessionId")
                completion(WebResponse(ok: true, data: try await GatherCore.JSONValue(from: assetStore.listCandidates(sessionId: sessionId)))); return

            // ── dup.*（3.6 服务层；TS 源 duplicate.ipc.ts）──

            // TS: duplicate.ipc.ts:46-55 —— ok(getGroups(sessionId))。
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "assets.accept_candidate":
            Task {
                do {
                // assets.ipc.ts:15-19 —— destructive。
                guard confirmed(params) else {
                    throw BridgeError.badParams("ASSET_LINK_ACCEPT_CONFIRM_REQUIRED")
                }
                let candidateId = try requiredString(params, "candidateId")
                // 仓库层 SQLiteFailure.message → BridgeError（命令边界仅对 BridgeError
                // 走 message 透传；NSError 桥接会丢失消息）。
                _ = try await mapRepoErrorAsync { try await assetStore.acceptCandidate(candidateId) }
                completion(WebResponse(ok: true, data: .bool(true))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "assets.reject_candidate":
            Task {
                do {
                // assets.ipc.ts:20-24 —— destructive。
                guard confirmed(params) else {
                    throw BridgeError.badParams("ASSET_LINK_REJECT_CONFIRM_REQUIRED")
                }
                let candidateId = try requiredString(params, "candidateId")
                _ = try await mapRepoErrorAsync { try await assetStore.rejectCandidate(candidateId) }
                completion(WebResponse(ok: true, data: .bool(true))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "assets.volumes":
            Task {
                do {
                // assets.ipc.ts:25-27 —— ok(listVolumes())。
                completion(WebResponse(ok: true, data: try await GatherCore.JSONValue(from: assetStore.listVolumes()))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "assets.relink_root":
            Task {
                do {
                // assets.ipc.ts:28-34 —— destructive。
                guard confirmed(params) else {
                    completion(WebResponse(ok: false, error: "ASSET_RELINK_CONFIRM_REQUIRED")); return
                }
                let oldRoot = try requiredString(params, "oldRoot")
                let newRoot = try requiredString(params, "newRoot")
                let relinkResult = try await mapRepoErrorAsync {
                    try await assetStore.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
                }
                completion(WebResponse(ok: true, data: .number(Double(relinkResult.relocatedFiles)))); return
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        case "image.preload_thumbnails":
            Task {
                do {
                    let paths = try await allowedPhotoPaths(params["paths"]?.arrayElements?.compactMap(\.stringValue) ?? [])
                    guard !paths.isEmpty else { completion(WebResponse(ok: true, data: .null)); return }
                    let size = Int((try? optionalNumber(params, "size")) ?? settings.number("thumbnail_size", default: 1024))
                    let fingerprint = paths.joined(separator: "\u{0}")
                    let job = try await jobRunner.create(JobCreateParams(
                        type: .thumbnailBuild,
                        scopeType: "paths",
                        scopeId: paths[0],
                        dedupeKey: "thumbnail.build:\(size):\(fingerprint)",
                        priority: -1,
                        checkpoint: [
                            "paths": .array(paths.map(JSONValue.string)),
                            "size": .number(Double(size)),
                        ]
                    ))
                    completion(WebResponse(ok: true, data: .string(job.id))); return


                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }



        // ── jobs.*（Store 化后并入异步路由）──
        case "jobs.list":
            Task {
                do {
                    let jobs = try await jobRunner.list()
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: jobs)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "jobs.cancel":
            guard let jobId = try? requiredString(params, "jobId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:jobId"))
                return
            }
            Task {
                do {
                    completion(WebResponse(ok: true, data: .bool(try await jobRunner.cancel(jobId))))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "jobs.retry":
            guard let jobId = try? requiredString(params, "jobId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:jobId"))
                return
            }
            Task {
                do {
                    completion(WebResponse(ok: true, data: .bool(try await jobRunner.retry(jobId))))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "jobs.clear_completed":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "JOBS_CLEAR_CONFIRM_REQUIRED"))
                return
            }
            Task {
                do {
                    completion(WebResponse(ok: true, data: .number(Double(try await jobRunner.clearCompleted()))))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: navigation.ipc.ts:6-15 —— async wrapper 内同步执行 analyze；
        // Swift 同步直连（与 TS 一致：主进程事件循环内同步 CPU + 同步 SQLite）。
        case "navigation.analyze":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let burstGapSeconds = try? optionalNumber(params, "burstGapSeconds")
            let sceneGapSeconds = try? optionalNumber(params, "sceneGapSeconds")
            let dryRun = optionalBool(params, "dryRun") ?? false
            Task {
                do {
                    let groups = try await navigationService.analyze(
                        sessionId: sessionId,
                        burstGapSeconds: burstGapSeconds ?? 2,
                        sceneGapSeconds: sceneGapSeconds ?? 1_800,
                        dryRun: dryRun
                    )
                    let data = try GatherCore.JSONValue(from: groups)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: similarity.ipc.ts:169-187 —— 阈值重聚类（await worker）。
        case "sim.recluster":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let threshold = (try? optionalNumber(params, "threshold"))
                        ?? settings.number("default_threshold", default: 10)
                    let minGroupSize = (try? optionalNumber(params, "minGroupSize"))
                        ?? settings.number("default_min_group_size", default: 2)
                    let groupingMode: SimilarityGroupingMode
                    if let raw = try? optionalString(params, "groupingMode"), raw == "sequential" {
                        groupingMode = .sequential
                    } else {
                        groupingMode = .global
                    }
                    try validateSimilarityParameters(threshold: threshold, minGroupSize: minGroupSize)
                    let result = try await similarityService.recluster(
                        sessionId: sessionId,
                        threshold: threshold,
                        minGroupSize: minGroupSize,
                        groupingMode: groupingMode
                    )
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: similarity.ipc.ts:100-144 —— 建 job 走 executor + waitForResult。
        // 阈值/组大小缺省走设置（默认 10/2），checkpoint/dedupeKey 逐字对齐 TS。
        case "sim.analyze":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let threshold = try? optionalNumber(params, "threshold")
            let minGroupSize = try? optionalNumber(params, "minGroupSize")
            let groupingMode: SimilarityGroupingMode
            if let raw = try? optionalString(params, "groupingMode"), raw == "sequential" {
                groupingMode = .sequential
            } else {
                groupingMode = .global
            }
            Task {
                do {
                    try validateSimilarityParameters(
                        threshold: threshold ?? settings.number("default_threshold", default: 10),
                        minGroupSize: minGroupSize ?? settings.number("default_min_group_size", default: 2)
                    )
                    // TS: threshold ?? 'default'（undefined 时不输出数值）。
                    let dedupeThreshold = threshold.map { String($0) } ?? "default"
                    let dedupeMinGroupSize = minGroupSize.map { String($0) } ?? "default"
                    let job = try await jobRunner.create(JobCreateParams(
                        type: .similarityAnalyze,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "similarity.analyze:\(sessionId):\(dedupeThreshold):\(dedupeMinGroupSize):\(groupingMode.rawValue)",
                        checkpoint: [
                            "threshold": threshold.map { .number($0) } ?? .null,
                            "minGroupSize": minGroupSize.map { .number($0) } ?? .null,
                            "groupingMode": .string(groupingMode.rawValue),
                        ]
                    ))
                    _ = try await jobRunner.waitForResult(jobId: job.id) as Any?
                    completion(WebResponse(ok: true, data: .bool(true)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: duplicate.ipc.ts:11-20（executor）+ 21-44（dup.scan 命令）——
        // checkpoint.visualThreshold 为 number 时透传；结果原样返回。
        case "dup.scan":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let visualThreshold = try? optionalNumber(params, "visualThreshold")
            Task {
                do {
                    let job = try await jobRunner.create(JobCreateParams(
                        type: .duplicateScan,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "duplicate.scan:\(sessionId):\(visualThreshold.map { "\($0)" } ?? "default")",
                        checkpoint: [
                            "visualThreshold": visualThreshold.map { .number($0) } ?? .null,
                        ]
                    ))
                    let result: DuplicateScanResult? = try await jobRunner.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobRunnerError.jobFailed(job.id, "empty duplicate.scan result")
                    }
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: face-kw.ipc.ts:41-62 —— 建 job 走 face.analyze executor +
        // waitForResult；eps/minSamples/detectorPath/encoderPath 缺省走设置。
        case "fkw.analyze":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let eps = try? optionalNumber(params, "eps")
            let minSamples = try? optionalNumber(params, "minSamples")
            let detectorPath = (try? optionalString(params, "detectorPath"))
                ?? settings.value("detector_model_path", default: "models/face_detector.onnx")
            let encoderPath = (try? optionalString(params, "encoderPath"))
                ?? settings.value("encoder_model_path", default: "models/face_encoder.onnx")
            Task {
                do {
                    try validateFaceClusteringParameters(
                        eps: eps ?? settings.number("default_eps", default: 0.6),
                        minPts: minSamples ?? settings.number("default_min_samples", default: 2)
                    )
                    let job = try await jobRunner.create(JobCreateParams(
                        type: .faceAnalyze,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "face.analyze:\(sessionId):\(detectorPath):\(encoderPath):\(eps ?? 0.6):\(minSamples ?? 2)",
                        checkpoint: [
                            "detectorPath": .string(detectorPath),
                            "encoderPath": .string(encoderPath),
                            "eps": eps.map { .number($0) } ?? .null,
                            "minSamples": minSamples.map { .number($0) } ?? .null,
                        ]
                    ))
                    let result: FaceAnalysisResult? = try await jobRunner.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobRunnerError.jobFailed(job.id, "empty fkw.analyze result")
                    }
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: face-kw.ipc.ts:82-96 —— 仅重聚类（不重推理），返回 {done:true}。
        case "fkw.recluster":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let eps = try? optionalNumber(params, "eps")
            let minSamples = try? optionalNumber(params, "minSamples")
            Task {
                do {
                    let epsValue = eps ?? settings.number("default_eps", default: 0.6)
                    let minSamplesValue = minSamples ?? settings.number("default_min_samples", default: 2)
                    try validateFaceClusteringParameters(eps: epsValue, minPts: minSamplesValue)
                    try await faceKwService.recluster(sessionId: sessionId, eps: epsValue, minPts: minSamplesValue)
                    completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: face-kw.ipc.ts:125-262 —— fkw 写回族：同步侧已有实现，
        // 这里补齐 executeAsync 转发分支（executeAsync 无分支会 NOT_IMPLEMENTED）。
        case "fkw.unbind":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "FKW_UNBIND_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            guard let clusterId = try? requiredNumber(params, "clusterId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:clusterId"))
                return
            }
            Task {
                do {
                    let result = try await faceKwService.unbind(
                        sessionId: sessionId, clusterId: Int64(clusterId), confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "fkw.preview":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let options = (try? parseWritebackOptions(params["options"])) ?? FaceKwWritebackOptions()
            Task {
                do {
                    let preview = try await faceKwService.preview(sessionId: sessionId, options: options)
                    let data = try GatherCore.JSONValue(from: preview)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "fkw.writeback":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            // TS face-kw.ipc.ts:223 `(params.items ?? [])` —— 非数组抛
            // FKW_ITEMS_INVALID（对齐同步分支，不静默降级为空数组）。
            let items: [FaceKwWritebackItem]
            do {
                items = try parseFaceKwWritebackItems(params["items"]) ?? []
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                return
            }
            Task {
                do {
                    let result = try await faceKwService.writeback(sessionId: sessionId, confirmed: true, items: items)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "fkw.confirm_sync":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let ok = try await faceKwService.confirmSync(sessionId: sessionId)
                    completion(WebResponse(ok: true, data: .bool(ok)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "fkw.confirm_cleanup":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "FKW_CLEANUP_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let result = try await faceKwService.cleanup(sessionId: sessionId, confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "fkw.cleanup":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "FKW_CLEANUP_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let result = try await faceKwService.cleanup(sessionId: sessionId, confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // 审计 P0-2 修复：页面走 executeAsync 的 5 个命令此前落入
        // NOT_IMPLEMENTED（dup.groups 导致重复页整页打不开、culling/sim 的
        // cleanup/retry 失效）。补转发分支（Task 内 await，与同步分支同语义）。
        case "dup.groups":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let data = try GatherCore.JSONValue(from: await duplicateService.getGroups(sessionId: sessionId))
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "culling.retry_failed_writeback":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_RETRY_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let result = try await culling.retryFailedWriteback(sessionId: sessionId, confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "culling.cleanup":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_CLEANUP_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let result = try await culling.cleanup(sessionId: sessionId, confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // culling.ipc.ts:360-370 —— 协调器确认 + 写回项存在时的写回确认；ok(true)。
        case "culling.confirm_sync":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    try await culling.confirmSync(sessionId: sessionId)
                    completion(WebResponse(ok: true, data: .bool(true)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "sim.retry_failed_writeback":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_RETRY_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let result = try await writebackService.retryFailed(sessionId: sessionId, module: "similarity")
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "sim.cleanup":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_CLEANUP_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let result = try await writebackService.cleanup(sessionId: sessionId, module: "similarity")
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: indexer.ipc.ts:68-77 —— 建 metadata.scan job 即返回
        // （progress 走 jobs:progress 事件/轮询，不等完成）。
        case "index.scan":            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let job = try await jobRunner.create(JobCreateParams(
                        type: .metadataScan,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "metadata.scan:\(sessionId)"
                    ))
                    let data = try GatherCore.JSONValue(from: job)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: quality.ipc.ts:13-24 —— 建 quality.score job 即返回。
        case "quality.analyze":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let photoIds = try? optionalStringArray(params, "photoIds")
            // TS validateStringArray：提供但为空 → INVALID_PARAM。
            if let photoIds, photoIds.isEmpty {
                completion(WebResponse(ok: false, error: "INVALID_PARAM:photoIds"))
                return
            }
            Task {
                do {
                    let job = try await jobRunner.create(JobCreateParams(
                        type: .qualityScore,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "quality.score:\(sessionId):\(photoIds?.sorted().joined(separator: ",") ?? "all")",
                        checkpoint: [
                            "photoIds": photoIds.map { .array($0.map(JSONValue.string)) } ?? .null,
                        ]
                    ))
                    let data = try GatherCore.JSONValue(from: job)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: session.ipc.ts:36-59 —— 一跳导入：建会话 + metadata.scan job
        // 入队；job 创建失败回滚会话行。
        case "session.create_from_directory":
            let name = (try? optionalString(params, "name")) ?? ""
            guard let sourcePath = try? requiredString(params, "sourcePath") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sourcePath"))
                return
            }
            Task {
                do {
                    let session = try await sessionService.createFromDirectory(name: name, sourcePath: sourcePath)
                    do {
                        _ = try await jobRunner.create(JobCreateParams(
                            type: .metadataScan,
                            scopeType: "session",
                            scopeId: session.id,
                            dedupeKey: "metadata.scan:\(session.id)"
                        ))
                    } catch {
                        // TS: 入队失败回滚会话行，工作区列表不出现半成品会话。
                        // R1/R2：删除依赖 face Store（async），经 Task 排队后抛出原始错误。
                        let rollbackId = session.id
                        Task { try? await sessionService.deleteSession(rollbackId, confirmed: true) }
                        throw error
                    }
                    let data = try GatherCore.JSONValue(from: session)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "metadata.resolve_conflict":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            guard let xmpPath = try? requiredString(params, "xmpPath") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:xmpPath"))
                return
            }
            guard let choicesValue = params["choices"], let choicesObject = choicesValue.objectValue else {
                completion(WebResponse(ok: false, error: "choices must be an object"))
                return
            }
            var choices: [MetadataField: MetadataConflictChoice] = [:]
            for (field, choice) in choicesObject {
                guard let fieldEnum = MetadataField(rawValue: field) else {
                    completion(WebResponse(ok: false, error: "Invalid metadata field: \(field)"))
                    return
                }
                guard let raw = choice.stringValue,
                      let choiceEnum = MetadataConflictChoice(rawValue: raw) else {
                    completion(WebResponse(ok: false, error: "Invalid conflict choice: \(choice.stringValue ?? "")"))
                    return
                }
                choices[fieldEnum] = choiceEnum
            }
            Task {
                do {
                    let summary = try await metadataSyncCoordinator.resolveConflict(
                        sessionId: sessionId, xmpPath: xmpPath, choices: choices)
                    let data = try GatherCore.JSONValue(from: summary)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: metadata.ipc.ts:80-89 —— destructive；action 校验。
        case "metadata.resolve_orphan":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED"))
                return
            }
            guard let xmpPath = try? requiredString(params, "xmpPath") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:xmpPath"))
                return
            }
            guard let rawAction = try? requiredString(params, "action"),
                  let action = MetadataOrphanAction(rawValue: rawAction) else {
                completion(WebResponse(ok: false, error: "Invalid orphan action"))
                return
            }
            Task {
                do {
                    let orphans = try await metadataSyncCoordinator.resolveOrphan(xmpPath: xmpPath, action: action)
                    let data = try GatherCore.JSONValue(from: orphans)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: culling.ipc.ts:296-334 —— destructive 写回（桥层
        // CONFIRMATION_REQUIRED + 直连路由 WRITEBACK_CONFIRM_REQUIRED 二次兜底）；
        // 决策计划 → preview → 属性合并 → execute（asyncCommands 白名单路由）。
        case "culling.writeback":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            guard let targetRaw = try? requiredString(params, "target") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:target"))
                return
            }
            guard let target = CullingWritebackTarget(rawValue: targetRaw) else {
                completion(WebResponse(ok: false, error: "Invalid target: must be rating, color_label, or keyword"))
                return
            }
            Task {
                do {
                    let result = try await culling.writeback(
                        sessionId: sessionId, target: target, confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: culling.ipc.ts:223-229 —— 取消计时器后并行冲刷会话内
        // pending/writing/failed 行（asyncCommands 白名单路由）。
        case "culling.flush":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let summary = try await culling.flush(sessionId: sessionId)
                    let data = try GatherCore.JSONValue(from: summary)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS 源: culling.ipc.ts:231-237 —— failed 行重置后整体 flush。
        case "culling.retry_sync":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let summary = try await culling.retrySync(sessionId: sessionId)
                    let data = try GatherCore.JSONValue(from: summary)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // TS export.ipc.ts：preview 为 async IPC，execute 创建可恢复导出 job
        // 并等待结果；路由仍保留 destructive confirmation 检查。
        case "export.preview":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let options = try self.decodeExportOptions(params["options"] ?? .object([:]))
                    let preview = try await self.exportService.preview(sessionId: sessionId, options: options)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: preview)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "export.execute":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "EXPORT_CONFIRMATION_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let options = try self.decodeExportOptions(params["options"] ?? .object([:]))
                    // makeDefault 的 router 可被 CLI/测试直接调用；start 是幂等的，
                    // 这里确保 export.execute 不会因宿主忘记启动 job service 而永久 queued。
                    await self.jobRunner.start()
                    let job = try await self.jobRunner.create(JobCreateParams(
                        type: .exportExecute,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "export.execute:\(sessionId)",
                        checkpoint: ["options": try GatherCore.JSONValue(from: options)]
                    ))
                    let result: ExportResult? = try await self.jobRunner.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobRunnerError.jobFailed(job.id, "empty export.execute result")
                    }
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // ── settings.*（写路径：R5 起唯一经 SettingsAPI，异步落库）──

        case "settings.set":
            do {
                let key = try validatedString(params, "key", maxLength: 256)
                let value = try validatedString(params, "value", maxLength: 4096, allowEmpty: true)
                Task {
                    do {
                        try await settingsAPI.set(key, value: value)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "settings.reset":
            Task {
                do {
                    try await settingsAPI.reset()
                    let snapshot = await settingsAPI.snapshot()
                    completion(WebResponse(
                        ok: true,
                        data: .object(snapshot.values.mapValues { GatherCore.JSONValue.string($0) })
                    ))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "settings.set_language":
            do {
                guard let language = try optionalString(params, "language"),
                      language == "zh-CN" || language == "en"
                else {
                    throw BridgeError.badParams("SETTINGS_LANGUAGE_INVALID")
                }
                Task {
                    do {
                        try await settingsAPI.set("ui_language", value: language)
                        NotificationCenter.default.post(
                            name: GatherAppNotification.languageChanged, object: language)
                        completion(WebResponse(ok: true, data: .object(["language": .string(language)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── person.*（R1/R5：经 PersonsAPI，异步路径）──

        // ── fkw.*（R1/R5：经 PersonStore，异步路径）──

        case "fkw.bind":
            do {
                // face-kw.ipc.ts:107-123 —— clusterId/roleName/keywords 校验后绑定。
                let sessionId = try requiredString(params, "sessionId")
                let clusterId = try requiredNumber(params, "clusterId")
                let roleName = try requiredString(params, "roleName")
                // TS FKW_KEYWORDS_INVALID：非数组或含非字符串元素即拒绝。
                guard case .array(let keywordValues)? = params["keywords"],
                      keywordValues.allSatisfy({ $0.stringValue != nil })
                else {
                    throw BridgeError.badParams("FKW_KEYWORDS_INVALID")
                }
                let keywords = keywordValues.compactMap(\.stringValue)
                Task {
                    do {
                        try await faceKwService.bindCluster(
                            sessionId: sessionId, clusterId: Int64(clusterId),
                            roleName: roleName, keywords: keywords)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "fkw.unbind":
            do {
                // face-kw.ipc.ts:125-172 —— destructive；removeOwnedFaceKeywords + 解除绑定。
                guard confirmed(params) else {
                    throw BridgeError.badParams("FKW_UNBIND_CONFIRM_REQUIRED")
                }
                let sessionId = try requiredString(params, "sessionId")
                let clusterId = try requiredNumber(params, "clusterId")
                Task {
                    do {
                        let result = try await faceKwService.unbind(
                            sessionId: sessionId, clusterId: Int64(clusterId), confirmed: true)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "fkw.merge":
            do {
                // face-kw.ipc.ts:174-183 —— 源/目标簇合并。
                let sessionId = try requiredString(params, "sessionId")
                let source = try requiredNumber(params, "source")
                let target = try requiredNumber(params, "target")
                Task {
                    do {
                        try await faceKwService.mergeClusters(
                            sessionId: sessionId, sourceId: Int64(source), targetId: Int64(target))
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "fkw.remove_member":
            do {
                // face-kw.ipc.ts:185-194 —— 从簇中移除成员。
                let sessionId = try requiredString(params, "sessionId")
                let clusterId = try requiredNumber(params, "clusterId")
                let memberId = try requiredNumber(params, "memberId")
                Task {
                    do {
                        try await faceKwService.removeMember(
                            sessionId: sessionId, clusterId: Int64(clusterId), memberId: Int64(memberId))
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:336-347 —— destructive；groupId 可选（整会话或按组）。
        case "culling.reset":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "CULLING_RESET_CONFIRM_REQUIRED"))
                return
            }
            do {
                let sessionId = try requiredString(params, "sessionId")
                let groupId = try optionalString(params, "groupId")
                Task {
                    do {
                        try await culling.resetCommand(
                            sessionId: sessionId, groupId: groupId, confirmed: true)
                        completion(WebResponse(ok: true, data: .bool(true)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // similarity.ipc.ts:159-167 —— 同步查询；无结果返回 null（TS ok(null)）。
        case "sim.result":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let threshold = try optionalNumber(params, "threshold").map(Int.init)
                Task {
                    do {
                        guard let result = try await similarityService.getResult(
                            sessionId: sessionId, threshold: threshold) else {
                            completion(WebResponse(ok: true, data: .null))
                            return
                        }
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // similarity.ipc.ts:205-235 —— destructive；itemIds 必填非空。
        case "sim.writeback":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_CONFIRM_REQUIRED"))
                return
            }
            do {
                let sessionId = try requiredString(params, "sessionId")
                let threshold = try optionalNumber(params, "threshold").map { Int($0) }
                let itemIds: [Int] = params["itemIds"]?.arrayElements?
                    .compactMap(\.numberValue)
                    .filter { $0.rounded() == $0 }
                    .map { Int($0) } ?? []
                guard !itemIds.isEmpty else {
                    throw BridgeError.badParams("SIM_PREVIEW_REQUIRED")
                }
                let idSet = Set(itemIds)
                Task {
                    do {
                        if let threshold,
                           !(try await similarityService.hasResult(sessionId: sessionId, threshold: threshold)) {
                            throw BridgeError.badParams("SIM_THRESHOLD_NO_RESULTS")
                        }
                        let pendingItems = try await writebackService.getItems(
                            sessionId: sessionId, module: "similarity", status: "pending")
                            .filter { item in item.id.map { idSet.contains($0) } ?? false }
                        guard pendingItems.count == idSet.count else {
                            throw BridgeError.badParams("SIM_PREVIEW_STALE")
                        }
                        let result = try await writebackService.execute(
                            sessionId: sessionId, module: "similarity", items: pendingItems)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "sim.writeback_items":
            do {
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        let items = try await writebackService.getItems(
                            sessionId: sessionId, module: "similarity")
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: items)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "culling.sync_status":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let summary = try await culling.syncStatus(sessionId: sessionId)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: summary)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "metadata.orphans":
            Task {
                do {
                    let orphans = try await metadataSyncCoordinator.listOrphans()
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: orphans)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        // ── culling 读路径（R1/R2：richLookup 经 MetadataStore，异步路径）──

        // culling.ipc.ts:83-107 —— 资产分组 keyset 分页；scope 白名单 +
        // afterRowId/limit 校验（limit 缺省 200，上限 2000）。
        case "culling.list_page":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let scopeRaw = try requiredString(params, "scope")
                guard let scope = CullingScope(rawValue: scopeRaw) else {
                    throw BridgeError.badParams("CULLING_INVALID_SCOPE")
                }
                let filters = try parseCullingFilters(params["filters"])
                let groupId = try optionalString(params, "groupId")
                let afterRowId: Int64?
                if let raw = params["afterRowId"] {
                    guard let value = raw.numberValue, value.isFinite,
                          value.rounded() == value, value >= 1 else {
                        throw BridgeError.badParams("afterRowId must be a positive integer")
                    }
                    afterRowId = Int64(value)
                } else {
                    afterRowId = nil
                }
                let limit: Int
                if let raw = params["limit"] {
                    guard let value = raw.numberValue, value.isFinite,
                          value.rounded() == value,
                          value >= 1, value <= Double(CullingQueryBuilder.pageLimitMax) else {
                        throw BridgeError.badParams("limit must be an integer between 1 and 2000")
                    }
                    limit = Int(value)
                } else {
                    limit = 200
                }
                Task {
                    do {
                        let page = try await culling.listPage(
                            sessionId: sessionId, scope: scope, filters: filters,
                            requestedGroupId: groupId, afterRowId: afterRowId, limit: limit)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: page)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:250-257 —— 相似度分组（决策计数 + 成员轻投影）。
        case "culling.groups":
            do {
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        let groups = try await culling.groups(sessionId: sessionId)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: groups)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "culling.summary":
            do {
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        let summary = try await culling.summary(sessionId: sessionId)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: summary)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:239-248 —— destructive（桥层 + 直连二次兜底）。
        case "culling.finalize_sync":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "CULLING_FINALIZE_CONFIRM_REQUIRED"))
                return
            }
            do {
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        let summary = try await culling.finalizeSync(sessionId: sessionId, confirmed: true)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: summary)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── culling.*（R1/R2：历史栈经 CullingStore，异步路径）──

        case "culling.history":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let limit: Int?
                if let raw = params["limit"] {
                    guard let value = raw.numberValue, value.isFinite,
                          value.rounded() == value, value >= 1, value <= 500 else {
                        throw BridgeError.badParams("limit must be an integer between 1 and 500")
                    }
                    limit = Int(value)
                } else {
                    limit = nil
                }
                Task {
                    do {
                        let operations = try await culling.history(
                            sessionId: sessionId, limit: limit ?? 100)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: operations)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:118-152 —— undo/redo 显式条目；entries 非空数组（≤10000）。
        case "culling.apply_history":
            do {
                let sessionId = try requiredString(params, "sessionId")
                guard let entryValues = params["entries"]?.arrayElements,
                      !entryValues.isEmpty, entryValues.count <= CullingQueryBuilder.batchMax else {
                    throw BridgeError.badParams("entries must be a non-empty array with at most 10000 items")
                }
                let entries: [CullingHistoryApplyEntry] = try entryValues.enumerated().map { index, item in
                    guard let object = item.objectValue else {
                        throw BridgeError.badParams("entries[\(index)] is invalid")
                    }
                    guard let patchValue = object["patch"] else {
                        throw BridgeError.badParams("entries[\(index)].patch is invalid")
                    }
                    guard let expectedRevision = object["expectedRevision"]?.numberValue,
                          expectedRevision.isFinite, expectedRevision.rounded() == expectedRevision,
                          expectedRevision >= 0 else {
                        throw BridgeError.badParams("entries[\(index)].expectedRevision is invalid")
                    }
                    guard let photoId = object["photoId"]?.stringValue else {
                        throw BridgeError.badParams("MISSING_PARAM:entries[\(index)].photoId")
                    }
                    return CullingHistoryApplyEntry(
                        photoId: photoId,
                        expectedRevision: Int(expectedRevision),
                        patch: try parseCullingUpdatePatch(patchValue)
                    )
                }
                guard let historyOperationId = params["historyOperationId"]?.numberValue,
                      historyOperationId.isFinite, historyOperationId.rounded() == historyOperationId,
                      historyOperationId >= 1 else {
                    throw BridgeError.badParams("historyOperationId must be a positive integer")
                }
                let directionRaw = try requiredString(params, "direction")
                guard let direction = CullingHistoryDirection(rawValue: directionRaw) else {
                    throw BridgeError.badParams("direction must be undo or redo")
                }
                Task {
                    do {
                        let results = try await culling.applyHistory(
                            sessionId: sessionId,
                            requestedEntries: entries,
                            historyOperationId: Int(historyOperationId),
                            direction: direction)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: results)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:154-177 —— 单张更新；复用缓存的会话级更新上下文
        //（点击突发不再重读整个会话）。历史条目在决策事务后经 Store 提交。
        case "culling.update":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let photoId = try requiredString(params, "photoId")
                guard let expectedRevision = params["expectedRevision"]?.numberValue,
                      expectedRevision.isFinite, expectedRevision.rounded() == expectedRevision,
                      expectedRevision >= 0 else {
                    throw BridgeError.badParams("expectedRevision must be a non-negative integer")
                }
                let patch = try parseCullingUpdatePatch(params["patch"])
                Task {
                    do {
                        let result = try await culling.update(
                            sessionId: sessionId, photoId: photoId,
                            expectedRevision: Int(expectedRevision), patch: patch)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:179-198 —— 批量更新（photoIds ≤10000，单事务）。
        case "culling.batch_update":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let photoIds = try requiredStringArray(params, "photoIds")
                if photoIds.count > CullingQueryBuilder.batchMax {
                    throw BridgeError.badParams("Too many photoIds in one batch")
                }
                let patch = try parseCullingUpdatePatch(params["patch"])
                Task {
                    do {
                        let results = try await culling.batchUpdate(
                            sessionId: sessionId, photoIds: photoIds, patch: patch)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: results)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // culling.ipc.ts:200-213 —— 整组批量 keep/reject。
        case "culling.decide_group":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let groupId = try requiredString(params, "groupId")
                let keepPhotoIds = try requiredStringArray(params, "keepPhotoIds")
                if keepPhotoIds.count > CullingQueryBuilder.batchMax {
                    throw BridgeError.badParams("Too many keepPhotoIds")
                }
                Task {
                    do {
                        let results = try await culling.decideGroup(
                            sessionId: sessionId, groupId: groupId, keepPhotoIds: keepPhotoIds)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: results)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── photo.list_page（R1/R2：faceCount 经 FaceStore，异步路径）──

        case "photo.list_page":
            do {
                let sessionId = try requiredString(params, "sessionId")
                let limit = clampedLimit(params, default: 200, max: 1_000)
                let afterFirstRowid: Int64?
                if let raw = try optionalNumber(params, "afterFirstRowid"), raw.isFinite {
                    afterFirstRowid = Int64(raw)
                } else {
                    afterFirstRowid = nil
                }
                let expandVariants = optionalBool(params, "expandVariants") ?? false
                Task {
                    do {
                        let page = try await photoStore.getAssetPage(
                            sessionId: sessionId, afterFirstRowid: afterFirstRowid, limit: limit)
                        let rows = await assemblePhotoRows(
                            page.rows, sessionId: sessionId, expandVariants: expandVariants)
                        completion(WebResponse(ok: true, data: .object([
                            "rows": .array(rows),
                            "cursor": page.cursor.map { .number(Double($0)) } ?? .null,
                        ])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── fkw.clusters（R1/R2：经 FaceStore，异步路径）──

        case "fkw.clusters":
            do {
                // face-kw.ipc.ts:98-105 —— ok(getClusters(sessionId))。
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        let clusters = try await faceKwService.getClusters(sessionId: sessionId)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: clusters)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── session.delete*（R1/R2：删除依赖 face Store，异步路径）──

        case "session.delete":
            do {
                let id = try requiredString(params, "sessionId")
                let confirmedValue = confirmed(params)
                Task {
                    do {
                        try await sessionService.deleteSession(id, confirmed: confirmedValue)
                        completion(WebResponse(ok: true, data: .null))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "session.delete_many":
            do {
                let ids = try requiredStringArray(params, "sessionIds")
                let confirmedValue = confirmed(params)
                Task {
                    do {
                        _ = try await sessionService.deleteSessions(ids, confirmed: confirmedValue)
                        completion(WebResponse(ok: true, data: .null))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.list":
            Task {
                do {
                    // person.ipc.ts:31-56 —— listWithCounts → PersonData[]。
                    let list = try await persons.list()
                    completion(WebResponse(
                        ok: true,
                        data: .array(try list.map { try GatherCore.JSONValue(from: $0) })))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "person.get":
            do {
                // person.ipc.ts:58-79 —— PERSON_NOT_FOUND；detail = data + photos。
                let personId = try requiredString(params, "personId")
                Task {
                    do {
                        guard let detail = try await persons.get(id: personId) else {
                            throw BridgeError.notFound("PERSON_NOT_FOUND")
                        }
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: detail)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.create":
            do {
                // person.ipc.ts:81-89 —— name 必填；keywords 可选。
                let name = try validatedString(params, "name")
                let keywords = try optionalStringArray(params, "keywords")
                Task {
                    do {
                        let id = try await persons.create(name: name, keywords: keywords)
                        completion(WebResponse(ok: true, data: .object(["id": .string(id)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.update":
            do {
                // person.ipc.ts:91-103 —— 仅更新传入的字段。
                let personId = try requiredString(params, "personId")
                let fields = try parsePersonUpdateFields(params)
                Task {
                    do {
                        try await persons.update(id: personId, fields: fields)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.delete":
            do {
                // person.ipc.ts:105-115 —— destructive。
                guard confirmed(params) else {
                    throw BridgeError.badParams("PERSON_DELETE_CONFIRM_REQUIRED")
                }
                let personId = try requiredString(params, "personId")
                Task {
                    do {
                        try await persons.delete(id: personId)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.merge":
            do {
                // person.ipc.ts:117-128 —— destructive。
                guard confirmed(params) else {
                    throw BridgeError.badParams("PERSON_MERGE_CONFIRM_REQUIRED")
                }
                let sourceId = try requiredString(params, "sourceId")
                let targetId = try requiredString(params, "targetId")
                Task {
                    do {
                        try await persons.merge(sourceId: sourceId, targetId: targetId)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.remove_photo":
            do {
                // person.ipc.ts:130-141 —— destructive。
                guard confirmed(params) else {
                    throw BridgeError.badParams("PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED")
                }
                let personId = try requiredString(params, "personId")
                let photoId = try requiredString(params, "photoId")
                Task {
                    do {
                        try await persons.removePhoto(personId: personId, photoId: photoId)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "person.search_photos":
            do {
                // person.ipc.ts:143-165 —— { photos, total }；sessionIds/limit/offset 可选。
                let personId = try requiredString(params, "personId")
                let sessionIds = try optionalStringArray(params, "sessionIds")
                let limit = try optionalNumber(params, "limit").map { Int($0) }
                let offset = try optionalNumber(params, "offset").map { Int($0) }
                Task {
                    do {
                        let result = try await persons.searchPhotos(
                            personId: personId, sessionIds: sessionIds, limit: limit, offset: offset)
                        completion(WebResponse(ok: true, data: .object([
                            "photos": try .array(result.photos.map { try GatherCore.JSONValue(from: $0) }),
                            "total": .number(Double(result.total)),
                        ])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "workspace.status":
            do {
                // Protocol WorkspaceStatusParams.sessionId 非可选；调用方均显式传
                // sessionId，故用 requiredString（缺省 "" 会静默查全部会话）。
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        guard let status = try await workspace.status(sessionId: sessionId) else {
                            throw BridgeError.notFound("SESSION_NOT_FOUND")
                        }
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: status)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── album.*（R1：经 AlbumsAPI，异步路径）──

        case "album.create":
            do {
                // filter.ipc.ts:111-146 —— criteria 经 buildWhereClause 校验后落库。
                let name = try validatedString(params, "name")
                let criteria = try parseFilterCriteria(params)
                _ = try filterEngine.buildWhereClause(criteria)
                let sortBy = try optionalString(params, "sortBy")
                let sortOrder = try optionalString(params, "sortOrder")
                let description = try optionalString(params, "description")
                let icon = try optionalString(params, "icon")
                Task {
                    do {
                        let record = try await albums.create(data: SmartAlbumCreateData(
                            name: name, description: description, filterCriteria: criteria,
                            sortBy: sortBy, sortOrder: sortOrder, icon: icon))
                        let detail = try await albumDetailData(row: record)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: detail)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "album.list":
            Task {
                do {
                    // filter.ipc.ts:148-186 —— 损坏 criteria 的行带 validationError 保留。
                    let records = try await albums.list()
                    let list: [SmartAlbumData] = records.map { record in
                        do {
                            let criteria = try decodeJSON(
                                FilterGroup.self, from: GatherCore.JSONValue.parse(record.filterCriteria))
                            _ = try filterEngine.buildWhereClause(criteria)
                            return SmartAlbumData(
                                id: record.id, schemaVersion: record.schemaVersion, name: record.name,
                                description: record.description, filterCriteria: criteria,
                                sortBy: record.sortBy, sortOrder: record.sortOrder, icon: record.icon,
                                createdAt: record.createdAt, updatedAt: record.updatedAt)
                        } catch {
                            return SmartAlbumData(
                                id: record.id, schemaVersion: record.schemaVersion, name: record.name,
                                description: record.description,
                                filterCriteria: FilterGroup(logic: .and, conditions: []),
                                sortBy: record.sortBy, sortOrder: record.sortOrder, icon: record.icon,
                                createdAt: record.createdAt, updatedAt: record.updatedAt,
                                validationError: Self.errorMessage(error))
                        }
                    }
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: list)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "album.get":
            do {
                // filter.ipc.ts:188-210 —— ALBUM_NOT_FOUND。
                let albumId = try requiredString(params, "albumId")
                Task {
                    do {
                        guard let record = try await albums.get(id: albumId) else {
                            throw BridgeError.notFound("ALBUM_NOT_FOUND")
                        }
                        await completion(WebResponse(
                            ok: true, data: try GatherCore.JSONValue(from: albumDetailData(row: record))))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "album.update":
            do {
                // filter.ipc.ts:212-230 —— 仅更新传入字段；criteria 传入时校验。
                let albumId = try requiredString(params, "albumId")
                let name = try optionalString(params, "name")
                let description = try optionalString(params, "description")
                var criteria: FilterGroup?
                if let rawCriteria = params["criteria"] {
                    guard rawCriteria.isObject else { throw BridgeError.badParams("Filter criteria is invalid") }
                    criteria = try parseFilterCriteria(params)
                    _ = try filterEngine.buildWhereClause(criteria!)
                }
                let sortBy = try optionalString(params, "sortBy")
                let sortOrder = try optionalString(params, "sortOrder")
                let icon = try optionalString(params, "icon")
                Task {
                    do {
                        try await albums.update(id: albumId, data: SmartAlbumUpdateData(
                            name: name, description: description, filterCriteria: criteria,
                            sortBy: sortBy, sortOrder: sortOrder, icon: icon))
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "album.delete":
            do {
                // filter.ipc.ts:232-244 —— destructive。
                guard confirmed(params) else {
                    throw BridgeError.badParams("album.delete requires confirmation")
                }
                let albumId = try requiredString(params, "albumId")
                Task {
                    do {
                        try await albums.delete(id: albumId)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "album.get_photos":
            do {
                // filter.ipc.ts:244-266 —— ALBUM_NOT_FOUND；limit 1..500 缺省 100。
                let albumId = try requiredString(params, "albumId")
                Task {
                    do {
                        guard let record = try await albums.get(id: albumId) else {
                            throw BridgeError.notFound("ALBUM_NOT_FOUND")
                        }
                        let criteria = try decodeJSON(
                            FilterGroup.self, from: GatherCore.JSONValue.parse(record.filterCriteria))
                        let limit = clampedLimit(params, default: 100, max: 500)
                        let offset = clampedOffset(params)
                        let photos = try await filterEngine.filterGlobally(
                            criteria: criteria, sortBy: record.sortBy, sortOrder: record.sortOrder,
                            limit: limit, offset: offset)
                        let total = try await filterEngine.countGlobally(criteria: criteria)
                        completion(WebResponse(ok: true, data: .object([
                            "photos": try .array(photos.map { try GatherCore.JSONValue(from: $0) }),
                            "total": .number(Double(total)),
                        ])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // ── template.*（R1/R5：经 TemplatesAPI + SettingsAPI，异步路径）──

        case "template.create":
            do {
                // template.ipc.ts:7-18 —— config 非对象抛 TEMPLATE_CONFIG_INVALID。
                let name = try validatedString(params, "name")
                let description = try optionalString(params, "description") ?? ""
                guard let configValue = params["config"], configValue.isObject else {
                    throw BridgeError.badParams("TEMPLATE_CONFIG_INVALID")
                }
                let config = try decodeJSON(WorkflowTemplateConfig.self, from: configValue)
                Task {
                    do {
                        let template = try await templates.create(
                            name: name, description: description, config: config)
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: template)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "template.list":
            Task {
                do {
                    let list = try await templates.list()
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: list)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "template.get":
            do {
                let templateId = try requiredString(params, "templateId")
                Task {
                    do {
                        guard let template = try await templates.get(id: templateId) else {
                            throw BridgeError.notFound("TEMPLATE_NOT_FOUND")
                        }
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: template)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "template.update":
            do {
                // template.ipc.ts:37-50 —— 仅更新传入字段；description 强制 String 化。
                let templateId = try requiredString(params, "templateId")
                var fields = TemplateUpdateFields()
                if let name = try optionalString(params, "name") {
                    fields.name = name
                }
                if let description = params["description"] {
                    fields.description = description.stringValue ?? String(describing: description)
                }
                if let configValue = params["config"] {
                    guard configValue.isObject else {
                        throw BridgeError.badParams("TEMPLATE_CONFIG_INVALID")
                    }
                    fields.config = try decodeJSON(WorkflowTemplateConfig.self, from: configValue)
                }
                Task {
                    do {
                        guard let template = try await templates.update(id: templateId, fields: fields) else {
                            throw BridgeError.notFound("TEMPLATE_NOT_FOUND")
                        }
                        completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: template)))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "template.delete":
            do {
                guard confirmed(params) else {
                    throw BridgeError.badParams("TEMPLATE_DELETE_CONFIRM_REQUIRED")
                }
                let templateId = try requiredString(params, "templateId")
                Task {
                    do {
                        try await templates.delete(id: templateId)
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        case "template.apply":
            do {
                guard confirmed(params) else {
                    throw BridgeError.badParams("TEMPLATE_APPLY_CONFIRM_REQUIRED")
                }
                let templateId = try requiredString(params, "templateId")
                let sessionId = try requiredString(params, "sessionId")
                Task {
                    do {
                        let updates = try await templates.applyUpdates(
                            templateId: templateId, sessionId: sessionId)
                        for update in updates {
                            try await settingsAPI.set(update.key, value: update.value)
                        }
                        completion(WebResponse(ok: true, data: .object(["done": .bool(true)])))
                    } catch {
                        completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                    }
                }
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        default:
            // 未在异步 switch 特化的命令（纯读/同步服务）：后台队列执行同步
            // execute，命令实现保持单一事实源（P0-2 修复方向：不再要求新命令
            // 在两个 switch 各写一遍）。走 GCD 而非 Task{}：避免继承调用方
            // MainActor 隔离，使读路径真正离主线程、awaitSync 防御也得以
            // 生效。未知命令经 execute 的 default 分支显式 NOT_IMPLEMENTED
            // 失败，禁止静默成功。
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let data = try execute(command, params: params)
                    completion(WebResponse(ok: true, data: data))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }
        }
    }

    // MARK: 参数读取

    private func requiredString(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> String {
        guard case .string(let value) = params[key] else {
            throw BridgeError.badParams("MISSING_PARAM:\(key)")
        }
        return value
    }

    /// Image commands receive user-controlled input. Keep the native decode
    /// boundary tied to photoStore.containsFilepath so callers cannot use
    /// dimensions/preload as an arbitrary file oracle.
    private func requirePhotoPath(_ path: String) async throws {
        guard !path.isEmpty, path.count <= 4096,
              try await photoStore.containsFilepath(filepath: path) else {
            throw BridgeError.notFound("PHOTO_NOT_FOUND")
        }
    }

    private func allowedPhotoPaths(_ paths: [String]) async throws -> [String] {
        var seen = Set<String>()
        var allowed: [String] = []
        for path in paths where !path.isEmpty && path.count <= 4096 && seen.insert(path).inserted {
            if try await photoStore.containsFilepath(filepath: path) { allowed.append(path) }
        }
        return allowed
    }

    private func optionalString(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> String? {
        // TS validateString 严格语义：null 视为缺省（TS JSON null 语义），
        // 其余类型错误抛错而非静默 nil（P3-2 修复）。
        guard let value = params[key], value != .null else { return nil }
        guard case .string(let string) = value else {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return string
    }

    /// TS helpers.validateString 语义：非 string 抛错；超长抛错；非 allowEmpty
    /// 时空白视为无效并 trim（allowEmpty 时原样返回）。
    private func validatedString(
        _ params: [String: GatherCore.JSONValue],
        _ key: String,
        maxLength: Int = 4096,
        allowEmpty: Bool = false
    ) throws -> String {
        let value = try requiredString(params, key)
        if value.count > maxLength {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        if !allowEmpty && value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return allowEmpty ? value : value.trimmingCharacters(in: .whitespaces)
    }

    private func requiredStringArray(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> [String] {
        guard case .array(let values) = params[key] else {
            throw BridgeError.badParams("MISSING_PARAM:\(key)")
        }
        // TS validateStringArray 严格语义：数组元素非字符串抛错（不再
        // compactMap 静默丢弃，与 optionalStringArray 校验哲学统一）。
        guard values.allSatisfy({ $0.stringValue != nil }) else {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return values.compactMap(\.stringValue)
    }

    private func optionalNumber(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> Double? {
        guard case .number(let value) = params[key], value.isFinite else { return nil }
        return value
    }

    /// TS helpers.validateNumber 语义：非 number 抛错；NaN/Infinity 视为非法。
    private func requiredNumber(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> Double {
        guard case .number(let value) = params[key], value.isFinite else {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return value
    }

    private func optionalBool(_ params: [String: GatherCore.JSONValue], _ key: String) -> Bool? {
        guard case .bool(let value) = params[key] else { return nil }
        return value
    }

    private func confirmed(_ params: [String: GatherCore.JSONValue]) -> Bool {
        if case .bool(true) = params["confirmed"] { return true }
        return false
    }

    /// TS filter.ipc.ts 钳制：limit 1..upperBound（floor），缺省 defaultValue。
    private func clampedLimit(_ params: [String: GatherCore.JSONValue], default defaultValue: Int, max upperBound: Int) -> Int {
        guard let raw = try? optionalNumber(params, "limit") else { return defaultValue }
        return Swift.max(1, Swift.min(upperBound, Int(floor(raw))))
    }

    /// TS filter.ipc.ts 钳制：offset ≥ 0（floor），缺省 0。
    private func clampedOffset(_ params: [String: GatherCore.JSONValue]) -> Int {
        guard let raw = try? optionalNumber(params, "offset") else { return 0 }
        return max(0, Int(floor(raw)))
    }

    // MARK: 参数装配

    /// TS filter.ipc.ts parseFilterCriteria：schemaVersion 仅 1；结构由
    /// FilterGroup 解码校验（logic ∈ and/or、conditions 数组、递归 rule/group）。
    private func parseFilterCriteria(_ params: [String: GatherCore.JSONValue], schemaVersion: Int = 1) throws -> FilterGroup {
        guard schemaVersion == 1 else {
            throw BridgeError.badParams("FILTER_SCHEMA_UNSUPPORTED")
        }
        guard let value = params["criteria"],
              let data = try? JSONEncoder().encode(value)
        else {
            throw BridgeError.badParams("Filter criteria is invalid")
        }
        do {
            return try JSONDecoder().decode(FilterGroup.self, from: data)
        } catch {
            // TS 消息逐字一致（filter.ipc.ts:21-33 的校验失败路径）。
            throw BridgeError.badParams("Filter criteria is invalid")
        }
    }

    /// TS filter-engine.ts rowToPhotoData（filter.ipc.ts 直接透传）：metadata/
    /// result 为 JSON.parse 后的对象；width/height 恒 0（SELECT 未含该列）。
    private func filterPhotoDataJSON(_ photo: FilteredPhotoData) -> GatherCore.JSONValue {
        .object([
            "id": .string(photo.id),
            "sessionId": .string(photo.sessionId),
            "filepath": .string(photo.filepath),
            "filename": .string(photo.filename),
            "checksum": .string(photo.checksum),
            "hasExistingXmp": .bool(photo.hasExistingXmp),
            "faceCount": .number(Double(photo.faceCount)),
            "width": .number(Double(photo.width)),
            "height": .number(Double(photo.height)),
            "metadata": parseJSONObject(photo.metadata),
            "result": parseJSONObject(photo.result),
            "status": .string(photo.status),
            "createdAt": .string(photo.createdAt),
            "updatedAt": .string(photo.updatedAt),
        ])
    }

    /// TS photo.ipc.ts assemblePhotos：按逻辑资产分组（asset_id ?? "photo:<id>"），
    /// expandVariants=false 时每组取 raw → camera_jpeg → 首行，并带成员角色与
    /// 人脸计数（三次小查询，页级成本）。
    private func assemblePhotoRows(
        _ rows: [PhotoPage],
        sessionId: String,
        expandVariants: Bool
    ) async -> [GatherCore.JSONValue] {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return [] }

        // 角色与脸数小查询下沉 Repo/Service（原内联 SQL，P1-2 修复）。
        let memberRoles = (try? await assetStore.memberRoles(sessionId: sessionId, photoIds: ids)) ?? [:]
        let faceCounts = (try? await faceKwService.faceCounts(sessionId: sessionId, photoIds: ids)) ?? [:]

        func toPhotoData(_ row: PhotoPage, variants: [PhotoPage]) -> GatherCore.JSONValue {
            var object: [String: GatherCore.JSONValue] = [
                "id": .string(row.id),
                "sessionId": .string(row.sessionId),
                "filepath": .string(row.filepath),
                "filename": .string(row.filename),
                "checksum": .string(row.checksum ?? ""),
                "hasExistingXmp": .bool(false),
                "faceCount": .number(Double(faceCounts[row.id] ?? 0)),
                "width": .number(Double(row.width)),
                "height": .number(Double(row.height)),
                "metadata": .object([:]),
                "result": .object([:]),
                "status": .string(row.status),
                "variantCount": .number(Double(variants.count)),
                "variants": .array(variants.map { variant in
                    .object([
                        "photoId": .string(variant.id),
                        "filepath": .string(variant.filepath),
                        "filename": .string(variant.filename),
                        "role": .string(memberRoles[variant.id] ?? "unknown"),
                    ])
                }),
                "createdAt": .string(row.createdAt),
                "updatedAt": .string(row.updatedAt),
            ]
            // TS: assetId: row.asset_id ?? undefined —— nil 时不输出 key。
            if let assetId = row.assetId {
                object["assetId"] = .string(assetId)
            }
            return .object(object)
        }

        var groups: [String: [PhotoPage]] = [:]
        var order: [String] = []
        for row in rows {
            let key = row.assetId ?? "photo:\(row.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        if expandVariants {
            return rows.map { toPhotoData($0, variants: groups[$0.assetId ?? "photo:\($0.id)"] ?? [$0]) }
        }
        return order.compactMap { key in
            guard let variants = groups[key] else { return nil }
            let preferred = variants.first { memberRoles[$0.id] == "raw" }
                ?? variants.first { memberRoles[$0.id] == "camera_jpeg" }
                ?? variants[0]
            return toPhotoData(preferred, variants: variants)
        }
    }

    /// TS JSON.parse 语义：字符串解析为对象，失败回退 {}。
    private func parseJSONObject(_ json: String) -> GatherCore.JSONValue {
        let parsed = (try? GatherCore.JSONValue.parse(json)) ?? .object([:])
        if case .object = parsed { return parsed }
        return .object([:])
    }

    // MARK: settings.get_ml_status（TS 源 settings.ipc.ts:48-79 + provider.ts）

    /// 形状逐字段对齐 settings.ipc.ts:53-78；差异（已在注释标注）：
    /// - modelIsUsable 用「存在且非零字节」近似 TS isValidOnnxModel 的结构校验
    /// - resolveModelPath 无 process.resourcesPath 候选（Swift 无等价物）
    /// - autoBackendLabel 内联 mainCopy 双语文案（locale-copy.ts:107/164）
    private func buildMLStatus() throws -> MLStatusData {
        let provider = settings.value("onnx_provider", default: "auto")
        let modelsDir = modelResourcesDir()
        let detectorPath = settings.value("detector_model_path", default: "models/face_detector.onnx")
        let encoderPath = settings.value("encoder_model_path", default: "models/face_encoder.onnx")
        let detectorResolved = resolveModelPath(detectorPath, modelsDir: modelsDir)
        let encoderResolved = resolveModelPath(encoderPath, modelsDir: modelsDir)
        return MLStatusData(
            platform: "darwin",
            autoBackend: "coreml",
            autoBackendLabel: GatherLocalization.l("CoreML（失败自动回退 CPU）"),
            provider: provider,
            isAuto: provider == "auto",
            availableBackends: [
                MLBackendOption(value: "coreml", label: "CoreML"),
                MLBackendOption(value: "cpu", label: "CPU"),
            ],
            modelResourcesDir: modelsDir,
            detectorModel: MLModelPresence(
                path: detectorPath,
                resolvedPath: detectorResolved,
                exists: modelUsable(detectorResolved)
            ),
            encoderModel: MLModelPresence(
                path: encoderPath,
                resolvedPath: encoderResolved,
                exists: modelUsable(encoderResolved)
            ),
            modelInfo: MLModelInfo(
                detectInputSize: Int(settings.number("detect_input_size", default: 640)),
                secondaryDetectInputSize: Int(settings.number("detect_secondary_input_size", default: 128)),
                previewMaxDimension: Int(settings.number("face_preview_max_dimension", default: 2048)),
                encoderInputSize: Int(settings.number("encoder_input_size", default: 112)),
                embeddingDim: Int(settings.number("embedding_dim", default: 512))
            )
        )
    }

    /// TS provider.ts getModelResourcesDir：userData/models（best-effort 创建）。
    private func modelResourcesDir() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Gather/models", isDirectory: true).path ?? "models"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// TS provider.ts resolveModelPath：绝对路径直取；相对路径依次尝试
    /// userData/models/<filename>（resourcesPath 候选 Swift 无等价物，跳过）。
    private func resolveModelPath(_ modelPath: String, modelsDir: String) -> String {
        if modelPath.hasPrefix("/") { return modelPath }
        if FileManager.default.fileExists(atPath: modelPath) {
            return URL(fileURLWithPath: modelPath).standardizedFileURL.path
        }
        let filename = modelPath.replacingOccurrences(
            of: "^models[/\\\\]",
            with: "",
            options: .regularExpression
        )
        return (modelsDir as NSString).appendingPathComponent(filename)
    }

    /// TS provider.ts modelIsUsable（isValidOnnxModel）的近似：存在且非零字节。
    private func modelUsable(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    // MARK: async → sync 桥接

    /// 仓库层 SQLiteFailure.message → BridgeError（命令边界只对 BridgeError 做
    /// message 透传，NSError 桥接会把 DBError 描述丢给系统错误文案）。
    private func mapRepoErrorAsync<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as SQLiteFailure {
            throw BridgeError.badParams(error.message)
        }
    }

    private func mapRepoError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as SQLiteFailure {
            throw BridgeError.badParams(error.message)
        }
    }

    /// TS wrapHandler 的 await 语义（主进程线程内等待 async 服务完成）：
    /// execute() 为同步接口，对 async 服务方法用信号量桥接。服务实现均为
    /// 后台 I/O（SQLite/文件），不依赖主线程（与 TS 主进程事件循环内 await
    /// 的对外行为一致）。
    /// 主线程防御：@MainActor 调用路径上阻塞主线程既冻结 UI，又会在被等待
    /// 操作内部含 MainActor 跳转时死锁——此类命令必须走 executeAsync。
    private func awaitSync<T>(_ operation: @escaping () async throws -> T) throws -> T {
        guard !Thread.isMainThread else {
            throw BridgeError.badParams("AWAIT_SYNC_ON_MAIN_THREAD")
        }
        let box = SyncAwaitBox<T>()
        Task {
            do {
                box.complete(.success(try await operation()))
            } catch {
                box.complete(.failure(error))
            }
        }
        return try box.wait()
    }

    // MARK: 参数解析（TS helpers / ipc 校验语义）

    /// TS validateStringArray（person/quality/metadata 共用）。
    private func optionalStringArray(_ params: [String: GatherCore.JSONValue], _ key: String) throws -> [String]? {
        guard let value = params[key] else { return nil }
        guard case .array(let items) = value else {
            throw BridgeError.badParams("MISSING_PARAM:\(key)")
        }
        guard items.allSatisfy({ $0.stringValue != nil }) else {
            throw BridgeError.badParams("INVALID_PARAM:\(key)")
        }
        return items.compactMap(\.stringValue)
    }

    /// 子对象取值（metadata.batch_set 的 updates[] 元素）。
    private func requireObject(_ value: GatherCore.JSONValue, _ context: String) throws -> [String: GatherCore.JSONValue] {
        guard let object = value.objectValue else {
            throw BridgeError.badParams("INVALID_PARAM:\(context)")
        }
        return object
    }

    private func requiredSubString(_ object: [String: GatherCore.JSONValue], _ key: String) throws -> String {
        guard let value = object[key]?.stringValue else {
            throw BridgeError.badParams("MISSING_PARAM:\(key)")
        }
        return value
    }

    /// TS JSON.parse(row.keywords)（person 关键词列）。
    private func parseKeywordsJSON(_ raw: String) -> [String] {
        guard let parsed = try? GatherCore.JSONValue.parse(raw) else { return [] }
        return parsed.arrayElements?.compactMap(\.stringValue) ?? []
    }



    /// TS person.ipc.ts update 的 fields 解析（仅传入字段参与更新）。
    private func parsePersonUpdateFields(_ params: [String: GatherCore.JSONValue]) throws -> PersonUpdateFields {
        PersonUpdateFields(
            name: try optionalString(params, "name")?.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: try optionalStringArray(params, "keywords"),
            notes: try optionalString(params, "notes"),
            matchThreshold: try optionalNumber(params, "matchThreshold")
        )
    }

    /// TS WritebackOptions（fkw.preview 的 options ?? {}）。
    private func parseWritebackOptions(_ value: GatherCore.JSONValue?) throws -> FaceKwWritebackOptions {
        guard let value else { return FaceKwWritebackOptions() }
        guard let object = value.objectValue else { return FaceKwWritebackOptions() }
        return FaceKwWritebackOptions(
            createAlbums: object["createAlbums"]?.boolValue,
            addPrefix: object["addPrefix"]?.boolValue,
            markUngrouped: object["markUngrouped"]?.boolValue,
            writeIPTC: object["writeIPTC"]?.boolValue
        )
    }

    /// TS face-kw.ipc.ts:223 `(params.items ?? [])` —— 非数组抛 FKW_ITEMS_INVALID。
    private func parseFaceKwWritebackItems(_ value: GatherCore.JSONValue?) throws -> [FaceKwWritebackItem]? {
        guard let value else { return nil }
        guard let items = value.arrayElements else {
            throw BridgeError.badParams("FKW_ITEMS_INVALID")
        }
        return try items.map { item in
            try decodeJSON(FaceKwWritebackItem.self, from: item)
        }
    }

    /// TS metadata.ipc.ts `(params.tags ?? {})` —— 非对象按空处理（TS 强转）。
    private func parseMetadataTags(_ value: GatherCore.JSONValue?) throws -> MetadataTags {
        guard let value, let object = value.objectValue else { return MetadataTags() }
        return try decodeJSON(MetadataTags.self, from: .object(object))
    }

    // MARK: culling.* 参数解析（TS 源 culling.ipc.ts）

    /// TS parseFilters（culling.ipc.ts:22-75）：字段白名单 + 逐字段校验
    /// （ADR-017 internal-invariant diagnostics，消息与 TS 逐字一致）。
    private func parseCullingFilters(_ value: GatherCore.JSONValue?) throws -> CullingFilters? {
        guard let value else { return nil }
        guard let object = value.objectValue else {
            throw BridgeError.badParams("filters must be an object")
        }
        var filters = CullingFilters()
        if let raw = object["unreviewedOnly"] {
            guard raw.boolValue != nil else {
                throw BridgeError.badParams("unreviewedOnly must be a boolean")
            }
            filters.unreviewedOnly = raw.boolValue
        }
        if let raw = object["ratings"] {
            guard let ratings = raw.arrayElements,
                  ratings.allSatisfy({ value in
                      guard let number = value.numberValue, number.isFinite else { return false }
                      return number.rounded() == number && (0...5).contains(number)
                  }) else {
                throw BridgeError.badParams("ratings must contain integers from 0 to 5")
            }
            filters.ratings = ratings.compactMap(\.numberValue)
        }
        if let raw = object["pickStates"] {
            guard let states = raw.arrayElements,
                  states.allSatisfy({ $0.stringValue.flatMap(PickState.init(rawValue:)) != nil }) else {
                throw BridgeError.badParams("pickStates contains an invalid state")
            }
            filters.pickStates = states.compactMap { $0.stringValue.flatMap(PickState.init(rawValue:)) }
        }
        if let raw = object["colorLabels"] {
            guard let labels = raw.arrayElements,
                  labels.allSatisfy({ $0.stringValue.flatMap(CaptureOneColorLabel.init(rawValue:)) != nil }) else {
                throw BridgeError.badParams("colorLabels contains an invalid label")
            }
            filters.colorLabels = labels.compactMap { $0.stringValue.flatMap(CaptureOneColorLabel.init(rawValue:)) }
        }
        if let raw = object["qualityStatus"] {
            guard let string = raw.stringValue,
                  let status = CullingFilterQualityStatus(rawValue: string) else {
                throw BridgeError.badParams("qualityStatus is invalid")
            }
            filters.qualityStatus = status
        }
        if let raw = object["metadataConflictOnly"] {
            guard raw.boolValue != nil else {
                throw BridgeError.badParams("metadataConflictOnly must be a boolean")
            }
            filters.metadataConflictOnly = raw.boolValue
        }
        return filters
    }

    /// TS `params.patch as CullingUpdatePatch`（TS 为运行时空转，非法值由服务的
    /// validatePatch 拒绝）—— 取值并复用 validatePatch 的逐字错误消息。
    private func parseCullingUpdatePatch(_ value: GatherCore.JSONValue?) throws -> CullingUpdatePatch {
        guard let object = value?.objectValue else {
            throw BridgeError.badParams("patch must be an object")
        }
        var patch = CullingUpdatePatch()
        if let raw = object["rating"] {
            guard let number = raw.numberValue, number.isFinite,
                  number.rounded() == number, (0...5).contains(number) else {
                throw BridgeError.badParams("rating must be an integer from 0 to 5")
            }
            patch.rating = number
        }
        if let raw = object["pickState"] {
            guard let string = raw.stringValue,
                  let state = PickState(rawValue: string) else {
                throw BridgeError.badParams("Invalid pickState")
            }
            patch.pickState = state
        }
        if let raw = object["colorLabel"] {
            guard let string = raw.stringValue,
                  let label = CaptureOneColorLabel(rawValue: string) else {
                throw BridgeError.badParams("Invalid colorLabel")
            }
            patch.colorLabel = label
        }
        return patch
    }

    /// JSONValue → Codable（JSONDecoder 往返；解码失败为契约漂移，抛原始错误）。
    private func decodeJSON<T: Decodable>(_ type: T.Type, from value: GatherCore.JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    /// TS export.ipc.ts：options 解码失败统一抛 EXPORT_PARAMS_INVALID（码值）。
    /// DecodingError 的英文散文会绕过 renderer 的 translateError 映射，故在此
    /// 收敛为 GatherErrorCode，保持「错误载荷是码值」约定。
    private func decodeExportOptions(_ value: GatherCore.JSONValue) throws -> ExportOptions {
        do {
            return try decodeJSON(ExportOptions.self, from: value)
        } catch {
            throw BridgeError.badParams("EXPORT_PARAMS_INVALID")
        }
    }

    /// TS similarity.ipc.ts validateAssignments（ADR-017 内部不变式校验；
    /// normalizeKeywords 对非字符串元素静默丢弃）。
    private func validateSimilarityAssignments(_ value: GatherCore.JSONValue?) throws -> [SimilarityKeywordAssignment] {
        guard let items = value?.arrayElements, !items.isEmpty else {
            throw BridgeError.badParams("SIM_WRITEBACK_EMPTY")
        }
        return try items.map { item in
            guard let object = item.objectValue else {
                throw BridgeError.badParams("SIM_ASSIGNMENT_INVALID")
            }
            guard let groupId = object["groupId"]?.numberValue,
                  groupId.rounded() == groupId,
                  let rawKeywords = object["keywords"]?.arrayElements
            else {
                throw BridgeError.badParams("SIM_WRITEBACK_INVALID_ITEM")
            }
            var seen = Set<String>()
            let keywords = rawKeywords.compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !keywords.isEmpty else {
                throw BridgeError.badParams("SIM_WRITEBACK_INVALID_ITEM")
            }
            return SimilarityKeywordAssignment(groupId: Int(groupId), keywords: keywords)
        }
    }

    /// TS similarity.ipc.ts buildKeywordPreview（50-91 行）。
    private func buildSimilarityKeywordPreview(
        sessionId: String,
        assignments: [SimilarityKeywordAssignment],
        threshold: Int?
    ) async throws -> GatherCore.JSONValue {
        let result = try await similarityService.getResult(sessionId: sessionId, threshold: threshold)
        guard let result else {
            throw BridgeError.badParams(threshold == nil ? "SIM_ANALYSIS_MISSING" : "SIM_THRESHOLD_NO_RESULTS")
        }
        let plan = try buildSimilarityKeywordPlan(
            groups: result.groups,
            assignments: assignments.map { (groupId: $0.groupId, keywords: $0.keywords) }
        )
        let preview = try await writebackService.preview(sessionId: sessionId, module: "similarity")
        let selectedItems = preview.items
            .filter { plan.keywordsBySidecar[$0.xmpPath] != nil }
            .map { item -> WritebackItem in
                var merged = item
                merged.keywords = orderedUnion(
                    item.keywords,
                    plan.keywordsBySidecar[item.xmpPath] ?? []
                )
                return merged
            }
        try await writebackService.persistKeywords(items: selectedItems)
        return .object([
            "items": try .array(selectedItems.map { try GatherCore.JSONValue(from: $0) }),
            "totalCount": .number(Double(selectedItems.count)),
            "affectedPhotos": .number(Double(plan.affectedPaths.count)),
        ])
    }

    /// TS filter.ipc.ts SmartAlbumDetailData（album.create / album.get）。
    private func albumDetailData(row: SmartAlbumRecord) async throws -> SmartAlbumDetailData {
        let criteria = try decodeJSON(FilterGroup.self, from: GatherCore.JSONValue.parse(row.filterCriteria))
        return SmartAlbumDetailData(
            id: row.id,
            schemaVersion: row.schemaVersion,
            name: row.name,
            description: row.description,
            filterCriteria: criteria,
            sortBy: row.sortBy,
            sortOrder: row.sortOrder,
            icon: row.icon,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            photoCount: try await filterEngine.countGlobally(criteria: criteria)
        )
    }

    /// TS `[...new Set([...a, ...b])]`（sim.preview_writeback 关键词合并）。
    private func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in a + b where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    // MARK: 错误消息

    /// 错误 message 保持 GatherErrorCode 字符串（renderer translateError 映射）。
    private static func errorMessage(_ error: Error) -> String {
        if let bridgeError = error as? BridgeError {
            return bridgeError.description
        }
        // 各已移植服务的错误 description 与 TS 错误消息逐字一致。
        if let settingsError = error as? SettingsError { return settingsError.description }
        if let navigationError = error as? NavigationError { return navigationError.description }
        if let filterError = error as? FilterEngineError {
            // 参数化错误码：路由返回 CODE::param 形式，由 UI 层
            // GatherLocalization.errorText 做 {{field}} 模板插值
            // （对齐 TS translateErrorCode 的 params 插值语义）。
            if case .fieldUnknown(let field) = filterError {
                return "FILTER_FIELD_UNKNOWN::\(field)"
            }
            return filterError.description
        }
        if let similarityError = error as? SimilarityServiceError { return similarityError.gatherCode.rawValue }
        if let assetError = error as? PhotoAssetResolverError { return assetError.gatherCode.rawValue }
        if let duplicateError = error as? DuplicateServiceError {
            return duplicateError.description
        }
        if let faceKwError = error as? FaceKwServiceError { return faceKwError.description }
        if let templateError = error as? TemplateError { return templateError.description }
        if let qualityError = error as? QualityServiceError { return qualityError.description }
        if let indexerError = error as? IndexerServiceError { return indexerError.description }
        if let writebackError = error as? WritebackServiceError { return writebackError.description }
        if let metadataSyncError = error as? MetadataSyncError { return metadataSyncError.description }
        if let metadataMutationError = error as? MetadataMutationError {
            return metadataMutationError.description
        }
        if let metadataServiceError = error as? MetadataServiceError {
            return metadataServiceError.description
        }
        if let cullingError = error as? CullingServiceError {
            // 参数化错误码：返回 CODE::expected::current，UI 层按
            // CULLING_REVISION_CONFLICT 模板插值（对齐 TS translateErrorCode）。
            if case .revisionConflict(let expected, let current) = cullingError {
                return "CULLING_REVISION_CONFLICT::\(expected)::\(current)"
            }
            return cullingError.description
        }
        if let exportError = error as? ExportServiceError { return exportError.description }
        if let imageError = error as? ImagePreloadError { return imageError.description }
        // 仓库层直接抛出的 SQLiteFailure.message（TS 侧 throw new Error(code) 的
        // 仓库等价物，如 ASSET_LINK_CANDIDATE_NOT_FOUND）逐字透传。
        if let sqliteError = error as? SQLiteFailure {
            return sqliteError.message
        }
        // JobRunner.waitForResult 失败终态：message 即 TS errorMessage
        // （executor 抛错经 String(describing:) 记录，错误枚举 description 对齐 TS）。
        if case JobRunnerError.jobFailed(_, let message) = error { return message }
        if error is JobCancelledError { return "CANCELLED" }
        // DecodingError（JSON 解码契约漂移）：错误载荷必须保持码值，英文散文
        // 会绕过 translateError 映射，统一收敛为 INVALID_PARAMS。
        if error is DecodingError { return "INVALID_PARAMS" }
        // NSError 无法稳定映射到具体业务码（无可靠 userInfo 结构），保留
        // localizedDescription 供宿主日志排查；renderer 侧经 translateError
        // 未命中时回退 error.unspecific，不会泄露原始散文到用户可见文案。
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String
            ?? nsError.localizedDescription
    }
}

/// awaitSync 的信号量结果盒（@unchecked Sendable：跨线程一次性写入）。
private final class SyncAwaitBox<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?

    func complete(_ result: Result<T, Error>) {
        self.result = result
        semaphore.signal()
    }

    func wait() throws -> T {
        semaphore.wait()
        guard let result else {
            throw BridgeError.badParams("AWAIT_SYNC_INTERNAL")
        }
        return try result.get()
    }
}

enum BridgeError: Error, CustomStringConvertible {
    case notImplemented(String)
    case badParams(String)
    case notFound(String)

    var description: String {
        switch self {
        case .notImplemented(let command): return "NOT_IMPLEMENTED: \(command)"
        case .badParams(let message): return message
        case .notFound(let code): return code
        }
    }
}

extension GatherCore.JSONValue {
    init<T: Encodable>(from value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(GatherCore.JSONValue.self, from: data)
    }
}
