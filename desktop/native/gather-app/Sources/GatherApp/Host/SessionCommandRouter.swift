// desktop/native/gather-app/Sources/GatherApp/Host/SessionCommandRouter.swift
// Phase 3/4 宿主与桥：纯 SwiftUI 同进程命令路由。
// 所有当前产品页面所需命令均在下方接入 GatherCore 服务；未知命令仍以
// NOT_IMPLEMENTED 明确失败，避免把协议遗漏伪装成成功。
//
// 接线清单（截至 2026-08-11，对应 NATIVE-DEVELOPMENT-ANALYSIS.md §10.4/§10.6）：
//   同步（execute）：
//     session.* / photo.list → SessionService + PhotoRepo（3.2 服务层）
//     workspace.status → WorkspaceStatusService（3.1 服务层）
//     jobs.list / jobs.cancel / jobs.retry / jobs.clear_completed → JobService
//     image.get_dimensions / image.prioritize_thumbnail / image.preload_* →
//       ImagePreloadService + RAWDecoder（2.1/3.6；缩略图任务走 JobService）
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
//     person.* → PersonRepo（TS 源 person.ipc.ts）
//     template.* → TemplateService（TS 源 template.ipc.ts）
//     quality.get → QualityService（TS 源 quality.ipc.ts）
//     metadata.get / set / batch_set / conflicts / orphans →
//       MetadataService + MetadataSyncCoordinator（TS 源 metadata.ipc.ts；
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
//     sim.analyze / dup.scan → JobService executor + waitForResult（TS 源
//       similarity.ipc.ts / duplicate.ipc.ts）
//     fkw.analyze → JobService executor（face.analyze）+ waitForResult；
//       job abort 经 signal handler 传播给 FaceKwService（TS 源 face-kw.ipc.ts）
//     fkw.recluster → FaceKwService.recluster（TS 源 face-kw.ipc.ts）
//     index.scan / quality.analyze → JobService executor（metadata.scan /
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
    public let workspaceStatusService: WorkspaceStatusService
    public let jobService: JobService
    private let photoRepo: PhotoRepo
    private let settingsService: SettingsService
    private let filterEngine: FilterEngine
    private let navigationService: NavigationService
    private let similarityService: SimilarityService
    private let duplicateService: DuplicateService
    private let assetRepo: AssetRepo
    /// 连接引用：仅用于零散 Repo 按需构造（SessionRepo reloadAckedAt 等），
    /// 领域查询一律经注入的 Repo/Service，不在此内联 SQL。
    private let db: DBConnection
    /// 3.0 接线扩展：人脸关键字 / 人物库 / 模板 / 质量 / 索引 / 元数据 / 写回 / 智能相册。
    private let faceKwService: FaceKwService
    private let personRepo: PersonRepo
    private let templateService: TemplateService
    private let qualityService: QualityService
    private let indexerService: IndexerService
    private let metadataService: MetadataService
    private let metadataSyncCoordinator: MetadataSyncCoordinator
    private let metadataMutationService: MetadataMutationService
    private let writebackService: WritebackService
    private let smartAlbumRepo: SmartAlbumRepo
    /// 3.4 Culling 模块（sync/writeback 端口注入真实协调器与写回服务）。
    private let cullingService: CullingService
    public let exportService: ExportService
    private let imagePreloadService: ImagePreloadService

    public init(
        db: DBConnection,
        sessionService: SessionService,
        workspaceStatusService: WorkspaceStatusService,
        jobService: JobService,
        photoRepo: PhotoRepo,
        settingsService: SettingsService,
        filterEngine: FilterEngine,
        navigationService: NavigationService,
        similarityService: SimilarityService,
        duplicateService: DuplicateService,
        assetRepo: AssetRepo,
        faceKwService: FaceKwService,
        personRepo: PersonRepo,
        templateService: TemplateService,
        qualityService: QualityService,
        indexerService: IndexerService,
        metadataService: MetadataService,
        metadataSyncCoordinator: MetadataSyncCoordinator,
        metadataMutationService: MetadataMutationService,
        writebackService: WritebackService,
        smartAlbumRepo: SmartAlbumRepo,
        cullingService: CullingService,
        exportService: ExportService,
        imagePreloadService: ImagePreloadService
    ) {
        self.db = db
        self.sessionService = sessionService
        self.workspaceStatusService = workspaceStatusService
        self.jobService = jobService
        self.photoRepo = photoRepo
        self.settingsService = settingsService
        self.filterEngine = filterEngine
        self.navigationService = navigationService
        self.similarityService = similarityService
        self.duplicateService = duplicateService
        self.assetRepo = assetRepo
        self.faceKwService = faceKwService
        self.personRepo = personRepo
        self.templateService = templateService
        self.qualityService = qualityService
        self.indexerService = indexerService
        self.metadataService = metadataService
        self.metadataSyncCoordinator = metadataSyncCoordinator
        self.metadataMutationService = metadataMutationService
        self.writebackService = writebackService
        self.smartAlbumRepo = smartAlbumRepo
        self.cullingService = cullingService
        self.exportService = exportService
        self.imagePreloadService = imagePreloadService
        registerExecutors()
    }

    /// Capture One 脚本成功后由宿主调用，写入持久 reload ack；页面不得在
    /// AppleScript 失败时伪造该标记。
    public func recordCaptureOneReloadAck(sessionId: String) throws {
        _ = try SessionRepo(connection: db).setReloadAckedAt(
            sessionId: sessionId,
            iso: nowISOString()
        )
    }

    /// 优雅停机（applicationShouldTerminate → prepareForTermination，ADR-023）：
    /// 停任务调度器（后续不再发起写回）→ 排空 XMP 协调器在飞任务与计时器
    /// （outbox 行保持 recoverable，下次启动由 start() 恢复）→ 关闭 SQLite。
    public func prepareForTermination() async {
        await jobService.stop()
        await metadataSyncCoordinator.shutdown()
        db.close()
    }

    /// 便捷装配：单 DB 连接构建全部已移植服务。
    /// - xmpProvider：XMP 侧车读写宿主实现（默认 SidecarXMPProvider；测试注入
    ///   内存假件）。
    /// - metadataWriteDebounceMs：协调器写去抖（TS 设置 metadata_write_debounce_ms，
    ///   默认 500；测试注入大值避免后台任务在用例窗口内落盘）。
    /// - faceKwService：默认装配 Vision 推理 + RAWDecoder 解码；测试可注入
    ///   假推理/解码（对齐 gather-core FaceKeywordingServiceTests 模式）。
    public static func makeDefault(
        db: DBConnection,
        xmpProvider: (any XMPProvider)? = nil,
        metadataWriteDebounceMs: Double? = nil,
        faceKwService: FaceKwService? = nil
    ) -> SessionCommandRouter {
        let sessionRepo = SessionRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let similarityResultRepo = SimilarityResultRepo(connection: db)
        let similarityService = SimilarityService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            similarityResultRepo: similarityResultRepo,
            clusterStateRepo: SimilarityClusterStateRepo(connection: db),
            connection: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            // 修复（审计 P0-1）：此前未注入 thumbnailProvider（默认恒 nil），
            // 相似度分析全部哈希计算失败 → SIM_NO_HASH_DATA。与
            // DuplicateService 共用同一 RAWDecoder 9x8 灰度管线。
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            }
        )
        let assetRepo = AssetRepo(connection: db)
        // 元数据写回链（TS di/init.ts 组合根）：XMP provider → 协调器 →
        // 变更服务 → 元数据服务 / 写回服务（XMPProvider 为宿主接缝，3.4
        // 正式 exiftool/XML-DOM 桥落位前用 SidecarXMPProvider 保证端到端可用）。
        let xmp = xmpProvider ?? SidecarXMPProvider()
        let outboxRepo = MetadataOutboxRepo(connection: db)
        let writebackRepo = WritebackRepo(connection: db)
        let metadataCacheRepo = MetadataCacheRepo(connection: db)
        let assetResolver = PhotoAssetResolver(connection: db, getSetting: { key, defaultValue in
            settingsService.get(key, defaultValue: defaultValue)
        })
        let metadataSyncCoordinator = MetadataSyncCoordinator(
            outboxRepo: outboxRepo,
            writebackRepo: writebackRepo,
            xmp: xmp,
            connection: db,
            getNumber: { key, defaultValue in
                if key == "metadata_write_debounce_ms", let metadataWriteDebounceMs {
                    return metadataWriteDebounceMs
                }
                return settingsService.getNumber(key, defaultValue: defaultValue)
            }
        )
        let metadataMutationService = MetadataMutationService(
            outboxRepo: outboxRepo,
            xmp: xmp,
            sync: metadataSyncCoordinator,
            assetResolver: assetResolver
        )
        // UI 对齐（§十一 11.9-1）：写回协调器 emitSummary 后广播 c1-sync-status
        // 事件，驱动 Culling/ControlCenter/Similarity 的同步状态即时刷新。
        // 注意：start(eventSink:) 是唯一恢复入口——它同时执行 recoverInterrupted()
        // （把进程被杀遗留的 writing 行归位并重新排程）。只赋 eventSink 属性会
        // 跳过恢复，使残留 writing 行永久阻塞 confirm/finalize/cleanup。
        metadataSyncCoordinator.start(eventSink: { summary in
            Task { @MainActor in
                GatherEventCenter.shared.postC1SyncStatusChange(sessionId: summary.sessionId)
            }
        })
        // 宿主侧的 EXIF/尺寸读取实现（ImageIO）。此前这两个注入点是空的：
        // getMetadata 会直接跳过 EXIF，
        // 于是 date_taken/cameraModel 永远为空、"按日期自动合并"恒为 0。
        let metadataService = MetadataService(
            metadataCacheRepo: metadataCacheRepo,
            xmp: xmp,
            connection: db,
            mutations: metadataMutationService,
            assetResolver: assetResolver,
            exif: ImageIOExifProvider(),
            dimensions: ImageIODimensionsProvider()
        )
        let writebackService = WritebackService(
            writebackRepo: writebackRepo,
            xmp: xmp,
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            metadataCacheRepo: metadataCacheRepo,
            metadataSync: metadataSyncCoordinator,
            metadataMutations: metadataMutationService,
            outboxRepo: outboxRepo,
            keywordOrigins: MetadataKeywordOriginRepo(connection: db),
            assetResolver: assetResolver
        )
        let personRepo = PersonRepo(connection: db)
        let jobService = JobService(repo: AnalysisJobRepo(connection: db))
        let exportService = ExportService(photoRepo: photoRepo, sessionRepo: sessionRepo, connection: db)
        let imagePreloadService = ImagePreloadService()
        let resolvedFaceKwService = faceKwService ?? FaceKwService(
            photoRepo: photoRepo,
            sessionRepo: sessionRepo,
            faceRepo: FaceRepo(connection: db),
            personRepo: personRepo,
            connection: db,
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            },
            getString: { key, defaultValue in
                settingsService.get(key, defaultValue: defaultValue)
            },
            writebackProvider: FaceKwWritebackBridge(writebackService: writebackService)
        )
        // 3.4 CullingService：sync/writeback 端口注入真实
        // MetadataSyncCoordinator / WritebackService（CullingSyncPort /
        // CullingWritebackPort 扩展即上述类型，见 CullingService.swift）。
        let cullingService = CullingService(
            photoRepo: photoRepo,
            cullingDecisionRepo: CullingDecisionRepo(connection: db),
            similarityResultRepo: similarityResultRepo,
            metadataCacheRepo: metadataCacheRepo,
            metadataOutboxRepo: outboxRepo,
            connection: db,
            metadataSync: metadataSyncCoordinator,
            metadataMutations: metadataMutationService,
            writeback: writebackService,
            cullingHistoryRepo: CullingHistoryRepo(connection: db),
            getNumber: { key, defaultValue in
                settingsService.getNumber(key, defaultValue: defaultValue)
            }
        )
        return SessionCommandRouter(
            db: db,
            sessionService: SessionService(
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                faceRepo: FaceRepo(connection: db),
                connection: db,
                dimensionsProvider: { path in
                    let dims = try RAWDecoder.getDimensions(path: path)
                    return (dims.width, dims.height)
                },
                assetRepo: assetRepo
            ),
            workspaceStatusService: WorkspaceStatusService(
                connection: db,
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                outboxRepo: outboxRepo
            ),
            jobService: jobService,
            photoRepo: photoRepo,
            settingsService: settingsService,
            filterEngine: FilterEngine(connection: db),
            navigationService: NavigationService(connection: db),
            similarityService: similarityService,
            duplicateService: DuplicateService(
                connection: db,
                thumbnailProvider: { path, size in
                    RAWDecoder.pixels9x8(path: path, maxPixel: size)
                },
                clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
                    try ClusterEngine.clusterByHash(
                        entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                        mode: mode, onProgress: onProgress)
                }
            ),
            assetRepo: assetRepo,
            faceKwService: resolvedFaceKwService,
            personRepo: personRepo,
            templateService: TemplateService(connection: db, settings: settingsService),
            qualityService: QualityService(
                photoRepo: photoRepo,
                connection: db,
                imageProvider: QualityService.defaultImageProvider,
                statProvider: QualityService.defaultStat
            ),
            indexerService: IndexerService(
                connection: db,
                sessionRepo: sessionRepo,
                photoRepo: photoRepo,
                assetRepo: assetRepo,
                // 照片内容/路径变化时只**失效命中 photoIds** 的派生人脸结果
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
            ),
            metadataService: metadataService,
            metadataSyncCoordinator: metadataSyncCoordinator,
            metadataMutationService: metadataMutationService,
            writebackService: writebackService,
            smartAlbumRepo: SmartAlbumRepo(connection: db),
            cullingService: cullingService,
            exportService: exportService,
            imagePreloadService: imagePreloadService
        )
    }

    /// TS di/init.ts 的 executor 注册段（similarity.analyze / duplicate.scan）。
    /// JobService 恢复 interrupted 任务时依赖 autoResume 注册表，故装配期
    /// 同步注册（autoResume 默认 true）。
    private func registerExecutors() {
        jobService.registerExecutor(type: .similarityAnalyze) { [similarityService] job, context in
            // TS similarity.ipc.ts:100-121：abort 时同步取消相似度占用。
            // 状态不再由 cancel 顺手写会话列（analysis_status 已改由 job 表派生，
            // 见 SimilarityService.cancel / §4.2 方案 A）。
            if context.signal.aborted {
                try? similarityService.cancel(sessionId: job.scopeId)
            }
            let checkpoint = job.checkpoint
            let onProgress: SimilarityService.ProgressHandler = { current, total, phase in
                context.updateProgress(JobProgressUpdate(
                    current: current, total: total, phase: phase, checkpoint: checkpoint))
            }
            // sim.recluster 与 sim.analyze 共用 .similarityAnalyze executor，由
            // checkpoint.operation 分派；两者的会话占用槽互斥由服务侧保证。
            // 阈值/组大小在命令层已解析为具体数值，executor 不再依赖设置服务。
            if checkpoint["operation"]?.stringValue == "recluster" {
                _ = try await similarityService.recluster(
                    sessionId: job.scopeId,
                    threshold: checkpoint["threshold"]?.numberValue ?? 10,
                    minGroupSize: checkpoint["minGroupSize"]?.numberValue ?? 2,
                    groupingMode: checkpoint["groupingMode"]?.stringValue == "sequential" ? .sequential : .global,
                    signal: context.signal,
                    onProgress: onProgress
                )
                return true
            }
            try await similarityService.analyze(
                sessionId: job.scopeId,
                threshold: checkpoint["threshold"]?.numberValue,
                minGroupSize: checkpoint["minGroupSize"]?.numberValue,
                groupingMode: checkpoint["groupingMode"]?.stringValue == "sequential" ? .sequential : .global,
                signal: context.signal,
                onProgress: onProgress
            )
            return true
        }

        jobService.registerExecutor(type: .duplicateScan) { [duplicateService] job, context in
            // TS duplicate.ipc.ts:11-20：checkpoint.visualThreshold 为 number
            // 时透传，否则 undefined。
            let result = try await duplicateService.scanDuplicates(
                sessionId: job.scopeId,
                visualThreshold: job.checkpoint["visualThreshold"]?.numberValue,
                signal: context.signal,
                onProgress: { current, total, phase in
                    context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: job.checkpoint))
                }
            )
            return result
        }

        // TS 源: face-kw.ipc.ts:24-40 —— face.analyze executor。job abort 经
        // signal handler 传播给 FaceKwService 的自持 controller（TS
        // addEventListener('abort') 语义；JobAbortSignal.addHandler 即等价物）。
        jobService.registerExecutor(type: .faceAnalyze) { [faceKwService] job, context in
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
                    context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: phase, checkpoint: checkpoint))
                }
            )
            return result
        }

        // TS 源: quality.ipc.ts:7-12 —— quality.score executor（photoIds 从
        // checkpoint 还原，TS 非数组过滤语义）。
        jobService.registerExecutor(type: .qualityScore) { [qualityService] job, context in
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
        jobService.registerExecutor(type: .metadataScan) { [indexerService, metadataService, photoRepo, assetRepo, jobService] job, context in
            // 扫描范围由 job 显式携带：checkpoint["requestedPaths"] 非空时只处理
            // 该集合（导入/显式扫描），否则回退到会话 source_path 全树。
            // 这里不再允许「调用方不给范围 → 静默全树扫描」的隐式语义。
            let requestedPaths: [String]? = {
                let paths = (job.checkpoint["requestedPaths"]?.arrayElements ?? [])
                    .compactMap(\.stringValue)
                return paths.isEmpty ? nil : paths
            }()
            let result = try await indexerService.scanSession(
                sessionId: job.scopeId,
                requestedPaths: requestedPaths,
                context: context
            )
            try context.throwIfCancelled()
            let photoIds = try photoRepo.getBySessionProjection(sessionId: job.scopeId)
                .filter { $0.status != "missing" }
                .map(\.id)
            context.updateProgress(JobProgressUpdate(
                current: 0, total: photoIds.count, phase: "index.metadata-read"
            ))
            _ = try await metadataService.getMetadata(photoIds: photoIds)
            _ = try assetRepo.reconcileRawJpegLinks(job.scopeId)
            context.updateCheckpoint(["result": try JSONValue(from: result)])
            context.updateProgress(JobProgressUpdate(
                current: photoIds.count, total: photoIds.count, phase: "index.metadata-done"
            ))
            if (try indexerService.pendingChecksums(sessionId: job.scopeId)) > 0 {
                _ = try jobService.create(JobCreateParams(
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
        jobService.registerExecutor(type: .checksumBackfill) { [indexerService] job, context in
            let result = try await indexerService.backfillChecksums(
                sessionId: job.scopeId,
                context: context
            )
            return result
        }

        // TS image.ipc.ts：缩略图预加载是低优先级可恢复任务；ImageIO
        // 解码失败按单张跳过，JobService 仍负责取消/心跳/终态。
        jobService.registerExecutor(type: .thumbnailBuild) { [imagePreloadService] job, context in
            let paths = job.checkpoint["paths"]?.arrayElements?.compactMap(\.stringValue) ?? []
            let size = Int(job.checkpoint["size"]?.numberValue ?? 1024)
            return try imagePreloadService.buildThumbnails(
                paths: paths,
                size: size,
                signal: context.signal,
                onProgress: { current, total in
                    context.updateProgress(JobProgressUpdate(
                        current: current, total: total, phase: "thumbnail.building",
                        checkpoint: [
                            "paths": .array(paths.map(JSONValue.string)),
                            "size": .number(Double(size)),
                            "nextPathIndex": .number(Double(current)),
                        ]
                    ))
                }
            )
        }

        // TS export.ipc.ts：断点状态以 checkpoint 为唯一持久化来源，
        // 避免导出中途退出后重新生成同名文件。
        jobService.registerExecutor(type: .exportExecute) { [exportService] job, context in
            let options: ExportOptions = try self.decodeJSON(
                ExportOptions.self,
                from: job.checkpoint["options"] ?? .object([:])
            )
            var destinations = job.checkpoint["destinations"]?.objectValue?.reduce(into: [String: String]()) { result, item in
                if let value = item.value.stringValue { result[item.key] = value }
            } ?? [:]
            var completedIds = Set(job.checkpoint["completedPhotoIds"]?.arrayElements?.compactMap(\.stringValue) ?? [])
            var completedSnapshot = Array(completedIds)
            // 问题 1：完成记录必须带上当时的边车版本（键缺失 → 视为不可信，重新交付）。
            var completedSidecarVersions = job.checkpoint["sidecarVersions"]?.objectValue?.compactMapValues { $0.stringValue } ?? [:]
            // D01 交付身份：指纹已在 dedupeKey 里（export.execute:<session>:<指纹>），
            // 任务仓库只会把**同一次交付**的完成清单继承过来；不同参数/照片集合拿到的是
            // 不同键，天然不会继承。G-4（审计 5）指出：既然键已含指纹，执行器里再比一次
            // stored != current 永远不成立（死代码）——已改为只兜「键内指纹缺失」：
            // 老版本或手工构造的 checkpoint 不带指纹时，一律不信任继承的完成清单。
            let currentFingerprint = try? exportService.deliveryFingerprint(sessionId: job.scopeId, options: options)
            if currentFingerprint != nil,
               job.checkpoint["deliveryFingerprint"]?.stringValue == nil {
                destinations = [:]
                completedIds = []
                completedSnapshot = []
            }
            /// 交付摘要（D02）：写入 checkpoint，供工作区完成标记与任务中心读取**实际结果**，
            /// 而不是只看 job.status == 'succeeded'。
            var deliverySummary: [String: JSONValue] = [:]
            // D-2/E-2/C-P2-3（性能审计）：checkpoint() 在**每张照片**的回调里被求值，
            // 旧实现每次都重建整份 options + destinations + completedPhotoIds
            //（1 万张 Σk ≈ 5×10⁷ 次装箱）。现在：options 只编码一次，
            // 其余键按代数缓存——只有真正变化时才重算。
            let optionsValue: JSONValue = (try? JSONValue(from: options)) ?? .object([:])
            var checkpointCache: [String: JSONValue]?
            var checkpointGeneration = 0
            var builtGeneration = -1
            let checkpoint: () -> [String: JSONValue] = {
                if builtGeneration == checkpointGeneration, let checkpointCache {
                    return checkpointCache
                }
                var value: [String: JSONValue] = [
                    "options": optionsValue,
                    "destinations": .object(destinations.mapValues(JSONValue.string)),
                    "completedPhotoIds": .array(completedSnapshot.map(JSONValue.string)),
                    "sidecarVersions": .object(completedSidecarVersions.mapValues(JSONValue.string)),
                ]
                if let currentFingerprint { value["deliveryFingerprint"] = .string(currentFingerprint) }
                for (key, item) in deliverySummary { value[key] = item }
                checkpointCache = value
                builtGeneration = checkpointGeneration
                return value
            }
            /// 目标名/完成清单变化时调用（唯一会改动 checkpoint 内容的两处）。
            // 前提：导出执行器的回调（onPlanned/onCompleted/onProgress/onPlanReady）
            // 由单线程串行触发（ExportService.execute 同步 for 循环）。若将来并行化
            // 导出循环，这里的可变缓存需要加锁。
            let invalidateCheckpoint: () -> Void = { checkpointGeneration += 1 }
            // 问题 2（第三轮审查）：按 run（= job id）取消，不能按会话取消——
            // 同会话并行导出两个目录时，取消一个不能中断另一个。
            context.signal.addHandler { exportService.cancel(runId: job.id) }
            let result = try exportService.execute(
                sessionId: job.scopeId,
                options: options,
                runId: job.id,
                onProgress: { progress in
                    context.updateProgress(JobProgressUpdate(
                        current: progress.current,
                        total: progress.total,
                        message: progress.status == "error" ? (progress.errorMessage ?? "export.error") : "export.processing",
                        checkpoint: checkpoint()
                    ))
                },
                resume: NativeExportResumeState(
                    destinations: destinations,
                    completedPhotoIds: completedIds,
                    sidecarVersions: completedSidecarVersions,
                    onPlanned: { photoId, destinationName in
                        destinations[photoId] = destinationName
                        invalidateCheckpoint()
                    },
                    onPlanReady: { context.updateCheckpoint(checkpoint()) },
                    onCompleted: { photoId, sidecarVersion in
                        completedSidecarVersions[photoId] = sidecarVersion
                        if completedIds.insert(photoId).inserted {
                            completedSnapshot.append(photoId)
                            invalidateCheckpoint()
                        }
                        context.updateProgress(JobProgressUpdate(checkpoint: checkpoint()))
                    }
                )
            )
            deliverySummary = [
                "exported": .number(Double(result.exported)),
                "failed": .number(Double(result.failed)),
                "skipped": .number(Double(result.skipped)),
                "totalFiles": .number(Double(result.totalFiles)),
                // F3（审计 1）：逐文件失败明细写进 checkpoint（截断 10 条）。
                // 全失败时 ExportResult 不返回给前端，若不落盘，UI 只能显示一句
                // 「请在导出结果中查看失败原因」而结果区是空的。
                "errors": .array(result.errors.prefix(10).map(JSONValue.string)),
            ]
            // P0（第二轮验证）：deliverySummary 是**唯一**漏掉失效的写入点——不失效时
            // 上面的 checkpoint 缓存命中，终态写库的字典里永远没有 exported/failed/
            // errors，导致工作区「已导出」判定对零产出任务误报、导出页可能闪错文案。
            invalidateCheckpoint()
            context.updateCheckpoint(checkpoint())
            // D02：零成功 + 有失败 = 本次交付没有产出任何文件。执行器原先正常返回，
            // JobService 因此写 'succeeded'、WorkspaceStatusService 推导出「已导出」，
            // 任务中心也把它当成功任务——全失败被当成交付完成。与写回同一约定：
            // 仍有未处理的失败就必须抛错误码，不得谎报成功。
            if result.exported == 0, result.failed > 0 {
                throw ExportServiceError.allFilesFailed(result.failed)
            }
            return result
        }
    }

    // MARK: 启动装配

    /// 启动时把持久化的界面语言应用到本地化层。
    /// `settings.ui_language` 是唯一真相源；此前只有 SettingsView 读它，
    /// 冷启动恒回退系统语言，导致「设置里显示中文、界面却是英文」。
    public func applyStoredInterfaceLanguage() {
        let stored = settingsService.get("ui_language")
        guard !stored.isEmpty else { return }
        GatherLocalization.setAppLanguage(stored)
    }

    // MARK: CommandRouter

    public func execute(_ command: String, params: [String: GatherCore.JSONValue]) throws -> GatherCore.JSONValue {
        switch command {
        // ── session.*（3.2 服务层）──

        case "session.list":
            let sessions = try sessionService.listSessions()
            return try GatherCore.JSONValue(from: sessions)

        case "session.get":
            let id = try requiredString(params, "sessionId")
            guard let session = try sessionService.getSession(id) else {
                throw BridgeError.notFound("SESSION_NOT_FOUND")
            }
            return try GatherCore.JSONValue(from: session)

        case "session.create":
            // TS session.ipc.ts createSessionParams：source 缺省 "manual"（非 "folder"）。
            let name = try requiredString(params, "name")
            let source = try optionalString(params, "source") ?? "manual"
            let requestedSourcePath = try optionalString(params, "sourcePath") ?? ""
            let requestedFilepaths = try optionalStringArray(params, "filepaths") ?? []
            let truncatedImport = optionalBool(params, "truncatedImport") ?? false
            // source_path 准入（与 sanitizeSessionSourcePath 同一域规则）：
            //  · 带 filepaths（文件导入）：只有「≥2 张照片的真实公共父目录」才被
            //    接受，单文件/根/主目录一律清空——文件导入的扫描范围必须由
            //    metadata.scan job 的 checkpoint.requestedPaths 显式携带，禁止
            //    用公共父目录把一次文件导入隐式放大成整棵树扫描。
            //  · 不带 filepaths（目录会话）：保留调用方显式给出的目录，仅拒绝禁根。
            let sourcePath: String
            if requestedFilepaths.isEmpty {
                sourcePath = (requestedSourcePath.isEmpty
                    || ScanPath.isForbiddenRoot(requestedSourcePath)) ? "" : requestedSourcePath
            } else {
                sourcePath = sanitizeSessionSourcePath(
                    sourcePath: requestedSourcePath, filepaths: requestedFilepaths)
            }
            let session = try sessionService.createSession(
                name: name, source: source, sourcePath: sourcePath, truncatedImport: truncatedImport)
            // TS 契约：filepaths 传入时创建即导入（addPhotos），返回
            // {session, failedFiles, added, skipped}；照片落库后重取会话
            // （status/photoCount 已更新），对齐 DashboardViewModel
            // LiveDashboardDataProvider.createSessionFromFiles。
            if !requestedFilepaths.isEmpty {
                let filepaths = requestedFilepaths
                let result = try sessionService.addPhotos(
                    sessionId: session.id, filepaths: filepaths, source: source)
                // 与 C1 / 菜单文件导入同一契约：source_path 已被清空，扫描作用域
                // 必须由 checkpoint.requestedPaths 显式承担——否则这条导入路径的
                // 照片永远不会被扫描，也就永远没有元数据/索引结果。
                _ = try jobService.create(JobCreateParams(
                    type: .metadataScan,
                    scopeType: "session",
                    scopeId: session.id,
                    dedupeKey: "metadata.scan:\(session.id)",
                    checkpoint: ["requestedPaths": .array(filepaths.map(GatherCore.JSONValue.string))]
                ))
                let refreshed = try sessionService.getSession(session.id) ?? session
                return .object([
                    "session": try GatherCore.JSONValue(from: refreshed),
                    "failedFiles": .array(result.failedFiles.map(GatherCore.JSONValue.string)),
                    "added": .number(Double(result.added)),
                    "skipped": .number(Double(result.skipped)),
                ])
            }
            return try GatherCore.JSONValue(from: session)

        case "session.delete":
            let id = try requiredString(params, "sessionId")
            try sessionService.deleteSession(id, confirmed: confirmed(params))
            return .null

        case "session.delete_many":
            let ids = try requiredStringArray(params, "sessionIds")
            _ = try sessionService.deleteSessions(ids, confirmed: confirmed(params))
            return .null

        case "session.update":
            let id = try requiredString(params, "sessionId")
            let name = try requiredString(params, "name")
            let session = try sessionService.updateSession(sessionId: id, name: name)
            return try GatherCore.JSONValue(from: session)

        case "session.add_photos":
            let id = try requiredString(params, "sessionId")
            let filepaths = try requiredStringArray(params, "filepaths")
            let source = try optionalString(params, "source") ?? "import"
            let result = try sessionService.addPhotos(sessionId: id, filepaths: filepaths, source: source)
            return .object([
                "added": .number(Double(result.added)),
                "skipped": .number(Double(result.skipped)),
                "total": .number(Double(result.total)),
                "failedFiles": .array(result.failedFiles.map(GatherCore.JSONValue.string)),
            ])

        // ── photo.*（3.2 服务层）──

        case "photo.list":
            let sessionId = try requiredString(params, "sessionId")
            let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            // 轻投影列（列名与 TS PhotoProjectionRow 逐字一致，见 PhotoRepo.swift）。
            return .array(photos.map { row in
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
            })

        // TS 源: photo.ipc.ts:96-112（键集分页；PAGE_SIZE=200 / MAX=1000）。
        case "photo.list_page":
            let sessionId = try requiredString(params, "sessionId")
            let limit = clampedLimit(params, default: 200, max: 1_000)
            let afterFirstRowid: Int64?
            if let raw = try optionalNumber(params, "afterFirstRowid"), raw.isFinite {
                afterFirstRowid = Int64(raw)
            } else {
                afterFirstRowid = nil
            }
            let expandVariants = optionalBool(params, "expandVariants") ?? false
            let page = try photoRepo.getAssetPage(sessionId: sessionId, afterFirstRowid: afterFirstRowid, limit: limit)
            return .object([
                "rows": .array(assemblePhotoRows(page.rows, sessionId: sessionId, expandVariants: expandVariants)),
                "cursor": page.cursor.map { .number(Double($0)) } ?? .null,
            ])

        // ── workspace（3.1 服务层）──

        case "workspace.status":
            // Protocol WorkspaceStatusParams.sessionId 非可选；现有调用方
            // （SessionControlView.load / 测试）均显式传 sessionId，故用
            // requiredString（缺省 "" 会静默查全部会话）。
            let sessionId = try requiredString(params, "sessionId")
            guard let status = try workspaceStatusService.getStatus(sessionId: sessionId) else {
                throw BridgeError.notFound("SESSION_NOT_FOUND")
            }
            return try GatherCore.JSONValue(from: status)

        // ── jobs.*（3.1 服务层）──

        case "jobs.list":
            // B-4/D-1/E-P0-2：展示型调用可传 includeCheckpoint=false，避免把每个
            // 任务的整份 checkpoint（导出可达 ~1MB）解析 + 序列化到主线程。
            let includeCheckpoint = params["includeCheckpoint"]?.boolValue ?? true
            let jobs = try jobService.list(includeCheckpoint: includeCheckpoint)
            return try GatherCore.JSONValue(from: jobs)

        // TS 源: jobs.ipc.ts:11 —— ok(jobs.cancel(jobId))。
        case "jobs.cancel":
            let jobId = try requiredString(params, "jobId")
            return .bool(try jobService.cancel(jobId))

        // TS 源: jobs.ipc.ts:12 —— ok(jobs.retry(jobId))。
        case "jobs.retry":
            let jobId = try requiredString(params, "jobId")
            return .bool(try jobService.retry(jobId))

        // TS 源: jobs.ipc.ts:13-19 —— destructive（confirmed 由命令边界校验；
        // 直连路由时二次兜底，对齐 TS JOBS_CLEAR_CONFIRM_REQUIRED）。
        case "jobs.clear_completed":
            guard confirmed(params) else {
                throw BridgeError.badParams("JOBS_CLEAR_CONFIRM_REQUIRED")
            }
            return .number(Double(try jobService.clearCompleted()))

        // ── settings.*（3.6 服务层；TS 源 settings.ipc.ts）──

        case "settings.get_all":
            // settings.ipc.ts:11 —— ok(svc.getAll())：Record<string, string>。
            return .object(settingsService.getAll().mapValues(GatherCore.JSONValue.string))

        case "settings.get":
            // settings.ipc.ts:13-16 —— key 校验后 ok(svc.get(key))。
            let key = try validatedString(params, "key", maxLength: 256)
            return .string(settingsService.get(key))

        case "settings.set":
            // settings.ipc.ts:18-23 —— ok({ done: true })；value 允许空串。
            let key = try validatedString(params, "key", maxLength: 256)
            let value = try validatedString(params, "value", maxLength: 4096, allowEmpty: true)
            try settingsService.set(key, value: value)
            return .object(["done": .bool(true)])

        case "settings.reset":
            // settings.ipc.ts:25-32 —— 重置后返回全部设置；菜单由原生
            // AppDelegate 管理，不在设置服务内重建。
            try settingsService.reset()
            return .object(settingsService.getAll().mapValues(GatherCore.JSONValue.string))

        case "settings.set_language":
            // settings.ipc.ts:38-46 —— 非 'zh-CN'/'en' 抛 SETTINGS_LANGUAGE_INVALID。
            guard let language = try optionalString(params, "language"),
                  language == "zh-CN" || language == "en"
            else {
                throw BridgeError.badParams("SETTINGS_LANGUAGE_INVALID")
            }
            try settingsService.set("ui_language", value: language)
            // 菜单文案跟随语言重建（对齐旧版 setAppLocale 即时 rebuild）。
            NotificationCenter.default.post(name: GatherAppNotification.languageChanged, object: language)
            return .object(["language": .string(language)])

        case "settings.get_ml_status":
            // settings.ipc.ts:48-79 —— 形状见 Protocol/Settings.swift MLStatusData。
            return try GatherCore.JSONValue(from: buildMLStatus())

        // ── filter.*（3.6 服务层；TS 源 filter.ipc.ts）──

        case "filter.photos":
            // filter.ipc.ts:39-69 —— 引擎内不钳制，IPC 层钳制 limit 1..500/offset ≥0
            // （默认 100/0），返回 PhotoData[]。
            let sessionId = try requiredString(params, "sessionId")
            let criteria = try parseFilterCriteria(params)
            let sortBy = try optionalString(params, "sortBy")
            let sortOrder = try optionalString(params, "sortOrder")
            let limit = clampedLimit(params, default: 100, max: 500)
            let offset = clampedOffset(params)
            let photos = try filterEngine.filterPhotos(
                sessionId: sessionId,
                criteria: criteria,
                sortBy: sortBy,
                sortOrder: sortOrder,
                limit: limit,
                offset: offset
            )
            return .array(photos.map(filterPhotoDataJSON))

        case "filter.photos_global":
            // filter.ipc.ts:71-94 —— ok({ photos, total })；total 为全局计数。
            let criteria = try parseFilterCriteria(params)
            let sessionId = try optionalString(params, "sessionId")
            let limit = clampedLimit(params, default: 100, max: 500)
            let offset = clampedOffset(params)
            let photos = try filterEngine.filterGlobally(
                criteria: criteria,
                limit: limit,
                offset: offset,
                sessionId: sessionId
            )
            let total = try filterEngine.countGlobally(criteria: criteria, sessionId: sessionId)
            return .object([
                "photos": try .array(photos.map { try GatherCore.JSONValue(from: $0) }),
                "total": .number(Double(total)),
            ])

        case "filter.suggest":
            // filter.ipc.ts:96-104 —— FilterSuggestion[]；keyword 非 string → ''。
            let sessionId = try requiredString(params, "sessionId")
            let keyword = try optionalString(params, "keyword") ?? ""
            let suggestions = try filterEngine.suggest(sessionId, keyword: keyword)
            return try .array(suggestions.map { try GatherCore.JSONValue(from: $0) })

        // ── navigation.*（3.6 服务层；TS 源 navigation.ipc.ts）──

        case "navigation.list":
            let sessionId = try requiredString(params, "sessionId")
            return try GatherCore.JSONValue(from: navigationService.list(sessionId: sessionId))

        case "navigation.split":
            let sessionId = try requiredString(params, "sessionId")
            let groupId = try requiredString(params, "groupId")
            let beforePhotoId = try requiredString(params, "beforePhotoId")
            return try GatherCore.JSONValue(
                from: navigationService.split(sessionId: sessionId, groupId: groupId, beforePhotoId: beforePhotoId)
            )

        case "navigation.merge":
            // ADR-017：服务内部重校验（组数 ≥2 / 同类型），IPC 仅做数组解析。
            let sessionId = try requiredString(params, "sessionId")
            let groupIds = try requiredStringArray(params, "groupIds")
            return try GatherCore.JSONValue(from: navigationService.merge(sessionId: sessionId, groupIds: groupIds))

        // ── sim.*（3.3 服务层；TS 源 similarity.ipc.ts）──

        case "sim.result":
            // similarity.ipc.ts:159-167 —— 同步查询；无结果返回 null（TS ok(null)）。
            let sessionId = try requiredString(params, "sessionId")
            let threshold = try optionalNumber(params, "threshold").map(Int.init)
            guard let result = try similarityService.getResult(sessionId: sessionId, threshold: threshold) else {
                return .null
            }
            return try GatherCore.JSONValue(from: result)

        case "sim.cancel_analysis":
            // similarity.ipc.ts:146-157 —— jobs.cancelScope + cancel，
            // 同步返回 ok(true)。分析状态由 job 表派生，cancel 不再写会话列。
            let sessionId = try requiredString(params, "sessionId")
            _ = try jobService.cancelScope(type: .similarityAnalyze, scopeId: sessionId)
            try similarityService.cancel(sessionId: sessionId)
            return .bool(true)

        // ── assets.*（3.2 服务层；TS 源 assets.ipc.ts:9-14）──

        case "assets.candidates":
            let sessionId = try optionalString(params, "sessionId")
            return try GatherCore.JSONValue(from: assetRepo.listCandidates(sessionId: sessionId))

        // ── dup.*（3.6 服务层；TS 源 duplicate.ipc.ts）──

        // TS: duplicate.ipc.ts:46-55 —— ok(getGroups(sessionId))。
        case "dup.resolve":
            guard confirmed(params) else {
                throw BridgeError.badParams("DUP_RESOLVE_CONFIRM_REQUIRED")
            }
            let groupId = try requiredNumber(params, "groupId")
            let resolutionRaw = try requiredString(params, "resolution")
            guard let resolution = DupResolution(rawValue: resolutionRaw) else {
                throw BridgeError.badParams("Invalid resolution: must be keep_one or keep_all")
            }
            try duplicateService.resolveGroup(groupId: Int(groupId), resolution: resolution)
            return .bool(true)

        // TS: duplicate.ipc.ts:77-92 —— destructive；isKept 缺省 true。
        case "dup.resolve_member":
            guard confirmed(params) else {
                throw BridgeError.badParams("DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED")
            }
            let memberId = try requiredNumber(params, "memberId")
            let isKept = optionalBool(params, "isKept") ?? true
            try duplicateService.resolveMember(memberId: Int(memberId), isKept: isKept)
            return .bool(true)

        // ── fkw.*（TS 源 face-kw.ipc.ts）──

        case "fkw.clusters":
            // face-kw.ipc.ts:98-105 —— ok(getClusters(sessionId))。
            let sessionId = try requiredString(params, "sessionId")
            let clusters = try faceKwService.getClusters(sessionId: sessionId)
            return try GatherCore.JSONValue(from: clusters)

        case "fkw.bind":
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
            try faceKwService.bindCluster(
                sessionId: sessionId, clusterId: Int64(clusterId), roleName: roleName, keywords: keywords)
            return .object(["done": .bool(true)])


        case "fkw.merge":
            // face-kw.ipc.ts:174-183 —— 源/目标簇合并。
            let sessionId = try requiredString(params, "sessionId")
            let source = try requiredNumber(params, "source")
            let target = try requiredNumber(params, "target")
            try faceKwService.mergeClusters(sessionId: sessionId, sourceId: Int64(source), targetId: Int64(target))
            return .object(["done": .bool(true)])

        case "fkw.remove_member":
            // face-kw.ipc.ts:185-194 —— 从簇中移除成员。
            let sessionId = try requiredString(params, "sessionId")
            let clusterId = try requiredNumber(params, "clusterId")
            let memberId = try requiredNumber(params, "memberId")
            try faceKwService.removeMember(sessionId: sessionId, clusterId: Int64(clusterId), memberId: Int64(memberId))
            return .object(["done": .bool(true)])


        case "fkw.cancel_analysis":
            // face-kw.ipc.ts:72-80 —— jobs.cancelScope + cancel，返回 {done:true}。
            let sessionId = try requiredString(params, "sessionId")
            _ = try jobService.cancelScope(type: .faceAnalyze, scopeId: sessionId)
            faceKwService.cancel(sessionId: sessionId)
            return .object(["done": .bool(true)])

        // ── person.*（TS 源 person.ipc.ts）──

        case "person.list":
            // person.ipc.ts:31-56 —— listWithCounts → PersonData[]。
            let rows = try personRepo.listWithCounts()
            return try .array(rows.map { try GatherCore.JSONValue(from: personData(row: $0)) })

        case "person.get":
            // person.ipc.ts:58-79 —— PERSON_NOT_FOUND；detail = data + photos。
            let personId = try requiredString(params, "personId")
            guard let row = try personRepo.get(id: personId) else {
                throw BridgeError.notFound("PERSON_NOT_FOUND")
            }
            let photos = try personRepo.getPhotosWithDetails(personId: personId)
            let detail = PersonDetailData(
                id: row.id,
                name: row.name,
                keywords: parseKeywordsJSON(row.keywords),
                // C-2 复核结论（第二轮验证）：这里其实是 person DTO，而
                // persons.thumbnail_base64 全仓无写入点（恒为空），fkw.clusters 的
                // DTO 在别处且其 base64 自迁移后也被清空 ⇒ 原审计前提不成立，
                // 回退为原样透传（无效改动不留在代码里）。
                thumbnailBase64: row.thumbnailBase64,
                thumbnailPath: row.thumbnailPath,
                notes: row.notes,
                matchThreshold: row.matchThreshold,
                photoCount: try personRepo.countPhotos(personId: personId),
                sessionCount: try personRepo.getSessionCount(personId: personId),
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                photos: photos.photos.map(personPhotoItem),
                totalPhotoCount: photos.total
            )
            return try GatherCore.JSONValue(from: detail)

        case "person.create":
            // person.ipc.ts:81-89 —— name 必填；keywords 可选。
            let name = try validatedString(params, "name")
            let keywords = try optionalStringArray(params, "keywords")
            let id = try personRepo.create(name: name, keywords: keywords)
            return .object(["id": .string(id)])

        case "person.update":
            // person.ipc.ts:91-103 —— 仅更新传入的字段。
            let personId = try requiredString(params, "personId")
            let fields = try parsePersonUpdateFields(params)
            try personRepo.update(id: personId, fields: fields)
            return .object(["done": .bool(true)])

        case "person.delete":
            // person.ipc.ts:105-115 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("PERSON_DELETE_CONFIRM_REQUIRED")
            }
            let personId = try requiredString(params, "personId")
            try personRepo.delete(id: personId)
            return .object(["done": .bool(true)])

        case "person.merge":
            // person.ipc.ts:117-128 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("PERSON_MERGE_CONFIRM_REQUIRED")
            }
            let sourceId = try requiredString(params, "sourceId")
            let targetId = try requiredString(params, "targetId")
            try personRepo.merge(sourceId: sourceId, targetId: targetId)
            return .object(["done": .bool(true)])

        case "person.remove_photo":
            // person.ipc.ts:130-141 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED")
            }
            let personId = try requiredString(params, "personId")
            let photoId = try requiredString(params, "photoId")
            try personRepo.removePhoto(personId: personId, photoId: photoId)
            return .object(["done": .bool(true)])

        case "person.search_photos":
            // person.ipc.ts:143-165 —— { photos, total }；sessionIds/limit/offset 可选。
            let personId = try requiredString(params, "personId")
            let sessionIds = try optionalStringArray(params, "sessionIds")
            let limit = try optionalNumber(params, "limit").map { Int($0) }
            let offset = try optionalNumber(params, "offset").map { Int($0) }
            let result = try personRepo.getPhotosWithDetails(
                personId: personId, sessionIds: sessionIds, limit: limit, offset: offset)
            return .object([
                "photos": try .array(result.photos.map { try GatherCore.JSONValue(from: personPhotoItem($0)) }),
                "total": .number(Double(result.total)),
            ])

        // ── template.*（TS 源 template.ipc.ts）──

        case "template.create":
            // template.ipc.ts:7-18 —— config 非对象抛 TEMPLATE_CONFIG_INVALID。
            let name = try validatedString(params, "name")
            let description = try optionalString(params, "description") ?? ""
            guard let configValue = params["config"], configValue.isObject else {
                throw BridgeError.badParams("TEMPLATE_CONFIG_INVALID")
            }
            let config = try decodeJSON(WorkflowTemplateConfig.self, from: configValue)
            let template = try templateService.create(name: name, description: description, config: config)
            return try GatherCore.JSONValue(from: template)

        case "template.list":
            return try GatherCore.JSONValue(from: templateService.list())

        case "template.get":
            let templateId = try requiredString(params, "templateId")
            guard let template = try templateService.get(id: templateId) else {
                throw BridgeError.notFound("TEMPLATE_NOT_FOUND")
            }
            return try GatherCore.JSONValue(from: template)

        case "template.update":
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
            let template = try templateService.update(id: templateId, fields: fields)
            return try GatherCore.JSONValue(from: template)

        case "template.delete":
            // template.ipc.ts:52-60 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("TEMPLATE_DELETE_CONFIRM_REQUIRED")
            }
            let templateId = try requiredString(params, "templateId")
            try templateService.delete(id: templateId)
            return .object(["done": .bool(true)])

        case "template.apply":
            // template.ipc.ts:62-71 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("TEMPLATE_APPLY_CONFIRM_REQUIRED")
            }
            let templateId = try requiredString(params, "templateId")
            let sessionId = try requiredString(params, "sessionId")
            try templateService.apply(templateId: templateId, sessionId: sessionId)
            return .object(["done": .bool(true)])

        // ── quality.*（TS 源 quality.ipc.ts）──

        case "quality.get":
            // quality.ipc.ts:25-30 —— photoIds 可选（validateStringArray 语义）。
            let sessionId = try requiredString(params, "sessionId")
            let photoIds = try optionalStringArray(params, "photoIds")
            let results = try qualityService.get(sessionId: sessionId, photoIds: photoIds)
            return try GatherCore.JSONValue(from: results)

        // ── metadata.*（TS 源 metadata.ipc.ts）──





        case "metadata.orphans":
            // metadata.ipc.ts:76-78 —— ok(listOrphans())。
            return try GatherCore.JSONValue(from: metadataSyncCoordinator.listOrphans())

        // ── sim.* 写回族（TS 源 similarity.ipc.ts:189-274）──



        case "sim.writeback_items":
            let sessionId = try requiredString(params, "sessionId")
            return try GatherCore.JSONValue(from: writebackService.getItems(sessionId: sessionId, module: "similarity"))




        case "assets.accept_candidate":
            // assets.ipc.ts:15-19 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("ASSET_LINK_ACCEPT_CONFIRM_REQUIRED")
            }
            let candidateId = try requiredString(params, "candidateId")
            // 仓库层 DBError.message → BridgeError（命令边界仅对 BridgeError
            // 走 message 透传；NSError 桥接会丢失消息）。
            try mapRepoError { try assetRepo.acceptCandidate(candidateId) }
            return .bool(true)

        case "assets.reject_candidate":
            // assets.ipc.ts:20-24 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("ASSET_LINK_REJECT_CONFIRM_REQUIRED")
            }
            let candidateId = try requiredString(params, "candidateId")
            try mapRepoError { try assetRepo.rejectCandidate(candidateId) }
            return .bool(true)

        case "assets.volumes":
            // assets.ipc.ts:25-27 —— ok(listVolumes())。
            return try GatherCore.JSONValue(from: assetRepo.listVolumes())

        case "assets.relink_root":
            // assets.ipc.ts:28-34 —— destructive。
            guard confirmed(params) else {
                throw BridgeError.badParams("ASSET_RELINK_CONFIRM_REQUIRED")
            }
            let oldRoot = try requiredString(params, "oldRoot")
            let newRoot = try requiredString(params, "newRoot")
            return .number(Double(try mapRepoError {
                try assetRepo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
            }))

        // ── album.*（TS 源 filter.ipc.ts registerAlbumHandlers）──

        case "album.create":
            // filter.ipc.ts:111-146 —— criteria 经 buildWhereClause 校验后落库。
            let name = try validatedString(params, "name")
            let criteria = try parseFilterCriteria(params)
            _ = try filterEngine.buildWhereClause(criteria)
            let sortBy = try optionalString(params, "sortBy")
            let sortOrder = try optionalString(params, "sortOrder")
            let description = try optionalString(params, "description")
            let icon = try optionalString(params, "icon")
            let row = try smartAlbumRepo.create(data: SmartAlbumCreateData(
                name: name, description: description, filterCriteria: criteria,
                sortBy: sortBy, sortOrder: sortOrder, icon: icon))
            let detail = try albumDetailData(row: row)
            return try GatherCore.JSONValue(from: detail)

        case "album.list":
            // filter.ipc.ts:148-186 —— 损坏 criteria 的行带 validationError 保留。
            let rows = try smartAlbumRepo.list()
            let albums: [SmartAlbumData] = rows.map { row in
                do {
                    let criteria = try decodeJSON(FilterGroup.self, from: JSONValue.parse(row.filterCriteria))
                    _ = try filterEngine.buildWhereClause(criteria)
                    return SmartAlbumData(
                        id: row.id, schemaVersion: row.schemaVersion, name: row.name,
                        description: row.description, filterCriteria: criteria,
                        sortBy: row.sortBy, sortOrder: row.sortOrder, icon: row.icon,
                        createdAt: row.createdAt, updatedAt: row.updatedAt)
                } catch {
                    return SmartAlbumData(
                        id: row.id, schemaVersion: row.schemaVersion, name: row.name,
                        description: row.description,
                        filterCriteria: FilterGroup(logic: .and, conditions: []),
                        sortBy: row.sortBy, sortOrder: row.sortOrder, icon: row.icon,
                        createdAt: row.createdAt, updatedAt: row.updatedAt,
                        validationError: Self.errorMessage(error))
                }
            }
            return try GatherCore.JSONValue(from: albums)

        case "album.get":
            // filter.ipc.ts:188-210 —— ALBUM_NOT_FOUND。
            let albumId = try requiredString(params, "albumId")
            guard let row = try smartAlbumRepo.get(id: albumId) else {
                throw BridgeError.notFound("ALBUM_NOT_FOUND")
            }
            return try GatherCore.JSONValue(from: albumDetailData(row: row))

        case "album.update":
            // filter.ipc.ts:212-230 —— 仅更新传入字段；criteria 传入时校验。
            let albumId = try requiredString(params, "albumId")
            let name = try optionalString(params, "name")
            let description = try optionalString(params, "description")
            var criteria: FilterGroup?
            if let rawCriteria = params["criteria"] {
                guard rawCriteria.isObject else { throw BridgeError.coded(.FILTER_CRITERIA_INVALID) }
                criteria = try parseFilterCriteria(params)
                _ = try filterEngine.buildWhereClause(criteria!)
            }
            let sortBy = try optionalString(params, "sortBy")
            let sortOrder = try optionalString(params, "sortOrder")
            let icon = try optionalString(params, "icon")
            try smartAlbumRepo.update(id: albumId, data: SmartAlbumUpdateData(
                name: name, description: description, filterCriteria: criteria,
                sortBy: sortBy, sortOrder: sortOrder, icon: icon))
            return .object(["done": .bool(true)])

        case "album.delete":
            // filter.ipc.ts:232-242 —— destructive（TS 消息非 GatherErrorCode）。
            guard confirmed(params) else {
                throw BridgeError.coded(.ALBUM_DELETE_CONFIRM_REQUIRED)
            }
            let albumId = try requiredString(params, "albumId")
            try smartAlbumRepo.delete(id: albumId)
            return .object(["done": .bool(true)])

        case "album.get_photos":
            // filter.ipc.ts:244-266 —— ALBUM_NOT_FOUND；limit 1..500 缺省 100。
            let albumId = try requiredString(params, "albumId")
            guard let row = try smartAlbumRepo.get(id: albumId) else {
                throw BridgeError.notFound("ALBUM_NOT_FOUND")
            }
            let criteria = try decodeJSON(FilterGroup.self, from: JSONValue.parse(row.filterCriteria))
            let limit = clampedLimit(params, default: 100, max: 500)
            let offset = clampedOffset(params)
            let photos = try filterEngine.filterGlobally(
                criteria: criteria, sortBy: row.sortBy, sortOrder: row.sortOrder,
                limit: limit, offset: offset)
            let total = try filterEngine.countGlobally(criteria: criteria)
            return .object([
                "photos": try .array(photos.map { try GatherCore.JSONValue(from: $0) }),
                "total": .number(Double(total)),
            ])

        // ── image / face ──

        case "image.prioritize_thumbnail":
            let path = try requiredString(params, "path")
            try requirePhotoPath(path)
            let size = clampedInt((try? optionalNumber(params, "size")) ?? settingsService.getNumber("thumbnail_size", defaultValue: 1024), fallback: 1024, range: 64...8192)
            try imagePreloadService.prioritizeThumbnail(path: path, size: size)
            return .null

        case "image.preload_thumbnails":
            let paths = try allowedPhotoPaths(params["paths"]?.arrayElements?.compactMap(\.stringValue) ?? [])
            guard !paths.isEmpty else { return .null }
            let size = Int((try? optionalNumber(params, "size")) ?? settingsService.getNumber("thumbnail_size", defaultValue: 1024))
            let fingerprint = paths.joined(separator: "\u{0}")
            let job = try jobService.create(JobCreateParams(
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
            return .string(job.id)

        case "image.preload_previews":
            let paths = try allowedPhotoPaths(params["paths"]?.arrayElements?.compactMap(\.stringValue) ?? [])
            let maxDimension = Int((try? optionalNumber(params, "maxDimension")) ?? 2048)
            imagePreloadService.preloadPreviews(paths: paths, maxDimension: maxDimension)
            return .null

        case "image.get_dimensions":
            if let paths = params["paths"]?.arrayElements?.compactMap(\.stringValue) {
                var results: [String: GatherCore.JSONValue] = [:]
                for path in try allowedPhotoPaths(paths) {
                    if let dims = try? RAWDecoder.getDimensions(path: path) {
                        results[path] = .object([
                            "width": .number(Double(dims.width)),
                            "height": .number(Double(dims.height)),
                        ])
                    }
                }
                return .object(results)
            }
            let path = try requiredString(params, "path")
            try requirePhotoPath(path)
            let dims = try RAWDecoder.getDimensions(path: path)
            return .object(["width": .number(Double(dims.width)), "height": .number(Double(dims.height))])


        case "export.cancel":
            let sessionId = try requiredString(params, "sessionId")
            _ = try jobService.cancelScope(type: .exportExecute, scopeId: sessionId)
            exportService.cancel(sessionId: sessionId)
            return .bool(true)

        case "export.report":
            let sessionId = try requiredString(params, "sessionId")
            let reportType = try optionalString(params, "reportType") ?? "session_summary"
            let format = try optionalString(params, "format")
            return try GatherCore.JSONValue(from: exportService.generateReport(
                sessionId: sessionId, reportType: reportType, format: format))

        case "face.models_status":
            let path = settingsService.get(FaceEmbeddingModelFactory.modelPathSetting, defaultValue: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = path.isEmpty ? FaceEmbeddingModelFactory.bundledModelURL
                : URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
            return .object([
                "provider": .string("coreml"), "fallbackToOnnxEnabled": .bool(false),
                "modelsPresent": .bool(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false),
                "downloading": .bool(false),
            ])

        // ── culling.* 同步面（TS 源 culling.ipc.ts；3.4 CullingService）──

        // culling.ipc.ts:83-107 —— 资产分组 keyset 分页；scope 白名单 +
        // afterRowId/limit 校验（limit 缺省 200，上限 2000）。
        case "culling.list_page":
            let sessionId = try requiredString(params, "sessionId")
            let scopeRaw = try requiredString(params, "scope")
            guard let scope = CullingScope(rawValue: scopeRaw) else {
                throw BridgeError.badParams("CULLING_INVALID_SCOPE")
            }
            let filters = try parseCullingFilters(params["filters"])
            let groupId = try optionalString(params, "groupId")
            // afterRowId 是上一页返回的 keyset 游标（仍是 photos.rowid 值）。
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
                      value >= 1, value <= Double(CullingService.pageLimitMax) else {
                    throw BridgeError.badParams("limit must be an integer between 1 and 2000")
                }
                limit = Int(value)
            } else {
                limit = 200
            }
            let page = try cullingService.listPage(
                sessionId: sessionId, scope: scope, filters: filters,
                requestedGroupId: groupId, afterRowId: afterRowId, limit: limit)
            return try GatherCore.JSONValue(from: page)

        // culling.ipc.ts:109-116 —— 历史栈（limit 1..500 缺省 100）。
        case "culling.history":
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
            let operations = try cullingService.getHistory(sessionId: sessionId, limit: limit ?? 100)
            return try GatherCore.JSONValue(from: operations)

        // culling.ipc.ts:118-152 —— undo/redo 显式条目；entries 非空数组（≤10000）。
        case "culling.apply_history":
            let sessionId = try requiredString(params, "sessionId")
            guard let entryValues = params["entries"]?.arrayElements,
                  !entryValues.isEmpty, entryValues.count <= CullingService.batchMax else {
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
            let results = try cullingService.applyHistory(
                sessionId: sessionId,
                requestedEntries: entries,
                historyOperationId: Int(historyOperationId),
                direction: direction)
            return try GatherCore.JSONValue(from: results)

        // culling.ipc.ts:154-177 —— 单张更新；复用缓存的会话级更新上下文
        //（点击突发不再重读整个会话）。
        case "culling.update":
            let sessionId = try requiredString(params, "sessionId")
            let photoId = try requiredString(params, "photoId")
            guard let expectedRevision = params["expectedRevision"]?.numberValue,
                  expectedRevision.isFinite, expectedRevision.rounded() == expectedRevision,
                  expectedRevision >= 0 else {
                throw BridgeError.badParams("expectedRevision must be a non-negative integer")
            }
            let patch = try parseCullingUpdatePatch(params["patch"])
            let context = try cullingService.getUpdateContext(sessionId: sessionId)
            let result = try cullingService.updateState(
                sessionId: sessionId, photoId: photoId,
                expectedRevision: Int(expectedRevision), patch: patch, context: context)
            return try GatherCore.JSONValue(from: result)

        // culling.ipc.ts:179-198 —— 批量更新（photoIds ≤10000，单事务）。
        case "culling.batch_update":
            let sessionId = try requiredString(params, "sessionId")
            let photoIds = try requiredStringArray(params, "photoIds")
            if photoIds.count > CullingService.batchMax {
                throw BridgeError.badParams("Too many photoIds in one batch")
            }
            let patch = try parseCullingUpdatePatch(params["patch"])
            let results = try cullingService.batchUpdate(
                sessionId: sessionId, photoIds: photoIds, patch: patch)
            return try GatherCore.JSONValue(from: results)

        // culling.ipc.ts:200-213 —— 整组批量 keep/reject。
        case "culling.decide_group":
            let sessionId = try requiredString(params, "sessionId")
            let groupId = try requiredString(params, "groupId")
            let keepPhotoIds = try requiredStringArray(params, "keepPhotoIds")
            if keepPhotoIds.count > CullingService.batchMax {
                throw BridgeError.badParams("Too many keepPhotoIds")
            }
            let results = try cullingService.decideSimilarityGroup(
                sessionId: sessionId, groupId: groupId, keepPhotoIds: keepPhotoIds)
            return try GatherCore.JSONValue(from: results)

        // culling.ipc.ts:215-221 —— ok(metadataSync.getSummary(sessionId))。
        // 额外附回 reloadAckedAt（session.reload_acked_at）：旧版胶囊的"最近同步"
        // 由 c1:sync-state 的 reloadAckedAt 提供；原生侧合并进同步摘要响应，
        // 解码方忽略未知键不受影响。
        case "culling.sync_status":
            let sessionId = try requiredString(params, "sessionId")
            let summary = try cullingService.syncStatus(sessionId: sessionId)
            guard let object = try? JSONValue(from: summary), case .object(var dict) = object else {
                return try GatherCore.JSONValue(from: summary)
            }
            let reloadAckedAt = try? SessionRepo(connection: db).get(id: sessionId)?.reloadAckedAt
            dict["reloadAckedAt"] = reloadAckedAt.map(JSONValue.string) ?? .null
            return .object(dict)

        // culling.ipc.ts:239-248 —— destructive（桥层 + 直连二次兜底）。
        case "culling.groups":
            let sessionId = try requiredString(params, "sessionId")
            return try GatherCore.JSONValue(from: cullingService.getGroups(sessionId: sessionId))

        // culling.ipc.ts:259-271 —— 旧版 renderer 单张决策；ok(true)。
        case "culling.decide":
            let sessionId = try requiredString(params, "sessionId")
            let photoId = try requiredString(params, "photoId")
            let decisionRaw = try requiredString(params, "decision")
            guard let decision = CullingDecisionValue(rawValue: decisionRaw) else {
                throw BridgeError.badParams("Invalid decision: must be keep, reject, or pending")
            }
            try cullingService.decide(sessionId: sessionId, photoId: photoId, decision: decision)
            return .bool(true)

        // culling.ipc.ts:273-285 —— 旧版 renderer 批量决策；ok(true)。
        case "culling.batch_decide":
            let sessionId = try requiredString(params, "sessionId")
            let photoIds = try requiredStringArray(params, "photoIds")
            let decisionRaw = try requiredString(params, "decision")
            guard let decision = CullingDecisionValue(rawValue: decisionRaw) else {
                throw BridgeError.badParams("Invalid decision: must be keep, reject, or pending")
            }
            try cullingService.batchDecide(sessionId: sessionId, photoIds: photoIds, decision: decision)
            return .bool(true)

        // culling.ipc.ts:287-294 —— 徽标计数。
        case "culling.summary":
            let sessionId = try requiredString(params, "sessionId")
            return try GatherCore.JSONValue(from: cullingService.getSummary(sessionId: sessionId))

        // culling.ipc.ts:349-358 —— destructive；重试失败写回项。
        case "culling.reset":
            guard confirmed(params) else {
                throw BridgeError.badParams("CULLING_RESET_CONFIRM_REQUIRED")
            }
            let sessionId = try requiredString(params, "sessionId")
            let groupId = try optionalString(params, "groupId")
            try cullingService.resetCommand(sessionId: sessionId, groupId: groupId, confirmed: true)
            return .bool(true)

        default:
            throw BridgeError.notImplemented(command)
        }
    }

    public func executeAsync(
        _ command: String,
        params: [String: GatherCore.JSONValue],
        completion: @escaping @Sendable (WebResponse) -> Void
    ) {
        switch command {
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
            do {
                let groups = try navigationService.analyze(
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

        // TS 源: similarity.ipc.ts:169-187 —— 阈值重聚类。
        // §4.2：与 sim.analyze 共用 .similarityAnalyze executor（checkpoint.operation
        // 分派），从而获得进度/取消/会话互斥与"提交前取消零落库"；命令层把缺省阈值
        // 解析为具体数值写进 checkpoint，executor 因此不依赖设置服务。响应形状不变：
        // job 完成后读回真实结果，UI 的采纳路径无需改动。
        case "sim.recluster":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let threshold = (try? optionalNumber(params, "threshold"))
                        ?? settingsService.getNumber("default_threshold", defaultValue: 10)
                    let minGroupSize = (try? optionalNumber(params, "minGroupSize"))
                        ?? settingsService.getNumber("default_min_group_size", defaultValue: 2)
                    let groupingMode: SimilarityGroupingMode
                    if let raw = try? optionalString(params, "groupingMode"), raw == "sequential" {
                        groupingMode = .sequential
                    } else {
                        groupingMode = .global
                    }
                    try validateSimilarityParameters(threshold: threshold, minGroupSize: minGroupSize)
                    let job = try jobService.create(JobCreateParams(
                        type: .similarityAnalyze,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "similarity.recluster:\(sessionId):\(threshold):\(minGroupSize):\(groupingMode.rawValue)",
                        checkpoint: [
                            "operation": .string("recluster"),
                            "threshold": .number(threshold),
                            "minGroupSize": .number(minGroupSize),
                            "groupingMode": .string(groupingMode.rawValue),
                        ]
                    ))
                    _ = try await jobService.waitForResult(jobId: job.id) as Any?
                    guard let result = try similarityService.getResult(
                        sessionId: sessionId, threshold: Int(threshold)
                    ) else {
                        completion(WebResponse(ok: true, data: .null))
                        return
                    }
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
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
                        threshold: threshold ?? settingsService.getNumber("default_threshold", defaultValue: 10),
                        minGroupSize: minGroupSize ?? settingsService.getNumber("default_min_group_size", defaultValue: 2)
                    )
                    // TS: threshold ?? 'default'（undefined 时不输出数值）。
                    let dedupeThreshold = threshold.map { String($0) } ?? "default"
                    let dedupeMinGroupSize = minGroupSize.map { String($0) } ?? "default"
                    let job = try jobService.create(JobCreateParams(
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
                    _ = try await jobService.waitForResult(jobId: job.id) as Any?
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
                    if let visualThreshold {
                        try duplicateService.validateDuplicateThreshold(visualThreshold)
                    }
                    let job = try jobService.create(JobCreateParams(
                        type: .duplicateScan,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "duplicate.scan:\(sessionId):\(visualThreshold.map { "\($0)" } ?? "default")",
                        checkpoint: [
                            "visualThreshold": visualThreshold.map { .number($0) } ?? .null,
                        ]
                    ))
                    let result: DuplicateScanResult? = try await jobService.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobServiceError.jobFailed(job.id, "empty duplicate.scan result")
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
                ?? settingsService.get("detector_model_path", defaultValue: "models/face_detector.onnx")
            let encoderPath = (try? optionalString(params, "encoderPath"))
                ?? settingsService.get("encoder_model_path", defaultValue: "models/face_encoder.onnx")
            Task {
                do {
                    try validateFaceClusteringParameters(
                        eps: eps ?? settingsService.getNumber("default_eps", defaultValue: 0.6),
                        minPts: minSamples ?? settingsService.getNumber("default_min_samples", defaultValue: 2)
                    )
                    let job = try jobService.create(JobCreateParams(
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
                    let result: FaceAnalysisResult? = try await jobService.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobServiceError.jobFailed(job.id, "empty fkw.analyze result")
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
                    let epsValue = eps ?? settingsService.getNumber("default_eps", defaultValue: 0.6)
                    let minSamplesValue = minSamples ?? settingsService.getNumber("default_min_samples", defaultValue: 2)
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
                    let data = try GatherCore.JSONValue(from: duplicateService.getGroups(sessionId: sessionId))
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
                    let result = try await cullingService.retryFailedWriteback(sessionId: sessionId, confirmed: true)
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
                    let result = try await cullingService.cleanup(sessionId: sessionId, confirmed: true)
                    let data = try GatherCore.JSONValue(from: result)
                    completion(WebResponse(ok: true, data: data))
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
            do {
                let job = try jobService.create(JobCreateParams(
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
            do {
                let job = try jobService.create(JobCreateParams(
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

        // TS 源: session.ipc.ts:36-59 —— 一跳导入：建会话 + metadata.scan job
        // 入队；job 创建失败回滚会话行。
        case "session.create_from_directory":
            let name = (try? optionalString(params, "name")) ?? ""
            guard let sourcePath = try? requiredString(params, "sourcePath") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sourcePath"))
                return
            }
            do {
                let session = try sessionService.createFromDirectory(name: name, sourcePath: sourcePath)
                do {
                    _ = try jobService.create(JobCreateParams(
                        type: .metadataScan,
                        scopeType: "session",
                        scopeId: session.id,
                        dedupeKey: "metadata.scan:\(session.id)"
                    ))
                } catch {
                    // TS: 入队失败回滚会话行，工作区列表不出现半成品会话。
                    try? sessionService.deleteSession(session.id, confirmed: true)
                    throw error
                }
                let data = try GatherCore.JSONValue(from: session)
                completion(WebResponse(ok: true, data: data))
            } catch {
                completion(WebResponse(ok: false, error: Self.errorMessage(error)))
            }

        // TS 源: metadata.ipc.ts:58-74 —— destructive；choices 逐字段校验。
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
                    let result = try await cullingService.writeback(
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
                    let summary = try await cullingService.flush(sessionId: sessionId)
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
                    let summary = try await cullingService.retrySync(sessionId: sessionId)
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
                    // D09：预览必须复用与执行**相同**的续跑基线——同指纹下若存在
                    // 终态任务，执行会复用它的 destinations/completedPhotoIds（跳过已写
                    // 文件、沿用旧名），预览若按"全新交付"算，就会显示 _2 后缀等与实际
                    // 写出不符的名字。
                    let deliveryFingerprint = try? self.exportService.deliveryFingerprint(
                        sessionId: sessionId,
                        options: options
                    )
                    var resumedNames: [String: String] = [:]
                    var completedPhotoIds: Set<String> = []
                    if let fingerprint = deliveryFingerprint,
                       let checkpoint = try? self.jobService.latestTerminalCheckpoint(
                           dedupeKey: "export.execute:\(sessionId):\(fingerprint)"
                       ),
                       // F6（审计 1）：只有 checkpoint 里记的指纹与本次请求一致才敢用它的
                       // 完成清单——dedupeKey 与内容指纹可能因 create→claim 之间的集合变化
                       // 而不一致，那时执行侧会重置，预览不能按旧基线显示「复用旧名」。
                       checkpoint["deliveryFingerprint"]?.stringValue == fingerprint {
                        resumedNames = checkpoint["destinations"]?.objectValue?.reduce(into: [String: String]()) { result, item in
                            if let value = item.value.stringValue { result[item.key] = value }
                        } ?? [:]
                        completedPhotoIds = Set(
                            checkpoint["completedPhotoIds"]?.arrayElements?.compactMap(\.stringValue) ?? []
                        )
                    }
                    let preview = try self.exportService.preview(
                        sessionId: sessionId,
                        options: options,
                        resumedNames: resumedNames,
                        completedPhotoIds: completedPhotoIds
                    )
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
                    self.jobService.start()
                    // D01：交付身份 = 完整输出参数 + 参与导出的照片集合指纹。
                    // 只有完全相同的请求才复用同一任务身份（=真续跑，允许继承完成记录）；
                    // 改命名/格式/XMP/范围或照片集合变化都是**新交付**，任务仓库找不到
                    // 同键终态行，因而不会把上次的 completedPhotoIds/destinations 补上。
                    let deliveryFingerprint = try self.exportService.deliveryFingerprint(
                        sessionId: sessionId,
                        options: options
                    )
                    let job = try self.jobService.create(JobCreateParams(
                        type: .exportExecute,
                        scopeType: "session",
                        scopeId: sessionId,
                        dedupeKey: "export.execute:\(sessionId):\(deliveryFingerprint)",
                        checkpoint: [
                            "options": try GatherCore.JSONValue(from: options),
                            "deliveryFingerprint": .string(deliveryFingerprint),
                        ]
                    ))
                    let result: ExportResult? = try await self.jobService.waitForResult(jobId: job.id)
                    guard let result else {
                        throw JobServiceError.jobFailed(job.id, "empty export.execute result")
                    }
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }


        case "metadata.get":
            guard let photoIds = try? requiredStringArray(params, "photoIds"), !photoIds.isEmpty else {
                completion(WebResponse(ok: false, error: "INVALID_PARAM:photoIds"))
                return
            }
            Task {
                do {
                    let map = try await self.metadataService.getMetadata(photoIds: photoIds)
                    var object: [String: GatherCore.JSONValue] = [:]
                    for (photoId, tags) in map {
                        object[photoId] = try GatherCore.JSONValue(from: tags)
                    }
                    completion(WebResponse(ok: true, data: .object(object)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "metadata.set":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "METADATA_SET_CONFIRM_REQUIRED"))
                return
            }
            guard let photoId = try? requiredString(params, "photoId"),
                  let tags = try? parseMetadataTags(params["tags"]) else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:tags"))
                return
            }
            Task {
                do {
                    let result = try await self.metadataService.setMetadata(photoId: photoId, tags: tags)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "metadata.batch_set":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "METADATA_BATCH_SET_CONFIRM_REQUIRED"))
                return
            }
            guard let updates = params["updates"]?.arrayElements, !updates.isEmpty else {
                completion(WebResponse(ok: false, error: "Invalid updates: must be a non-empty array"))
                return
            }
            Task {
                do {
                    let parsed: [(photoId: String, tags: MetadataTags)] = try updates.map { item in
                        let object = try self.requireObject(item, "updates[].photoId")
                        let photoId = try self.requiredSubString(object, "photoId")
                        let tags = try self.parseMetadataTags(object["tags"])
                        return (photoId, tags)
                    }
                    let result = try await self.metadataService.batchSet(updates: parsed)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "metadata.conflicts":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let conflicts = try await self.metadataSyncCoordinator.getConflicts(sessionId: sessionId)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: conflicts)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "sim.preview_writeback":
            guard let sessionId = try? requiredString(params, "sessionId"),
                  let assignments = try? validateSimilarityAssignments(params["assignments"]) else {
                completion(WebResponse(ok: false, error: "INVALID_PARAM:assignments"))
                return
            }
            let previewThreshold: Int? = (try? optionalNumber(params, "threshold")).map { Int($0) }
            Task {
                do {
                    let preview = try await self.buildSimilarityKeywordPreview(
                        sessionId: sessionId, assignments: assignments, threshold: previewThreshold)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: preview)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "sim.writeback":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "WRITEBACK_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            let itemIds: [Int] = (params["itemIds"]?.arrayElements ?? [])
                .compactMap(\.numberValue)
                .filter { $0.rounded() == $0 }
                .map { Int($0) }
            guard !itemIds.isEmpty else {
                completion(WebResponse(ok: false, error: "SIM_PREVIEW_REQUIRED"))
                return
            }
            Task {
                do {
                    if let threshold = (try? optionalNumber(params, "threshold")).map({ Int($0) }),
                       try !self.similarityService.hasResult(sessionId: sessionId, threshold: threshold) {
                        completion(WebResponse(ok: false, error: "SIM_THRESHOLD_NO_RESULTS"))
                        return
                    }
                    let idSet = Set(itemIds)
                    let pendingItems = try self.writebackService
                        .getItems(sessionId: sessionId, module: "similarity", status: "pending")
                        .filter { item in item.id.map { idSet.contains($0) } ?? false }
                    guard pendingItems.count == idSet.count else {
                        completion(WebResponse(ok: false, error: "SIM_PREVIEW_STALE"))
                        return
                    }
                    let result = try await self.writebackService.execute(
                        sessionId: sessionId, module: "similarity", items: pendingItems)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: result)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "sim.confirm_sync":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    try await self.writebackService.confirmSync(sessionId: sessionId, module: "similarity")
                    completion(WebResponse(ok: true, data: .bool(true)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "culling.finalize_sync":
            guard confirmed(params) else {
                completion(WebResponse(ok: false, error: "CULLING_FINALIZE_CONFIRM_REQUIRED"))
                return
            }
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    let summary = try await self.cullingService.finalizeSync(sessionId: sessionId, confirmed: true)
                    completion(WebResponse(ok: true, data: try GatherCore.JSONValue(from: summary)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }

        case "culling.confirm_sync":
            guard let sessionId = try? requiredString(params, "sessionId") else {
                completion(WebResponse(ok: false, error: "MISSING_PARAM:sessionId"))
                return
            }
            Task {
                do {
                    try await self.cullingService.confirmSync(sessionId: sessionId)
                    completion(WebResponse(ok: true, data: .bool(true)))
                } catch {
                    completion(WebResponse(ok: false, error: Self.errorMessage(error)))
                }
            }


        default:
            // 未在异步 switch 特化的命令（纯读/同步服务）：后台队列执行同步
            // execute，命令实现保持单一事实源（P0-2 修复方向：不再要求新命令
            // 在两个 switch 各写一遍）。走 GCD 而非 Task{}：避免继承调用方
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
    /// boundary tied to photoRepo.containsFilepath so callers cannot use
    /// dimensions/preload as an arbitrary file oracle.
    private func requirePhotoPath(_ path: String) throws {
        guard !path.isEmpty, path.count <= 4096,
              try photoRepo.containsFilepath(filepath: path) else {
            throw BridgeError.notFound("PHOTO_NOT_FOUND")
        }
    }

    private func allowedPhotoPaths(_ paths: [String]) throws -> [String] {
        var seen = Set<String>()
        var allowed: [String] = []
        for path in paths where !path.isEmpty && path.count <= 4096 && seen.insert(path).inserted {
            if try photoRepo.containsFilepath(filepath: path) { allowed.append(path) }
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
            throw BridgeError.coded(.FILTER_CRITERIA_INVALID)
        }
        do {
            return try JSONDecoder().decode(FilterGroup.self, from: data)
        } catch {
            // TS 消息逐字一致（filter.ipc.ts:21-33 的校验失败路径）。
            throw BridgeError.coded(.FILTER_CRITERIA_INVALID)
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
        _ rows: [PhotoPageRow],
        sessionId: String,
        expandVariants: Bool
    ) -> [GatherCore.JSONValue] {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return [] }

        // 角色与脸数小查询下沉 Repo/Service（原内联 SQL，P1-2 修复）。
        let memberRoles = (try? assetRepo.memberRoles(sessionId: sessionId, photoIds: ids)) ?? [:]
        let faceCounts = (try? faceKwService.faceCounts(sessionId: sessionId, photoIds: ids)) ?? [:]

        func toPhotoData(_ row: PhotoPageRow, variants: [PhotoPageRow]) -> GatherCore.JSONValue {
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

        var groups: [String: [PhotoPageRow]] = [:]
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
        let provider = settingsService.get("face_compute_units", defaultValue: "auto")
        let custom = settingsService.get(FaceEmbeddingModelFactory.modelPathSetting, defaultValue: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let encoderURL = custom.isEmpty ? FaceEmbeddingModelFactory.bundledModelURL
            : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        let encoderPath = encoderURL?.path ?? "SFace.mlpackage"
        return MLStatusData(
            platform: "darwin", autoBackend: "coreml",
            autoBackendLabel: "Vision + CoreML SFace", provider: provider, isAuto: provider == "auto",
            availableBackends: [MLBackendOption(value: "cpu", label: "CPU")],
            modelResourcesDir: encoderURL?.deletingLastPathComponent().path ?? modelResourcesDir(),
            detectorModel: MLModelPresence(path: "Apple Vision", resolvedPath: nil, exists: true),
            encoderModel: MLModelPresence(path: custom.isEmpty ? "内置 SFace" : custom,
                resolvedPath: encoderPath, exists: FileManager.default.fileExists(atPath: encoderPath)),
            modelInfo: MLModelInfo(detectInputSize: 0, secondaryDetectInputSize: 0,
                previewMaxDimension: clampedInt(settingsService.getNumber("face_preview_max_dimension", defaultValue: 2048), fallback: 2048, range: 256...8192),
                encoderInputSize: 112, embeddingDim: custom.isEmpty ? 128 : 0)
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

    /// 仓库层 DBError.message → BridgeError（命令边界只对 BridgeError 做
    /// message 透传，NSError 桥接会把 DBError 描述丢给系统错误文案）。
    private func mapRepoError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DBError {
            if case .message(let message) = error {
                throw BridgeError.badParams(message)
            }
            throw error
        }
    }


    // MARK: 参数解析（TS helpers / ipc 校验语义）


    /// 问题 6（第三轮审查）：Double → Int 必须分界安全（非有限/超范围会 trap）。
    /// 仅用于设置/游标这类外部可写值。
    private func clampedInt(_ value: Double, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return fallback }
        let rounded = value.rounded()
        if rounded < Double(range.lowerBound) { return range.lowerBound }
        if rounded > Double(range.upperBound) { return range.upperBound }
        return Int(rounded)
    }

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

    /// TS person.ipc.ts makeToPersonData。
    private func personData(row: PersonWithCountsRow) throws -> PersonData {
        PersonData(
            id: row.person.id,
            name: row.person.name,
            keywords: parseKeywordsJSON(row.person.keywords),
            thumbnailBase64: row.person.thumbnailBase64,
            thumbnailPath: row.person.thumbnailPath,
            notes: row.person.notes,
            matchThreshold: row.person.matchThreshold,
            photoCount: row.photoCount,
            sessionCount: row.sessionCount,
            createdAt: row.person.createdAt,
            updatedAt: row.person.updatedAt
        )
    }

    /// TS person.ipc.ts 的 PersonPhotoItem 映射（faceBbox JSON.parse 兜底 []）。
    private func personPhotoItem(_ detail: PersonPhotoDetail) -> PersonPhotoItem {
        let bbox = (try? GatherCore.JSONValue.parse(detail.photo.faceBbox))?
            .arrayElements?.compactMap(\.numberValue) ?? []
        return PersonPhotoItem(
            photoId: detail.photo.photoId,
            sessionId: detail.photo.sessionId,
            sessionName: detail.sessionName,
            filename: detail.filename,
            filepath: detail.filepath,
            faceBbox: bbox,
            confidence: detail.photo.confidence
        )
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
        let result = try similarityService.getResult(sessionId: sessionId, threshold: threshold)
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
        try writebackService.persistKeywords(items: selectedItems)
        return .object([
            "items": try .array(selectedItems.map { try GatherCore.JSONValue(from: $0) }),
            "totalCount": .number(Double(selectedItems.count)),
            "affectedPhotos": .number(Double(plan.affectedPaths.count)),
        ])
    }

    /// TS filter.ipc.ts SmartAlbumDetailData（album.create / album.get）。
    private func albumDetailData(row: SmartAlbumRow) throws -> SmartAlbumDetailData {
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
            photoCount: try filterEngine.countGlobally(criteria: criteria)
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
        // 人脸嵌入模型错误（配置的 .mlmodel/.mlmodelc 不可加载等）：description 是中文
        // 可读原因，必须在此映射，否则会落到 NSError 散文分支、被 UI 收敛成"发生未知错误"，
        // 用户根本无法知道是模型路径写错了（对抗审查高 4）。
        if let embeddingError = error as? FaceEmbeddingError { return embeddingError.description }
        if let templateError = error as? TemplateServiceError { return templateError.description }
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
        // 仓库层直接抛出的 DBError.message（TS 侧 throw new Error(code) 的
        // 仓库等价物，如 ASSET_LINK_CANDIDATE_NOT_FOUND）逐字透传。
        if let dbError = error as? DBError, case .message(let message) = dbError {
            return message
        }
        // JobService.waitForResult 失败终态：message 即 TS errorMessage
        // （executor 抛错经 String(describing:) 记录，错误枚举 description 对齐 TS）。
        if case JobServiceError.jobFailed(_, let message) = error { return message }
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


enum BridgeError: Error, CustomStringConvertible {
    case notImplemented(String)
    case badParams(String)
    case notFound(String)
    /// 结构化错误码（UI 侧按码取本地化文案；禁止用 badParams 传裸英文）
    case coded(GatherCore.GatherErrorCode)

    var description: String {
        switch self {
        case .notImplemented(let command): return "NOT_IMPLEMENTED: \(command)"
        case .badParams(let message): return message
        case .notFound(let code): return code
        case .coded(let code): return code.rawValue
        }
    }
}

extension GatherCore.JSONValue {
    init<T: Encodable>(from value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(GatherCore.JSONValue.self, from: data)
    }
}
