// desktop/native/gather-core/Sources/GatherCore/Services/FaceKwService.swift
// TS 源: desktop/src/main/services/face-kw/face-kw.service.ts（Phase 3.5 移植，
// 全量：analyze / recluster / getClusters / bind / unbind / merge / remove_member /
// preview / writeback / confirmSync / cleanup / cancel）
//
// 移植差异说明（均为有意取舍，行为对账以 TS 单测为基线）：
// - 推理与解码经注入的 inferenceProvider / decodeProvider 接入（对齐
//   SimilarityService 的 thumbnailProvider 模式）。默认 provider 走
//   FaceInferenceEngine（Vision feature print，768 维）与 RAWDecoder；
//   Vision 不可用且未注入时抛 FACE_WORKERS_INIT_FAILED（TS 的 worker init
//   失败聚合路径；Vision 无模型加载，该分支只在缺注入时触发）。
// - TS 的滑动窗口解码预取与 per-worker 背压（MAX_IN_FLIGHT_BATCHES_PER_WORKER）
//   是 sharp/worker 延迟优化；Swift 侧逐张解码、按 decodeWindow 攒批、批内
//   单图失败不拖垮整批（TS worker 语义保留），不做预取（注入解码为纯函数，
//   无去重需求）。face_inference_parallel_workers 仍按 TS 语义读取并轮询分配，
//   但默认 provider 内部共用单引擎（Vision 无 ONNX 线程池可分）。
// - TS 的 fs.stat 区分 ENOENT（缺失照片清理）与其他错误（算检测失败）；Swift
//   用 POSIX stat + errno 复刻该分支。
// - 取消语义对齐 SimilarityService：聚类为同步调用，abort 在聚类返回后补查
//   抛取消（TS worker 可中途拒绝；Swift 更严格，取消不落库）。
// - analysis_runs.params 经 JSONEncoder 编码，键序不保证与 TS JSON.stringify
//   的插入序一致；消费方按 JSON 语义解析。
// - 写回（fkw.unbind 的 removeOwnedFaceKeywords、fkw.preview / writeback /
//   confirm_sync / confirm_cleanup / cleanup）经注入的 FaceWritebackProvider
//   调用；宿主已注入 WritebackService 适配器。未注入 provider 时仍明确抛出
//   WRITEBACK_PROVIDER_NOT_INJECTED，避免误报写回成功。
// - TS 侧 analyze/错误路径会 invalidateSessionLookup（culling 缓存）；Swift
//   侧通过原生挑片页面重新加载 session 数据，保持同进程状态一致。
import Foundation

public enum FaceKwServiceError: Error, Equatable {
    /// TS: ValidationError('FACE_EPS_INVALID')
    case epsInvalid
    /// TS: ValidationError('FACE_MIN_CLUSTER_INVALID')
    case minClusterInvalid
    /// TS: Error('FKW_ANALYSIS_RUNNING')
    case analysisRunning
    /// TS: NotFoundError('SESSION_NOT_FOUND')
    case sessionNotFound
    /// TS: ValidationError('FACE_NO_PHOTOS')
    case noPhotos
    /// TS: Error('FACE_WORKERS_INIT_FAILED')
    case workersInitFailed
    /// TS: ValidationError('FKW_NO_OBSERVATIONS')
    case noObservations
    /// TS: NotFoundError('FKW_CLUSTER_NOT_FOUND')
    case clusterNotFound
    /// TS: ValidationError('FKW_CLUSTER_NOT_IN_SESSION')
    case clusterNotInSession
    /// TS: NotFoundError('FKW_CLUSTER_MEMBER_NOT_FOUND')
    case clusterMemberNotFound
    /// TS: ValidationError('FKW_ROLE_NAME_EMPTY')
    case roleNameEmpty
    /// TS: ValidationError('FKW_KEYWORDS_INVALID')
    case keywordsInvalid
    /// TS: ValidationError('FACE_SELF_MERGE')
    case selfMerge
    /// TS: Error('FKW_UNBIND_CONFIRM_REQUIRED')
    case unbindConfirmRequired
    /// TS: Error('WRITEBACK_CONFIRM_REQUIRED')
    case writebackConfirmRequired
    /// TS: Error('FKW_ITEMS_INVALID')
    case itemsInvalid
    /// TS: Error('FKW_CLEANUP_CONFIRM_REQUIRED')
    case cleanupConfirmRequired
    /// 写回 Provider 未注入（迁移接缝，非 TS 错误码；3.4 Wave 接线后不可达）。
    case writebackProviderMissing
}

/// TS 错误消息逐字对齐（executor 失败路径经 JobService 以 String(describing:)
/// 记录为 errorMessage，必须等于 TS error.message）。
extension FaceKwServiceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .epsInvalid: "FACE_EPS_INVALID"
        case .minClusterInvalid: "FACE_MIN_CLUSTER_INVALID"
        case .analysisRunning: "FKW_ANALYSIS_RUNNING"
        case .sessionNotFound: "SESSION_NOT_FOUND"
        case .noPhotos: "FACE_NO_PHOTOS"
        case .workersInitFailed: "FACE_WORKERS_INIT_FAILED"
        case .noObservations: "FKW_NO_OBSERVATIONS"
        case .clusterNotFound: "FKW_CLUSTER_NOT_FOUND"
        case .clusterNotInSession: "FKW_CLUSTER_NOT_IN_SESSION"
        case .clusterMemberNotFound: "FKW_CLUSTER_MEMBER_NOT_FOUND"
        case .roleNameEmpty: "FKW_ROLE_NAME_EMPTY"
        case .keywordsInvalid: "FKW_KEYWORDS_INVALID"
        case .selfMerge: "FACE_SELF_MERGE"
        case .unbindConfirmRequired: "FKW_UNBIND_CONFIRM_REQUIRED"
        case .writebackConfirmRequired: "WRITEBACK_CONFIRM_REQUIRED"
        case .itemsInvalid: "FKW_ITEMS_INVALID"
        case .cleanupConfirmRequired: "FKW_CLEANUP_CONFIRM_REQUIRED"
        case .writebackProviderMissing: "WRITEBACK_PROVIDER_NOT_INJECTED"
        }
    }
}

/// TS 错误码映射（rawValue 与 TS 错误消息字符串逐字一致，桥接层序列化用）。
extension FaceKwServiceError {
    public var gatherCode: GatherErrorCode {
        switch self {
        case .epsInvalid: .FACE_EPS_INVALID
        case .minClusterInvalid: .FACE_MIN_CLUSTER_INVALID
        case .analysisRunning: .FKW_ANALYSIS_RUNNING
        case .sessionNotFound: .SESSION_NOT_FOUND
        case .noPhotos: .FACE_NO_PHOTOS
        case .workersInitFailed: .FACE_WORKERS_INIT_FAILED
        case .noObservations: .FKW_NO_OBSERVATIONS
        case .clusterNotFound: .FKW_CLUSTER_NOT_FOUND
        case .clusterNotInSession: .FKW_CLUSTER_NOT_IN_SESSION
        case .clusterMemberNotFound: .FKW_CLUSTER_MEMBER_NOT_FOUND
        case .roleNameEmpty: .FKW_ROLE_NAME_EMPTY
        case .keywordsInvalid: .FKW_KEYWORDS_INVALID
        case .selfMerge: .FACE_SELF_MERGE
        case .unbindConfirmRequired: .FKW_UNBIND_CONFIRM_REQUIRED
        case .writebackConfirmRequired: .WRITEBACK_CONFIRM_REQUIRED
        case .itemsInvalid: .FKW_ITEMS_INVALID
        case .cleanupConfirmRequired: .FKW_CLEANUP_CONFIRM_REQUIRED
        case .writebackProviderMissing: .WRITEBACK_OTHER_MODULE_ACTIVE
        }
    }
}

/// TS: FaceAnalysisResult（fkw.analyze 返回；status 为 'done' | 'failed' | 'cancelled'）。
public struct FaceAnalysisResult: Codable, Equatable, Sendable {
    public let status: String
    public let detectionFailures: Int
    public let encodingFailures: Int

    public init(status: String, detectionFailures: Int, encodingFailures: Int) {
        self.status = status
        self.detectionFailures = detectionFailures
        self.encodingFailures = encodingFailures
    }
}

/// TS: FaceClusterData.binding（{ roleName, keywords }）。
public struct FaceClusterBinding: Codable, Equatable, Sendable {
    public let roleName: String
    public let keywords: [String]

    public init(roleName: String, keywords: [String]) {
        self.roleName = roleName
        self.keywords = keywords
    }
}

/// TS: FaceClusterData（fkw.clusters 返回；members 截断至预览窗口 4 条，
/// size 保持精确总数——见 face-kw.service.ts:756-783 注释）。
public struct FaceClusterData: Codable, Equatable, Sendable {
    public let id: Int
    public let sessionId: String
    public let label: String
    public let size: Int
    public let status: String
    public let thumbnailBase64: String
    public let binding: FaceClusterBinding?
    public let thumbnailPhotoId: String?
    public let members: [ClusterMember]

    public init(
        id: Int,
        sessionId: String,
        label: String,
        size: Int,
        status: String,
        thumbnailBase64: String,
        binding: FaceClusterBinding?,
        thumbnailPhotoId: String?,
        members: [ClusterMember]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.label = label
        self.size = size
        self.status = status
        self.thumbnailBase64 = thumbnailBase64
        self.binding = binding
        self.thumbnailPhotoId = thumbnailPhotoId
        self.members = members
    }
}

/// TS: fkw.unbind 返回（{ done, removedKeywords }）。
public struct FkwUnbindResult: Codable, Equatable, Sendable {
    public let done: Bool
    public let removedKeywords: [String]

    public init(done: Bool, removedKeywords: [String]) {
        self.done = done
        self.removedKeywords = removedKeywords
    }
}

/// TS: FaceInferenceObservation（face-kw.service.ts 的 face 投影）。
public struct FaceInferenceObservation: Equatable, Sendable {
    public let bbox: [Double]
    public let confidence: Double
    public let embedding: [Double]

    public init(bbox: [Double], confidence: Double, embedding: [Double]) {
        self.bbox = bbox
        self.confidence = confidence
        self.embedding = embedding
    }
}

/// TS: FaceInferenceBatchItem（单图推理结果；error 非 nil 时其余字段无效）。
public struct FaceInferenceItem: Equatable, Sendable {
    public let error: String?
    public let observations: [FaceInferenceObservation]
    public let encodingFailures: Int

    public init(error: String? = nil, observations: [FaceInferenceObservation] = [], encodingFailures: Int = 0) {
        self.error = error
        self.observations = observations
        self.encodingFailures = encodingFailures
    }
}

/// TS: fkw.unbind 的 removeOwnedFaceKeywords entries 元素。
public struct FaceKeywordEntry: Equatable, Sendable {
    public let photoId: String
    public let xmpPath: String
    public let keywords: [String]

    public init(photoId: String, xmpPath: String, keywords: [String]) {
        self.photoId = photoId
        self.xmpPath = xmpPath
        self.keywords = keywords
    }
}

// ── 写回接缝契约（TS 源: packages/shared/src/protocol/core.ts writeback 段）──
// FaceKw 服务对写回只做直传（preview/execute/confirm/cleanup 的入参与返回值
// 原样透传），接缝类型按 TS 字段逐字对齐；3.4 共享类型落位后可直接替换，
// JSON 形状不变。

// TS: WritebackAttributes（core.ts:35-39）
public struct FaceKwWritebackAttributes: Codable, Equatable, Sendable {
    public var keywords: [String]? // TS: keywords?
    public var rating: Double? // TS: rating?
    public var label: String? // TS: label?

    public init(keywords: [String]? = nil, rating: Double? = nil, label: String? = nil) {
        self.keywords = keywords
        self.rating = rating
        self.label = label
    }
}

// TS: WritebackOptions（core.ts:47-52）
public struct FaceKwWritebackOptions: Codable, Equatable, Sendable {
    public var createAlbums: Bool? // TS: createAlbums?
    public var addPrefix: Bool? // TS: addPrefix?
    public var markUngrouped: Bool? // TS: markUngrouped?
    public var writeIPTC: Bool? // TS: writeIPTC?

    public init(createAlbums: Bool? = nil, addPrefix: Bool? = nil, markUngrouped: Bool? = nil, writeIPTC: Bool? = nil) {
        self.createAlbums = createAlbums
        self.addPrefix = addPrefix
        self.markUngrouped = markUngrouped
        self.writeIPTC = writeIPTC
    }
}

// TS: WritebackItem.preview（core.ts:74-82，内联匿名对象）
public struct FaceKwWritebackPreviewInfo: Codable, Equatable, Sendable {
    public var dirtyFields: [String] // TS: Array<'rating' | 'label' | 'keywords'>
    public var before: FaceKwWritebackAttributes
    public var after: FaceKwWritebackAttributes
    public var source: String
    public var sharedPhotoCount: Int
    public var externalChanged: Bool
    public var willCreate: Bool

    public init(
        dirtyFields: [String],
        before: FaceKwWritebackAttributes,
        after: FaceKwWritebackAttributes,
        source: String,
        sharedPhotoCount: Int,
        externalChanged: Bool,
        willCreate: Bool
    ) {
        self.dirtyFields = dirtyFields
        self.before = before
        self.after = after
        self.source = source
        self.sharedPhotoCount = sharedPhotoCount
        self.externalChanged = externalChanged
        self.willCreate = willCreate
    }
}

// TS: WritebackItem（core.ts:60-83）
public struct FaceKwWritebackItem: Codable, Equatable, Sendable {
    public var id: Int64? // TS: id?: number
    public var photoId: String
    public var photoPath: String
    public var sessionId: String
    public var module: String
    public var keywords: [String]
    public var attributes: FaceKwWritebackAttributes? // TS: attributes?
    public var xmpPath: String
    public var backupPath: String
    public var xmpStatus: String
    public var errorMessage: String
    public var attemptCount: Int
    public var lastAttemptAt: String
    public var preview: FaceKwWritebackPreviewInfo? // TS: preview?

    public init(
        id: Int64? = nil,
        photoId: String,
        photoPath: String,
        sessionId: String,
        module: String,
        keywords: [String],
        attributes: FaceKwWritebackAttributes? = nil,
        xmpPath: String,
        backupPath: String,
        xmpStatus: String,
        errorMessage: String,
        attemptCount: Int,
        lastAttemptAt: String,
        preview: FaceKwWritebackPreviewInfo? = nil
    ) {
        self.id = id
        self.photoId = photoId
        self.photoPath = photoPath
        self.sessionId = sessionId
        self.module = module
        self.keywords = keywords
        self.attributes = attributes
        self.xmpPath = xmpPath
        self.backupPath = backupPath
        self.xmpStatus = xmpStatus
        self.errorMessage = errorMessage
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.preview = preview
    }
}

// TS: WritebackPreview（core.ts:54-58）
public struct FaceKwWritebackPreview: Codable, Equatable, Sendable {
    public var items: [FaceKwWritebackItem]
    public var totalCount: Int
    public var affectedPhotos: Int

    public init(items: [FaceKwWritebackItem], totalCount: Int, affectedPhotos: Int) {
        self.items = items
        self.totalCount = totalCount
        self.affectedPhotos = affectedPhotos
    }
}

// TS: WritebackResult（core.ts:85-93）
public struct FaceKwWritebackResult: Codable, Equatable, Sendable {
    public var totalAffected: Int
    public var written: Int
    public var failed: Int
    public var skipped: Int
    public var errors: [String]
    public var failedItems: [FaceKwWritebackItem]
    public var report: String

    public init(
        totalAffected: Int,
        written: Int,
        failed: Int,
        skipped: Int,
        errors: [String],
        failedItems: [FaceKwWritebackItem],
        report: String
    ) {
        self.totalAffected = totalAffected
        self.written = written
        self.failed = failed
        self.skipped = skipped
        self.errors = errors
        self.failedItems = failedItems
        self.report = report
    }
}

// TS: CleanupResult（core.ts:95-98）
public struct FaceKwCleanupResult: Codable, Equatable, Sendable {
    public var deletedCount: Int
    public var errors: [String]

    public init(deletedCount: Int, errors: [String]) {
        self.deletedCount = deletedCount
        self.errors = errors
    }
}

/// 写回 Provider（3.4 Wave 实现；注入协议对齐 TS WritebackService 的相关方法）。
/// 实现留给 3.4 的 writeback 服务，本服务只按同样契约调用。
public protocol FaceWritebackProvider: Sendable {
    /// TS: writebackService.removeOwnedFaceKeywords(sessionId, entries) → removedKeywords。
    func removeOwnedFaceKeywords(sessionId: String, entries: [FaceKeywordEntry]) async throws -> [String]
    /// TS: writebackService.preview(sessionId, 'face_kw', options, boundPhotoIds, additions)。
    func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?,
        boundPhotoIds: Set<String>,
        additions: [String: [String]]
    ) async throws -> FaceKwWritebackPreview
    /// TS: writebackService.execute(sessionId, 'face_kw', items)。
    func execute(sessionId: String, items: [FaceKwWritebackItem]) async throws -> FaceKwWritebackResult
    /// TS: writebackService.confirmSync(sessionId, 'face_kw')。
    func confirmSync(sessionId: String) async throws
    /// TS: writebackService.cleanup(sessionId, 'face_kw')。
    func cleanup(sessionId: String) async throws -> FaceKwCleanupResult
}

/// TS: validateFaceClusteringParameters。minPts 为 Double 对齐 TS number：
/// Number.isInteger 校验（拒绝 NaN/∞/小数），通过后调用方再安全转 Int。
public func validateFaceClusteringParameters(eps: Double, minPts: Double) throws {
    if eps.isNaN || eps.isInfinite || eps < 0 || eps > 1 {
        throw FaceKwServiceError.epsInvalid
    }
    if minPts.isNaN || minPts.isInfinite || minPts.rounded() != minPts || minPts < 1 {
        throw FaceKwServiceError.minClusterInvalid
    }
}

/// TS: FaceKwService（desktop/src/main/services/face-kw/face-kw.service.ts）。
public final class FaceKwService {
    /// TS: onProgress({ current, total, phase })。
    public typealias ProgressHandler = (Int, Int, String) -> Void
    /// TS: imageService.getPreview(filepath, maxDimension, 0, false) → buffer；
    /// 解码失败返回 nil（对应 getPreview reject）。
    public typealias DecodeProvider = (String, Int) async -> Data?
    /// TS: FaceInferenceWorker.analyzeBatch(images, config, signal) →
    /// 逐图 FaceInferenceBatchItem（与输入序对齐；单图失败不拖垮整批）。
    public typealias FaceInferenceProvider = ([Data], FaceInferenceConfig, JobAbortSignal?) async throws -> [FaceInferenceItem]
    /// TS: clusterFacesInWorker（eps/minPts 聚类，同步 CPU 实现）。
    public typealias FaceClusterProvider = ([EmbeddingEntry], Double, Int, ((Int, Int) -> Void)?) throws -> FaceClusterResult

    /// TS: MAX_PREVIEW_MEMBERS（getClusters 的成员截断窗口）。
    private static let maxPreviewMembers = 4

    private let photoRepo: PhotoRepo
    private let sessionRepo: SessionRepo
    private let faceStore: any FaceStore
    private let personStore: any PersonStore
    private let connection: DBConnection
    /// TS: SettingsService.getNumber 注入。
    private let getNumber: (String, Double) -> Double
    /// TS: SettingsService.get 注入（onnx_provider 等字符串设置）。
    private let getString: (String, String) -> String
    /// TS: imageService 注入。
    private let decodeProvider: DecodeProvider?
    /// TS: FaceInferenceWorker 注入（默认走 FaceInferenceEngine）。
    private let inferenceProvider: FaceInferenceProvider?
    /// TS: clusterFacesInWorker 注入。
    private let clusterProvider: FaceClusterProvider
    /// TS: writebackService 注入（3.4 Wave 实现）。
    private let writebackProvider: FaceWritebackProvider?

    /// TS: controllers（Map<sessionId, AbortController>）。
    private var controllers: [String: JobAbortSignal] = [:]
    private let controllersLock = NSLock()

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func controller(for sessionId: String) -> JobAbortSignal? {
        controllersLock.lock()
        defer { controllersLock.unlock() }
        return controllers[sessionId]
    }

    private func registerController(_ signal: JobAbortSignal, for sessionId: String) {
        controllersLock.lock()
        controllers[sessionId] = signal
        controllersLock.unlock()
    }

    private func removeControllerIfCurrent(_ signal: JobAbortSignal, for sessionId: String) {
        controllersLock.lock()
        if controllers[sessionId] === signal {
            controllers.removeValue(forKey: sessionId)
        }
        controllersLock.unlock()
    }

    public init(
        photoRepo: PhotoRepo,
        sessionRepo: SessionRepo,
        faceStore: any FaceStore,
        personStore: any PersonStore,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        getString: @escaping (String, String) -> String = { _, defaultValue in defaultValue },
        decodeProvider: DecodeProvider? = nil,
        inferenceProvider: FaceInferenceProvider? = nil,
        clusterProvider: @escaping FaceClusterProvider = { entries, eps, minPts, onProgress in
            try FaceClusterer.clusterEmbeddings(
                entries: entries, eps: eps, minPts: minPts, onProgress: onProgress)
        },
        writebackProvider: FaceWritebackProvider? = nil
    ) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.faceStore = faceStore
        self.personStore = personStore
        self.connection = connection
        self.getNumber = getNumber
        self.getString = getString
        self.decodeProvider = decodeProvider
        self.inferenceProvider = inferenceProvider
        self.clusterProvider = clusterProvider
        self.writebackProvider = writebackProvider
    }

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
        let epsValue = eps ?? getNumber("default_eps", 0.6)
        let minPtsValue = minPts ?? getNumber("default_min_samples", 2)
        try validateFaceClusteringParameters(eps: epsValue, minPts: minPtsValue)
        if controller(for: sessionId) != nil { throw FaceKwServiceError.analysisRunning }
        let signal = JobAbortSignal()
        registerController(signal, for: sessionId)

        var detectionFailures = 0
        var encodingFailures = 0
        var totalFaces = 0
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
            try sessionRepo.updateAnalysisStatus(id: sessionId, status: "running")
            onProgress?(0, 0, "face.init")

            // TS 的 onnx_threads 用于 worker 线程预算分摊；Vision 无 ONNX
            // 线程池，该设置在此保留读取语义（见文件头差异说明）但不消费。
            let encoderInputSize = Int(getNumber("encoder_input_size", 112))
            let embeddingDim = Int(getNumber("embedding_dim", 512))
            // 照片与 index_seq 快照共享一个读事务（design §8）。
            let snapshot: (photos: [PhotoProjectionRow], indexSeq: Int) = try connection.transaction {
                (PhotoAssets.collapse(try photoRepo.getBySessionProjection(sessionId: sessionId)),
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

            let primaryDetectionSize = Int(getNumber("detect_input_size", 640))
            let secondaryDetectionSize = Int(getNumber("detect_secondary_input_size", 128))
            let confidenceThreshold = getNumber("detect_confidence", 0.5)
            let previewMaxDimension = max(640, Int(getNumber("face_preview_max_dimension", 2048)))
            let analysisSignature = Self.makeAnalysisSignature(
                detectorPath: detectorPath,
                encoderPath: encoderPath,
                primaryDetectionSize: primaryDetectionSize,
                secondaryDetectionSize: secondaryDetectionSize,
                confidenceThreshold: confidenceThreshold,
                encoderInputSize: encoderInputSize,
                embeddingDim: embeddingDim,
                previewMaxDimension: previewMaxDimension
            )

            var cachedByPhoto: [String: [FaceObservationRecord]] = [:]
            for observation in try await faceStore.observations(sessionId: sessionId) {
                var values = cachedByPhoto[observation.photoId] ?? []
                values.append(observation)
                cachedByPhoto[observation.photoId] = values
            }
            var analysisStates = try await faceStore.analysisStates(sessionId: sessionId)

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
                    try await faceStore.deleteObservationsByPhoto(sessionId: sessionId, photoId: photoId)
                    try await faceStore.deleteAnalysisStateByPhoto(sessionId: sessionId, photoId: photoId)
                    analysisStates.removeValue(forKey: photoId)
                    cachedByPhoto.removeValue(forKey: photoId)
                }
                GatherLogger.log(
                    "Face analysis: cleaned up \(missingPhotoIds.count) photo(s) whose files no longer exist",
                    level: .warn
                )
            }

            // 跨会话复用查找：一次批量 IN 查询代替逐照片 SELECT（TS 同款）。
            var reuseTargets: [FaceReuseTargetInput] = []
            for photo in snapshot.photos {
                guard case .ok(let size, let mtimeMs)? = sourceStats[photo.id] else { continue }
                if Self.isCacheValid(
                    analysisStates[photo.id], sourceSize: size, sourceMtimeMs: mtimeMs,
                    analysisSignature: analysisSignature
                ) { continue }
                reuseTargets.append(FaceReuseTargetInput(
                    photoId: photo.id,
                    assetFileId: photo.assetFileId,
                    sourceFileSize: size,
                    sourceFileMtimeMs: mtimeMs
                ))
            }
            let reuseResults = try await faceStore.reuseObservations(
                sessionId: sessionId,
                targets: reuseTargets,
                analysisSignature: analysisSignature
            )
            var reusedAcrossSessions = false
            for target in reuseTargets {
                guard let reused = reuseResults[target.photoId], reused.reused else { continue }
                reusedAcrossSessions = true
                analysisStates[target.photoId] = FaceAnalysisStateRecord(
                    sourceFileSize: target.sourceFileSize,
                    sourceFileMtimeMs: target.sourceFileMtimeMs,
                    analysisSignature: analysisSignature
                )
            }
            if reusedAcrossSessions {
                cachedByPhoto.removeAll()
                for observation in try await faceStore.observations(sessionId: sessionId) {
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
            let clusterSignature = "\(epsValue):\(Int(minPtsValue))"
            let signatureMatches = (try? await faceStore.clusterSignature(sessionId: sessionId)) == clusterSignature
            let existingClusters = try await faceStore.clusters(sessionId: sessionId, includeMembers: false)
            let hasClusters = !existingClusters.isEmpty
            if missingPhotoIds.isEmpty && photosNeedingAnalysis.isEmpty && signatureMatches && hasClusters {
                onProgress?(totalPhotos, totalPhotos, "face.cached-clusters")
                try sessionRepo.updateAnalysisStatus(id: sessionId, status: "done")
                runStatus = "ok"
                return FaceAnalysisResult(status: "done", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }

            let requestedWorkers = max(1, min(2, Int(getNumber("face_inference_parallel_workers", 1))))
            let inferenceConfig = FaceInferenceConfig(
                confidenceThreshold: confidenceThreshold,
                nmsThreshold: getNumber("nms_threshold", 0.4),
                maxDetections: Int(getNumber("max_detections", 100)),
                embeddingDim: embeddingDim,
                primaryInputSize: primaryDetectionSize,
                secondaryInputSize: secondaryDetectionSize,
                encodeInputSize: encoderInputSize,
                fallbackToOnnxEnabled: false
            )
            // 旧集群与角色绑定刻意保留到新结果就绪（TS 注释 270-272）：失败
            // 的推理不得摧毁用户已绑定的集群与角色名。
            if !photosNeedingAnalysis.isEmpty && inferenceProvider == nil && !Self.visionAvailable {
                throw FaceKwServiceError.workersInitFailed
            }
            let provider: FaceInferenceProvider = try inferenceProvider ?? {
                guard Self.visionAvailable else { throw FaceKwServiceError.workersInitFailed }
                return Self.makeDefaultProvider(config: inferenceConfig)
            }()
            let decode: DecodeProvider = decodeProvider ?? { path, maxDimension in
                await Self.defaultDecode(path: path, maxDimension: maxDimension)
            }

            onProgress?(0, totalPhotos, "face.detect")

            let decodeWindow = max(1, min(8, Int(getNumber("face_decode_concurrency", 4))))

            // TS: applyInferenceResult（替换旧观察只在推理成功之后；失败批次
            // 不得摧毁该照片先前有效的检测）。
            func applyInferenceResult(index: Int, item: FaceInferenceItem) async {
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
                            analysisSignature: analysisSignature
                        )
                    }
                    _ = try await faceStore.replaceObservationsByPhoto(
                        sessionId: sessionId, photoId: photo.id, observations: observations)
                    if !item.observations.isEmpty {
                        totalFaces += item.observations.count
                    }
                    try await faceStore.upsertAnalysisState(
                        sessionId: sessionId,
                        photoId: photo.id,
                        sourceFileSize: size,
                        sourceFileMtimeMs: mtimeMs,
                        analysisSignature: analysisSignature
                    )
                } catch {
                    detectionFailures += 1
                    GatherLogger.log("Face detection failed for \(photo.filepath) \(error)", level: .warn)
                }
            }

            // 每 worker 一个攒批队列；照片按 i % N 轮询分配。批满即派发，
            // 派发后等待结果（TS 的在飞批上限/背压为 worker 消息队列优化，
            // 见文件头差异说明）。
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
                    await applyInferenceResult(index: indices[b], item: results[b])
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

            // 重聚类前先判定失败：全失败 run 不得清掉先前绑定的集群与角色名。
            let allDetectionsFailed = detectionFailures == totalPhotos && totalPhotos > 0
            let allEncodingsFailed = encodingFailures == totalFaces && totalFaces > 0
            let analysisFailed = allDetectionsFailed || allEncodingsFailed

            onProgress?(0, 0, "face.cluster")
            try await clusterStoredObservations(
                sessionId: sessionId,
                photos: snapshot.photos,
                eps: epsValue,
                minPts: Int(minPtsValue),
                signal: signal,
                clearOnEmpty: !analysisFailed,
                onProgress: { current, total in onProgress?(current, total, "face.cluster") }
            )
            try await faceStore.upsertClusterSignature(sessionId: sessionId, signature: clusterSignature)

            if analysisFailed {
                try sessionRepo.updateAnalysisStatus(id: sessionId, status: "failed")
                return FaceAnalysisResult(status: "failed", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }
            onProgress?(0, 0, "face.done")
            try sessionRepo.updateAnalysisStatus(id: sessionId, status: "done")
            runStatus = "ok"
            return FaceAnalysisResult(status: "done", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
        } catch {
            if error is JobCancelledError {
                try? sessionRepo.updateAnalysisStatus(id: sessionId, status: "cancelled")
                return FaceAnalysisResult(status: "cancelled", detectionFailures: detectionFailures, encodingFailures: encodingFailures)
            }
            try? sessionRepo.updateAnalysisStatus(id: sessionId, status: "failed")
            throw error
        }
    }

    /// TS: recluster（fkw.recluster；仅重聚类，不重推理）。
    public func recluster(sessionId: String, eps: Double, minPts: Double) async throws {
        try validateFaceClusteringParameters(eps: eps, minPts: minPts)
        guard try sessionRepo.get(id: sessionId) != nil else {
            throw FaceKwServiceError.sessionNotFound
        }
        if try await faceStore.observations(sessionId: sessionId).isEmpty {
            throw FaceKwServiceError.noObservations
        }
        let photos = PhotoAssets.collapse(try photoRepo.getBySessionProjection(sessionId: sessionId))
        try await clusterStoredObservations(
            sessionId: sessionId, photos: photos, eps: eps, minPts: Int(minPts),
            signal: nil, clearOnEmpty: true, onProgress: nil)
        try await faceStore.upsertClusterSignature(sessionId: sessionId, signature: "\(eps):\(Int(minPts))")
    }

    /// TS: getClusters（fkw.clusters）。成员截断至预览窗口，size 保持精确总数。
    public func getClusters(sessionId: String) async throws -> [FaceClusterData] {
        let clusters = try await faceStore.clusters(sessionId: sessionId, includeMembers: true)
        return clusters.map { cluster in
            let previewMembers = Array((cluster.members ?? []).prefix(Self.maxPreviewMembers))
            return FaceClusterData(
                id: Int(cluster.id),
                sessionId: cluster.sessionId,
                label: cluster.label,
                size: Int(cluster.memberCount),
                status: cluster.status,
                thumbnailBase64: cluster.thumbnailBase64,
                binding: cluster.binding.map { FaceClusterBinding(roleName: $0.roleName, keywords: $0.keywords) },
                thumbnailPhotoId: previewMembers.first?.photoId,
                members: previewMembers.map { member in
                    ClusterMember(
                        memberId: Int(member.id),
                        photoId: member.photoId,
                        photoPath: member.photoPath,
                        filename: (member.photoPath as NSString).lastPathComponent,
                        bbox: Self.parseBbox(member.bbox),
                        confidence: member.confidence
                    )
                }
            )
        }
    }

    // ─────────────────────────── 绑定 / 合并 / 成员 ───────────────────────────

    /// 批量照片的人脸观测计数（photo.id → 数量），供宿主 photo 列表分页附带
    /// faceCount（TS photo.ipc.ts assemblePhotos 的人脸计数小查询下沉）。
    public func faceCounts(sessionId: String, photoIds: [String]) async throws -> [String: Int] {
        try await faceStore.countsByPhoto(sessionId: sessionId, photoIds: photoIds)
    }

    /// TS: bindCluster（fkw.bind）。绑定后把角色桥接进人物库（best-effort）。
    public func bindCluster(sessionId: String, clusterId: Int64, roleName: String, keywords: [String]) async throws {
        let clusterSessionId = try await faceStore.clusterSessionId(clusterId: clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        let normalizedRoleName = roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedRoleName.isEmpty { throw FaceKwServiceError.roleNameEmpty }
        // TS 的 FKW_KEYWORDS_INVALID（Array.isArray / typeof === 'string' 校验）
        // 属 JSON 契约层职责；Swift 参数类型已强约束，此处不做重复校验。
        var seen = Set<String>()
        let dedupedKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        try await faceStore.updateBinding(clusterId: clusterId, roleName: normalizedRoleName, keywords: dedupedKeywords)
        // 角色桥接进人物库（「人脸库」页不孤立）：按角色名 upsert 人物并挂接
        // 集群照片。Best-effort —— 桥接失败不得使绑定本身失败。
        do {
            let members = try await faceStore.clusterMembers(clusterId: clusterId)
            let personId = try await personStore.upsertByName(name: normalizedRoleName, keywords: dedupedKeywords)
            try await personStore.addPhotos(
                personId: personId,
                sessionId: sessionId,
                photos: members.map { member in
                    PersonPhotoInput(photoId: member.photoId, faceBbox: member.bbox, confidence: member.confidence)
                }
            )
        } catch {
            GatherLogger.log("Failed to link bound role into person library \(error)", level: .warn)
        }
    }

    /// TS: unbindCluster（fkw.unbind 的服务层步骤；解除绑定并重算人物库）。
    public func unbindCluster(sessionId: String, clusterId: Int64) async throws {
        let clusterSessionId = try await faceStore.clusterSessionId(clusterId: clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        try await faceStore.deleteBinding(clusterId: clusterId)
        // 不再被角色绑定覆盖的照片从人物库摘除。Best-effort。
        do {
            try await personStore.reconcileSession(sessionId: sessionId)
        } catch {
            GatherLogger.log("Failed to reconcile person library after unbind \(error)", level: .warn)
        }
    }

    /// TS: face-kw.ipc.ts fkw.unbind 全流程：确认 → 受保护关键字过滤 →
    /// removeOwnedFaceKeywords（写回）→ unbindCluster。
    public func unbind(sessionId: String, clusterId: Int64, confirmed: Bool) async throws -> FkwUnbindResult {
        guard confirmed else { throw FaceKwServiceError.unbindConfirmRequired }
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        // getClusters(includeMembers=true) 是一次昂贵的批量读；结果同时用于
        // 目标查找与剩余已绑定集群的扫描（TS 注释 133-135）。
        let clusters = try await faceStore.clusters(sessionId: sessionId, includeMembers: true)
        guard let cluster = clusters.first(where: { $0.id == clusterId }) else {
            throw FaceKwServiceError.clusterNotFound
        }
        var protectedByPath: [String: Set<String>] = [:]
        for remaining in clusters {
            if remaining.id == clusterId { continue }
            guard let binding = remaining.binding else { continue }
            for member in remaining.members ?? [] {
                let xmpPath = TSPath.xmpSidecarPath(member.photoPath)
                var protected = protectedByPath[xmpPath] ?? []
                for keyword in ([binding.roleName] + binding.keywords)
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                    if !keyword.isEmpty { protected.insert(keyword) }
                }
                protectedByPath[xmpPath] = protected
            }
        }
        let roleKeywords = [cluster.binding?.roleName ?? ""] + (cluster.binding?.keywords ?? [])
        let entries = (cluster.members ?? []).map { member in
            let xmpPath = TSPath.xmpSidecarPath(member.photoPath)
            let protected = protectedByPath[xmpPath] ?? []
            let keywords = roleKeywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !protected.contains($0) }
            return FaceKeywordEntry(photoId: member.photoId, xmpPath: xmpPath, keywords: keywords)
        }
        let removedKeywords = try await writebackProvider.removeOwnedFaceKeywords(
            sessionId: sessionId, entries: entries)
        try await unbindCluster(sessionId: sessionId, clusterId: clusterId)
        return FkwUnbindResult(done: true, removedKeywords: removedKeywords)
    }

    /// TS: mergeClusters（fkw.merge）。
    public func mergeClusters(sessionId: String, sourceId: Int64, targetId: Int64) async throws {
        if sourceId == targetId { throw FaceKwServiceError.selfMerge }
        let sourceSessionId = try await faceStore.clusterSessionId(clusterId: sourceId)
        let targetSessionId = try await faceStore.clusterSessionId(clusterId: targetId)
        guard let sourceSessionId, let targetSessionId else { throw FaceKwServiceError.clusterNotFound }
        if sourceSessionId != sessionId || targetSessionId != sessionId {
            throw FaceKwServiceError.clusterNotInSession
        }
        try await faceStore.mergeClusters(sourceId: sourceId, targetId: targetId)
        // 移入目标集群的照片归属目标角色；源角色失去它们。Best-effort。
        do {
            try await personStore.reconcileSession(sessionId: sessionId)
        } catch {
            GatherLogger.log("Failed to reconcile person library after merge \(error)", level: .warn)
        }
    }

    /// TS: removeMember（fkw.remove_member）。
    public func removeMember(sessionId: String, clusterId: Int64, memberId: Int64) async throws {
        let clusterSessionId = try await faceStore.clusterSessionId(clusterId: clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        if !(try await faceStore.removeMemberFromCluster(clusterId: clusterId, memberId: memberId)) {
            throw FaceKwServiceError.clusterMemberNotFound
        }
        // 被移除成员的照片不再被该集群的角色绑定覆盖。Best-effort。
        do {
            try await personStore.reconcileSession(sessionId: sessionId)
        } catch {
            GatherLogger.log("Failed to reconcile person library after member removal \(error)", level: .warn)
        }
    }

    /// TS: cancel（fkw.cancel_analysis 的服务层步骤）。
    public func cancel(sessionId: String) {
        controller(for: sessionId)?.abort()
    }

    // ─────────────────────────── 写回（经注入 Provider） ───────────────────────────

    /// TS: face-kw.ipc.ts fkw.preview。
    public func preview(
        sessionId: String,
        options: FaceKwWritebackOptions?
    ) async throws -> FaceKwWritebackPreview {
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        let clusters = try await faceStore.clusters(sessionId: sessionId, includeMembers: true)
        let additions = Self.buildFaceKeywordAdditions(clusters)
        let boundPhotoIds = Set(additions.keys)
        return try await writebackProvider.preview(
            sessionId: sessionId,
            options: options,
            boundPhotoIds: boundPhotoIds,
            additions: additions
        )
    }

    /// TS: face-kw.ipc.ts fkw.writeback。
    public func writeback(
        sessionId: String,
        confirmed: Bool,
        items: [FaceKwWritebackItem]?
    ) async throws -> FaceKwWritebackResult {
        guard confirmed else { throw FaceKwServiceError.writebackConfirmRequired }
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        // TS 的 FKW_ITEMS_INVALID（Array.isArray 校验）属 JSON 契约层职责；
        // Swift 参数类型已强约束（nil 等价 TS 的 `params.items ?? []`）。
        let resolved = items ?? []
        return try await writebackProvider.execute(sessionId: sessionId, items: resolved)
    }

    /// TS: face-kw.ipc.ts fkw.confirm_sync（返回 ok(true)）。
    public func confirmSync(sessionId: String) async throws -> Bool {
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        try await writebackProvider.confirmSync(sessionId: sessionId)
        return true
    }

    /// TS: face-kw.ipc.ts fkw.confirm_cleanup / fkw.cleanup。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> FaceKwCleanupResult {
        guard confirmed else { throw FaceKwServiceError.cleanupConfirmRequired }
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        return try await writebackProvider.cleanup(sessionId: sessionId)
    }

    // ─────────────────────────── 内部 ───────────────────────────

    /// TS: clusterStoredObservations（analyze / recluster 共用）。
    /// clearOnEmpty=false 时（全失败 run）保留旧集群与角色绑定。
    private func clusterStoredObservations(
        sessionId: String,
        photos: [PhotoProjectionRow],
        eps: Double,
        minPts: Int,
        signal: JobAbortSignal?,
        clearOnEmpty: Bool,
        onProgress: ((Int, Int) -> Void)?
    ) async throws {
        let observations = try await faceStore.observations(sessionId: sessionId)
        let observationById = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })

        var entries: [EmbeddingEntry] = []
        for observation in observations {
            let embedding = Self.floats(from: observation.embedding)
            if embedding.contains(where: { $0 != 0 }) {
                entries.append(EmbeddingEntry(
                    observationId: Int(observation.id),
                    photoId: observation.photoId,
                    embedding: embedding
                ))
            }
        }

        let clustered = try clusterProvider(entries, eps, minPts, onProgress)
        if signal?.aborted ?? false { throw JobCancelledError() }

        let clusterInputs = clustered.clusters.enumerated().map { index, cluster in
            FaceClusterInput(
                label: "Person \(index + 1)",
                members: cluster.map { entry in
                    let observation = observationById[Int64(entry.observationId)]
                    return FaceClusterMemberInput(
                        photoId: entry.photoId,
                        photoPath: photoById[entry.photoId] ?? "",
                        bbox: [
                            observation?.bboxX ?? 0,
                            observation?.bboxY ?? 0,
                            observation?.bboxW ?? 0,
                            observation?.bboxH ?? 0,
                        ],
                        confidence: observation?.confidence ?? 0,
                        observationId: Int64(entry.observationId)
                    )
                }
            )
        }
        if clusterInputs.isEmpty {
            // 分析成功但无脸时不应留下陈旧集群；全失败 run 则保留（TS 注释）。
            if clearOnEmpty { try await faceStore.deleteClustersBySession(sessionId) }
            return
        }

        // 新结果就绪才替换旧集群（TS 注释 689-693）：用户绑定的角色经成员
        // 重叠迁移，否则重新聚类后绑定会静默消失。
        let previousBindings = try await faceStore.bindingsBySession(sessionId)
        try await faceStore.deleteClustersBySession(sessionId)
        let newClusterIds = try await faceStore.saveClusters(sessionId: sessionId, clusters: clusterInputs)
        if !previousBindings.isEmpty {
            let membersByCluster = newClusterIds.enumerated().map { index, clusterId in
                (
                    clusterId: clusterId,
                    photoIds: Set(
                        clusterInputs[index].members.map(\.photoId).filter { !$0.isEmpty }
                    )
                )
            }
            await migrateBindings(previousBindings, newMembers: membersByCluster)
        }
    }

    /// TS: migrateBindings —— 按照片 id 重叠度把角色绑定挂回新集群；重叠降序
    /// 认领（竞争由更优匹配者获胜）；消失的脸对应的绑定被丢弃。Best-effort：
    /// 迁移失败不得使分析本身失败。
    private func migrateBindings(
        _ previousBindings: [FaceBindingDetail],
        newMembers: [(clusterId: Int64, photoIds: Set<String>)]
    ) async {
        var candidates: [(binding: FaceBindingDetail, clusterId: Int64, overlap: Int)] = []
        for binding in previousBindings {
            let memberPhotos = Set(binding.memberPhotoIds)
            for candidate in newMembers {
                var overlap = 0
                for photoId in candidate.photoIds where memberPhotos.contains(photoId) {
                    overlap += 1
                }
                if overlap > 0 {
                    candidates.append((binding, candidate.clusterId, overlap))
                }
            }
        }
        candidates.sort { $0.overlap > $1.overlap }
        var claimedClusters = Set<Int64>()
        var migratedBindings = Set<Int64>()
        for candidate in candidates {
            if claimedClusters.contains(candidate.clusterId) { continue }
            if migratedBindings.contains(candidate.binding.clusterId) { continue }
            claimedClusters.insert(candidate.clusterId)
            migratedBindings.insert(candidate.binding.clusterId)
            do {
                try await faceStore.updateBinding(
                    clusterId: candidate.clusterId,
                    roleName: candidate.binding.roleName,
                    keywords: candidate.binding.keywords
                )
            } catch {
                GatherLogger.log("Failed to migrate role binding after re-clustering \(error)", level: .warn)
            }
        }
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
        _ = try connection.prepare("""
            INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, ?, ?, ?, ?, '', ?, 'running')
          """).run([
            .text(sessionId), .text(kind), .int(Int64(photoCount)), .int(Int64(indexSeq)),
            .text(nowISOString()), .text(String(data: data, encoding: .utf8) ?? "{}"),
        ])
        return connection.lastInsertRowid
    }

    // 取消的 run 在此以 'failed' 终态（sessions.analysis_status 在 catch 写
    // 'cancelled'）：run 记录按设计只区分 ok/failed，该分歧是刻意的（TS 注释
    // 603-606；过期检测 1.4.2 一律忽略非 ok run）。
    private func finalizeAnalysisRun(runId: Int64, status: String) throws {
        _ = try connection.prepare("UPDATE analysis_runs SET status = ?, finished_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISOString()), .int(runId)])
    }

    /// TS: buildFaceKeywordAdditions（fkw.preview 的写回规划）。
    public static func buildFaceKeywordAdditions(_ clusters: [FaceClusterRecord]) -> [String: [String]] {
        var additions: [String: [String]] = [:]
        for cluster in clusters {
            guard let binding = cluster.binding else { continue }
            var seen = Set<String>()
            let keywords = ([binding.roleName] + binding.keywords)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            for member in cluster.members ?? [] {
                var merged = additions[member.photoId] ?? []
                for keyword in keywords where !merged.contains(keyword) {
                    merged.append(keyword)
                }
                additions[member.photoId] = merged
            }
        }
        return additions
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
        previewMaxDimension: Int
    ) -> String {
        let fields = [
            jsonField("detector", Self.modelFingerprint(detectorPath)),
            jsonField("encoder", Self.modelFingerprint(encoderPath)),
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
        _ state: FaceAnalysisStateRecord?,
        sourceSize: Int64,
        sourceMtimeMs: Double,
        analysisSignature: String
    ) -> Bool {
        guard let state else { return false }
        return state.sourceFileSize == sourceSize &&
            abs(state.sourceFileMtimeMs - sourceMtimeMs) < 1 &&
            state.analysisSignature == analysisSignature
    }

    /// 存储 BLOB 的 Float32 视图（TS: Float32Array 视图，零拷贝语义）。
    private static func floats(from data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        _ = floats.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return floats
    }

    /// TS: JSON.parse(m.bbox)。
    private static func parseBbox(_ raw: String) -> [Double] {
        guard let value = try? JSONValue.parse(raw), case .array(let items) = value else { return [] }
        return items.compactMap {
            if case .number(let v) = $0 { return v }
            return nil
        }
    }

    /// 文件 stat 三态：ok / missing（ENOENT）/ failed（其他错误，算检测失败）。
    private enum SourceStat {
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

    private static func sourceStat(_ path: String) -> SourceStat {
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
    private static func makeDefaultProvider(config: FaceInferenceConfig) -> FaceInferenceProvider {
        let engine = FaceInferenceEngine(config: config)
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
                FaceInferenceObservation(bbox: $0.bbox, confidence: $0.confidence, embedding: $0.embedding)
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
