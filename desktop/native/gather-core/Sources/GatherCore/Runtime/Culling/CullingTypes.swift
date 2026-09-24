// desktop/native/gather-core/Sources/GatherCore/Runtime/Culling/CullingTypes.swift
// culltypes（Culling 切换·片 A：类型搬迁）：以下声明自 Services/CullingService.swift 原样搬迁，
// 无语义变化、public 可见性不变。Runtime/Culling/ 尚无 CullingError，故 CullingServiceError 保持原名。
// 含：CullingServiceError；CullingSyncPort / CullingWritebackPort（及宿主一致性扩展）；
// CullingPhotoRow（含 3 个 init(row:)）；CullingOutboxWrite；CullingDecisionWrite；CullingCachePatch。

import Foundation

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

/// TS: culling.service.ts 依赖的协调器最小面（`Pick<MetadataSyncCoordinator,
/// 'schedule' | 'getSummary' | 'flushSession' | 'retrySession' |
/// 'finalizeSession' | 'confirmSync' | 'cleanup'>`）—— 3.4 CullingService 与测试
/// 可注入替身。不要求 Sendable：Swift 5 模式下的跨文件可回溯一致性与现有
/// MetadataSyncPort（同文件一致）同款处理。
public protocol CullingSyncPort {
    func schedule(xmpPath: String)
    func getSummary(sessionId: String) async throws -> MetadataSyncSummary
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary
    func retrySession(sessionId: String) async throws -> MetadataSyncSummary
    func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary
    func confirmSync(sessionId: String, sourceModule: String) async throws -> MetadataSyncSummary
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult
}

extension MetadataSyncRuntime: CullingSyncPort {
    /// TS: schedule(xmpPath) —— 默认去抖窗口；协调器的 delayMs 是 default-arg，
    /// 双参方法不能作单参需求的 witness，显式转发（nonisolated：调度入口同步返回）。
    public nonisolated func schedule(xmpPath: String) {
        schedule(xmpPath: xmpPath, delayMs: nil)
    }
}

/// TS: culling.ipc.ts 用到的 WritebackService 最小面（culling 写回四命令 +
/// confirm/cleanup 协作）—— 宿主注入 WritebackService，测试注入替身。
public protocol CullingWritebackPort {
    func preview(
        sessionId: String,
        module: String,
        options: WritebackOptions,
        photoIds: Set<String>?,
        keywordAdditions: [String: [String]]?
    ) async throws -> WritebackPreview
    func persistAttributes(items: [WritebackItem]) async throws
    func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult
    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult
    func getItems(sessionId: String, module: String, status: String?) async throws -> [WritebackItem]
    func confirmSync(sessionId: String, module: String) async throws
    func cleanup(sessionId: String, module: String) async throws -> CleanupResult
}

extension WritebackService: CullingWritebackPort {}

/// TS: CullingPhotoRow（PhotoRow | PhotoPageRow | PhotoProjection 的并集）——
/// culling 服务消费的最小行形状：重 JSON 列（metadata/result）为可选，三种投影
/// 互换（TS 注释：heavy JSON columns 从不在此读取，故可互换）。
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
    public let metadata: String? // 仅全行投影携带
    public let result: String? // 仅全行投影携带
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
        metadata: String?,
        result: String?,
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
        self.metadata = metadata
        self.result = result
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension CullingPhotoRow {
    init(row: PhotoRecord) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum, status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            metadata: row.metadata, result: row.result,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    init(row: PhotoPage) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum ?? "", status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            metadata: row.metadata, result: row.result,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    init(row: PhotoProjection) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum, status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            metadata: nil, result: nil,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

}

/// 决策事务提交后入队的 outbox 值直写（queuePhotoValues 只能 async，事务内收集）。
public struct CullingOutboxWrite: Sendable {
    public let sessionId: String
    public let photoId: String
    public let values: [String: JSONValue]
    public let source: MetadataMutationSource
    public let schedule: Bool

    public init(
        sessionId: String,
        photoId: String,
        values: [String: JSONValue],
        source: MetadataMutationSource,
        schedule: Bool
    ) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.values = values
        self.source = source
        self.schedule = schedule
    }
}

/// 决策事务提交后要落库的决策行写入（决策表在 Store 连接上，跨连接不共享事务）。
public struct CullingDecisionWrite: Sendable {
    public let sessionId: String
    public let photoId: String
    public let groupId: String
    public let state: CullingDecisionState

    public init(sessionId: String, photoId: String, groupId: String, state: CullingDecisionState) {
        self.sessionId = sessionId
        self.photoId = photoId
        self.groupId = groupId
        self.state = state
    }
}

/// 决策事务提交后要写回元数据缓存列的补丁（派生数据，事务外经 MetadataStore 落库）。
public struct CullingCachePatch: Sendable {
    public let photoId: String
    public let rating: Int64?
    public let label: String?

    public init(photoId: String, rating: Int64? = nil, label: String? = nil) {
        self.photoId = photoId
        self.rating = rating
        self.label = label
    }
}
