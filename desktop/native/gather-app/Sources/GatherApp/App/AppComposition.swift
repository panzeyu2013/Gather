// desktop/native/gather-app/Sources/GatherApp/App/AppComposition.swift
// R5 宿主组合根：构造全部 Runtime 与 19 域类型化命令实现，注册作业执行器。
// 旧宿主路由层同时承担「装配 + 命令分发」；本文件只保留装配职责，
// 命令分发由各域 `*CommandsImpl` 经 CommandSurface 提供，不存在命令名分发表。
import Foundation
import GatherCore

/// 宿主组合根产物：命令面 + 作业运行器 + 会话运行时 + 停机入口。
///
/// 生命周期：GatherApp.bootstrap 构造一次并持有；页面只拿自己需要的域协议。
public final class AppComposition {
    /// 19 域类型化命令面（唯一命令入口）。
    public let commands: CommandSurface
    /// 作业运行器（进度事件 / 停机 / 面板查询）。
    public let jobRunner: JobRunner
    /// 会话运行时（菜单导入、deep-link 导入、启动迁移复用）。
    public let sessionRuntime: SessionRuntime
    /// 设置写路径（启动期 embedding_dim 迁移等）。
    public let settingsAPI: SettingsAPI

    private let metadataSync: MetadataSyncRuntime
    private let sessionStore: any SessionStore
    private let photoStore: any PhotoStore
    private let assetStore: any AssetStore

    // 作业执行器依赖（registerExecutors 使用）。
    private let similarity: SimilarityRuntime
    private let duplicate: DuplicateRuntime
    private let faceKwRuntime: FaceKeywordingRuntime
    private let quality: QualityRuntime
    private let indexer: IndexerRuntime
    private let exportService: ExportRuntime
    private let metadataService: MetadataService

    init(
        commands: CommandSurface,
        jobRunner: JobRunner,
        sessionRuntime: SessionRuntime,
        settingsAPI: SettingsAPI,
        metadataSync: MetadataSyncRuntime,
        sessionStore: any SessionStore,
        photoStore: any PhotoStore,
        assetStore: any AssetStore,
        similarity: SimilarityRuntime,
        duplicate: DuplicateRuntime,
        faceKwRuntime: FaceKeywordingRuntime,
        quality: QualityRuntime,
        indexer: IndexerRuntime,
        exportService: ExportRuntime,
        metadataService: MetadataService
    ) {
        self.commands = commands
        self.jobRunner = jobRunner
        self.sessionRuntime = sessionRuntime
        self.settingsAPI = settingsAPI
        self.metadataSync = metadataSync
        self.sessionStore = sessionStore
        self.photoStore = photoStore
        self.assetStore = assetStore
        self.similarity = similarity
        self.duplicate = duplicate
        self.faceKwRuntime = faceKwRuntime
        self.quality = quality
        self.indexer = indexer
        self.exportService = exportService
        self.metadataService = metadataService
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
    /// （outbox 行保持 recoverable，下次启动由 start() 恢复）→ 由组合根关闭 SQLite。
    public func prepareForTermination() async {
        await jobRunner.stop()
        await metadataSync.shutdown()
    }

    /// 便捷装配：单 DB 连接构建全部已移植 Runtime 与命令实现。
    /// - xmpProvider：XMP 侧车读写宿主实现（默认 SidecarXMPProvider；测试注入内存假件）。
    /// - metadataWriteDebounceMs：协调器写去抖（TS 设置 metadata_write_debounce_ms，
    ///   默认 500；测试注入大值避免后台任务在用例窗口内落盘）。
    /// - faceKwRuntime：默认装配 Vision 推理 + RAWDecoder 解码；测试可注入
    ///   假推理/解码（对齐 Runtime/FaceKeywording 测试模式）。
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
        faceKwRuntime: FaceKeywordingRuntime? = nil
    ) async -> AppComposition {
        // SimilarityRuntime（Store/provider 注入）。
        let similarity = SimilarityRuntime(
            dependencies: SimilarityRuntime.Dependencies(
                photoStore: photoStore,
                sessionStore: sessionStore,
                similarityStore: similarityStore,
                jobStore: jobStore,
                getNumber: { key, defaultValue in
                    settings.number(key, default: defaultValue)
                }
            ),
            providers: SimilarityRuntime.Providers(
                // 修复（审计 P0-1）：thumbnailProvider 若不注入（默认恒 nil），
                // 相似度分析会全部哈希计算失败 → SIM_NO_HASH_DATA。与
                // DuplicateRuntime 共用同一 RAWDecoder 9x8 灰度管线。
                thumbnail: { path, size in
                    RAWDecoder.pixels9x8(path: path, maxPixel: size)
                }
            )
        )
        // 元数据写回链（TS di/init.ts 组合根）：XMP provider → 协调器 →
        // 变更 Runtime → 元数据服务 / 写回服务（XMPProvider 为宿主接缝，
        // SidecarXMPProvider 保证端到端可用）。
        let xmp = xmpProvider ?? SidecarXMPProvider()
        let assetResolver = PhotoAssetResolver(database: database, getSetting: { key, defaultValue in
            settings.value(key, default: defaultValue)
        })
        let metadataSyncCoordinator = MetadataSyncRuntime(
            writebackStore: writebackStore,
            xmp: xmp,
            sessionStore: sessionStore,
            getNumber: { key, defaultValue in
                if key == "metadata_write_debounce_ms", let metadataWriteDebounceMs {
                    return metadataWriteDebounceMs
                }
                return settings.number(key, default: defaultValue)
            }
        )
        let metadataMutationRuntime = MetadataMutationRuntime(
            dependencies: MetadataMutationRuntime.Dependencies(
                writebackStore: writebackStore,
                xmp: xmp,
                sync: metadataSyncCoordinator,
                assetResolver: assetResolver
            )
        )
        // UI 对齐（§十一 11.9-1）：写回协调器 emitSummary 后广播 c1-sync-status
        // 事件，驱动 Culling/ControlCenter/Similarity 的同步状态即时刷新。
        // P1-1：经 actor 隔离的 setEventSink 注入（不再有跨隔离域裸写）。
        await metadataSyncCoordinator.setEventSink { (summary: MetadataSyncSummary) in
            Task { @MainActor in
                GatherEventCenter.shared.postC1SyncStatusChange(sessionId: summary.sessionId)
            }
        }
        let metadataService = MetadataService(
            metadataStore: metadataStore,
            xmp: xmp,
            database: database,
            mutations: metadataMutationRuntime,
            assetResolver: assetResolver
        )
        let writebackService = WritebackRuntime(
            writebackStore: writebackStore,
            xmp: xmp,
            photoStore: photoStore,
            sessionStore: sessionStore,
            metadataSync: metadataSyncCoordinator,
            metadataMutations: metadataMutationRuntime,
            metadataStore: metadataStore,
            assetResolver: assetResolver
        )
        let jobRunner = JobRunner(jobStore: jobStore)
        let exportService = ExportRuntime(
            dependencies: .init(
                photoStore: photoStore,
                sessionStore: sessionStore,
                reportSource: SQLiteExportReportSource(store: SQLiteExportStore(database: database)),
                fileSystem: DiskExportFileSystem()
            )
        )
        let resolvedFaceKwRuntime = faceKwRuntime ?? FaceKeywordingRuntime(
            dependencies: FaceKeywordingRuntime.Dependencies(
                photoStore: photoStore,
                sessionStore: sessionStore,
                faceStore: faceStore,
                personStore: personStore,
                analysisRunStore: SQLiteAnalysisRunStore(database: database),
                getNumber: { key, defaultValue in
                    settings.number(key, default: defaultValue)
                },
                getString: { key, defaultValue in
                    settings.value(key, default: defaultValue)
                },
                writebackProvider: FaceKwWritebackBridge(writebackService: writebackService)
            )
        )
        // CullingRuntime：查询/写回端口注入真实协调器与写回服务；
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
                metadataMutations: metadataMutationRuntime,
                writeback: writebackService,
                getNumber: { key, defaultValue in
                    settings.number(key, default: defaultValue)
                }
            ),
            cache: CullingSessionCache()
        )
        // QualityRuntime：提交后经失效端口让 Culling 分析派生映射立即失效。
        let quality = QualityRuntime(
            photoStore: photoStore,
            jobStore: jobStore,
            similarityStore: similarityStore,
            faceStore: faceStore,
            imageProvider: QualityRuntime.defaultImageProvider,
            statProvider: QualityRuntime.defaultStat,
            invalidation: CullingQualityInvalidationPort(culling: culling)
        )
        // DuplicateRuntime：dup.scan / dup.groups / dup.resolve* 的 Runtime 化。
        let duplicate = DuplicateRuntime(
            store: SQLiteDuplicateStore(database: database),
            thumbnailProvider: { path, size in
                RAWDecoder.pixels9x8(path: path, maxPixel: size)
            },
            clusterProvider: { entries, threshold, minGroupSize, mode, onProgress in
                try ClusterEngine.clusterByHash(
                    entries: entries, threshold: threshold, minGroupSize: minGroupSize,
                    mode: mode, onProgress: onProgress)
            }
        )
        let sessionRuntime = SessionRuntime(
            sessionStore: sessionStore,
            photoStore: photoStore,
            faceStore: faceStore,
            deletionStore: SQLiteSessionDeletionStore(database: database),
            dimensionsProvider: { path in
                let dims = try RAWDecoder.getDimensions(path: path)
                return (dims.width, dims.height)
            },
            assetStore: assetStore
        )
        let indexer = IndexerRuntime(
            dependencies: IndexerRuntime.Dependencies(
                sessionStore: sessionStore,
                photoStore: photoStore,
                assetStore: assetStore,
                database: database,
                getDimensions: { path in
                    try RAWDecoder.getDimensions(path: path)
                },
                getSetting: { key, defaultValue in
                    settings.value(key, default: defaultValue)
                }
            )
        )
        let filterEngine = FilterEngine(database: database)
        let navigationService = NavigationRuntime(store: SQLiteNavigationStore(database: database))

        // 19 域类型化命令实现。
        let commands = CommandSurface(
            album: AlbumCommandsImpl(albums: albums, engine: filterEngine),
            assets: AssetsCommandsImpl(assets: assetStore),
            culling: CullingCommandsImpl(culling: culling),
            duplicate: DuplicateCommandsImpl(duplicate: duplicate, jobs: jobRunner),
            export: ExportCommandsImpl(export: exportService, jobs: jobRunner),
            face: FaceCommandsImpl(face: resolvedFaceKwRuntime, jobs: jobRunner, settings: settings),
            filter: FilterCommandsImpl(engine: filterEngine),
            index: IndexCommandsImpl(indexer: indexer),
            jobs: JobsCommandsImpl(jobs: jobRunner),
            metadata: MetadataCommandsImpl(metadata: metadataService, sync: metadataSyncCoordinator),
            navigation: NavigationCommandsImpl(navigation: navigationService),
            person: PersonCommandsImpl(persons: persons),
            photo: PhotoCommandsImpl(photos: photoStore, assets: assetStore, faces: faceStore),
            quality: QualityCommandsImpl(quality: quality, jobs: jobRunner),
            session: SessionCommandsImpl(runtime: sessionRuntime, jobs: jobRunner),
            settings: SettingsCommandsImpl(
                settings: settingsAPI,
                mlStatusProvider: { MLStatusBuilder.build(settings: settings) }
            ),
            similarity: SimilarityCommandsImpl(
                similarity: similarity,
                jobs: jobRunner,
                writeback: writebackService,
                settings: settings
            ),
            template: TemplateCommandsImpl(templates: templates, settings: settingsAPI),
            workspace: WorkspaceCommandsImpl(workspace: workspace)
        )
        let composition = AppComposition(
            commands: commands,
            jobRunner: jobRunner,
            sessionRuntime: sessionRuntime,
            settingsAPI: settingsAPI,
            metadataSync: metadataSyncCoordinator,
            sessionStore: sessionStore,
            photoStore: photoStore,
            assetStore: assetStore,
            similarity: similarity,
            duplicate: duplicate,
            faceKwRuntime: resolvedFaceKwRuntime,
            quality: quality,
            indexer: indexer,
            exportService: exportService,
            metadataService: metadataService
        )
        await composition.registerExecutors()
        return composition
    }

    /// TS di/init.ts 的 executor 注册段。JobRunner 恢复 interrupted 任务时依赖
    /// autoResume 注册表，故装配期同步注册（autoResume 默认 true）。
    private func registerExecutors() async {
        await jobRunner.registerExecutor(type: .similarityAnalyze) { [similarity] job, context in
            // TS similarity.ipc.ts:100-121：abort 时同步取消相似度占用
            // （session 列仅在真正持有者取消时写入）。
            if context.signal.aborted {
                try? await similarity.cancel(sessionId: job.scopeId, markStatus: false)
            }
            let checkpoint = job.checkpoint
            try await similarity.analyze(
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

        await jobRunner.registerExecutor(type: .duplicateScan) { [duplicate] job, context in
            // TS duplicate.ipc.ts:11-20：checkpoint.visualThreshold 为 number
            // 时透传，否则 undefined。
            let result = try await duplicate.scanDuplicates(
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
        // signal handler 传播给 FaceKeywordingRuntime 的自持 controller。
        await jobRunner.registerExecutor(type: .faceAnalyze) { [faceKwRuntime] job, context in
            context.signal.addHandler {
                faceKwRuntime.cancel(sessionId: job.scopeId)
            }
            let checkpoint = job.checkpoint
            let result = try await faceKwRuntime.analyze(
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
        await jobRunner.registerExecutor(type: .qualityScore) { [quality] job, context in
            let photoIds = job.checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue)
            return try await quality.analyze(
                sessionId: job.scopeId,
                photoIds: photoIds,
                context: context
            )
        }

        // TS 源: indexer.ipc.ts:26-67 —— metadata.scan executor：扫描 →
        // 元数据提取 → 资产链接对账 → checkpoint 落结果（恢复语义），
        // 剩余待回填 checksum 时入队 checksum.backfill。
        await jobRunner.registerExecutor(type: .metadataScan) { [indexer, metadataService, photoStore, assetStore, jobRunner] job, context in
            let scanSessionId = job.scopeId
            context.signal.addHandler {
                Task { await indexer.cancel(sessionId: scanSessionId) }
            }
            try await context.throwIfCancelled()
            let result = try await indexer.scan(
                sessionId: scanSessionId,
                options: IndexScanParams(sessionId: scanSessionId)
            )
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
            let pendingChecksums = try await photoStore.getBySessionProjection(sessionId: job.scopeId)
                .filter { IndexAssembler.needsChecksumBackfill(checksum: $0.checksum, status: $0.status) }
                .count
            if pendingChecksums > 0 {
                _ = try await jobRunner.create(JobCreateParams(
                    type: .checksumBackfill,
                    scopeType: "session",
                    scopeId: job.scopeId,
                    dedupeKey: "checksum.backfill:\(job.scopeId)"
                ))
            }
            return result
        }

        // TS 源: indexer.ipc.ts:26-32 —— checksum.backfill executor。
        await jobRunner.registerExecutor(type: .checksumBackfill) { [indexer] job, context in
            let result = try await indexer.backfillChecksums(
                sessionId: job.scopeId,
                context: context
            )
            return result
        }

        // TS export.ipc.ts：断点状态以 checkpoint 为唯一持久化来源，
        // 避免导出中途退出后重新生成同名文件。
        await jobRunner.registerExecutor(type: .exportExecute) { [exportService] job, context in
            let options: ExportOptions = try Self.decodeExportOptions(
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
            context.signal.addHandler { Task { try? await exportService.cancel(job.scopeId) } }
            let result = try await exportService.execute(
                ExportExecuteParams(sessionId: job.scopeId, options: options, confirmed: true),
                resume: ExportResumeState(destinations: destinations, completedPhotoIds: completedIds),
                onProgress: { progress in
                    Task { await context.updateProgress(JobProgressUpdate(
                        current: progress.current,
                        total: progress.total,
                        message: progress.status == "error" ? (progress.errorMessage ?? "export.error") : "export.processing",
                        checkpoint: checkpoint())) }
                },
                onPlanned: { photoId, destinationName in destinations[photoId] = destinationName },
                onPlanReady: { Task { await context.updateCheckpoint(checkpoint()) } },
                onCompleted: { photoId in
                    if completedIds.insert(photoId).inserted { completedSnapshot.append(photoId) }
                    Task { await context.updateProgress(JobProgressUpdate(checkpoint: checkpoint())) }
                }
            )
            await context.updateCheckpoint(checkpoint())
            return result
        }
    }

    /// JSONValue → Decodable（导出 executor 的 checkpoint 选项还原）。
    private static func decodeExportOptions(from value: JSONValue) throws -> ExportOptions {
        do {
            return try JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(value))
        } catch {
            // TS export.ipc.ts：options 解码失败统一抛 EXPORT_PARAMS_INVALID
            // （码值；英文散文会绕过 UI 的错误码翻译，故收敛为码值文本）。
            throw ExportCheckpointParamsInvalid()
        }
    }
}

/// 导出 checkpoint 选项解码失败（等价旧命令边界的 EXPORT_PARAMS_INVALID）。
private struct ExportCheckpointParamsInvalid: Error, CustomStringConvertible {
    var description: String { "EXPORT_PARAMS_INVALID" }
}

/// Quality 结果提交后的失效适配器 —— 端口方法
/// `QualityInvalidationPort.invalidateQualityLookup` 落到
/// `CullingRuntime.invalidateSessionLookup`（质量/人脸/关键词立即失效，
/// 下一次读取按需重载）。
private struct CullingQualityInvalidationPort: QualityInvalidationPort {
    let culling: CullingRuntime

    func invalidateQualityLookup(sessionId: String) async {
        await culling.invalidateSessionLookup(sessionId: sessionId)
    }
}
