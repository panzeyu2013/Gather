// WP5b：FaceKwService 拆分（纯移动，行为不变）——Types。
// 源：HEAD 95f0075 的 Services/FaceKwService.swift；仅调整跨文件访问级。

import Foundation
import GatherAnalysis
import GatherPersistence
import GatherDelivery
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
