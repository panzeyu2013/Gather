// desktop/native/gather-core/Sources/GatherApplication/Services/Culling/CullingService+Types.swift
// WP5a：CullingService 按角色拆分（纯移动；方法体/错误码/事务/查询逐字未改）。
// 共享类型：错误码、写回端口、照片行、历史缓冲、更新上下文、内部查找/缓存条目。
import Foundation
import GatherPersistence
import GatherDelivery
import GatherProtocol

/// TS: culling.service.ts / culling.ipc.ts 抛出的全部错误消息（description 与
/// TS 逐字一致，桥接层按 description 序列化）。
public enum CullingServiceError: Error, Equatable, CustomStringConvertible {
    case photoNotInSession // CULLING_PHOTO_NOT_IN_SESSION
    case revisionConflict(expected: Int, current: Int) // CULLING_REVISION_CONFLICT
    case patchInvalid // CULLING_PATCH_INVALID
    case emptySelection // CULLING_EMPTY_SELECTION
    case photosNotInSession // CULLING_PHOTOS_NOT_IN_SESSION
    case historyNotFound // CULLING_HISTORY_NOT_FOUND
    case historyAlreadyUndone // CULLING_HISTORY_ALREADY_UNDONE
    case historyNotUndone // CULLING_HISTORY_NOT_UNDONE
    case historyDuplicatePhotos // 'History command contains duplicate photos'
    case historyDiverged // CULLING_HISTORY_DIVERGED
    case noSimilarity // CULLING_NO_SIMILARITY
    case groupTooSmall // CULLING_GROUP_TOO_SMALL
    case keepNotInGroup // CULLING_KEEP_NOT_IN_GROUP
    case ratingOutOfRange // 'rating must be an integer from 0 to 5'
    case invalidPickState // 'Invalid pickState'
    case invalidColorLabel // 'Invalid colorLabel'
    case invalidScope // CULLING_INVALID_SCOPE（IPC 校验）
    case afterRowIdInvalid // 'afterRowId must be a positive integer'（IPC 校验）
    case pageLimitInvalid // 'limit must be an integer between 1 and 2000'（IPC 校验）
    case tooManyPhotoIds // 'Too many photoIds in one batch'（IPC 校验）
    case tooManyKeepPhotoIds // 'Too many keepPhotoIds'（IPC 校验）
    case finalizeConfirmRequired // CULLING_FINALIZE_CONFIRM_REQUIRED
    case resetConfirmRequired // CULLING_RESET_CONFIRM_REQUIRED
    case noDecisions // CULLING_NO_DECISIONS
    case writebackConfirmRequired // WRITEBACK_CONFIRM_REQUIRED
    case writebackRetryConfirmRequired // WRITEBACK_RETRY_CONFIRM_REQUIRED
    case writebackCleanupConfirmRequired // WRITEBACK_CLEANUP_CONFIRM_REQUIRED

    public var description: String {
        switch self {
        case .photoNotInSession: "CULLING_PHOTO_NOT_IN_SESSION"
        case .revisionConflict: "CULLING_REVISION_CONFLICT"
        case .patchInvalid: "CULLING_PATCH_INVALID"
        case .emptySelection: "CULLING_EMPTY_SELECTION"
        case .photosNotInSession: "CULLING_PHOTOS_NOT_IN_SESSION"
        case .historyNotFound: "CULLING_HISTORY_NOT_FOUND"
        case .historyAlreadyUndone: "CULLING_HISTORY_ALREADY_UNDONE"
        case .historyNotUndone: "CULLING_HISTORY_NOT_UNDONE"
        case .historyDuplicatePhotos: "History command contains duplicate photos"
        case .historyDiverged: "CULLING_HISTORY_DIVERGED"
        case .noSimilarity: "CULLING_NO_SIMILARITY"
        case .groupTooSmall: "CULLING_GROUP_TOO_SMALL"
        case .keepNotInGroup: "CULLING_KEEP_NOT_IN_GROUP"
        case .ratingOutOfRange: "rating must be an integer from 0 to 5"
        case .invalidPickState: "Invalid pickState"
        case .invalidColorLabel: "Invalid colorLabel"
        case .invalidScope: "CULLING_INVALID_SCOPE"
        case .afterRowIdInvalid: "afterRowId must be a positive integer"
        case .pageLimitInvalid: "limit must be an integer between 1 and 2000"
        case .tooManyPhotoIds: "Too many photoIds in one batch"
        case .tooManyKeepPhotoIds: "Too many keepPhotoIds"
        case .finalizeConfirmRequired: "CULLING_FINALIZE_CONFIRM_REQUIRED"
        case .resetConfirmRequired: "CULLING_RESET_CONFIRM_REQUIRED"
        case .noDecisions: "CULLING_NO_DECISIONS"
        case .writebackConfirmRequired: "WRITEBACK_CONFIRM_REQUIRED"
        case .writebackRetryConfirmRequired: "WRITEBACK_RETRY_CONFIRM_REQUIRED"
        case .writebackCleanupConfirmRequired: "WRITEBACK_CLEANUP_CONFIRM_REQUIRED"
        }
    }
}
/// TS: culling.ipc.ts 用到的 WritebackService 最小面（culling 写回四命令 +
/// confirm/cleanup 协作）—— 宿主注入 WritebackService，测试注入替身。
/// S5c-2b-1：execute/retryFailed 仍是文件写入执行器；getItems 重新被镜像路径使用
/// （读取 written/failed 行状态）。confirmSync/cleanup 已不再被调用，
/// S5c-2b-3 删除旧服务时收敛。
public protocol CullingWritebackPort {
    func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions,
        photoIds: Set<String>?,
        keywordAdditions: [String: [String]]?
    ) async throws -> WritebackPreview
    func persistAttributes(items: [WritebackItem]) throws
    func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult
    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult
    func getItems(sessionId: String, module: String, status: String?) throws -> [WritebackItem]
    func confirmSync(sessionId: String, module: String) async throws
    func cleanup(sessionId: String, module: String) async throws -> CleanupResult
}

extension WritebackService: CullingWritebackPort {}
/// TS: CullingPhotoRow（PhotoRow | PhotoPageRow | PhotoProjectionRow 的并集）——
/// culling 服务消费的最小行形状。photos.metadata/result 已从 V1 列清单删除
/// （Cut 2 S5a），三种投影形状一致，不再有“仅全行投影携带”的字段。
public struct CullingPhotoRow: Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let filepath: String
    public let filename: String
    public let checksum: String
    public let status: String
    public let assetId: String?
    public let assetFileId: String?
    public let width: Int
    public let height: Int
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        sessionId: String,
        filepath: String,
        filename: String,
        checksum: String,
        status: String,
        assetId: String?,
        assetFileId: String?,
        width: Int,
        height: Int,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.filepath = filepath
        self.filename = filename
        self.checksum = checksum
        self.status = status
        self.assetId = assetId
        self.assetFileId = assetFileId
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CullingPhotoRow {
    init(row: PhotoRow) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum, status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    init(row: PhotoProjectionRow) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum, status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    init(row: PhotoPageRow) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum ?? "", status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }
}
/// TS: CullingUpdateContext.historySink —— 批量/历史路径共用的追加缓冲区
/// （batchUpdate 把局部数组经上下文传入 updateState，成功后再整体落库）。
public final class CullingHistorySink: @unchecked Sendable {
    public private(set) var entries: [CullingHistoryEntry] = []

    func append(_ newEntries: [CullingHistoryEntry]) {
        entries.append(contentsOf: newEntries)
    }
}
/// TS: CullingUpdateContext —— IPC handler 与 batch/history 路径共享的
/// 每会话更新输入（photos + id 索引 + 相似度组索引 + xmp 联动映射，均在一次
/// 更新突发内不可变）。
public struct CullingUpdateContext {
    public var photos: [CullingPhotoRow]
    public var photoById: [String: CullingPhotoRow]
    public var photosByAssetId: [String: [CullingPhotoRow]]
    public var groupMap: [String: String]
    public var linkedByXmp: [String: [CullingPhotoRow]]
    public var historySink: CullingHistorySink? // TS: historySink?

    public init(
        photos: [CullingPhotoRow],
        photoById: [String: CullingPhotoRow],
        photosByAssetId: [String: [CullingPhotoRow]],
        groupMap: [String: String],
        linkedByXmp: [String: [CullingPhotoRow]],
        historySink: CullingHistorySink? = nil
    ) {
        self.photos = photos
        self.photoById = photoById
        self.photosByAssetId = photosByAssetId
        self.groupMap = groupMap
        self.linkedByXmp = linkedByXmp
        self.historySink = historySink
    }
}
// MARK: - 内部类型

/// TS: LookupMode。
enum LookupMode {
    case session
    case page
}

/// TS: CullingRichLookup。
struct CullingRichLookup {
    let decisions: [String: CullingDecisionRow]
    let cacheRows: [String: MetadataCacheRow]
    let deliveryByPath: [String: DeliveryRow]
    let metadataSourceByPath: [String: MetadataMutationSource]
    let similarityMap: [String: String]
    let qualityByPhoto: [String: CullingQuality]
    let facesByPhoto: [String: [[Double]]]
    let analysisMaxByPhoto: [String: Double]
    let peopleByPhoto: [String: [String]]
    let linkedCounts: [String: Int]
}

/// TS: SessionLookupEntry —— 版本键控缓存条目（可变，见 getSessionLookup）。
final class SessionLookupEntry {
    var resultRow: SimilarityResultRow?
    var similarityMap: [String: String]
    var groupIndex: [String: String]
    var groupIndexResolved: Bool
    var analysesLoaded: Bool
    var qualityByPhoto: [String: CullingQuality]
    var facesByPhoto: [String: [[Double]]]
    var analysisMaxByPhoto: [String: Double]
    var peopleByPhoto: [String: [String]]
    var groupCount: Int
    var groupCountResolved: Bool
    var expiresAt: Date

    init(
        resultRow: SimilarityResultRow?,
        similarityMap: [String: String],
        groupIndex: [String: String],
        groupIndexResolved: Bool,
        analysesLoaded: Bool,
        qualityByPhoto: [String: CullingQuality],
        facesByPhoto: [String: [[Double]]],
        analysisMaxByPhoto: [String: Double],
        peopleByPhoto: [String: [String]],
        groupCount: Int,
        groupCountResolved: Bool,
        expiresAt: Date
    ) {
        self.resultRow = resultRow
        self.similarityMap = similarityMap
        self.groupIndex = groupIndex
        self.groupIndexResolved = groupIndexResolved
        self.analysesLoaded = analysesLoaded
        self.qualityByPhoto = qualityByPhoto
        self.facesByPhoto = facesByPhoto
        self.analysisMaxByPhoto = analysisMaxByPhoto
        self.peopleByPhoto = peopleByPhoto
        self.groupCount = groupCount
        self.groupCountResolved = groupCountResolved
        self.expiresAt = expiresAt
    }
}

/// TS: SessionUpdateEntry —— TTL 缓存的更新上下文（可变，见
/// getSessionUpdateContext）。groupMap/linkedByXmp 为懒填充的可选值
/// （TS `Map | undefined`）：nil 即未解析，首个 ensureUpdateExtras 填充。
final class SessionUpdateEntry {
    var photos: [CullingPhotoRow]
    var photoById: [String: CullingPhotoRow]
    var photosByAssetId: [String: [CullingPhotoRow]]
    var groupMap: [String: String]?
    var groupMapResultId: Int64?
    var linkedByXmp: [String: [CullingPhotoRow]]?
    var refreshed: Bool
    var expiresAt: Date

    init(
        photos: [CullingPhotoRow],
        photoById: [String: CullingPhotoRow],
        photosByAssetId: [String: [CullingPhotoRow]],
        groupMap: [String: String]?,
        groupMapResultId: Int64?,
        linkedByXmp: [String: [CullingPhotoRow]]?,
        refreshed: Bool,
        expiresAt: Date
    ) {
        self.photos = photos
        self.photoById = photoById
        self.photosByAssetId = photosByAssetId
        self.groupMap = groupMap
        self.groupMapResultId = groupMapResultId
        self.linkedByXmp = linkedByXmp
        self.refreshed = refreshed
        self.expiresAt = expiresAt
    }
}
