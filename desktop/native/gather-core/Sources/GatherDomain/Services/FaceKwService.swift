// desktop/native/gather-core/Sources/GatherDomain/Services/FaceKwService.swift
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
// - 写回（fkw.unbind 的 removeOwnedFaceKeywords、fkw.preview / writeback）
//   经注入的 FaceWritebackProvider 调用；宿主已注入 WritebackService 适配器。
//   S5c-2b-2 起：writeback 执行后按 xmpPath 镜像 deliveries（module=face-keyword），
//   confirm_sync / confirm_cleanup / cleanup 改由 FaceKwDeliveryPort
//   （DeliveryCoordinator）执行。未注入 provider 时 writeback 仍明确抛出
//   WRITEBACK_PROVIDER_NOT_INJECTED，避免误报写回成功。
// - TS 侧 analyze/错误路径会 invalidateSessionLookup（culling 缓存）；Swift
//   侧通过原生挑片页面重新加载 session 数据，保持同进程状态一致。
import Foundation
import GatherAnalysis
import GatherPersistence
import GatherProtocol

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

/// TS: FaceInferenceObservation（face-kw.service.ts 的 face 投影）。
public struct FaceInferenceObservation: Equatable, Sendable {
    public let bbox: [Double]
    public let confidence: Double
    public let embedding: [Double]
    /// 综合质量 [0,1]（FaceQuality.composite；假推理 provider 可用默认值 0）。
    public let quality: Double
    /// bbox 短边像素（PhotoPrism FACE_SIZE 同义）。
    public let faceSizePx: Double
    /// 头部滚转角（度）；无关键点时 0。
    public let rollDegrees: Double
    /// 产出该 embedding 的模型标识/版本（FaceEmbeddingSpec；假推理 provider 可用默认值）。
    public let modelId: String
    public let modelVersion: String

    public init(
        bbox: [Double],
        confidence: Double,
        embedding: [Double],
        quality: Double = 0,
        faceSizePx: Double = 0,
        rollDegrees: Double = 0,
        modelId: String = FaceEncoder.modelId,
        modelVersion: String = FaceEncoder.modelVersion
    ) {
        self.bbox = bbox
        self.confidence = confidence
        self.embedding = embedding
        self.quality = quality
        self.faceSizePx = faceSizePx
        self.rollDegrees = rollDegrees
        self.modelId = modelId
        self.modelVersion = modelVersion
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
/// 最小簇大小的业务上界（D8）：超过它没有实际意义，且能保证 Int 转换安全。
let maxMinClusterSize = 1_000_000

public func validateFaceClusteringParameters(eps: Double, minPts: Double) throws {
    if eps.isNaN || eps.isInfinite || eps < 0 || eps > 1 {
        throw FaceKwServiceError.epsInvalid
    }
    // D8（深审）：除有限/整数外还要有**业务上界** —— 1e30 是有限且整数，
    // 但后续 Int(minPts) 会 trap，且这种规模没有业务含义。
    if minPts.isNaN || minPts.isInfinite || minPts.rounded() != minPts || minPts < 1
        || minPts > Double(maxMinClusterSize) {
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
    /// options 携带"质量核心点门槛 / 二遍核心点阈值"（竞品对标新增，语义见 FaceClusterOptions）。
    /// 末位参数是 Cut 5 / 5c-2 注入的取消检查闭包（B 阶段调用方 = FaceKwService 的
    /// JobAbortSignal；默认实现把它转发进 FaceClusterer 的 DBSCAN 检查点）。
    public typealias FaceClusterProvider = ([EmbeddingEntry], Double, Int, FaceClusterOptions, ((Int, Int) -> Void)?, (() throws -> Void)?) throws -> FaceClusterResult

    /// 聚类调参（竞品对标：PhotoPrism 的 CLUSTER_CORE / CLUSTER_CORE_RETRY）。
    /// 默认 `disabled` 使既有调用语义逐位不变；服务层按 settings 组装具体值。
    public struct FaceClusterOptions: Sendable {
        /// 只有 quality ≥ 此值的点能成为核心点或扩展簇（0 = 不设门槛）。
        /// 低质量点仍可被吸收为边界点——不会从结果里消失，只是不能"带簇"。
        public var coreQualityFloor: Double
        /// 第二遍核心点 minPts（≥ 2；nil = 关闭）。用于恢复被严格首遍漏掉的小簇。
        public var retryMinSamples: Int?

        public static let disabled = FaceClusterOptions(coreQualityFloor: 0, retryMinSamples: nil)

        public init(coreQualityFloor: Double = 0, retryMinSamples: Int? = nil) {
            self.coreQualityFloor = coreQualityFloor
            self.retryMinSamples = retryMinSamples
        }
    }

    /// TS: MAX_PREVIEW_MEMBERS（getClusters 的成员截断窗口）。
    /// 簇卡片携带的成员上限。仓库层已把成员全量取出（ClusterMember 不含缩略图，
    /// 单条约 250 B），12 ≈ 3 KB/簇，远小于一张预览图；上限只影响**载荷裁剪**，
    /// 不影响聚类/合并/绑定语义（按成员计数的地方都在仓库层）。
    private static let maxPreviewMembers = 12

    private let photoRepo: PhotoRepo
    private let sessionRepo: SessionRepo
    private let faceRepo: FaceRepo
    private let personRepo: PersonRepo
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
    /// 交付模型的 faceKeyword 面（S5c-2b-2）：writeback 镜像 + confirm/cleanup 的唯一出口。
    private let delivery: any FaceKwDeliveryPort

    /// TS: controllers（Map<sessionId, AbortController>）。
    private var controllers: [String: JobAbortSignal] = [:]
    private let controllersLock = NSLock()

    /// 同步锁临界区辅助（Swift 6 并发检查：async 上下文不可直接拿 NSLock）。
    private func controller(for sessionId: String) -> JobAbortSignal? {
        controllersLock.lock()
        defer { controllersLock.unlock() }
        return controllers[sessionId]
    }

    private func claimController(_ signal: JobAbortSignal, for sessionId: String) throws {
        controllersLock.lock()
        defer { controllersLock.unlock() }
        guard controllers[sessionId] == nil else { throw FaceKwServiceError.analysisRunning }
        controllers[sessionId] = signal
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
        faceRepo: FaceRepo,
        personRepo: PersonRepo,
        connection: DBConnection,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        getString: @escaping (String, String) -> String = { _, defaultValue in defaultValue },
        decodeProvider: DecodeProvider? = nil,
        inferenceProvider: FaceInferenceProvider? = nil,
        clusterProvider: @escaping FaceClusterProvider = { entries, eps, minPts, options, onProgress, isCancelled in
            try FaceClusterer.clusterEmbeddings(
                entries: entries,
                eps: eps,
                minPts: minPts,
                coreQualityFloor: options.coreQualityFloor,
                retryMinSamples: options.retryMinSamples,
                onProgress: onProgress,
                isCancelled: isCancelled)
        },
        writebackProvider: FaceWritebackProvider? = nil,
        delivery: (any FaceKwDeliveryPort)? = nil
    ) {
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.faceRepo = faceRepo
        self.personRepo = personRepo
        self.connection = connection
        self.getNumber = getNumber
        self.getString = getString
        self.decodeProvider = decodeProvider
        self.inferenceProvider = inferenceProvider
        self.clusterProvider = clusterProvider
        self.writebackProvider = writebackProvider
        // S5c-2b-2 过渡默认：宿主未注入时按同一 connection 自建 coordinator。
        // 文件阶段用文件系统端口（与 CullingService 的 S5c-2a 默认同口径）；
        // 宿主接线后应显式注入共享实例 + XMPDeliveryFilePort（S5c-2b-3）。
        self.delivery = delivery ?? DeliveryCoordinator(
            connection: connection,
            files: FileSystemDeliveryFilePort()
        )
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
            // 线程池，该设置在此保留读取语义（见文件头差异说明）但不消费。
            let encoderInputSize = getNumber("encoder_input_size", 112).safeInt(fallback: 112)
            let embeddingDim = getNumber("embedding_dim", 512).safeInt(fallback: 512)
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
                try connection.transaction {
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
                            _ = try connection.transaction {
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
        let snapshot: (photos: [PhotoProjectionRow], indexSeq: Int) = try connection.transaction {
            (PhotoAssets.collapse(try photoRepo.getBySessionProjection(sessionId: sessionId)),
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

    /// TS: getClusters（fkw.clusters）。成员截断至预览窗口，size 保持精确总数。
    /// 建议字段：matchedPersonId 来自 face_clusters 匹配列，名字按身份批量解析
    /// （解析失败只丢名字，不影响簇清单）。
    public func getClusters(sessionId: String) throws -> [FaceClusterData] {
        let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
        let matchedIds = Array(Set(clusters.compactMap(\.matchedPersonId)))
        let summaries = (try? personRepo.summaries(ids: matchedIds)) ?? [:]
        return clusters.map { cluster in
            let previewMembers = Array((cluster.members ?? []).prefix(Self.maxPreviewMembers))
            return FaceClusterData(
                id: Int(cluster.id),
                sessionId: cluster.sessionId,
                label: cluster.label,
                size: Int(cluster.memberCount),
                status: cluster.status,
                // V1 已删除 face_clusters.thumbnail_base64：DTO 保留为空串，
                // 不再从行读（网格用 members 的 photoPath+bbox 裁切）。
                thumbnailBase64: "",
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
                },
                matchedPersonId: cluster.matchedPersonId,
                matchedPersonName: cluster.matchedPersonId.flatMap { summaries[$0]?.name },
                matchConfidence: cluster.matchConfidence
            )
        }
    }

    // ─────────────────────────── 绑定 / 合并 / 成员 ───────────────────────────

    /// 批量照片的人脸观测计数（photo.id → 数量），供宿主 photo 列表分页附带
    /// faceCount（TS photo.ipc.ts assemblePhotos 的人脸计数小查询下沉）。
    public func faceCounts(sessionId: String, photoIds: [String]) throws -> [String: Int] {
        try faceRepo.countsByPhoto(sessionId: sessionId, photoIds: photoIds)
    }

    /// TS: bindCluster（fkw.bind）。绑定、人工身份约束与人物库在同一事务提交。
    public func bindCluster(sessionId: String, clusterId: Int64, roleName: String, keywords: [String]) throws {
        let clusterSessionId = try faceRepo.getClusterSessionId(clusterId)
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
        try connection.transaction {
            try faceRepo.updateBinding(clusterId: clusterId, roleName: normalizedRoleName, keywords: dedupedKeywords)
        // 身份链接 + 人物库投影 + 跨会话向量入库（单一身份入口 PersonRepo.bindRole
        // 负责 adopt-or-create、照片桥接与 matched_person_id 链接；随后把该簇成员的
        // 观察向量写入 person_embeddings，作为其它会话 analyze/recluster 的匹配库）。
        // 任一身份或向量写入失败会回滚绑定，避免半套身份投影。
            let members = try faceRepo.getClusterMembers(clusterId)
            let outcome = try personRepo.bindRole(
                clusterId: clusterId,
                sessionId: sessionId,
                roleName: normalizedRoleName,
                keywords: dedupedKeywords,
                members: members.map { member in
                    PersonPhotoInput(photoId: member.photoId, faceBbox: member.bbox, confidence: member.confidence)
                }
            )
            if let personId = outcome.personId {
                let feedback = FaceFeedbackRepo(connection: connection)
                for member in members {
                    try feedback.record(sessionId: sessionId, photoId: member.photoId,
                        bbox: member.bbox, personId: personId, confirmed: true, keywords: dedupedKeywords)
                }
                let embeddings = try faceRepo.getClusterMemberEmbeddings(clusterId)
                try personRepo.saveEmbeddings(embeddings: embeddings.map { member in
                    SaveEmbeddingInput(
                        personId: personId,
                        embedding: member.embedding,
                        photoId: member.photoId,
                        sessionId: member.sessionId,
                        faceObservationId: member.observationId
                    )
                })
            }
        }
    }

    /// TS: unbindCluster（fkw.unbind 的服务层步骤；解除绑定并重算人物库）。
    public func unbindCluster(sessionId: String, clusterId: Int64) throws {
        let clusterSessionId = try faceRepo.getClusterSessionId(clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        try connection.transaction {
            let cluster = try faceRepo.getClusters(sessionId, includeMembers: true).first { $0.id == clusterId }
            let repo = FaceFeedbackRepo(connection: connection)
            for member in cluster?.members ?? [] {
                try repo.forgetConfirmation(sessionId: sessionId, photoId: member.photoId,
                    bbox: Self.parseBbox(member.bbox), personId: cluster?.matchedPersonId)
            }
            try faceRepo.deleteBinding(clusterId: clusterId)
            try personRepo.reconcileSession(sessionId: sessionId)
        }

    }

    /// TS: face-kw.ipc.ts fkw.unbind 全流程：确认 → 受保护关键字过滤 →
    /// removeOwnedFaceKeywords（写回）→ unbindCluster。
    public func unbind(sessionId: String, clusterId: Int64, confirmed: Bool) async throws -> FkwUnbindResult {
        guard confirmed else { throw FaceKwServiceError.unbindConfirmRequired }
        guard let writebackProvider else { throw FaceKwServiceError.writebackProviderMissing }
        // getClusters(includeMembers=true) 是一次昂贵的批量读；结果同时用于
        // 目标查找与剩余已绑定集群的扫描（TS 注释 133-135）。
        let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
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
        try unbindCluster(sessionId: sessionId, clusterId: clusterId)
        return FkwUnbindResult(done: true, removedKeywords: removedKeywords)
    }

    /// TS: mergeClusters（fkw.merge）。
    public func mergeClusters(sessionId: String, sourceId: Int64, targetId: Int64) throws {
        if sourceId == targetId { throw FaceKwServiceError.selfMerge }
        let sourceSessionId = try faceRepo.getClusterSessionId(sourceId)
        let targetSessionId = try faceRepo.getClusterSessionId(targetId)
        guard let sourceSessionId, let targetSessionId else { throw FaceKwServiceError.clusterNotFound }
        if sourceSessionId != sessionId || targetSessionId != sessionId {
            throw FaceKwServiceError.clusterNotInSession
        }
        try connection.transaction {
            try faceRepo.mergeClusters(sourceId: sourceId, targetId: targetId)
            try personRepo.reconcileSession(sessionId: sessionId)
            if let target = try faceRepo.getClusters(sessionId, includeMembers: true).first(where: { $0.id == targetId }),
               let binding = target.binding, let personId = target.matchedPersonId {
                let feedback = FaceFeedbackRepo(connection: connection)
                for member in target.members ?? [] {
                    try feedback.record(sessionId: sessionId, photoId: member.photoId,
                        bbox: Self.parseBbox(member.bbox), personId: personId, confirmed: true, keywords: binding.keywords)
                }
            }
        }
    }

    /// TS: removeMember（fkw.remove_member）。
    public func removeMember(sessionId: String, clusterId: Int64, memberId: Int64) throws {
        let clusterSessionId = try faceRepo.getClusterSessionId(clusterId)
        guard let clusterSessionId else { throw FaceKwServiceError.clusterNotFound }
        if clusterSessionId != sessionId { throw FaceKwServiceError.clusterNotInSession }
        try connection.transaction {
            let cluster = try faceRepo.getClusters(sessionId, includeMembers: true).first { $0.id == clusterId }
            guard let member = cluster?.members?.first(where: { $0.id == memberId }) else {
                throw FaceKwServiceError.clusterMemberNotFound
            }
            try FaceFeedbackRepo(connection: connection).record(sessionId: sessionId,
                photoId: member.photoId, bbox: Self.parseBbox(member.bbox),
                personId: cluster?.matchedPersonId, confirmed: false)
            if !(try faceRepo.removeMemberFromCluster(clusterId: clusterId, memberId: memberId)) {
                throw FaceKwServiceError.clusterMemberNotFound
            }
            try personRepo.reconcileSession(sessionId: sessionId)
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
        let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
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
    ///
    /// S5c-2b-2：旧写盘路径不变（provider.execute），执行后按 xmpPath 把结果镜像进
    /// deliveries / delivery_items（module=.faceKeyword，status written/failed，
    /// revision/base 与 Culling 同一规则）。XMP 已落盘：镜像失败不回滚文件，
    /// 只把错误并入返回的 errors。
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
        let result = try await writebackProvider.execute(sessionId: sessionId, items: resolved)
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId, items: resolved, result: result
        )
        guard !mirrorErrors.isEmpty else { return result }
        var merged = result
        merged.errors.append(contentsOf: mirrorErrors)
        return merged
    }

    /// TS: face-kw.ipc.ts fkw.confirm_sync（返回 ok(true)）。
    ///
    /// S5c-2b-2 起由 DeliveryCoordinator 确认（module=.faceKeyword）：
    /// 门禁读 + 单事务推进；不再写 sessions.writeback_status（D-021）。
    /// 错误码保持旧 UI 认得的 XMP_CONFIRM_INCOMPLETE / XMP_CONFIRM_REQUIRES_SYNC /
    /// XMP_CONFIRM_OTHER_SESSION_PENDING（见 confirmDelivery）。
    public func confirmSync(sessionId: String) async throws -> Bool {
        _ = try confirmDelivery(sessionId: sessionId)
        return true
    }

    /// TS: face-kw.ipc.ts fkw.confirm_cleanup / fkw.cleanup。
    ///
    /// S5c-2b-2 起由 DeliveryCoordinator 清理（module=.faceKeyword）：
    /// 外部修改的交付标 conflict、不恢复、不删行；文件/DB 失败保留 intent。
    /// 本域没有 flush/retry_sync 命令，cleanup 是唯一的用户重试入口，因此先回放
    /// 未完成的 intent（失败只记日志，不阻断本次清理）。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> FaceKwCleanupResult {
        guard confirmed else { throw FaceKwServiceError.cleanupConfirmRequired }
        await replayPendingDeliveries(reason: "face_kw cleanup", sessionId: sessionId)
        let summary = try await delivery.cleanupFaceKeyword(sessionId: sessionId)
        return Self.cleanupResult(from: summary)
    }

    // MARK: - 交付（Cut 2 / S5c-2b-2）

    /// confirm 的唯一出口：coordinator 错误 → 旧码。
    private func confirmDelivery(sessionId: String) throws -> DeliveryConfirmSummary {
        let summary: DeliveryConfirmSummary
        do {
            summary = try delivery.confirmFaceKeyword(sessionId: sessionId)
        } catch let error as DeliveryCoordinatorError {
            switch error {
            case .confirmIncomplete(let blockers):
                // 旧码保持可读；阻断项进日志（UI 文案只认码值）。
                GatherLogger.log(
                    "face_kw confirm blocked (\(sessionId)): " + blockers.joined(separator: ","),
                    level: .warn
                )
                throw DeliveryError.confirmIncomplete
            case .reloadNotAcknowledged:
                // §5.4-2：Capture One 未确认重载 → 旧 UI 认得的"还不能收口"码。
                throw DeliveryError.confirmRequiresSync
            default:
                throw error
            }
        }
        if let blocker = summary.unconfirmedSessionIds.first {
            // 本会话 confirmed_at 已先落地；交付留在 written 等对方确认（旧语义）。
            throw DeliveryError.otherSessionNotConfirmed(sessionId: blocker)
        }
        return summary
    }

    /// DeliveryCleanupSummary → 旧 FaceKwCleanupResult（协议/UI 契约不变）。
    /// 外部修改冲突按路径回填 XMP_EXTERNALLY_MODIFIED（旧链路 throw externallyModified
    /// 的同码文案），可重试失败保留在 errors。
    private static func cleanupResult(from summary: DeliveryCleanupSummary) -> FaceKwCleanupResult {
        var errors = summary.errors
        for path in summary.conflictedXmpPaths {
            errors.append(
                MetadataWritebackFailure.from(
                    DeliveryError.externallyModified,
                    xmpPath: path
                ).description
            )
        }
        return FaceKwCleanupResult(deletedCount: summary.deletedCount, errors: errors)
    }

    /// cleanup 前的 intent 回放（本域无 flush 命令）。失败只记日志：
    /// 未完成的 intent 仍由 cleanup 的 INTENT_PENDING 跳过保护，不会静默丢。
    private func replayPendingDeliveries(reason: String, sessionId: String) async {
        do {
            let replay = try await delivery.replayPendingDeliveries()
            for error in replay.errors {
                GatherLogger.log("\(reason) replay (\(sessionId)): \(error)", level: .warn)
            }
        } catch {
            GatherLogger.log("\(reason) replay (\(sessionId)): \(error)", level: .warn)
        }
    }

    /// 写回执行结果 → 交付镜像（S5c-2b-2 过渡双写）。
    ///
    /// S5c-2b-3b-2b-1：状态/属性改读 delivery_items（执行器已把行更新为
    /// written/failed），旧 writeback_items 不再读取；无交付行时按
    /// failedItems + result.written 推断（测试替身/无行场景）。
    /// 基线与备份直接回读 deliveries 行（执行器已落库），不再抄 outbox。
    private func mirrorWritebackOutcome(
        sessionId: String,
        items: [FaceKwWritebackItem],
        result: FaceKwWritebackResult
    ) -> [String] {
        guard !items.isEmpty else { return [] }
        let deliveryRepo = DeliveryRepo(connection: connection)
        var persistedById: [Int64: DeliveryItemRow] = [:]
        let executedIds = Set(items.compactMap(\.id))
        if !executedIds.isEmpty {
            do {
                // 一次按会话读，再按本次执行的 id 收窄（避免逐项 N+1 查询）。
                for row in try deliveryRepo.listItems(sessionId: sessionId, module: .faceKeyword)
                where executedIds.contains(row.id) {
                    persistedById[row.id] = row
                }
            } catch {
                GatherLogger.log(
                    "face_kw writeback mirror: delivery items unavailable (\(sessionId)): \(error)",
                    level: .debug
                )
            }
        }

        var mirrorItems: [DeliveryWritebackMirrorItem] = []
        for item in items {
            // 无 id = 未执行（execute 对无 id 项同样 skipped），不镜像避免谎报写入。
            guard let id = item.id else { continue }
            let row = persistedById[id]
            let failedItem = result.failedItems.first { $0.id == id }
            let status: DeliveryItemStatus
            switch row?.status ?? failedItem?.xmpStatus ?? "" {
            case "written": status = .written
            case "failed": status = .failed
            default:
                if failedItem != nil {
                    status = .failed
                } else if result.written > 0 {
                    status = .written
                } else {
                    continue
                }
            }
            var errorMessage = ""
            if status == .failed {
                errorMessage = [row?.errorMessage, failedItem?.errorMessage]
                    .compactMap { $0 }
                    .first { !$0.isEmpty }
                    ?? result.errors.first {
                        $0.hasPrefix(item.photoPath) || $0.hasPrefix("\(id):")
                    }
                    ?? "WRITEBACK_FAILED"
            }

            let baseline = deliveryWritebackBaseline(connection: connection, xmpPath: item.xmpPath)
            var attributes: [String: JSONValue] = [:]
            var parsedAttributes = false
            if let raw = row?.attributesJSON, !raw.isEmpty {
                do {
                    if case .object(let dict) = try JSONValue.parse(raw) {
                        // keywords 单列写，不重复进 attributes（与 Culling 镜像同口径）。
                        attributes = dict.filter { $0.key != "keywords" }
                        parsedAttributes = true
                    }
                } catch {
                    GatherLogger.log(
                        "face_kw writeback mirror: invalid attributes_json (\(item.xmpPath)): \(error)",
                        level: .debug
                    )
                }
            }
            if !parsedAttributes {
                if let rating = item.attributes?.rating { attributes["rating"] = .number(rating) }
                if let label = item.attributes?.label { attributes["label"] = .string(label) }
            }

            mirrorItems.append(DeliveryWritebackMirrorItem(
                photoId: item.photoId,
                photoPath: item.photoPath,
                xmpPath: item.xmpPath,
                keywords: Self.orderedUnion(item.keywords, item.attributes?.keywords ?? []),
                attributes: attributes,
                status: status,
                errorMessage: errorMessage,
                backupPath: baseline.backupPath.isEmpty ? item.backupPath : baseline.backupPath,
                baseFingerprint: baseline.baseFingerprint,
                baseValues: baseline.baseValues
            ))
        }

        guard !mirrorItems.isEmpty else { return [] }
        do {
            return try delivery.mirrorFaceKeywordWriteback(
                sessionId: sessionId, items: mirrorItems
            ).errors
        } catch {
            return ["DELIVERY_MIRROR_FAILED: \(error)"]
        }
    }

    /// 有序并集（现有在前、新增去重追加），镜像 keywords 用。
    private static func orderedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        var merged: [String] = []
        for value in lhs + rhs where !merged.contains(value) {
            merged.append(value)
        }
        return merged
    }

    // ─────────────────────────── 内部 ───────────────────────────

    // ─────────────── 聚类（Cut 5 / 5c-2：B 锁外纯内存 + C 短事务） ───────────────

    /// A 阶段产出的迁移观察（尚未落库）。
    /// 模型迁移时旧观测必须保留到"全部照片都成功"之后（FaceIdentityArchitectureTests
    /// 的「失败/取消不发布半成品向量」契约）：A 只把结果放在内存，B 用覆盖层参与
    /// 聚类，C 才在同一个短事务里写入。观察 id 用负数临时占位，落库后按
    /// photoId + 序号回填真实 id。
    private struct PreparedObservations {
        let observations: [FaceObservationInput]
        let sourceFileSize: Int64
        let sourceFileMtimeMs: Double
        /// 本次运行的 analysis_signature（0 张脸时 observations.first 为空，不能从输入反推）。
        let analysisSignature: String
        let complete: Bool
    }

    /// B 阶段的一次性只读快照：observations + feedback + 已有簇（含成员/绑定）
    /// + 人工反馈引用的人物行。读取在同一个读事务内完成；事务结束即释放连接锁，
    /// 随后的聚类是纯内存计算（不持 DB 锁）。
    private struct ClusterReadSnapshot {
        let observations: [FaceObservationRow]
        let feedback: [FaceIdentityFeedback]
        let clusters: [FaceClusterRow]
        let personRows: [String: PersonRow]
    }

    /// 聚类输入的统一视图（DB 行或 A 阶段待提交的迁移观察）。
    private struct ClusterObservation {
        let id: Int64
        let photoId: String
        let bbox: [Double]
        let confidence: Double
        let quality: Double
        let embedding: [Float]
        let analysisSignature: String
    }

    /// 角色绑定迁移的只读投影（Persistence 的 FaceBindingDetail 没有公开构造器，
    /// 服务层从"已有簇（含绑定）"快照里自行组装；也省掉 getBindingsBySession 的
    /// 两次额外查询）。
    private struct ClusterBindingSnapshot {
        let clusterId: Int64
        let roleName: String
        let keywords: [String]
        let memberPhotoIds: [String]
    }

    /// 人工确认簇在 C 阶段要写的绑定（人物名/关键词在 B 阶段一次读完）。
    private struct ManualBindingWrite {
        let index: Int
        let personId: String
        let roleName: String
        let keywords: [String]
    }

    /// 全量路径的 C 阶段输入（B 内算完，C 只落库）。
    private struct FullClusterPlan {
        let clusterInputs: [FaceClusterInput]
        /// 每个新簇的查询向量集合（外层按簇、内层按成员）。
        let embeddingsByCluster: [[[Float]]]
        let manualBindings: [ManualBindingWrite]
        let previousBindings: [ClusterBindingSnapshot]
        let feedbackWasEmpty: Bool
    }

    /// B/C 共用入口：读快照（一个读事务）→ 纯内存聚类 → C 短事务落库。
    ///
    /// 失败边界（审计 §4.3/§4.4）：
    /// - A 已提交的照片级观测/状态保留（checkpoint = face_analysis_state）；
    /// - B 失败不改簇；只清 cluster_signature，避免下次把旧簇误判为最新；
    /// - C 的 index_seq 守卫失败 / 取消 → 整个 C 事务回滚，不留半套簇。
    private func clusterStoredObservations(
        sessionId: String,
        photos: [PhotoProjectionRow],
        indexSeq: Int,
        eps: Double,
        minPts: Int,
        options: FaceClusterOptions,
        signature: String,
        signal: JobAbortSignal?,
        clearOnEmpty: Bool,
        incremental: Bool = false,
        prepared: [String: PreparedObservations] = [:],
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws {
        do {
            try runClusterStoredObservations(
                sessionId: sessionId, photos: photos, indexSeq: indexSeq, eps: eps,
                minPts: minPts, options: options, signature: signature, signal: signal,
                clearOnEmpty: clearOnEmpty, incremental: incremental,
                prepared: prepared, onProgress: onProgress)
        } catch {
            // A 与 C 之间失败的统一失效：观测可能已是新的，簇还是旧的；签名必须清空，
            // 否则下一次 analyze 的 "photosNeedingAnalysis.isEmpty && signatureMatches"
            // 快路径会永远跳过重聚类。
            try? faceRepo.clearClusterSignature(sessionId: sessionId)
            throw error
        }
    }

    private func runClusterStoredObservations(
        sessionId: String,
        photos: [PhotoProjectionRow],
        indexSeq: Int,
        eps: Double,
        minPts: Int,
        options: FaceClusterOptions,
        signature: String,
        signal: JobAbortSignal?,
        clearOnEmpty: Bool,
        incremental: Bool,
        prepared: [String: PreparedObservations],
        onProgress: ((Int, Int) -> Void)?
    ) throws {
        if signal?.aborted ?? false { throw JobCancelledError() }
        let cancelCheck: (() throws -> Void)? = signal.map { signal in
            { if signal.aborted { throw JobCancelledError() } }
        }
        let snapshot = try readClusterSnapshot(sessionId: sessionId)
        let (observations, tempIdsByPhoto) = Self.clusterObservations(
            snapshot.observations, photos: photos, prepared: prepared)
        let spaces = Set(observations.map {
            FaceIdentityPolicy.modelSpace(analysisSignature: $0.analysisSignature)
        })
        guard spaces.count <= 1 else {
            throw DBError.message("当前工作区包含不同人脸模型的向量，请先完成全量人脸分析")
        }
        let modelSpace = spaces.first
        let feedbackByPhoto = Dictionary(grouping: snapshot.feedback, by: \.photoId)
        let observationById = Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) })
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })

        var entries: [EmbeddingEntry] = []
        for observation in observations {
            if observation.embedding.contains(where: { $0 != 0 }) {
                entries.append(EmbeddingEntry(
                    observationId: Int(observation.id),
                    photoId: observation.photoId,
                    embedding: observation.embedding,
                    // quality ≤ 0 = v34 迁移的旧行（或注入式假推理未提供质量）：按"不设限"
                    // 处理，否则升级后旧库会被质量门槛整库判成噪声；真实质量分恒 > 0。
                    quality: observation.quality > 0 ? observation.quality : 1))
            }
        }

        // 增量资格在 run 开始时的状态上判定（signatureMatches / hasClusters 取分析前
        // 的快照）：设置开启 + 聚类签名未变 + 库里已有簇 + 本次分析没有整体失败。
        // recluster 命令恒走全量。约束检查与旧实现逐行相同。
        let constraintsPermitIncremental = snapshot.feedback.allSatisfy { correction in
            guard correction.decision == "confirmed" else { return false }
            let matchingObservations = observations.filter {
                $0.photoId == correction.photoId && FaceIdentityPolicy.overlap(
                    $0.bbox, correction.bbox) >= 0.5
            }
            return matchingObservations.allSatisfy { observation in
                snapshot.clusters.contains { cluster in
                    cluster.matchedPersonId == correction.personId &&
                    (cluster.members ?? []).contains { $0.observationId == observation.id }
                }
            }
        }
        if incremental && !entries.isEmpty && constraintsPermitIncremental {
            try commitIncrementalClusters(
                sessionId: sessionId, indexSeq: indexSeq, signature: signature,
                entries: entries, observationById: observationById, photoById: photoById,
                existingRows: snapshot.clusters, modelSpace: modelSpace,
                eps: eps, minPts: minPts, options: options, signal: signal,
                cancelCheck: cancelCheck, onProgress: onProgress)
            return
        }

        // 全量：自动/人工确认/待复核分类（与旧实现逐行相同）。
        var automatic: [EmbeddingEntry] = []
        var confirmed: [String: [EmbeddingEntry]] = [:]
        var review: [[EmbeddingEntry]] = []
        for entry in entries {
            guard let observation = observationById[Int64(entry.observationId)] else { continue }
            let decisions = (feedbackByPhoto[entry.photoId] ?? []).filter {
                FaceIdentityPolicy.overlap($0.bbox, observation.bbox) >= 0.5
            }
            if let identity = decisions.last(where: { $0.decision == "confirmed" })?.personId {
                confirmed[identity, default: []].append(entry)
            } else if decisions.contains(where: { $0.decision == "rejected" }) {
                // Keep the face visible for reassignment, but never silently restore a rejected label.
                review.append([entry])
            } else { automatic.append(entry) }
        }
        // B：聚类计算在连接锁之外执行（isCancelled 注入到 DBSCAN 内）。
        let clustered = try clusterProvider(
            automatic, eps, minPts, options, onProgress, cancelCheck)
        let manualIds = confirmed.keys.sorted()
        let automaticClusters = clustered.clusters.filter { !$0.isEmpty }
        let resolvedClusters = automaticClusters + manualIds.compactMap { confirmed[$0] } + review
        let manualOffset = automaticClusters.count
        if signal?.aborted ?? false { throw JobCancelledError() }

        let clusterInputs = resolvedClusters.enumerated().map { index, cluster in
            FaceClusterInput(
                label: "Person \(index + 1)",
                members: cluster.map { entry in
                    memberInput(for: entry, observationById: observationById, photoById: photoById)
                }
            )
        }
        // 人工绑定所需的 person.name / keywords 也来自 B 的快照（C 内零读取）。
        var manualBindings: [ManualBindingWrite] = []
        for (offset, personId) in manualIds.enumerated() {
            guard let person = snapshot.personRows[personId] else { continue }
            let keywords = snapshot.feedback.last(where: {
                $0.personId == personId && $0.decision == "confirmed"
            })?.keywords ?? Self.parseKeywords(person.keywords)
            manualBindings.append(ManualBindingWrite(
                index: manualOffset + offset, personId: personId,
                roleName: person.name, keywords: keywords))
        }
        let plan = FullClusterPlan(
            clusterInputs: clusterInputs,
            embeddingsByCluster: resolvedClusters.map { $0.map(\.embedding) },
            manualBindings: manualBindings,
            previousBindings: Self.bindings(from: snapshot.clusters),
            feedbackWasEmpty: snapshot.feedback.isEmpty)
        try commitFullClusters(
            sessionId: sessionId, indexSeq: indexSeq, signature: signature, plan: plan,
            photos: photos, prepared: prepared, tempIdsByPhoto: tempIdsByPhoto,
            clearOnEmpty: clearOnEmpty, signal: signal, modelSpace: modelSpace)
    }

    /// B 阶段读快照（唯一读事务；不包含任何写）。
    private func readClusterSnapshot(sessionId: String) throws -> ClusterReadSnapshot {
        try connection.transaction {
            let observations = try faceRepo.getObservations(sessionId)
            let feedback = try FaceFeedbackRepo(connection: connection).list(sessionId: sessionId)
            let clusters = try faceRepo.getClusters(sessionId, includeMembers: true)
            // 人工确认簇要在 C 里写 role_name/keywords：person 行（含 keywords）在
            // 读事务内一次取齐，B/C 都不再回读。确认身份通常个位数，逐条 get 可接受。
            let personIds = Set(feedback.filter { $0.decision == "confirmed" }.compactMap(\.personId))
            var personRows: [String: PersonRow] = [:]
            for personId in personIds {
                if let row = try personRepo.get(id: personId) { personRows[personId] = row }
            }
            return ClusterReadSnapshot(
                observations: observations, feedback: feedback,
                clusters: clusters, personRows: personRows)
        }
    }

    /// DB 行 + A 阶段迁移观察的合并视图。迁移照片的旧行被覆盖层替换；覆盖层追加在
    /// 未变化行之后（旧实现先 replace 再 getObservations，新行 id 恒更大），并分配
    /// 负数临时 id 供 C 回填。
    private static func clusterObservations(
        _ rows: [FaceObservationRow],
        photos: [PhotoProjectionRow],
        prepared: [String: PreparedObservations]
    ) -> (observations: [ClusterObservation], tempIdsByPhoto: [String: [Int64]]) {
        var observations: [ClusterObservation] = []
        observations.reserveCapacity(rows.count)
        for row in rows where prepared[row.photoId] == nil {
            observations.append(ClusterObservation(
                id: row.id,
                photoId: row.photoId,
                bbox: [row.bboxX, row.bboxY, row.bboxW, row.bboxH],
                confidence: row.confidence,
                quality: row.quality,
                embedding: floats(from: row.embedding),
                analysisSignature: row.analysisSignature))
        }
        var tempIdsByPhoto: [String: [Int64]] = [:]
        var nextTempId: Int64 = -1
        for photo in photos {
            guard let item = prepared[photo.id] else { continue }
            var tempIds: [Int64] = []
            tempIds.reserveCapacity(item.observations.count)
            for input in item.observations {
                let tempId = nextTempId
                nextTempId -= 1
                tempIds.append(tempId)
                observations.append(ClusterObservation(
                    id: tempId,
                    photoId: input.photoId,
                    bbox: [input.bboxX, input.bboxY, input.bboxW, input.bboxH],
                    confidence: input.confidence,
                    quality: input.quality,
                    embedding: input.embedding,
                    analysisSignature: input.analysisSignature ?? item.analysisSignature))
            }
            tempIdsByPhoto[photo.id] = tempIds
        }
        return (observations, tempIdsByPhoto)
    }

    /// 已有簇（含绑定）→ 绑定迁移快照。
    private static func bindings(from clusters: [FaceClusterRow]) -> [ClusterBindingSnapshot] {
        clusters.compactMap { cluster in
            guard let binding = cluster.binding else { return nil }
            return ClusterBindingSnapshot(
                clusterId: cluster.id,
                roleName: binding.roleName,
                keywords: binding.keywords,
                memberPhotoIds: (cluster.members ?? []).map(\.photoId))
        }
    }

    /// C 阶段（全量）：一个短事务落库 + 一个 best-effort 的身份/匹配阶段。
    private func commitFullClusters(
        sessionId: String,
        indexSeq: Int,
        signature: String,
        plan: FullClusterPlan,
        photos: [PhotoProjectionRow],
        prepared: [String: PreparedObservations],
        tempIdsByPhoto: [String: [Int64]],
        clearOnEmpty: Bool,
        signal: JobAbortSignal?,
        modelSpace: String?
    ) throws {
        let pathById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.filepath) })
        var newClusterIds: [Int64] = []
        try connection.transaction {
            guard try sessionRepo.getIndexSeq(id: sessionId) == indexSeq else {
                throw DBError.message("工作区内容已变化，请重新运行人脸分析")
            }
            if signal?.aborted ?? false { throw JobCancelledError() }

            // 迁移观察在 C 内落库：任一步失败整事务回滚，旧观测/旧簇/旧绑定保持原样。
            var realIdByTemp: [Int64: Int64] = [:]
            for photoId in prepared.keys.sorted() {
                guard let result = prepared[photoId], let path = pathById[photoId],
                      case let .ok(size, mtime) = Self.sourceStat(path),
                      size == result.sourceFileSize, mtime == result.sourceFileMtimeMs else {
                    throw DBError.message("分析期间原始照片已变化，请重新运行人脸分析")
                }
                let ids = try faceRepo.replaceObservationsByPhoto(
                    sessionId: sessionId, photoId: photoId, observations: result.observations)
                if result.complete {
                    try faceRepo.upsertAnalysisState(
                        sessionId: sessionId, photoId: photoId,
                        sourceFileSize: result.sourceFileSize,
                        sourceFileMtimeMs: result.sourceFileMtimeMs,
                        analysisSignature: result.analysisSignature)
                }
                for (index, tempId) in (tempIdsByPhoto[photoId] ?? []).enumerated() where index < ids.count {
                    realIdByTemp[tempId] = ids[index]
                }
            }

            if plan.clusterInputs.isEmpty {
                // 分析成功但无脸时不应留下陈旧集群；全失败 run 则保留（TS 注释）。
                if clearOnEmpty {
                    _ = try connection.prepare("DELETE FROM face_cluster_members WHERE session_id = ?").run([.text(sessionId)])
                    _ = try connection.prepare("DELETE FROM face_clusters WHERE session_id = ? AND id NOT IN (SELECT cluster_id FROM role_bindings)").run([.text(sessionId)])
                }
                try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
                return
            }

            // 幂等重放（Cut 5 / 5c-2）：目标状态与库中现有簇逐行一致时只推进签名。
            // recluster 同参数重跑不再"删全表重插"（簇 id / 绑定 / UI 选中都不抖动）；
            // 成员或反馈变化时走下面的替换路径（旧语义不变）。
            if prepared.isEmpty, plan.feedbackWasEmpty,
               let current = try? faceRepo.getClusters(sessionId, includeMembers: true),
               Self.clusterRowsMatch(plan.clusterInputs, current) {
                try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
                newClusterIds = current.map(\.id)
                return
            }

            // 新结果就绪才替换旧集群（TS 注释 689-693）：用户绑定的角色经成员
            // 重叠迁移，否则重新聚类后绑定会静默消失。删旧 + 建新 + 迁移同事务，
            // 避免中途失败留下半套簇（审计 P1「聚类替换非原子」）。
            try faceRepo.deleteClustersBySession(sessionId)
            let resolvedInputs = plan.clusterInputs.map { input in
                FaceClusterInput(
                    label: input.label,
                    members: input.members.map { member in
                        FaceClusterMemberInput(
                            photoId: member.photoId,
                            photoPath: member.photoPath,
                            bbox: member.bbox,
                            confidence: member.confidence,
                            // 迁移观察的临时 id 在同一个事务里已回填为真实行 id。
                            observationId: member.observationId.flatMap { realIdByTemp[$0] ?? $0 })
                    })
            }
            let ids = try faceRepo.saveClusters(sessionId: sessionId, clusters: resolvedInputs)
            if plan.feedbackWasEmpty && !plan.previousBindings.isEmpty {
                let membersByCluster = ids.enumerated().map { index, clusterId in
                    (
                        clusterId: clusterId,
                        photoIds: Set(
                            plan.clusterInputs[index].members.map(\.photoId).filter { !$0.isEmpty }
                        )
                    )
                }
                migrateBindings(plan.previousBindings, newMembers: membersByCluster)
            }
            for manual in plan.manualBindings where manual.index < ids.count {
                try faceRepo.updateBinding(
                    clusterId: ids[manual.index], roleName: manual.roleName,
                    keywords: manual.keywords)
                try faceRepo.setClusterMatch(
                    clusterId: ids[manual.index], personId: manual.personId, confidence: 1)
            }
            let restoredNames = Set(try faceRepo.getBindingsBySession(sessionId).map(\.roleName))
            for binding in plan.previousBindings where !restoredNames.contains(binding.roleName) {
                let orphan = try faceRepo.saveClusters(sessionId: sessionId, clusters: [
                    FaceClusterInput(label: binding.roleName, members: [])
                ])[0]
                try faceRepo.updateBinding(clusterId: orphan, roleName: binding.roleName, keywords: binding.keywords)
            }
            try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
            newClusterIds = ids
        }

        // C2（txn2，best-effort）：身份投影 + 跨会话重识别都不再决定本次分析成败。
        // 旧实现把两者放在分析事务里，匹配建议写失败会连带回滚整批簇；阶段化后
        // 落库已完成，失败只记日志（下次重算可复原，与增量路径同口径）。
        try reconcileAndMatch(
            sessionId: sessionId,
            clusters: newClusterIds.enumerated().map { index, clusterId in
                (clusterId: clusterId, embeddings: plan.embeddingsByCluster[index])
            },
            modelSpace: modelSpace,
            reconcileEvenWhenEmpty: plan.clusterInputs.isEmpty)
    }

    /// C2：身份投影（短事务）+ 跨库匹配（读/算/写各自短语句，不持长事务）。
    private func reconcileAndMatch(
        sessionId: String,
        clusters: [(clusterId: Int64, embeddings: [[Float]])],
        modelSpace: String?,
        reconcileEvenWhenEmpty: Bool
    ) throws {
        if reconcileEvenWhenEmpty || !clusters.isEmpty {
            do {
                try connection.transaction {
                    try personRepo.reconcileSession(sessionId: sessionId)
                }
            } catch {
                GatherLogger.log(
                    "Face analysis: person reconciliation failed (best-effort) \(error)",
                    level: .warn)
            }
        }
        guard !clusters.isEmpty else { return }
        do {
            try matchClustersAgainstLibrary(
                sessionId: sessionId, clusters: clusters, modelSpace: modelSpace)
        } catch {
            GatherLogger.log(
                "Face analysis: cross-session match failed (best-effort) \(error)", level: .warn)
        }
    }

    /// 目标簇与库中现有簇逐行一致（标签 + 成员顺序 + 照片/观察 id/置信度）。
    /// 只用于 C 的幂等重放判定：不一致时必须走完整替换，不能跳过绑定迁移。
    private static func clusterRowsMatch(
        _ inputs: [FaceClusterInput],
        _ rows: [FaceClusterRow]
    ) -> Bool {
        guard inputs.count == rows.count else { return false }
        for (input, row) in zip(inputs, rows) {
            let members = row.members ?? []
            guard row.label == input.label, members.count == input.members.count else { return false }
            for (expected, actual) in zip(input.members, members) {
                guard actual.photoId == expected.photoId,
                      actual.observationId == expected.observationId,
                      actual.confidence == expected.confidence else { return false }
            }
        }
        return true
    }

    /// 增量聚类落库（analyze 且 face_incremental_clustering = "1"、签名未变、
    /// 库里已有簇时）。语义：
    /// - 已有簇行、id、matched_person_id、role_bindings 一律保留（不删不重建，
    ///   因此用户绑定不会像全量那样被冲掉）；
    /// - 本次读到、且未被任何已有簇成员引用的观测是"新增/变化"集合：命中某簇质心
    ///   的追加为该簇成员，未命中的只对彼此跑全量同参 DBSCAN 产出新簇；
    /// - 引用已消失观测的"幽灵成员行"在**落库事务内**清理（删除推迟到最后，取消
    ///   不落库）：重推理会替换观察行（新 id），不清理会让同一张照片同时留下旧成员
    ///   行与新成员行（簇大小虚高），而全量路径本来就会丢弃这些行；
    /// - 跨会话身份匹配只对新簇做，已有簇的 matched_person_id 不重算；
    ///   person_photos 由 reconcileSession 按绑定+成员幂等重放（best-effort）。
    ///
    /// Cut 5 / 5c-2：质心匹配 + 未命中集合 DBSCAN 全部在事务之外（B）；C 的落库
    /// 事务以 index_seq 守卫开头、同事务写签名；身份桥接/跨库匹配降级为 txn2
    /// best-effort（失败只记日志，不回滚已提交的簇）。
    private func commitIncrementalClusters(
        sessionId: String,
        indexSeq: Int,
        signature: String,
        entries: [EmbeddingEntry],
        observationById: [Int64: ClusterObservation],
        photoById: [String: String],
        existingRows: [FaceClusterRow],
        modelSpace: String?,
        eps: Double,
        minPts: Int,
        options: FaceClusterOptions,
        signal: JobAbortSignal?,
        cancelCheck: (() throws -> Void)?,
        onProgress: ((Int, Int) -> Void)?
    ) throws {
        if signal?.aborted ?? false { throw JobCancelledError() }
        let entryByObservationId = Dictionary(
            uniqueKeysWithValues: entries.map { (Int64($0.observationId), $0) })

        // 1) 已有簇及其"现存"成员（observation_id 仍在当前观察集合 → 转 EmbeddingEntry）；
        //    引用 NULL/已消失观察的成员行收集为幽灵，随后在落库事务内一并删除。
        //    同一观察只会被一个簇认领（covered），重复成员行按幽灵处理。
        var covered = Set<Int64>()
        var ghostMemberIds: [Int64] = []
        var existing: [(clusterId: Int, entries: [EmbeddingEntry])] = []
        for row in existingRows {
            var members: [EmbeddingEntry] = []
            for member in row.members ?? [] {
                guard let observationId = member.observationId,
                      let entry = entryByObservationId[observationId],
                      covered.insert(observationId).inserted
                else {
                    ghostMemberIds.append(member.id)
                    continue
                }
                members.append(entry)
            }
            existing.append((clusterId: Int(row.id), entries: members))
        }
        let newEntries = entries.filter { !covered.contains(Int64($0.observationId)) }
        if newEntries.isEmpty {
            // 没有新增观测就不需要聚类；只有确有幽灵行时才落一次清理事务。
            guard !ghostMemberIds.isEmpty else { return }
            if signal?.aborted ?? false { throw JobCancelledError() }
            try connection.transaction {
                guard try sessionRepo.getIndexSeq(id: sessionId) == indexSeq else {
                    throw DBError.message("工作区内容已变化，请重新运行人脸分析")
                }
                try deleteClusterMembers(ids: ghostMemberIds)
                try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
            }
            return
        }

        // B：质心匹配 + 未命中集合 DBSCAN（连接锁外；isCancelled 注入）。
        let incremental = try FaceClusterer.assignIncrementally(
            existingClusters: existing,
            newEntries: newEntries,
            eps: eps,
            minPts: minPts,
            coreQualityFloor: options.coreQualityFloor,
            retryMinSamples: options.retryMinSamples,
            // 歧义不猜：与 matchClustersAgainstLibrary 的 face_match_margin 同源同语义，
            // 冠军/亚军近似并列时宁可另立新簇，也不把脸塞进可能错误的人。
            ambiguityMargin: max(0, getNumber("face_match_margin", 0.01)),
            onProgress: onProgress,
            isCancelled: cancelCheck)
        if signal?.aborted ?? false { throw JobCancelledError() }

        // 2) 落库：清理幽灵成员 + 追加新成员 + 建新簇（同一事务）。已有簇行与其
        //    绑定/匹配列不动。
        var appendedMembers: [(clusterId: Int64, members: [FaceClusterMemberInput])] = []
        var newClusters: [FaceClusterInput] = []
        var newClusterEntries: [[EmbeddingEntry]] = []
        let labelBase = existingRows.count
        for assignment in incremental.assignments {
            let members = assignment.entries.map {
                memberInput(for: $0, observationById: observationById, photoById: photoById)
            }
            if let clusterId = assignment.clusterId {
                appendedMembers.append((Int64(clusterId), members))
            } else {
                newClusters.append(FaceClusterInput(
                    label: "Person \(labelBase + newClusters.count + 1)", members: members))
                newClusterEntries.append(assignment.entries)
            }
        }
        var createdClusterIds: [Int64] = []
        try connection.transaction {
            guard try sessionRepo.getIndexSeq(id: sessionId) == indexSeq else {
                throw DBError.message("工作区内容已变化，请重新运行人脸分析")
            }
            if signal?.aborted ?? false { throw JobCancelledError() }
            if !ghostMemberIds.isEmpty {
                try deleteClusterMembers(ids: ghostMemberIds)
            }
            if !appendedMembers.isEmpty {
                let insertMember = try connection.prepare("""
                    INSERT INTO face_cluster_members
                     (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
                     VALUES (?, ?, ?, ?, ?, ?)
                    """)
                for item in appendedMembers {
                    for member in item.members {
                        let bboxJSON = try JSONValue.stringify(
                            JSONValue.array(member.bbox.map { JSONValue.real($0) }))
                        _ = try insertMember.run([
                            .int(item.clusterId),
                            .text(sessionId),
                            .text(member.photoId),
                            .text(bboxJSON),
                            .real(member.confidence),
                            optDB(member.observationId),
                        ])
                    }
                }
            }
            if !newClusters.isEmpty {
                createdClusterIds = try faceRepo.saveClusters(sessionId: sessionId, clusters: newClusters)
            }
            try faceRepo.upsertClusterSignature(sessionId: sessionId, signature: signature)
        }

        // 3) 身份桥接与跨会话建议只针对新簇；已有簇的 matched_person_id 不被覆盖。
        //    Best-effort：落库已完成，桥接失败只记日志（下次重算可复原）。
        try reconcileAndMatch(
            sessionId: sessionId,
            clusters: createdClusterIds.enumerated().map { index, clusterId in
                (clusterId: clusterId, embeddings: newClusterEntries[index].map(\.embedding))
            },
            modelSpace: modelSpace,
            reconcileEvenWhenEmpty: true)
    }

    /// 增量成员落库输入（bbox/confidence 取自观察行；照片路径缺失回落空串，同全量）。
    private func memberInput(
        for entry: EmbeddingEntry,
        observationById: [Int64: ClusterObservation],
        photoById: [String: String]
    ) -> FaceClusterMemberInput {
        let observation = observationById[Int64(entry.observationId)]
        return FaceClusterMemberInput(
            photoId: entry.photoId,
            photoPath: photoById[entry.photoId] ?? "",
            bbox: observation?.bbox ?? [0, 0, 0, 0],
            confidence: observation?.confidence ?? 0,
            observationId: Int64(entry.observationId))
    }

    /// 按成员行 id 删除（幽灵成员清理；分批防 SQLite 参数上限）。
    private func deleteClusterMembers(ids: [Int64]) throws {
        for chunk in ids.chunked(by: 400) where !chunk.isEmpty {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare(
                "DELETE FROM face_cluster_members WHERE id IN (\(placeholders))"
            ).run(chunk.map { .int($0) })
        }
    }

    /// 人员匹配兜底阈值（与 persons.match_threshold 列默认值 0.65 一致）。
    static let defaultPersonMatchThreshold = 0.65

    /// 跨会话重识别：把新簇的成员向量与 person_embeddings 库比对，写入建议
    /// （face_clusters.matched_person_id / match_confidence）。
    /// - 已绑定的簇（matched_person_id 非空，含刚迁移回来的绑定）不被建议覆盖；
    /// - 阈值取该人物自己的 persons.match_threshold，取不到用 0.65；
    /// - 库为空、维度不一致或没有合格候选时静默跳过（建议是可选增强，
    ///   不是分析结果的必要条件）。
    ///
    /// Cut 5 / 5c-1（去 N+1）：旧实现簇循环内每簇 1 次 getClusterMembers + 1 次
    /// FaceFeedbackRepo.list（2C 次查询）、每条 query 重扫库并重算库行范数。现在：
    /// - 成员一次批量读（getClusterMatchRows 的簇+成员 LEFT JOIN，800 分块 IN）；
    /// - feedback 一次 list，rejected 集合在簇循环外按成员 bbox 算好；
    /// - 一个 FaceMatcher 实例做一次批量 match(clusters:)，库/范数只准备一次。
    ///
    /// Cut 5 / 5c-2：modelSpace 由 B 阶段快照传入（不再为取模型空间重读全表
    /// observations）；固定 SELECT = 4（库向量 / 簇+成员 / feedback / 人物阈值），
    /// 与簇数无关（C ≤ 800；FaceMatcherBatchTests / FaceKwMatchBatchTests 守门）。
    /// 未传 modelSpace 时保留旧的自省路径（直接调用方/测试兼容）。
    /// internal（非 private）仅为 @testable 查询计数守门；生产调用点在本文件。
    func matchClustersAgainstLibrary(
        sessionId: String,
        clusters: [(clusterId: Int64, embeddings: [[Float]])],
        modelSpace: String? = nil
    ) throws {
        guard !clusters.isEmpty else { return }
        let resolvedSpace: String
        if let modelSpace {
            guard !modelSpace.isEmpty else { return }
            resolvedSpace = modelSpace
        } else {
            let spaces = Set(try faceRepo.getObservations(sessionId).map {
                FaceIdentityPolicy.modelSpace(analysisSignature: $0.analysisSignature)
            })
            guard spaces.count == 1, let space = spaces.first, !space.isEmpty else { return }
            resolvedSpace = space
        }
        let library = try personRepo.getAllEmbeddings(modelSpace: resolvedSpace).compactMap { ref -> LibraryEmbedding? in
            let floats = Self.floats(from: ref.embedding)
            guard !floats.isEmpty else { return nil }
            return LibraryEmbedding(personId: ref.personId, embedding: floats)
        }
        guard let libraryDim = library.first?.embedding.count else { return }
        let usable = library.filter { $0.embedding.count == libraryDim }

        // 成员一次批量读：簇匹配状态 + 成员几何来自同一条 LEFT JOIN（无成员的簇也有
        // 一行，memberPhotoId == nil），不再经过 getClusters 的簇/成员/绑定三次查询。
        let matchRows = try faceRepo.getClusterMatchRows(
            sessionId: sessionId, clusterIds: clusters.map(\.clusterId))
        var membersByCluster: [Int64: [(photoId: String, bbox: String)]] = [:]
        var linkedClusterIds = Set<Int64>()
        for row in matchRows {
            if row.matchedPersonId != nil { linkedClusterIds.insert(row.clusterId) }
            if let photoId = row.memberPhotoId {
                membersByCluster[row.clusterId, default: []].append(
                    (photoId: photoId, bbox: row.memberBbox))
            }
        }
        // feedback 一次读（旧实现簇循环内每簇重读整表）。
        let feedback = try FaceFeedbackRepo(connection: connection).list(sessionId: sessionId)
        let rejectedByPhoto = Dictionary(
            grouping: feedback.filter { $0.decision == "rejected" }, by: \.photoId)

        let summaries = (try? personRepo.summaries(ids: Array(Set(usable.map(\.personId))))) ?? [:]
        let thresholds = summaries.mapValues(\.matchThreshold)
        let margin = max(0, getNumber("face_match_margin", 0.01))

        // 簇循环只做内存过滤：已绑定跳过、rejected 集合、维度过滤。
        var queries: [FaceMatchCluster] = []
        queries.reserveCapacity(clusters.count)
        for cluster in clusters where !linkedClusterIds.contains(cluster.clusterId) {
            let members = membersByCluster[cluster.clusterId] ?? []
            var rejected = Set<String>()
            var rejectsWholeCluster = false
            for member in members {
                let bbox = Self.parseBbox(member.bbox)
                for correction in rejectedByPhoto[member.photoId] ?? []
                    where FaceIdentityPolicy.overlap(bbox, correction.bbox) >= 0.5 {
                    guard let personId = correction.personId else {
                        // 无 personId 的 rejected（"不是人脸"）整簇不猜（旧行为 continue）。
                        rejectsWholeCluster = true
                        break
                    }
                    rejected.insert(personId)
                }
                if rejectsWholeCluster { break }
            }
            if rejectsWholeCluster { continue }
            let embeddings = cluster.embeddings.filter { $0.count == libraryDim }
            guard !embeddings.isEmpty else { continue }
            queries.append(FaceMatchCluster(
                clusterId: cluster.clusterId,
                embeddings: embeddings,
                excludedPersonIds: rejected))
        }
        guard !queries.isEmpty else { return }

        let matcher = FaceMatcher(library: usable)
        let decisions = try matcher.match(
            clusters: queries,
            thresholds: thresholds,
            defaultThreshold: Self.defaultPersonMatchThreshold,
            margin: margin)
        for decision in decisions {
            guard case let .accepted(personId, score) = decision.decision else { continue }
            try faceRepo.setClusterMatch(
                clusterId: decision.clusterId, personId: personId, confidence: score)
        }
    }

    private static func parseKeywords(_ raw: String) -> [String] {
        (try? JSONValue.parse(raw))?.arrayElements?.compactMap(\.stringValue) ?? []
    }

    private func captureManualIdentityFeedback(sessionId: String) throws {
        let repo = FaceFeedbackRepo(connection: connection)
        let recorded = try repo.list(sessionId: sessionId)
        for cluster in try faceRepo.getClusters(sessionId, includeMembers: true) {
            guard let binding = cluster.binding else { continue }
            let personId = try cluster.matchedPersonId ?? personRepo.upsertByName(name: binding.roleName)
            try faceRepo.setClusterMatch(clusterId: cluster.id, personId: personId, confidence: 1)
            for member in cluster.members ?? [] {
                let bbox = Self.parseBbox(member.bbox)
                guard !recorded.contains(where: {
                    $0.photoId == member.photoId && FaceIdentityPolicy.overlap($0.bbox, bbox) >= 0.5
                }) else { continue }
                try repo.record(sessionId: sessionId, photoId: member.photoId,
                                bbox: bbox, personId: personId, confirmed: true, keywords: binding.keywords)
            }
        }
    }

    /// TS: migrateBindings —— 按照片 id 重叠度把角色绑定挂回新集群；重叠降序
    /// 认领（竞争由更优匹配者获胜）；消失的脸对应的绑定被丢弃。Best-effort：
    /// 迁移失败不得使分析本身失败。
    private func migrateBindings(
        _ previousBindings: [ClusterBindingSnapshot],
        newMembers: [(clusterId: Int64, photoIds: Set<String>)]
    ) {
        var candidates: [(binding: ClusterBindingSnapshot, clusterId: Int64, overlap: Int)] = []
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
                try faceRepo.updateBinding(
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
        // V1：params 改名 params_json；created_at 为 NOT NULL，与 started_at 同值写入。
        let now = nowISOString()
        _ = try connection.prepare("""
            INSERT INTO analysis_runs
              (session_id, kind, photo_count, index_seq, started_at, finished_at, params_json, status, created_at)
            VALUES (?, ?, ?, ?, ?, '', ?, 'running', ?)
          """).run([
            .text(sessionId), .text(kind), .int(Int64(photoCount)), .int(Int64(indexSeq)),
            .text(now), .text(String(data: data, encoding: .utf8) ?? "{}"), .text(now),
        ])
        return connection.lastInsertRowid
    }

    // 取消的 run 在此以 'failed' 终态：run 记录按设计只区分 ok/failed，取消态由
    // analysis_jobs（JobService 的 status 机）表达（TS 注释 603-606；过期检测
    // 1.4.2 一律忽略非 ok run；sessions.analysis_status 已不再写入）。
    private func finalizeAnalysisRun(runId: Int64, status: String) throws {
        _ = try connection.prepare("UPDATE analysis_runs SET status = ?, finished_at = ? WHERE id = ?")
            .run([.text(status), .text(nowISOString()), .int(runId)])
    }

    /// TS: buildFaceKeywordAdditions（fkw.preview 的写回规划）。
    public static func buildFaceKeywordAdditions(_ clusters: [FaceClusterRow]) -> [String: [String]] {
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
    /// 聚类调参（竞品对标：PhotoPrism CLUSTER_CORE / CLUSTER_CORE_RETRY）：
    /// - `face_core_quality`（默认 0.35）：低于此质量的脸不能成为核心点。0.35 的标定依据——
    ///   96px 以上清晰正脸 ≈ 0.9，30px 但清晰 ≈ 0.6，明显模糊/侧倾 < 0.3；门槛只影响
    ///   "谁能带簇"，低质量脸仍会被吸收为边界点（见 FaceClusterer）。
    /// - `face_core_retry_min_samples`（默认 2）：二遍核心点阈值，用于恢复被严格首遍漏掉的
    ///   小簇；< 2 视为关闭——= 1 会让单张噪声脸各自成簇（PhotoPrism 的 retry 不产生单点簇）。
    static func clusterOptions(from getNumber: (String, Double) -> Double) -> FaceClusterOptions {
        let floor = min(max(getNumber("face_core_quality", 0.35), 0), 1)
        let retry = getNumber("face_core_retry_min_samples", 2).safeInt(fallback: 2)
        return FaceClusterOptions(coreQualityFloor: floor, retryMinSamples: retry >= 2 ? retry : nil)
    }

    /// `face_incremental_clustering`（默认 "1" = 开；只有逐字 "1" 视为开，其余
    /// （含 "0"/"true"/空串）一律关闭）：开启且聚类签名未变、库里已有簇时，analyze
    /// 走增量路径保留已有簇 id 与用户绑定；首次分析、签名变化、recluster 命令与
    /// 全失败 run 仍走全量。用字符串而非 getNumber 判定：避免 "true"/"1" 两种写法
    /// 的解析歧义（键值由设置界面下拉写入，取值域就是 "1"/"0"）。
    static func incrementalClusteringEnabled(_ getString: (String, String) -> String) -> Bool {
        getString("face_incremental_clustering", "1") == "1"
    }

    /// 聚类签名（缓存键）：除 eps/minPts 外必须包含质量门槛与二遍阈值——
    /// 否则改了 face_core_quality 之后旧簇会被判定"仍然有效"而跳过重聚类。
    static func clusterSignature(eps: Double, minPts: Int, options: FaceClusterOptions) -> String {
        "\(eps):\(minPts):q\(options.coreQualityFloor):r\(options.retryMinSamples.map(String.init) ?? "-")"
    }

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
