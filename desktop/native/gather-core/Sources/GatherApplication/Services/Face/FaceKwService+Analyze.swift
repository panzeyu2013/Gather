// WP5b：FaceKwService 拆分（纯移动，行为不变）——Analyze。
// 源：HEAD 95f0075 的 Services/FaceKwService.swift；仅调整跨文件访问级。
// P0-1（计划 01-perf-kernels.md §2.1）：analyze 的照片解码改为有界并发（默认
// min(6, activeProcessorCount - 2)），推理仍是单引擎（actor 串行），照片级落库从
// 每张一事务改为每批一事务。
// P1（rev-swift 并发复审）：①批事务失败降级为逐张重试（只计真正失败的照片）；
// ②解码并发不再借用 face_inference_parallel_workers；③取消即抛，不冲刷待提交批
// （默认 provider 在 abort 后每图先抛 → 冲刷是 no-op；注入 provider 会落库，违背取消语义）。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
import GatherProtocol

extension FaceKwService {
    // ─────────────────────────── analyze ───────────────────────────

    /// TS: analyze（fkw.analyze executor 主体）。detectorPath/encoderPath 为
    /// 模型路径；eps/minPts 缺省走设置（default_eps / default_min_samples）。
    public func analyze(
        sessionId: String,
        detectorPath: String,
        encoderPath: String,
        eps: Double? = nil,
        minPts: Double? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> FaceAnalysisResult {
        let epsValue = eps ?? settings.double(.defaultEps)
        let minPtsValue = minPts ?? settings.double(.defaultMinSamples)
        try validateFaceClusteringParameters(eps: epsValue, minPts: minPtsValue)
        let clusterOptions = Self.clusterOptions(from: settings)
        let signal = JobAbortSignal()
        try claimController(signal, for: sessionId)

        var detectionFailures = 0
        var encodingFailures = 0
        /// 检测到脸但一张都没编码成功的照片数（保留旧观测/旧状态，见写入分支）。
        var encodingFailedPhotos = 0
        var totalFaces = 0
        /// A 阶段是否已提交过任何观测/状态变更（含缺失照片清理）。用于失败/取消时
        /// 判断是否必须清 cluster_signature（A 与 C 之间的"观测新、簇旧"窗口）。
        var observationsChanged = false
        var runId: Int64 = 0
        var runStatus = "failed"

        // TS finally：成功/失败/取消路径都必须落 run 终态并释放占用。
        defer {
            if runId != 0 {
                try? finalizeAnalysisRun(runId: runId, status: runStatus)
            }
            removeControllerIfCurrent(signal, for: sessionId)
        }

        do {
            guard try sessionRepo.get(id: sessionId) != nil else {
                throw FaceKwServiceError.sessionNotFound
            }
            // sessions.analysis_status 不再由本服务写入：分析状态真相源是
            // analysis_jobs（派生读），run 终态在 analysis_runs。
            onProgress?(0, 0, "face.init")

            // TS 的 onnx_threads 用于 worker 线程预算分摊；Vision 无 ONNX
            // 线程池，该设置在此保留读取语义（见 FaceKwService.swift 文件头差异说明）但不消费。
            let encoderInputSize = settings.int(.encoderInputSize)
            let embeddingDim = settings.int(.embeddingDim)
            // 照片与 index_seq 快照共享一个读事务（design §8）。
            let snapshot: (photos: [PhotoProjectionRow], indexSeq: Int) = try transactions.transaction {
                // P2：已移出工作区的照片不参与人脸聚类（与列表/导出/写回同口径）。
                (PhotoAssets.collapse(
                    try photoRepo.getBySessionProjection(sessionId: sessionId)
                        .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }),
                 try sessionRepo.getIndexSeq(id: sessionId))
            }
            if snapshot.photos.isEmpty { throw FaceKwServiceError.noPhotos }
            if signal.aborted { throw JobCancelledError() }
            runId = try startAnalysisRun(
                sessionId: sessionId,
                kind: "face",
                photoCount: snapshot.photos.count,
                indexSeq: snapshot.indexSeq,
                params: FaceRunParams(
                    detectorPath: detectorPath,
                    encoderPath: encoderPath,
                    eps: epsValue,
                    minPts: Int(minPtsValue)
                )
            )

            let primaryDetectionSize = settings.int(.detectInputSize)
            let secondaryDetectionSize = settings.int(.detectSecondaryInputSize)
            let confidenceThreshold = settings.double(.detectConfidence)
            let previewMaxDimension = max(640, settings.int(.facePreviewMaxDimension))
            // 嵌入模型规格：空路径 = 随应用分发的 SFace；自定义模型必须可加载——
            // 配置错误在这里就失败，而不是把两种向量空间混进同一列（见 EmbeddingModel）。
            // 一次运行只创建**一个**嵌入实例，签名与推理共用（见 FaceInferenceEngine.init）：
            // 否则"签名算完后模型文件被替换"会让本次运行用 A 的签名标注 B 的向量。
            let embedder = try FaceEmbeddingModelFactory.make(
                modelPath: settings.string(.faceEmbeddingModelPath),
                modelVersion: settings.string(.faceEmbeddingModelVersion),
                computeUnits: settings.string(.faceComputeUnits)
            )
            let embeddingSpec = embedder.spec
            let analysisSignature = Self.makeAnalysisSignature(
                detectorPath: detectorPath,
                encoderPath: encoderPath,
                primaryDetectionSize: primaryDetectionSize,
                secondaryDetectionSize: secondaryDetectionSize,
                confidenceThreshold: confidenceThreshold,
                encoderInputSize: encoderInputSize,
                embeddingDim: embeddingDim,
                previewMaxDimension: previewMaxDimension,
                embeddingSpec: embeddingSpec.signature
            )

            var cachedByPhoto: [String: [FaceObservationRow]] = [:]
            for observation in try faceRepo.getObservations(sessionId) {
                var values = cachedByPhoto[observation.photoId] ?? []
                values.append(observation)
                cachedByPhoto[observation.photoId] = values
            }
            var analysisStates = try faceRepo.getAnalysisStates(sessionId)
            let migratingModel = cachedByPhoto.values.joined().contains {
                FaceIdentityPolicy.modelSpace(analysisSignature: $0.analysisSignature) != embeddingSpec.signature
            }
            // A model migration is prepared off-database. Failure/cancellation leaves the old
            // observations, clusters, manual labels and person vectors intact. B consumes
            // the prepared rows as an in-memory overlay; C publishes them in its own
            // short transaction (see commitFullClusters).
            var prepared: [String: PreparedObservations] = [:]

            let totalPhotos = snapshot.photos.count
            // 文件 stat：ENOENT 视为缺失（清观察，防陈旧聚类）；其他失败
            // 留给主循环计检测失败（TS 语义，见 face-kw.service.ts:169-197）。
            var sourceStats: [String: SourceStat] = [:]
            var missingPhotoIds = Set<String>()
            let statResults = await Self.statPhotos(snapshot.photos)
            for (photoId, result) in statResults {
                switch result {
                case .ok(let size, let mtimeMs):
                    sourceStats[photoId] = .ok(size: size, mtimeMs: mtimeMs)
                case .missing:
                    missingPhotoIds.insert(photoId)
                case .failed:
                    break
                }
            }
            if !missingPhotoIds.isEmpty {
                for photoId in missingPhotoIds {
                    analysisStates.removeValue(forKey: photoId)
                    cachedByPhoto.removeValue(forKey: photoId)
                }
                // A 阶段即清理（旧实现在 C 的分析事务里）：B 必须看不到已消失照片的
                // 陈旧观测，否则会把它们重新聚进簇；照片级删除是幂等的。
                try transactions.transaction {
                    for photoId in missingPhotoIds {
                        try faceRepo.deleteObservationsByPhoto(
                            sessionId: sessionId, photoId: photoId)
                        try faceRepo.deleteAnalysisStateByPhoto(
                            sessionId: sessionId, photoId: photoId)
                    }
                }
                observationsChanged = true
                GatherLogger.log(
                    "Face analysis: cleaned up \(missingPhotoIds.count) photo(s) whose files no longer exist",
                    level: .warn
                )
            }

            // 跨会话复用查找：一次批量 IN 查询代替逐照片 SELECT（TS 同款）。
            var reuseTargets: [FaceReuseTarget] = []
            for photo in snapshot.photos {
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else { continue }
                if Self.isCacheValid(
                    analysisStates[photo.id], sourceSize: size, sourceMtimeMs: mtimeMs,
                    analysisSignature: analysisSignature
                ) { continue }
                reuseTargets.append(FaceReuseTarget(
                    photoId: photo.id,
                    assetFileId: photo.assetFileId,
                    sourceFileSize: size,
                    sourceFileMtimeMs: mtimeMs
                ))
            }
            let reuseResults = try faceRepo.reuseObservationsForAssetFile(
                sessionId: sessionId,
                targets: migratingModel ? [] : reuseTargets,
                analysisSignature: analysisSignature
            )
            var reusedAcrossSessions = false
            for target in reuseTargets {
                guard let reused = reuseResults[target.photoId], reused.reused else { continue }
                reusedAcrossSessions = true
                analysisStates[target.photoId] = FaceAnalysisState(
                    sourceFileSize: target.sourceFileSize,
                    sourceFileMtimeMs: target.sourceFileMtimeMs,
                    analysisSignature: analysisSignature
                )
            }
            if reusedAcrossSessions {
                cachedByPhoto.removeAll()
                for observation in try faceRepo.getObservations(sessionId) {
                    var values = cachedByPhoto[observation.photoId] ?? []
                    values.append(observation)
                    cachedByPhoto[observation.photoId] = values
                }
            }

            let photosNeedingAnalysis = snapshot.photos.filter { photo in
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else { return false }
                return !Self.isCacheValid(
                    analysisStates[photo.id], sourceSize: size, sourceMtimeMs: mtimeMs,
                    analysisSignature: analysisSignature
                )
            }
            let clusterSignature = Self.clusterSignature(
                eps: epsValue, minPts: Int(minPtsValue), options: clusterOptions)
            let signatureMatches = (try? faceRepo.getClusterSignature(sessionId)) == clusterSignature
            let hasClusters = try !faceRepo.getClusters(sessionId).isEmpty
            if missingPhotoIds.isEmpty && photosNeedingAnalysis.isEmpty && signatureMatches && hasClusters {
                onProgress?(totalPhotos, totalPhotos, "face.cached-clusters")
                runStatus = "ok"
                return FaceAnalysisResult(status: "done", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }

            let requestedWorkers = max(1, min(2, settings.int(.faceInferenceParallelWorkers)))
            let inferenceConfig = FaceInferenceConfig(
                confidenceThreshold: confidenceThreshold,
                nmsThreshold: settings.double(.nmsThreshold),
                maxDetections: settings.int(.maxDetections),
                embeddingDim: embeddingDim,
                primaryInputSize: primaryDetectionSize,
                secondaryInputSize: secondaryDetectionSize,
                encodeInputSize: encoderInputSize,
                fallbackToOnnxEnabled: false,
                faceEmbeddingModelPath: settings.string(.faceEmbeddingModelPath),
                faceEmbeddingModelVersion: settings.string(.faceEmbeddingModelVersion)
            )
            // 旧集群与角色绑定刻意保留到新结果就绪（TS 注释 270-272）：失败
            // 的推理不得摧毁用户已绑定的集群与角色名。
            if !photosNeedingAnalysis.isEmpty && inferenceProvider == nil && !Self.visionAvailable {
                throw FaceKwServiceError.workersInitFailed
            }
            let provider: FaceInferenceProvider = try inferenceProvider ?? {
                guard Self.visionAvailable else { throw FaceKwServiceError.workersInitFailed }
                return Self.makeDefaultProvider(config: inferenceConfig, embedder: embedder)
            }()
            let decode: DecodeProvider = decodeProvider ?? { path, maxDimension in
                await Self.defaultDecode(path: path, maxDimension: maxDimension)
            }

            onProgress?(0, totalPhotos, "face.detect")

            // 攒批窗口 = 每批照片数（= provider 批大小 = DB 事务粒度）。P0-1 不改它的
            // 语义：provider 的调用序与批组成依赖它（例如 FaceIdentityArchitectureTests
            // 把 face_decode_concurrency 设成 "2" 来钉住批内下标）。
            let batchWindow = max(1, min(8, settings.int(.faceDecodeConcurrency)))
            // 解码并发度见 resolveDecodeConcurrency（纯性能旋钮，自动值按机器推导，
            // 不另建设置键以免动 SettingsKey/preferenceKeys/oracle 三处）。
            // 注入 decodeProvider 时只能串行解码：DecodeProvider 是普通（非 @Sendable）
            // 闭包，Swift 6 下把它跨隔离域传进子任务是硬错误；默认 ImageIO 路径走
            // 静态方法、子任务只捕获 Sendable 值，因此可以安全并发。
            let parallelWorkers = settings.int(.faceInferenceParallelWorkers)
            let decodeConcurrency = Self.resolveDecodeConcurrency(
                parallelWorkers: parallelWorkers,
                processorCount: ProcessInfo.processInfo.activeProcessorCount)
            let hasInjectedDecode = decodeProvider != nil
            let photoPaths = snapshot.photos.map(\.filepath)

            // TS: applyInferenceResult（替换旧观察只在推理成功之后；失败批次
            // 不得摧毁该照片先前有效的检测）。P0-1：逐张调用点不再落库——照片级写入
            // 先攒进 `writes`，由 flushBatch 在**一个**批事务里按索引序提交（旧实现
            // 每张照片一次 transactions.transaction，1 万张 = 1 万次提交）。
            func applyInferenceResult(
                index: Int,
                item: FaceInferenceItem,
                writes: inout [FaceObservationWrite]
            ) {
                let photo = snapshot.photos[index]
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else { return }
                if let error = item.error {
                    detectionFailures += 1
                    GatherLogger.log("Face detection failed for \(photo.filepath) \(error)", level: .warn)
                    return
                }
                let observations = item.observations.map { face in
                    FaceObservationInput(
                        photoId: photo.id,
                        bboxX: face.bbox.count > 0 ? face.bbox[0] : 0,
                        bboxY: face.bbox.count > 1 ? face.bbox[1] : 0,
                        bboxW: face.bbox.count > 2 ? face.bbox[2] : 0,
                        bboxH: face.bbox.count > 3 ? face.bbox[3] : 0,
                        embedding: face.embedding.map { Float($0) },
                        confidence: face.confidence,
                        sourceFileSize: size,
                        sourceFileMtimeMs: mtimeMs,
                        analysisSignature: analysisSignature,
                        quality: face.quality,
                        faceSizePx: face.faceSizePx,
                        rollDegrees: face.rollDegrees,
                        modelId: face.modelId,
                        modelVersion: face.modelVersion,
                        embeddingDim: face.embedding.count
                    )
                }
                // "检测到脸但一张都没编码成功"的照片：**保留**旧观测与旧分析状态，
                // 既不 replaceObservationsByPhoto 也不 upsertAnalysisState。
                // 为什么：把这种情况当成"这张照片没有脸"会删掉旧观测、写下 analysis_state
                // 使其永不再重试，随后重聚类还会连带清掉旧簇与人工绑定——即"模型配错一次
                // 就静默摧毁用户工作"（对抗审查阻断项 2）。保留旧状态后，下次运行仍会
                // 重试这张照片，而本次 run 会带上 encodingFailures 让失败可见。
                let detectedFaces = item.observations.count + item.encodingFailures
                let photoEncodingsAllFailed = item.observations.isEmpty && item.encodingFailures > 0
                encodingFailures += item.encodingFailures
                if detectedFaces > 0 {
                    totalFaces += detectedFaces
                }
                // 只要有**任何**脸编码失败：这张照片就不算"分析完"，不写 analysis_state
                // （下次运行重试）。部分失败时仍然落库成功的脸（部分结果可见），全失败时
                // 连观测都不替换（保留旧数据）。
                // 反面教材（对抗验证 V1 实测）：1 成功 + 1 失败也写 state、且失败的脸被静默
                // 丢弃，第二次运行直接跳过这张照片 ⇒ 那些脸永不重试。
                let hasEncodingFailures = item.encodingFailures > 0
                if !photoEncodingsAllFailed {
                    if migratingModel {
                        // 模型迁移：旧观测必须保留到全部照片成功之后（见 C 阶段），
                        // A 只把结果放入内存覆盖层。
                        prepared[photo.id] = PreparedObservations(
                            observations: observations,
                            sourceFileSize: size,
                            sourceFileMtimeMs: mtimeMs,
                            analysisSignature: analysisSignature,
                            complete: !hasEncodingFailures)
                    } else {
                        // A 的照片级写入意图：观测替换 + 分析状态同一批提交
                        // （checkpoint = face_analysis_state；取消/崩溃后由 isCacheValid 跳过）。
                        writes.append(FaceObservationWrite(
                            photoId: photo.id,
                            sourceFileSize: size,
                            sourceFileMtimeMs: mtimeMs,
                            observations: observations,
                            writesAnalysisState: !hasEncodingFailures))
                    }
                }
                if hasEncodingFailures {
                    encodingFailedPhotos += 1
                    GatherLogger.log(
                        "Face encoding failed for \(item.encodingFailures)/\(detectedFaces) face(s) in "
                            + "\(photo.filepath); keeping previous analysis state so it is retried "
                            + "(observations replaced: \(!photoEncodingsAllFailed))",
                        level: .warn
                    )
                }
            }

            // 每 worker 一个攒批队列；照片按 index % N 轮询分配。批满即派发，
            // 派发后等待结果（TS 的在飞批上限/背压为 worker 消息队列优化，
            // 见 FaceKwService.swift 文件头差异说明）。P0-1 不改批组成与派发序：
            // 变的只是"解码何时发生"（片内并发预取）与"落库粒度"（一批一事务）。
            var batchImages: [[Data]] = Array(repeating: [], count: requestedWorkers)
            var batchIndices: [[Int]] = Array(repeating: [], count: requestedWorkers)

            // P0-1：一批一个事务，照片级语句按索引序串行执行（单写者不变）。
            // P1：批事务失败**不再整批连坐**。旧实现 catch 里
            // `detectionFailures += writes.count` 后整批回滚：一批里 1 张写失败会让
            // ≤batchWindow-1 张好照片一起不落库（也不写 analysis_state）→ 每轮重解码
            // 重推理、永不收敛，且 allDetectionsFailed 被这批虚增的失败污染成"整轮失败"。
            // 现在批失败只降级为逐张重试（见下），只把真正失败的那几张计入。
            func commitObservations(_ writes: [FaceObservationWrite]) throws {
                try transactions.transaction {
                    for write in writes {
                        _ = try faceRepo.replaceObservationsByPhoto(
                            sessionId: sessionId, photoId: write.photoId,
                            observations: write.observations)
                        if write.writesAnalysisState {
                            try faceRepo.upsertAnalysisState(
                                sessionId: sessionId,
                                photoId: write.photoId,
                                sourceFileSize: write.sourceFileSize,
                                sourceFileMtimeMs: write.sourceFileMtimeMs,
                                analysisSignature: analysisSignature)
                        }
                    }
                }
            }

            /// 批事务失败后的降级路径：逐张单独事务重试，返回仍未写入成功的张数。
            /// 为什么逐张：一张写失败只应影响那张照片（旧观测/旧 analysis_state 原样
            /// 保留，下次运行由 isCacheValid 判否后重试），其余照片必须照常落库。
            func commitObservationsAfterBatchFailure(_ writes: [FaceObservationWrite]) -> Int {
                var failed = 0
                for write in writes {
                    do {
                        try commitObservations([write])
                        observationsChanged = true
                    } catch {
                        failed += 1
                        GatherLogger.log(
                            "Face observation write failed for photo \(write.photoId) "
                                + "in degraded per-photo retry: \(error)",
                            level: .warn)
                    }
                }
                return failed
            }

            func flushBatch(_ w: Int) async throws {
                guard !batchIndices[w].isEmpty else { return }
                let images = batchImages[w]
                let indices = batchIndices[w]
                batchImages[w] = []
                batchIndices[w] = []
                let results = try await provider(images, inferenceConfig, signal)
                guard results.count == indices.count else {
                    throw FaceKwServiceError.workersInitFailed
                }
                var writes: [FaceObservationWrite] = []
                writes.reserveCapacity(indices.count)
                for b in 0..<indices.count {
                    applyInferenceResult(index: indices[b], item: results[b], writes: &writes)
                }
                guard !writes.isEmpty else { return }
                do {
                    try commitObservations(writes)
                    observationsChanged = true
                } catch {
                    // 两条日志刻意分开：「批失败」是事务级事件，「单张失败」是降级路径里的
                    // 逐照片事件；运维据此区分"这一批回滚了"与"这张照片写不进去"。
                    let failed = commitObservationsAfterBatchFailure(writes)
                    detectionFailures += failed
                    GatherLogger.log(
                        "Face observation batch write failed for \(writes.count) photo(s) "
                            + "(worker \(w)): \(error); degraded to per-photo retry: "
                            + "\(writes.count - failed) committed, \(failed) failed",
                        level: .warn)
                }
            }

            // P0-1：先做纯判定计划（只读内存快照 sourceStats / analysisStates：无 I/O、
            // 无副作用、无计数），再按片执行。为什么需要它：并发解码必须提前知道哪些
            // 索引真的要解码，而"要不要解码"的判定本身是纯的；所有副作用（进度、失败
            // 计数、日志、落库）仍严格按索引序在主任务里发生 —— 与串行版逐条相等。
            var plan: [FacePlannedStep] = []
            plan.reserveCapacity(totalPhotos)
            for index in 0..<totalPhotos {
                let photo = snapshot.photos[index]
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else {
                    plan.append(missingPhotoIds.contains(photo.id) ? .missing(index) : .unreadable(index))
                    continue
                }
                if Self.isCacheValid(
                    analysisStates[photo.id], sourceSize: size, sourceMtimeMs: mtimeMs,
                    analysisSignature: analysisSignature
                ) {
                    plan.append(.cached(index))
                } else {
                    plan.append(.analyze(index))
                }
            }

            // 片宽 = 解码并发度：片内需要解码的索引 ≤ 片宽，故子任务数即并发上限。
            var stepCursor = 0
            while stepCursor < plan.count {
                if signal.aborted {
                    // 取消即抛：`batchImages` 里已解码但未提交的照片直接丢弃（下次运行重解码）
                    // 是取消语义的一部分。不冲刷：冲刷要调 provider——默认 provider 在 abort
                    // 后每图先抛、`try?` 吞掉后什么也没提交；注入 provider 则会推理并落库，
                    // 违背"取消不落库"。
                    throw JobCancelledError()
                }
                let sliceEnd = min(stepCursor + decodeConcurrency, plan.count)
                let slice = plan[stepCursor..<sliceEnd]
                stepCursor = sliceEnd
                var sliceIndices: [Int] = []
                sliceIndices.reserveCapacity(slice.count)
                for step in slice {
                    if case .analyze(let index) = step { sliceIndices.append(index) }
                }
                let decoded: [Int: Data]
                if hasInjectedDecode || sliceIndices.isEmpty {
                    decoded = [:]
                } else {
                    decoded = await Self.decodeConcurrently(
                        indices: sliceIndices,
                        paths: photoPaths,
                        maxDimension: previewMaxDimension,
                        concurrency: decodeConcurrency,
                        signal: signal,
                        using: { path, maxDimension in
                            await Self.defaultDecode(path: path, maxDimension: maxDimension)
                        })
                }
                for step in slice {
                    if signal.aborted { throw JobCancelledError() }
                    switch step {
                    case .missing(let index):
                        // ENOENT 照片的观察已提前清理；不计算为检测失败。
                        onProgress?(index + 1, totalPhotos, "face.detect")
                    case .unreadable(let index):
                        detectionFailures += 1
                        GatherLogger.log(
                            "Face detection failed for \(snapshot.photos[index].filepath) photo is not readable",
                            level: .warn)
                        onProgress?(index + 1, totalPhotos, "face.detect")
                    case .cached(let index):
                        totalFaces += cachedByPhoto[snapshot.photos[index].id]?.count ?? 0
                        onProgress?(index + 1, totalPhotos, "face.cached-faces")
                    case .analyze(let index):
                        let photo = snapshot.photos[index]
                        // 注入 provider：在主任务里串行解码（注入闭包不可跨隔离域）；
                        // 默认路径：取本片并发解码的结果（缺键 = 解码失败）。
                        let preview: Data?
                        if hasInjectedDecode {
                            preview = await decode(photo.filepath, previewMaxDimension)
                        } else {
                            preview = decoded[index]
                        }
                        guard let preview else {
                            detectionFailures += 1
                            GatherLogger.log("Face detection failed for \(photo.filepath)", level: .warn)
                            onProgress?(index + 1, totalPhotos, "face.detect")
                            continue
                        }
                        let w = index % requestedWorkers
                        batchImages[w].append(preview)
                        batchIndices[w].append(index)
                        onProgress?(index + 1, totalPhotos, "face.detect")
                        if batchIndices[w].count >= batchWindow {
                            try await flushBatch(w)
                        }
                    }
                }
            }
            for w in 0..<requestedWorkers {
                try await flushBatch(w)
            }
            if signal.aborted { throw JobCancelledError() }
            if encodingFailedPhotos > 0 {
                GatherLogger.log(
                    "Face analysis kept previous observations/state for \(encodingFailedPhotos) "
                        + "photo(s) whose faces all failed to encode (will retry next run)",
                    level: .warn
                )
            }

            // 重聚类前先判定失败：全失败 run 不得清掉先前绑定的集群与角色名。
            let allDetectionsFailed = detectionFailures == totalPhotos && totalPhotos > 0
            let allEncodingsFailed = encodingFailures == totalFaces && totalFaces > 0
            let analysisFailed = allDetectionsFailed || allEncodingsFailed

            onProgress?(0, 0, "face.cluster")
            // 增量资格在 run 开始时的状态上判定（signatureMatches / hasClusters 取
            // 分析前的快照）：设置开启（face_incremental_clustering，默认 "1"）+ 聚类
            // 签名未变 + 库里已有簇 + 本次分析没有整体失败。recluster 命令恒走全量。
            let incrementalEligible = Self.incrementalClusteringEnabled(settings)
                && signatureMatches && hasClusters && !analysisFailed
            if migratingModel && (detectionFailures > 0 || encodingFailures > 0) {
                return FaceAnalysisResult(status: "failed", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }
            if signal.aborted { throw JobCancelledError() }
            // C 之前只采集一次人工反馈（B 的 feedback 快照因此包含刚采集的确认记录；
            // C 内不再重读/重写 feedback——审计 §4.4）。
            try captureManualIdentityFeedback(sessionId: sessionId)
            try clusterStoredObservations(
                sessionId: sessionId, photos: snapshot.photos,
                indexSeq: snapshot.indexSeq, eps: epsValue,
                minPts: Int(minPtsValue), options: clusterOptions,
                signature: clusterSignature, signal: signal,
                clearOnEmpty: !analysisFailed,
                incremental: incrementalEligible && !migratingModel,
                prepared: prepared,
                onProgress: { current, total in onProgress?(current, total, "face.cluster") })

            if analysisFailed {
                return FaceAnalysisResult(status: "failed", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }
            onProgress?(0, 0, "face.done")
            runStatus = "ok"
            return FaceAnalysisResult(status: "done", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
        } catch {
            // A 已提交观测（或本 run 被取消）而 C 未完成：签名必须失效，否则下一次
            // analyze 的快路径会拿旧簇当"最新结果"永远跳过重聚类。
            if observationsChanged || error is JobCancelledError {
                try? faceRepo.clearClusterSignature(sessionId: sessionId)
            }
            if error is JobCancelledError {
                return FaceAnalysisResult(status: "cancelled", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }
            throw error
        }
    }

    /// TS: recluster（fkw.recluster；仅重聚类，不重推理）。
    public func recluster(sessionId: String, eps: Double, minPts: Double) async throws {
        try validateFaceClusteringParameters(eps: eps, minPts: minPts)
        guard try sessionRepo.get(id: sessionId) != nil else {
            throw FaceKwServiceError.sessionNotFound
        }
        if try faceRepo.getObservations(sessionId).isEmpty {
            throw FaceKwServiceError.noObservations
        }
        let signal = JobAbortSignal()
        try claimController(signal, for: sessionId)
        defer { removeControllerIfCurrent(signal, for: sessionId) }
        // 照片 + index_seq 一个读事务（旧实现只读照片；C 的守卫需要 run 起点的序号）。
        let snapshot: (photos: [PhotoProjectionRow], indexSeq: Int) = try transactions.transaction {
            // P2：重聚类同样只看工作区可见照片。
            (PhotoAssets.collapse(
                try photoRepo.getBySessionProjection(sessionId: sessionId)
                    .filter { PhotoVisibility.isVisible(archivedAt: $0.archivedAt) }),
             try sessionRepo.getIndexSeq(id: sessionId))
        }
        let clusterOptions = Self.clusterOptions(from: settings)
        if signal.aborted { throw JobCancelledError() }
        // C 之前只采集一次人工反馈（同 analyze）。
        try captureManualIdentityFeedback(sessionId: sessionId)
        try clusterStoredObservations(
            sessionId: sessionId, photos: snapshot.photos, indexSeq: snapshot.indexSeq,
            eps: eps, minPts: Int(minPts), options: clusterOptions,
            signature: Self.clusterSignature(eps: eps, minPts: Int(minPts), options: clusterOptions),
            signal: signal, clearOnEmpty: true, onProgress: nil)
    }

    /// TS: cancel（fkw.cancel_analysis 的服务层步骤）。
    public func cancel(sessionId: String) {
        controller(for: sessionId)?.abort()
    }

    /// TS: startAnalysisRun。
    private func startAnalysisRun(
        sessionId: String,
        kind: String,
        photoCount: Int,
        indexSeq: Int,
        params: FaceRunParams
    ) throws -> Int64 {
        let data = try JSONEncoder().encode(params)
        // 载荷编码留在应用层（params_json 键序是契约）；落库交 AnalysisRunRepo。
        return try analysisRuns.start(
            sessionId: sessionId,
            kind: kind,
            photoCount: photoCount,
            indexSeq: indexSeq,
            paramsJson: String(data: data, encoding: .utf8) ?? "{}"
        )
    }

    // 取消的 run 在此以 'failed' 终态：run 记录按设计只区分 ok/failed，取消态由
    // analysis_jobs（JobService 的 status 机）表达（TS 注释 603-606；过期检测
    // 1.4.2 一律忽略非 ok run；sessions.analysis_status 已不再写入）。
    private func finalizeAnalysisRun(runId: Int64, status: String) throws {
        try analysisRuns.finish(runId: runId, status: status)
    }

    /// TS: analysisSignature 构造（face-kw.service.ts:139-158）。键序与 TS
    /// JSON.stringify 的插入序逐字一致；preprocessingVersion 恒为 2。

    static func makeAnalysisSignature(
        detectorPath: String,
        encoderPath: String,
        primaryDetectionSize: Int,
        secondaryDetectionSize: Int,
        confidenceThreshold: Double,
        encoderInputSize: Int,
        embeddingDim: Int,
        previewMaxDimension: Int,
        embeddingSpec: String
    ) -> String {
        let fields = [
            jsonField("detector", Self.modelFingerprint(detectorPath)),
            jsonField("encoder", Self.modelFingerprint(encoderPath)),
            // 对齐方式/特征模型的指纹：换 embedding 规格必须让旧 observation 过期
            //（否则 768 维旧向量会与新对齐向量混在同一簇里）。
            jsonField("embeddingSpec", embeddingSpec),
            "\(jsonKey("primaryDetectionSize")):\(primaryDetectionSize)",
            "\(jsonKey("secondaryDetectionSize")):\(secondaryDetectionSize)",
            "\(jsonKey("confidenceThreshold")):\(confidenceThreshold)",
            "\(jsonKey("encoderInputSize")):\(encoderInputSize)",
            "\(jsonKey("embeddingDim")):\(embeddingDim)",
            "\(jsonKey("previewMaxDimension")):\(previewMaxDimension)",
            "\(jsonKey("preprocessingVersion")):2",
        ]
        return "{\(fields.joined(separator: ","))}"
    }

    /// TS: modelFingerprint —— resolveModelPath 后 stat；失败回落为路径本身。
    static func modelFingerprint(_ modelPath: String) -> String {
        guard let stat = tsStat(modelPath) else { return modelPath }
        return "\(modelPath):\(stat.size):\(Int64(stat.mtimeMs.rounded()))"
    }

    private static func jsonKey(_ key: String) -> String { "\"\(key)\"" }

    private static func jsonField(_ key: String, _ value: String) -> String {
        "\"\(key)\":\"\(jsonEscape(value))\""
    }

    /// TS: JSON.stringify 的最小等价转义（签名只含路径/整数，控制字符按
    /// \uXXXX 转义；JSON.parse 侧无感知差异）。
    private static func jsonEscape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// TS: isCacheValid（观察/状态与文件状态、签名一致）。
    private static func isCacheValid(
        _ state: FaceAnalysisState?,
        sourceSize: Int64,
        sourceMtimeMs: Double,
        analysisSignature: String
    ) -> Bool {
        guard let state else { return false }
        return state.sourceFileSize == sourceSize &&
            abs(state.sourceFileMtimeMs - sourceMtimeMs) < 1 &&
            state.analysisSignature == analysisSignature
    }

    /// 文件 stat 三态：ok / missing（ENOENT）/ failed（其他错误，算检测失败）。
    enum SourceStat {
        case ok(size: Int64, mtimeMs: Double)
        case missing
        case failed
    }

    /// TS: batchAsync(fs.promises.stat, 32) —— ENOENT 与其他 stat 失败区分。
    private static func statPhotos(_ photos: [PhotoProjectionRow]) async -> [String: SourceStat] {
        var result: [String: SourceStat] = [:]
        for chunkStart in stride(from: 0, to: photos.count, by: 32) {
            let chunk = Array(photos[chunkStart..<min(chunkStart + 32, photos.count)])
            await withTaskGroup(of: (String, SourceStat).self) { group in
                for photo in chunk {
                    group.addTask {
                        (photo.id, sourceStat(photo.filepath))
                    }
                }
                for await pair in group {
                    result[pair.0] = pair.1
                }
            }
        }
        return result
    }

    static func sourceStat(_ path: String) -> SourceStat {
        var s = stat()
        guard stat(path, &s) == 0 else {
            return errno == ENOENT ? .missing : .failed
        }
        #if canImport(Glibc)
        let mtimeMs = Double(s.st_mtim.tv_sec) * 1000 + Double(s.st_mtim.tv_nsec) / 1_000_000
        #else
        let mtimeMs = Double(s.st_mtimespec.tv_sec) * 1000 + Double(s.st_mtimespec.tv_nsec) / 1_000_000
        #endif
        return .ok(size: Int64(s.st_size), mtimeMs: mtimeMs)
    }

    /// 解码并发度（计划 01 §2.1）：自动值 max(1, min(6, 核数 - 2)) 保底，只有**显式更大**
    /// 的 face_inference_parallel_workers 才覆盖（钳 1…16）；0 / 负数与"自动"同义。该键
    /// 本是推理 worker 预算，旧实现当解码并发后"设 2"反而从自动 6 降到 2——拆纯函数钉方向。
    static func resolveDecodeConcurrency(parallelWorkers: Int, processorCount: Int) -> Int {
        let auto = max(1, min(6, processorCount - 2))
        return max(auto, min(16, parallelWorkers))
    }

    /// 有界并发解码一批照片索引（P0-1：把解码从串行主循环里拿出来）。
    /// 只服务默认解码路径：`DecodeProvider` 是普通（非 `@Sendable`）闭包，跨隔离域传进
    /// 子任务是 Swift 6 硬错误，所以注入时留在主任务串行；默认路径调静态 `defaultDecode`，
    /// 子任务只捕获 Sendable 值（索引 / 路径 / 尺寸 / 取消信号）。在飞上限由本函数排队
    /// 保证（analyze 传片宽）；`using` 是 seam：单测注入计数解码器钉住上限 / 索引归位 /
    /// abort 后不再解码。
    /// 线程安全依据同 SimilarityService+Analyze.swift:116-120：RAWDecoder 走 ImageIO
    /// （线程安全），这里不共享任何可变状态；JobAbortSignal 的可变状态在 NSLock 内。
    /// 返回 索引 → JPEG buffer；**缺键 = 解码失败**（不抛错，逐张失败语义不变）。
    static func decodeConcurrently(
        indices: [Int],
        paths: [String],
        maxDimension: Int,
        concurrency: Int,
        signal: JobAbortSignal,
        using decode: @escaping @Sendable (String, Int) async -> Data?
    ) async -> [Int: Data] {
        let cap = max(1, concurrency)
        return await withTaskGroup(of: (Int, Data?).self, returning: [Int: Data].self) { group in
            var pending = indices.makeIterator()
            var decoded: [Int: Data] = [:]
            var inFlight = 0
            while true {
                while inFlight < cap, let index = pending.next() {
                    group.addTask {
                        // 取消点与串行版同粒度：每张图解码前查一次 abort。
                        guard !signal.aborted else { return (index, nil) }
                        return (index, await decode(paths[index], maxDimension))
                    }
                    inFlight += 1
                }
                guard inFlight > 0, let (index, buffer) = await group.next() else { break }
                inFlight -= 1
                if let buffer { decoded[index] = buffer }
            }
            return decoded
        }
    }

    #if canImport(Vision)
    /// 默认推理 provider：单引擎逐图处理，单图失败不拖垮整批；取消点在图边界。
    private static func makeDefaultProvider(
        config: FaceInferenceConfig,
        embedder: FaceEmbeddingProvider
    ) -> FaceInferenceProvider {
        let engine = FaceInferenceEngine(config: config, embedder: embedder)
        return { images, _, signal in
            var results: [FaceInferenceItem] = []
            results.reserveCapacity(images.count)
            for image in images {
                if signal?.aborted ?? false { throw JobCancelledError() }
                let items = try await engine.analyzeBatch(images: [image])
                results.append(Self.convert(items[0]))
            }
            return results
        }
    }

    private static func convert(_ item: FaceInferenceBatchItem) -> FaceInferenceItem {
        FaceInferenceItem(
            error: item.error,
            observations: item.observations.map {
                FaceInferenceObservation(
                    bbox: $0.bbox,
                    confidence: $0.confidence,
                    embedding: $0.embedding,
                    quality: $0.quality,
                    faceSizePx: $0.faceSizePx,
                    rollDegrees: $0.rollDegrees,
                    modelId: $0.modelId,
                    modelVersion: $0.modelVersion
                )
            },
            encodingFailures: item.encodingFailures
        )
    }
    #endif

    static var visionAvailable: Bool {
        #if canImport(Vision)
        true
        #else
        false
        #endif
    }

    #if canImport(ImageIO)
    /// 默认解码：TS imageService.getPreview(filepath, maxDimension, 0, false)。
    private static func defaultDecode(path: String, maxDimension: Int) async -> Data? {
        try? RAWDecoder.getPreview(path: path, maxDimension: maxDimension).buffer
    }
    #else
    private static func defaultDecode(path: String, maxDimension: Int) async -> Data? { nil }
    #endif
}

// MARK: - 私有载荷类型

/// TS: analysis_runs.params（face run）。
private struct FaceRunParams: Codable {
    let detectorPath: String
    let encoderPath: String
    let eps: Double
    let minPts: Int
}

/// P0-1：一条照片级人脸观察写入（批内按索引序提交，一批一事务）。
private struct FaceObservationWrite {
    let photoId: String
    let sourceFileSize: Int64
    let sourceFileMtimeMs: Double
    let observations: [FaceObservationInput]
    /// false = 该照片有脸编码失败：不写 analysis_state（下次运行重试）。
    let writesAnalysisState: Bool
}

/// P0-1：analyze 的逐照片执行计划元素（纯判定结果，无副作用）。
private enum FacePlannedStep {
    /// 文件已消失（ENOENT）：观察已提前清理，不计检测失败。
    case missing(Int)
    /// stat 失败：计 1 次检测失败。
    case unreadable(Int)
    /// isCacheValid 命中：沿用旧观测。
    case cached(Int)
    /// 需要解码 + 推理。
    case analyze(Int)
}
