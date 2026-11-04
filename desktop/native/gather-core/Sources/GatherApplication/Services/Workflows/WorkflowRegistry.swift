// desktop/native/gather-core/Sources/GatherApplication/Services/Workflows/WorkflowRegistry.swift
// Cut 1 / B8.3a / #3：JobService 的 8 个 workflow 注册表（从 GatherHost 回迁）。
//
// 本文件从旧路由的 registerExecutors（原 423-698 行，已删除）逐字搬出
// 以下 8 个执行器，闭包体/注释/checkpoint 语义保持不变：
//   similarity.analyze / duplicate.scan / face.analyze / quality.score /
//   metadata.scan / checksum.backfill / thumbnail.build / output.run
//
// 依赖全部经 Dependencies 显式传入（禁止引用命令路由类型）；路由宿主
// 在 B8.3b 之前只做委托，避免出现两份实现。executor 的注册顺序、weight 与
// autoResume 均沿用 JobService.registerExecutor 的默认值，与搬移前一致。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis

/// 8 个 executor 的依赖集合（组合根在 B8.3b 由 AppComposition 提供）。
///
/// 说明：`metadata.scan` 的恢复语义会用 jobService 再入队 checksum.backfill，
/// 但 jobService 已作为 register(jobService:deps:) 的显式参数传入，故不在本
/// struct 中重复持有。
public struct WorkflowDependencies {
    public let similarityService: SimilarityService
    public let duplicateService: DuplicateService
    public let faceKwService: FaceKwService
    public let qualityService: QualityService
    public let modelReviewService: ModelReviewService
    /// triage_model_review 设置（false 时 quality job 只跑技术质量）。
    public let modelReviewEnabled: @Sendable () -> Bool
    /// triage_auto_generate：导入完成后自动接 metadata.scan → quality.score。
    public let triageAutoGenerateEnabled: @Sendable () -> Bool
    public let indexerService: IndexerService
    public let metadataService: MetadataService
    public let photoRepo: any PhotoRepository
    public let assetRepo: any AssetRepository
    public let imagePreloadService: ImagePreloadService
    public let exportService: ExportService
    public let outputService: OutputService
    /// P1-3：ingest.run 执行器需要会话/登记服务。
    public let sessionService: SessionService
    public init(
        similarityService: SimilarityService,
        duplicateService: DuplicateService,
        faceKwService: FaceKwService,
        qualityService: QualityService,
        modelReviewService: ModelReviewService,
        modelReviewEnabled: @escaping @Sendable () -> Bool,
        triageAutoGenerateEnabled: @escaping @Sendable () -> Bool,
        indexerService: IndexerService,
        metadataService: MetadataService,
        photoRepo: any PhotoRepository,
        assetRepo: any AssetRepository,
        imagePreloadService: ImagePreloadService,
        exportService: ExportService,
        outputService: OutputService,
        sessionService: SessionService
    ) {
        self.similarityService = similarityService
        self.duplicateService = duplicateService
        self.faceKwService = faceKwService
        self.qualityService = qualityService
        self.modelReviewService = modelReviewService
        self.modelReviewEnabled = modelReviewEnabled
        self.triageAutoGenerateEnabled = triageAutoGenerateEnabled
        self.indexerService = indexerService
        self.metadataService = metadataService
        self.photoRepo = photoRepo
        self.assetRepo = assetRepo
        self.imagePreloadService = imagePreloadService
        self.exportService = exportService
        self.outputService = outputService
        self.sessionService = sessionService
    }
}

/// JobService 执行器注册表：装配期一次性注册 8 个 type。
///
/// 无状态命名空间：注册只发生在组合根/测试装配阶段，注册后 JobService 持有
/// 不可变 Registration；本类型不保存任何服务实例，避免第二份缓存/状态。
public enum WorkflowRegistry {
    public typealias Dependencies = WorkflowDependencies

    /// 注册全部 8 个 executor，返回实际注册的 type（顺序与注册顺序一致）。
    ///
    /// 返回值只用于装配期自检与测试断言，生产调用方可忽略；注册失败不会发生
    /// （JobService.registerExecutor 无失败路径，同 type 重复注册为覆盖）。
    @discardableResult
    public static func register(jobService: JobService, deps: Dependencies) -> [AnalysisJobType] {
        let registrations = makeExecutors(jobService: jobService, deps: deps)
        for (type, executor) in registrations {
            jobService.registerExecutor(type: type, executor: executor)
        }
        return registrations.map { $0.0 }
    }

    /// 8 个 executor 的唯一构造点（register 与测试共用，防止两份清单漂移）。
    ///
    /// 每个闭包的执行体与原注册方法完全一致；
    /// 唯一的机械改动是 output.run 里的 `self.decodeJSON` 改为本类型私有
    /// 静态函数（路由实例方法不能跨类型引用）。
    public static func makeExecutors(
        jobService: JobService,
        deps: Dependencies
    ) -> [(AnalysisJobType, JobService.JobExecutor)] {
        let similarityService = deps.similarityService
        let duplicateService = deps.duplicateService
        let faceKwService = deps.faceKwService
        let qualityService = deps.qualityService
        let modelReviewService = deps.modelReviewService
        let modelReviewEnabled = deps.modelReviewEnabled
        let triageAutoGenerateEnabled = deps.triageAutoGenerateEnabled
        let indexerService = deps.indexerService
        let metadataService = deps.metadataService
        let photoRepo = deps.photoRepo
        let assetRepo = deps.assetRepo
        let imagePreloadService = deps.imagePreloadService
        let exportService = deps.exportService
        let outputService = deps.outputService
        let sessionService = deps.sessionService

        return [
            (.similarityAnalyze, { job, context in
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
            }),

            (.duplicateScan, { job, context in
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
            }),

            // TS 源: face-kw.ipc.ts:24-40 —— face.analyze executor。job abort 经
            // signal handler 传播给 FaceKwService 的自持 controller（TS
            // addEventListener('abort') 语义；JobAbortSignal.addHandler 即等价物）。
            (.faceAnalyze, { job, context in
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
            }),

            // TS 源: quality.ipc.ts:7-12 —— quality.score executor（photoIds 从
            // checkpoint 还原，TS 非数组过滤语义）。
            // quality.score = 技术质量 + 模型信号两段。第二段失败不改变第一段已提交的
            // 结果：模型失败只记 failed 行，job 仍成功（技术质量是主产物）。
            (.qualityScore, { job, context in
                let photoIds = job.checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue)
                let results = try await qualityService.analyze(
                    sessionId: job.scopeId,
                    photoIds: photoIds,
                    context: context
                )
                try context.throwIfCancelled()
                // 只有设置开关决定是否跑模型段：checkpoint["modelReview"] 从来没有生产者，
                // 之前那条 `?? true` 只是死代码（读的人会以为存在按任务关闭的入口）。
                let runModel = modelReviewEnabled()
                if runModel {
                    do {
                        _ = try await modelReviewService.analyze(
                            sessionId: job.scopeId,
                            photoIds: photoIds,
                            isCancelled: { context.signal.aborted },
                            onProgress: { current, total in
                                context.updateProgress(JobProgressUpdate(
                                    current: current, total: total, phase: "model.review"))
                            })
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // 模型段失败不拖垮技术质量：结果行已按 failed 落库，job 继续。
                        GatherLogger.log("model.review stage failed: \(error)", level: .warn)
                    }
                }
                return results
            }),

            // TS 源: indexer.ipc.ts:26-67 —— metadata.scan executor：扫描 →
            // 元数据提取 → 资产链接对账 → checkpoint 落结果（恢复语义），
            // 剩余待回填 checksum 时入队 checksum.backfill。
            (.metadataScan, { [indexerService, metadataService, photoRepo, assetRepo, jobService] job, context in
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
                // P1：导入触发的扫描把新照片接给 quality.score（技术质量 + 模型信号）。
                if job.checkpoint["autoQuality"]?.boolValue == true, !photoIds.isEmpty {
                    do {
                        _ = try jobService.create(JobCreateParams(
                            type: .qualityScore,
                            scopeType: "session",
                            scopeId: job.scopeId,
                            dedupeKey: "quality.score:\(job.scopeId):auto-triage:\(Self.idsFingerprint(photoIds))",
                            checkpoint: ["photoIds": .array(photoIds.map(JSONValue.string))]
                        ))
                    } catch {
                        GatherLogger.log(
                            "auto-triage quality enqueue failed: \(error)", level: .warn)
                    }
                }
                // 合并而不是整块替换：checkpoint 里的 requestedPaths 是
                // SessionDirectoryMonitor 判定"窄 job 是否覆盖本次目录"的唯一依据；
                // 写 result 时丢掉它会让运行中的窄 job 被误判为全树扫描，
                // watcher 提前 ack + 持久化 eventID → 永久漏扫（P1）。
                var checkpoint = job.checkpoint
                checkpoint["result"] = try Self.encodeJSONValue(result)
                context.updateCheckpoint(checkpoint)
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
            }),

            // TS 源: indexer.ipc.ts:26-32 —— checksum.backfill executor（后台回填
            // 懒索引留下的空 checksum）。
            (.checksumBackfill, { job, context in
                // P1-3：ingest.run 复用 checksum.backfill 载体（schema CHECK 不允许新 type），
                // 由 checkpoint.operation 分派；请求完整编码在 checkpoint。
                if job.checkpoint["operation"]?.stringValue == "ingest" {
                    let payload = try SessionIngestRunner.decode(job.checkpoint)
                    let runner = SessionIngestRunner(sessionService: sessionService)
                    let result = try await runner.run(payload, context: context)
                    // P1：导入收尾后自动初审（默认关；用户开 triage_auto_generate）。
                    // 取消/全部跳过不触发；扫描只针对本会话，quality 只跑新登记的照片。
                    if !context.signal.aborted,
                       triageAutoGenerateEnabled(),
                       result.registered > 0 {
                        do {
                            _ = try jobService.create(JobCreateParams(
                                type: .metadataScan,
                                scopeType: "session",
                                scopeId: job.scopeId,
                                dedupeKey: "metadata.scan:\(job.scopeId):auto-triage:\(UUID().uuidString)",
                                // 显式空数组：清掉上次终态继承的 requestedPaths，
                                // 否则新导入的照片会被旧窄范围漏掉（空=全树）。
                                checkpoint: [
                                    "autoQuality": .bool(true),
                                    "requestedPaths": .array([]),
                                ]
                            ))
                        } catch {
                            GatherLogger.log(
                                "auto-triage scan enqueue failed: \(error)", level: .warn)
                        }
                    }
                    return result
                }
                let result = try await indexerService.backfillChecksums(
                    sessionId: job.scopeId,
                    context: context
                )
                return result
            }),

            // TS image.ipc.ts：缩略图预加载是低优先级可恢复任务；ImageIO
            // 解码失败按单张跳过，JobService 仍负责取消/心跳/终态。
            (.thumbnailBuild, { job, context in
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
            }),

            // TS export.ipc.ts：断点状态以 checkpoint 为唯一持久化来源，
            // 避免导出中途退出后重新生成同名文件。
            (.outputRun, { job, context in
                // 整套交付：checkpoint 带 outputRun=true + input（配方/根目录/联系表）。
                if job.checkpoint["outputRun"]?.boolValue == true {
                    let input: OutputRunInput = try decodeJSON(
                        OutputRunInput.self, from: job.checkpoint["input"] ?? .object([:]))
                    // 取消：把 job 的取消信号同时接到「当前配方导出」与编排层，
                    // 否则 UI 显示已取消、磁盘还在写剩余配方/画廊/联系表。
                    context.signal.addHandler { exportService.cancel(runId: job.id) }
                    var storedResume: [String: OutputRecipeResume] = [:]
                    var latestCheckpoint = job.checkpoint
                    if let resumeValue = job.checkpoint["resume"] {
                        do {
                            storedResume = try decodeJSON(
                                [String: OutputRecipeResume].self, from: resumeValue)
                        } catch {
                            storedResume = [:]
                        }
                    }
                    let summary = try outputService.run(
                        input: input,
                        runId: job.id,
                        isCancelled: { context.signal.aborted },
                        resume: storedResume,
                        onRecipeResume: { recipeId, state in
                            storedResume[recipeId] = state
                            var merged = latestCheckpoint
                            merged["outputRun"] = .bool(true)
                            do {
                                merged["resume"] = try Self.encodeJSONValue(storedResume)
                            } catch {
                                return
                            }
                            latestCheckpoint = merged
                            context.updateCheckpoint(merged)
                        }
                    ) { progress in
                        context.updateProgress(JobProgressUpdate(
                            current: progress.current, total: max(1, progress.total),
                            message: "output.\(progress.recipeIndex + 1)/\(progress.recipeCount)"))
                    }
                    // 与单导出同一约定：checkpoint 是工作区「已导出/已交付」判定的
                    // 唯一来源；0 成功 + 有失败必须抛错，不能落 succeeded。
                    let totalExported = summary.recipes.reduce(0) { $0 + $1.exported }
                    let totalFailed = summary.recipes.reduce(0) { $0 + $1.failed }
                    let totalFiles = summary.recipes.reduce(0) { $0 + $1.exported + $1.failed + $1.skipped }
                    let errors = summary.recipes.flatMap(\.errors)
                    // 合并而不是整块替换：retry 复用同一行 checkpoint，
                    // 抹掉 outputRun/input 会让重试落到单导出分支并解码失败。
                    // 必须基于运行中最新的 checkpoint（含 onRecipeResume 写入的 resume），
                    // 否则成功收尾会丢掉续跑状态，下一次运行会整目录重导成 _2。
                    var finalCheckpoint = latestCheckpoint
                    finalCheckpoint["exported"] = .number(Double(totalExported))
                    finalCheckpoint["failed"] = .number(Double(totalFailed))
                    finalCheckpoint["skipped"] = .number(Double(summary.recipes.reduce(0) { $0 + $1.skipped }))
                    finalCheckpoint["totalFiles"] = .number(Double(totalFiles))
                    finalCheckpoint["errors"] = .array(errors.prefix(10).map(JSONValue.string))
                    finalCheckpoint["manifestPath"] = .string(summary.manifestPath)
                    finalCheckpoint["outputRun"] = .bool(true)
                    context.updateCheckpoint(finalCheckpoint)
                    if totalExported == 0, totalFailed > 0 {
                        throw ExportServiceError.allFilesFailed(totalFailed)
                    }
                    return summary
                }
                let options: ExportOptions = try decodeJSON(
                    ExportOptions.self,
                    from: job.checkpoint["options"] ?? .object([:])
                )
                var destinations = job.checkpoint["destinations"]?.objectValue?.reduce(into: [String: String]()) { result, item in
                    if let value = item.value.stringValue { result[item.key] = value }
                } ?? [:]
                var completedIds = Set(job.checkpoint["completedPhotoIds"]?.arrayElements?.compactMap(\.stringValue) ?? [])
                var completedSnapshot = Array(completedIds)
                // 问题 1：完成记录必须带上当时的 sidecar 版本（键缺失 → 视为不可信，重新交付）。
                var completedSidecarVersions = job.checkpoint["sidecarVersions"]?.objectValue?.compactMapValues { $0.stringValue } ?? [:]
                // D01 交付身份：指纹已在 dedupeKey 里（output.run:<session>:<指纹>），
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
                let optionsValue: JSONValue = (try? Self.encodeJSONValue(options)) ?? .object([:])
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
            }),
        ]
    }

    /// JSONValue → Codable（JSONDecoder 往返；解码失败为契约漂移，抛原始错误）。
    /// 与原路由私有 decodeJSON（原 3100-3102 行）逐字同义。
    /// 稳定短指纹（FNV-1a 64）：auto-triage 的 dedupeKey 只区分 photoIds 集合，
    /// 不把完整 ID 列表塞进 dedupe_key。
    static func idsFingerprint(_ photoIds: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in photoIds.sorted().joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    /// Encodable → JSONValue（checkpoint 的通用编码入口）。
    ///
    /// 为什么不复用 GatherUI 的同名便利初始化（Support/JSONValueDecoding.swift）：
    /// #3 把 workflow 搬进 core 后那条初始化在 UI target 里，core 不能依赖 UI。
    /// 这里留一份 3 行本地实现，比把 UI 扩展上移到 GatherProtocol（涨公开面）更小。
    private static func encodeJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
