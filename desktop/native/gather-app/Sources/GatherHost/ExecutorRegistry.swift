// desktop/native/gather-app/Sources/GatherHost/ExecutorRegistry.swift
// Cut 1 / B8.3a：JobService 的 8 个 executor 注册表。
//
// 本文件从旧路由的 registerExecutors（原 423-698 行，已删除）逐字搬出
// 以下 8 个执行器，闭包体/注释/checkpoint 语义保持不变：
//   similarity.analyze / duplicate.scan / face.analyze / quality.score /
//   metadata.scan / checksum.backfill / thumbnail.build / export.execute
//
// 依赖全部经 Dependencies 显式传入（禁止引用命令路由类型）；路由宿主
// 在 B8.3b 之前只做委托，避免出现两份实现。executor 的注册顺序、weight 与
// autoResume 均沿用 JobService.registerExecutor 的默认值，与搬移前一致。
import Foundation
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication

/// 8 个 executor 的依赖集合（组合根在 B8.3b 由 AppComposition 提供）。
///
/// 说明：`metadata.scan` 的恢复语义会用 jobService 再入队 checksum.backfill，
/// 但 jobService 已作为 register(jobService:deps:) 的显式参数传入，故不在本
/// struct 中重复持有。
struct ExecutorRegistryDependencies {
    let similarityService: SimilarityService
    let duplicateService: DuplicateService
    let faceKwService: FaceKwService
    let qualityService: QualityService
    let indexerService: IndexerService
    let metadataService: MetadataService
    let photoRepo: PhotoRepo
    let assetRepo: AssetRepo
    let imagePreloadService: ImagePreloadService
    let exportService: ExportService
}

/// JobService 执行器注册表：装配期一次性注册 8 个 type。
///
/// 无状态命名空间：注册只发生在组合根/测试装配阶段，注册后 JobService 持有
/// 不可变 Registration；本类型不保存任何服务实例，避免第二份缓存/状态。
enum ExecutorRegistry {
    typealias Dependencies = ExecutorRegistryDependencies

    /// 注册全部 8 个 executor，返回实际注册的 type（顺序与注册顺序一致）。
    ///
    /// 返回值只用于装配期自检与测试断言，生产调用方可忽略；注册失败不会发生
    /// （JobService.registerExecutor 无失败路径，同 type 重复注册为覆盖）。
    @discardableResult
    static func register(jobService: JobService, deps: Dependencies) -> [AnalysisJobType] {
        let registrations = makeExecutors(jobService: jobService, deps: deps)
        for (type, executor) in registrations {
            jobService.registerExecutor(type: type, executor: executor)
        }
        return registrations.map { $0.0 }
    }

    /// 8 个 executor 的唯一构造点（register 与测试共用，防止两份清单漂移）。
    ///
    /// 每个闭包的执行体与原注册方法完全一致；
    /// 唯一的机械改动是 export.execute 里的 `self.decodeJSON` 改为本类型私有
    /// 静态函数（路由实例方法不能跨类型引用）。
    static func makeExecutors(
        jobService: JobService,
        deps: Dependencies
    ) -> [(AnalysisJobType, JobService.JobExecutor)] {
        let similarityService = deps.similarityService
        let duplicateService = deps.duplicateService
        let faceKwService = deps.faceKwService
        let qualityService = deps.qualityService
        let indexerService = deps.indexerService
        let metadataService = deps.metadataService
        let photoRepo = deps.photoRepo
        let assetRepo = deps.assetRepo
        let imagePreloadService = deps.imagePreloadService
        let exportService = deps.exportService

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
            (.qualityScore, { job, context in
                let photoIds = job.checkpoint["photoIds"]?.arrayElements?.compactMap(\.stringValue)
                return try await qualityService.analyze(
                    sessionId: job.scopeId,
                    photoIds: photoIds,
                    context: context
                )
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
                // 合并而不是整块替换：checkpoint 里的 requestedPaths 是
                // SessionDirectoryMonitor 判定"窄 job 是否覆盖本次目录"的唯一依据；
                // 写 result 时丢掉它会让运行中的窄 job 被误判为全树扫描，
                // watcher 提前 ack + 持久化 eventID → 永久漏扫（P1）。
                var checkpoint = job.checkpoint
                checkpoint["result"] = try JSONValue(from: result)
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
            (.exportExecute, { job, context in
                let options: ExportOptions = try decodeJSON(
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
            }),
        ]
    }

    /// JSONValue → Codable（JSONDecoder 往返；解码失败为契约漂移，抛原始错误）。
    /// 与原路由私有 decodeJSON（原 3100-3102 行）逐字同义。
    private static func decodeJSON<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
