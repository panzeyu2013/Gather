// WP5b：FaceKwService 拆分（纯移动，行为不变）——Analyze。
// 源：HEAD 95f0075 的 Services/FaceKwService.swift；仅调整跨文件访问级。

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
        let epsValue = eps ?? getNumber("default_eps", 0.65)
        let minPtsValue = minPts ?? getNumber("default_min_samples", 2)
        try validateFaceClusteringParameters(eps: epsValue, minPts: minPtsValue)
        let clusterOptions = Self.clusterOptions(from: getNumber)
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
            let encoderInputSize = getNumber("encoder_input_size", 112).safeInt(fallback: 112)
            let embeddingDim = getNumber("embedding_dim", 512).safeInt(fallback: 512)
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

            let primaryDetectionSize = getNumber("detect_input_size", 640).safeInt(fallback: 640)
            let secondaryDetectionSize = getNumber("detect_secondary_input_size", 128).safeInt(fallback: 128)
            let confidenceThreshold = getNumber("detect_confidence", 0.5)
            let previewMaxDimension = max(640, getNumber("face_preview_max_dimension", 2048).safeInt(fallback: 2048))
            // 嵌入模型规格：空路径 = 随应用分发的 SFace；自定义模型必须可加载——
            // 配置错误在这里就失败，而不是把两种向量空间混进同一列（见 EmbeddingModel）。
            // 一次运行只创建**一个**嵌入实例，签名与推理共用（见 FaceInferenceEngine.init）：
            // 否则"签名算完后模型文件被替换"会让本次运行用 A 的签名标注 B 的向量。
            let embedder = try FaceEmbeddingModelFactory.make(
                modelPath: getString(FaceEmbeddingModelFactory.modelPathSetting, ""),
                modelVersion: getString(FaceEmbeddingModelFactory.modelVersionSetting, ""),
                computeUnits: getString("face_compute_units", "auto")
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

            let requestedWorkers = max(1, min(2, getNumber("face_inference_parallel_workers", 1).safeInt(fallback: 1)))
            let inferenceConfig = FaceInferenceConfig(
                confidenceThreshold: confidenceThreshold,
                nmsThreshold: getNumber("nms_threshold", 0.4),
                maxDetections: getNumber("max_detections", 100).safeInt(fallback: 100),
                embeddingDim: embeddingDim,
                primaryInputSize: primaryDetectionSize,
                secondaryInputSize: secondaryDetectionSize,
                encodeInputSize: encoderInputSize,
                fallbackToOnnxEnabled: false,
                faceEmbeddingModelPath: getString(FaceEmbeddingModelFactory.modelPathSetting, ""),
                faceEmbeddingModelVersion: getString(FaceEmbeddingModelFactory.modelVersionSetting, "")
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

            let decodeWindow = max(1, min(8, getNumber("face_decode_concurrency", 4).safeInt(fallback: 4)))

            // TS: applyInferenceResult（替换旧观察只在推理成功之后；失败批次
            // 不得摧毁该照片先前有效的检测）。
            func applyInferenceResult(index: Int, item: FaceInferenceItem) {
                let photo = snapshot.photos[index]
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else { return }
                if item.error != nil {
                    detectionFailures += 1
                    GatherLogger.log("Face detection failed for \(photo.filepath) \(item.error!)", level: .warn)
                    return
                }
                do {
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
                            // A 的短事务：观测替换 + 分析状态同一提交（checkpoint =
                            // face_analysis_state）。取消发生在照片边界，已提交的照片下次
                            // 由 isCacheValid 跳过。
                            _ = try transactions.transaction {
                                let ids = try faceRepo.replaceObservationsByPhoto(
                                    sessionId: sessionId, photoId: photo.id,
                                    observations: observations)
                                if !hasEncodingFailures {
                                    try faceRepo.upsertAnalysisState(
                                        sessionId: sessionId,
                                        photoId: photo.id,
                                        sourceFileSize: size,
                                        sourceFileMtimeMs: mtimeMs,
                                        analysisSignature: analysisSignature
                                    )
                                }
                                return ids
                            }
                            observationsChanged = true
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
                } catch {
                    detectionFailures += 1
                    GatherLogger.log("Face detection failed for \(photo.filepath) \(error)", level: .warn)
                }
            }

            // 每 worker 一个攒批队列；照片按 i % N 轮询分配。批满即派发，
            // 派发后等待结果（TS 的在飞批上限/背压为 worker 消息队列优化，
            // 见 FaceKwService.swift 文件头差异说明）。
            var batchImages: [[Data]] = Array(repeating: [], count: requestedWorkers)
            var batchIndices: [[Int]] = Array(repeating: [], count: requestedWorkers)
            var inferredPhotoCount = 0

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
                for b in 0..<indices.count {
                    applyInferenceResult(index: indices[b], item: results[b])
                }
            }

            for i in 0..<totalPhotos {
                if signal.aborted { throw JobCancelledError() }
                let photo = snapshot.photos[i]
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else {
                    if missingPhotoIds.contains(photo.id) {
                        // ENOENT 照片的观察已提前清理；不计算为检测失败。
                        onProgress?(i + 1, totalPhotos, "face.detect")
                        continue
                    }
                    detectionFailures += 1
                    GatherLogger.log("Face detection failed for \(photo.filepath) photo is not readable", level: .warn)
                    onProgress?(i + 1, totalPhotos, "face.detect")
                    continue
                }
                if Self.isCacheValid(
                    analysisStates[photo.id], sourceSize: size, sourceMtimeMs: mtimeMs,
                    analysisSignature: analysisSignature
                ) {
                    totalFaces += cachedByPhoto[photo.id]?.count ?? 0
                    onProgress?(i + 1, totalPhotos, "face.cached-faces")
                    continue
                }
                guard let preview = await decode(photo.filepath, previewMaxDimension) else {
                    detectionFailures += 1
                    GatherLogger.log("Face detection failed for \(photo.filepath)", level: .warn)
                    onProgress?(i + 1, totalPhotos, "face.detect")
                    continue
                }
                let w = i % requestedWorkers
                batchImages[w].append(preview)
                batchIndices[w].append(i)
                inferredPhotoCount += 1
                onProgress?(i + 1, totalPhotos, "face.detect")
                if batchIndices[w].count >= decodeWindow {
                    try await flushBatch(w)
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
            let incrementalEligible = Self.incrementalClusteringEnabled(getString)
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
        let clusterOptions = Self.clusterOptions(from: getNumber)
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
