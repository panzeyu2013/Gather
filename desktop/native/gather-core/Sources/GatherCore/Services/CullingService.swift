// desktop/native/gather-core/Sources/GatherCore/Services/CullingService.swift
// TS 源: desktop/src/main/services/culling/culling.service.ts（1902 行，逐字移植）
// + culling.ipc.ts（387 行）的命令面（writeback/sync_status/flush/retry_sync/
// finalize_sync/retry_failed_writeback/confirm_sync/cleanup 的确认校验与委托）。
//
// Culling 服务：资产列表（含 RAW/JPEG 变体折叠与 asset 分组分页）、decide
// （星级/标签/关键词选择）、批量操作、summary、history/apply_history（undo/redo
// 历史栈）、reset、写回协作。写回引擎与 XMP 同步引擎不在此重写——经
// CullingWritebackPort（WritebackService 已移植接口）与 CullingSyncPort
// （MetadataSyncCoordinator 已移植接口）注入，测试可注入替身。
//
// 注入点：
// - CullingSyncPort = TS Pick<MetadataSyncCoordinator, schedule | getSummary |
//   flushSession | retrySession | finalizeSession | confirmSync | cleanup>。
// - CullingWritebackPort = TS WritebackService 的 culling.ipc.ts 用到的最小面
//   （preview/persistAttributes/execute/retryFailed/getItems/confirmSync/cleanup）。
// - MetadataMutationPort = TS MetadataMutationService（queuePhotoValues）。
// - getNumber = TS SettingsService.getNumber（detect_input_size /
//   face_preview_max_dimension 兜底，测试注入）。
// - cullingStore 与 TS 一样是可选依赖（老装配缺省时历史栈禁用）。
//
// 错误消息与 TS 逐字一致：CullingServiceError.description 即 TS `new Error(code)`
// 的 message；CULLING_REVISION_CONFLICT 带 expected/current 插值参数。
//
// 缓存注记：TTL 缓存（sessionLookup/sessionUpdate）与 TS 同语义——主进程单线程
// 同步 SQLite，Swift 侧服务实例同样按会话单线程使用，Map 无需加锁（与
// SimilarityResultRepo 的 photoGroupMapCache 同款决策）。

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
    func getSummary(sessionId: String) throws -> MetadataSyncSummary
    func flushSession(sessionId: String) async throws -> MetadataSyncSummary
    func retrySession(sessionId: String) async throws -> MetadataSyncSummary
    func finalizeSession(sessionId: String) async throws -> MetadataSyncSummary
    func confirmSync(sessionId: String, sourceModule: String) throws -> MetadataSyncSummary
    func cleanup(sessionId: String, sourceModule: String) async throws -> CleanupResult
}

extension MetadataSyncCoordinator: CullingSyncPort {
    /// TS: schedule(xmpPath) —— 默认去抖窗口；协调器的 delayMs 是 default-arg，
    /// 双参方法不能作单参需求的 witness，显式转发。
    public func schedule(xmpPath: String) {
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
    func persistAttributes(items: [WritebackItem]) throws
    func execute(sessionId: String, module: String, items: [WritebackItem]) async throws -> WritebackResult
    func retryFailed(sessionId: String, module: String) async throws -> WritebackResult
    func getItems(sessionId: String, module: String, status: String?) throws -> [WritebackItem]
    func confirmSync(sessionId: String, module: String) async throws
    func cleanup(sessionId: String, module: String) async throws -> CleanupResult
}

extension WritebackService: CullingWritebackPort {}

/// TS: CullingPhotoRow（PhotoRow | PhotoPageRow | PhotoProjectionRow 的并集）——
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
    init(row: PhotoRow) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum, status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            metadata: row.metadata, result: row.result,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    init(row: PhotoProjectionRow) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum, status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            metadata: nil, result: nil,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
    }

    init(row: PhotoPageRow) {
        self.init(
            id: row.id, sessionId: row.sessionId, filepath: row.filepath,
            filename: row.filename, checksum: row.checksum ?? "", status: row.status,
            assetId: row.assetId, assetFileId: row.assetFileId,
            width: row.width, height: row.height,
            metadata: row.metadata, result: row.result,
            createdAt: row.createdAt, updatedAt: row.updatedAt
        )
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

/// TS: CullingUpdateContext.historySink —— 批量/历史路径共用的追加缓冲区
/// （batchUpdate 把局部数组经上下文传入 updateState，成功后再整体落库）。
public final class CullingHistorySink: @unchecked Sendable {
    public private(set) var entries: [CullingHistoryEntry] = []
    /// 事务内收集、提交后落库的元数据缓存补丁（rating/label 派生列）。
    public private(set) var cachePatches: [CullingCachePatch] = []
    /// 事务内收集、提交后落库的决策行写入。
    public private(set) var decisionWrites: [CullingDecisionWrite] = []

    public init() {}

    func appendCachePatch(_ patch: CullingCachePatch) {
        cachePatches.append(patch)
    }

    func appendDecisionWrite(_ write: CullingDecisionWrite) {
        decisionWrites.append(write)
    }

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
    /// 元数据缓存行（派生列基线）：调用方在事务外预读后传入。
    public var cacheRows: [String: MetadataCacheRecord]
    /// 当前决策行（revision 基线）：调用方在事务外预读后传入。
    public var currentDecision: CullingDecisionRecord?
    /// 批量路径的决策行快照（photoId → 行）。
    public var decisionRows: [String: CullingDecisionRecord]

    public init(
        photos: [CullingPhotoRow],
        photoById: [String: CullingPhotoRow],
        photosByAssetId: [String: [CullingPhotoRow]],
        groupMap: [String: String],
        linkedByXmp: [String: [CullingPhotoRow]],
        historySink: CullingHistorySink? = nil,
        cacheRows: [String: MetadataCacheRecord] = [:],
        currentDecision: CullingDecisionRecord? = nil,
        decisionRows: [String: CullingDecisionRecord] = [:]
    ) {
        self.photos = photos
        self.photoById = photoById
        self.photosByAssetId = photosByAssetId
        self.groupMap = groupMap
        self.linkedByXmp = linkedByXmp
        self.historySink = historySink
        self.cacheRows = cacheRows
        self.currentDecision = currentDecision
        self.decisionRows = decisionRows
    }
}

/// TS: CullingService。
public final class CullingService {
    // MARK: - 常量（TS 文件头部）

    /// TS: COLOR_LABELS。
    private static let colorLabels: Set<CaptureOneColorLabel> = [
        .none, .red, .orange, .yellow, .green, .blue, .pink, .purple,
    ]

    /// TS: PREFERRED_RAW_EXTENSIONS（预编译小写 RAW 扩展名集合，O(1) 探测）。
    private static let preferredRawExtensions: Set<String> = Set(PhotoRepo.rawExtensions)

    /// TS: LOOKUP_TTL_MS / LOOKUP_CACHE_MAX / UPDATE_TTL_MS / UPDATE_CACHE_MAX。
    private static let lookupTTLSeconds: TimeInterval = 5
    private static let lookupCacheMax = 8
    private static let updateTTLSeconds: TimeInterval = 5
    private static let updateCacheMax = 8

    /// TS: withChunkedIds 的分块大小（SQLite 参数上限以内，同其他批量读）。
    private static let chunkSize = 800

    /// TS: culling.ipc.ts 的 limit 校验区间。
    public static let pageLimitMax = 2_000
    public static let batchMax = 10_000

    // MARK: - 依赖

    private let photoRepo: PhotoRepo
    private let similarityResultRepo: SimilarityResultRepo
    private let metadataOutboxRepo: MetadataOutboxRepo
    private let connection: DBConnection
    private let metadataSync: any CullingSyncPort
    private let metadataMutations: any MetadataMutationPort
    private let writeback: any CullingWritebackPort
    private let cullingStore: (any CullingStore)?
    private let metadataStore: any MetadataStore
    private let getNumber: (String, Double) -> Double

    public init(
        photoRepo: PhotoRepo,
        similarityResultRepo: SimilarityResultRepo,
        metadataOutboxRepo: MetadataOutboxRepo,
        connection: DBConnection,
        metadataSync: any CullingSyncPort,
        metadataMutations: any MetadataMutationPort,
        writeback: any CullingWritebackPort,
        cullingStore: (any CullingStore)? = nil,
        metadataStore: any MetadataStore,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue }
    ) {
        self.photoRepo = photoRepo
        self.similarityResultRepo = similarityResultRepo
        self.metadataOutboxRepo = metadataOutboxRepo
        self.connection = connection
        self.metadataSync = metadataSync
        self.metadataMutations = metadataMutations
        self.writeback = writeback
        self.cullingStore = cullingStore
        self.metadataStore = metadataStore
        self.getNumber = getNumber
    }

    /// 单张更新完整入口：事务内决策 + 事务外历史落库（路由/decide 使用）。
    @discardableResult
    public func update(
        sessionId: String,
        photoId: String,
        expectedRevision: Int,
        patch: CullingUpdatePatch
    ) async throws -> CullingUpdateResult {
        let base = try getUpdateContext(sessionId: sessionId)
        let sink = CullingHistorySink()
        let singleCache = try await metadataStore.metadataBatch(photoIds: [photoId])
        let cacheRows = Dictionary(uniqueKeysWithValues: singleCache.map { ($0.photoId, $0) })
        let currentDecision = try await cullingStore?.decision(sessionId: sessionId, photoId: photoId)
        var decisionRows: [String: CullingDecisionRecord] = [:]
        if let currentDecision { decisionRows[photoId] = currentDecision }
        var result = try updateState(
            sessionId: sessionId,
            photoId: photoId,
            expectedRevision: expectedRevision,
            patch: patch,
            context: CullingUpdateContext(
                photos: base.photos,
                photoById: base.photoById,
                photosByAssetId: base.photosByAssetId,
                groupMap: base.groupMap,
                linkedByXmp: base.linkedByXmp,
                historySink: sink,
                cacheRows: cacheRows,
                currentDecision: currentDecision,
                decisionRows: decisionRows
            )
        )
        result.historyOperationId = try await commitHistory(
            sink.entries, sessionId: sessionId,
            cachePatches: sink.cachePatches, decisionWrites: sink.decisionWrites)
        return result
    }

    /// 把 updateState 收集到的历史条目落到 Store（必须在决策事务提交之后）。
    /// 返回操作 id；无 Store 或空条目时返回 nil（历史栈禁用语义）。
    public func commitHistory(
        _ entries: [CullingHistoryEntry],
        sessionId: String,
        cachePatches: [CullingCachePatch] = [],
        decisionWrites: [CullingDecisionWrite] = []
    ) async throws -> Int? {
        try await commitCachePatches(cachePatches)
        try await commitDecisionWrites(decisionWrites)
        guard let cullingStore, !entries.isEmpty else { return nil }
        return try await cullingStore.appendHistory(sessionId: sessionId, entries: entries).id
    }

    /// 事务外落库决策行写入（决策表在 Store 连接上）。
    public func commitDecisionWrites(_ writes: [CullingDecisionWrite]) async throws {
        guard let cullingStore else { return }
        for write in writes {
            try await cullingStore.upsertDecisionState(
                sessionId: write.sessionId,
                photoId: write.photoId,
                groupId: write.groupId,
                state: write.state
            )
        }
    }

    /// 事务外写回元数据缓存列（rating/label 派生列）。
    public func commitCachePatches(_ patches: [CullingCachePatch]) async throws {
        for patch in patches {
            if let rating = patch.rating {
                try await metadataStore.updateRating(photoId: patch.photoId, rating: rating)
            }
            if let label = patch.label {
                try await metadataStore.updateLabel(photoId: patch.photoId, label: label)
            }
        }
    }

    // MARK: - 会话查找缓存（TS SessionLookupEntry / SessionUpdateEntry）

    /// TS: sessionLookupCache —— 版本键控的会话查找条目（见 SessionLookupEntry）。
    private var sessionLookupCache: [String: SessionLookupEntry] = [:]
    /// TS: sessionUpdateCache —— 会话级更新上下文（见 SessionUpdateEntry）。
    private var sessionUpdateCache: [String: SessionUpdateEntry] = [:]

    // MARK: - 列表

    /// TS: list —— 会话全量资产列表。
    public func list(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil
    ) async throws -> [CullingAsset] {
        let photos = try photoRepo.getBySession(sessionId: sessionId).map { CullingPhotoRow(row: $0) }
        let lookup = try await buildRichLookup(photos: photos, sessionId: sessionId, mode: .session)
        return filterVisible(
            assembleAssets(photos: photos, lookup: lookup),
            scope: scope,
            filters: filters,
            requestedGroupId: requestedGroupId
        )
    }

    /// TS: listPage —— 资产分组 keyset 分页（RAW/JPEG 变体永不分页；total 精确）。
    public func listPage(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters? = nil,
        requestedGroupId: String? = nil,
        afterRowId: Int64? = nil,
        limit: Int = 200
    ) async throws -> CullingPage {
        if let afterRowId, afterRowId < 1 {
            throw CullingServiceError.afterRowIdInvalid
        }
        guard limit >= 1, limit <= Self.pageLimitMax else {
            throw CullingServiceError.pageLimitInvalid
        }
        let page = try pagePhotosQuery(
            sessionId: sessionId, scope: scope, filters: filters,
            requestedGroupId: requestedGroupId, afterRowId: afterRowId, limit: limit
        )
        let lookup = try await buildRichLookup(photos: page.photos, sessionId: sessionId, mode: .page)
        let assets = filterVisible(
            assembleAssets(photos: page.photos, lookup: lookup),
            scope: scope, filters: filters, requestedGroupId: requestedGroupId
        )
        let total = try countForScope(
            sessionId: sessionId, scope: scope, filters: filters,
            requestedGroupId: requestedGroupId, similarityMap: lookup.similarityMap
        )
        return CullingPage(
            assets: assets,
            nextRowId: page.cursor.map(Int.init),
            total: total
        )
    }

    // MARK: - 更新上下文（IPC culling.update 复用）

    /// TS: getUpdateContext —— 缓存的 `updateState` 上下文；IPC 更新 handler 复用
    /// 它，点击突发不再每次重读整个会话。
    public func getUpdateContext(sessionId: String) throws -> CullingUpdateContext {
        let entry = getSessionUpdateContext(sessionId: sessionId)
        try ensureUpdateExtras(entry: entry, sessionId: sessionId)
        return CullingUpdateContext(
            photos: entry.photos,
            photoById: entry.photoById,
            photosByAssetId: entry.photosByAssetId,
            groupMap: entry.groupMap!,
            linkedByXmp: entry.linkedByXmp!
        )
    }

    /// TS: updateState —— 单张照片状态更新（pick/rating/colorLabel），受影响
    /// 照片为 asset 变体（pick）或共享侧车（shared metadata）。
    @discardableResult
    public func updateState(
        sessionId: String,
        photoId: String,
        expectedRevision: Int,
        patch: CullingUpdatePatch,
        context: CullingUpdateContext? = nil
    ) throws -> CullingUpdateResult {
        try validatePatch(patch)
        let entry = getSessionUpdateContext(sessionId: sessionId)
        var photos = context?.photos ?? entry.photos
        var photoById = context?.photoById ?? entry.photoById
        var contextGroupMap = context?.groupMap
        var contextLinkedByXmp = context?.linkedByXmp
        var contextPhotosByAssetId = context?.photosByAssetId
        let target: CullingPhotoRow
        if let initial = photoById[photoId] ?? photos.first(where: { $0.id == photoId }) {
            target = initial
        } else {
            // TTL 缓存的照片集合可能缺索引器刚加的照片，每次窗口先试一次新鲜读
            //（见 refreshSessionUpdateContext）。陈旧的调用方上下文被丢弃。
            refreshSessionUpdateContext(sessionId: sessionId, entry: entry)
            photos = entry.photos
            photoById = entry.photoById
            contextGroupMap = nil
            contextLinkedByXmp = nil
            contextPhotosByAssetId = nil
            guard let refreshed = photoById[photoId] ?? photos.first(where: { $0.id == photoId }) else {
                throw CullingServiceError.photoNotInSession
            }
            target = refreshed
        }

        let currentRow = context?.currentDecision
        let currentRevision = currentRow?.revision ?? 0
        if currentRevision != Int64(expectedRevision) {
            throw CullingServiceError.revisionConflict(
                expected: expectedRevision, current: Int(currentRevision)
            )
        }

        let targetXmpPath = TSPath.xmpSidecarPath(target.filepath)
        let changesSharedMetadata = patch.rating != nil || patch.colorLabel != nil
        // 完整的调用方上下文（IPC/batch）已过 ensureUpdateExtras；只有直连路径与
        // 新鲜读回退（丢弃了上下文映射）之后才需要按点击做版本检查。
        if contextGroupMap == nil {
            try ensureUpdateExtras(entry: entry, sessionId: sessionId)
        }
        let photosByAssetId = contextPhotosByAssetId ?? entry.photosByAssetId
        // 保序受影响集合：TS Map.set 保留首见位置（先资产变体，后共享侧车），
        // 结果状态数组的顺序依赖它。
        var affectedById: [(id: String, photo: CullingPhotoRow)] = []
        var affectedSeen = Set<String>()
        func addAffected(_ photo: CullingPhotoRow) {
            if affectedSeen.insert(photo.id).inserted {
                affectedById.append((photo.id, photo))
            }
        }
        if patch.pickState != nil, let assetId = target.assetId {
            for photo in photosByAssetId[assetId] ?? [] {
                addAffected(photo)
            }
        } else {
            addAffected(target)
        }
        if changesSharedMetadata {
            for photo in (contextLinkedByXmp ?? entry.linkedByXmp!)[targetXmpPath] ?? [] {
                addAffected(photo)
            }
        }
        let affectedPhotos = affectedById.map(\.photo)
        let pickTargets: Set<String> = patch.pickState != nil && target.assetId != nil
            ? Set((photosByAssetId[target.assetId!] ?? []).map(\.id))
            : [target.id]
        let groupMap = contextGroupMap ?? entry.groupMap!
        var resultStates: [AssetCullingState] = []
        var beforeStates: [AssetCullingState] = []
        var historyOperationId: Int?
        var metadataPatch: [String: JSONValue] = [:]
        let cacheRows = context?.cacheRows ?? [:]
        if let rating = patch.rating { metadataPatch["rating"] = .number(rating) }
        if let colorLabel = patch.colorLabel {
            // TS: colorLabel === 'None' → ''（写盘标签语义）。
            metadataPatch["label"] = .string(colorLabel == .none ? "" : colorLabel.rawValue)
        }

        try connection.transaction {
            let existingRows = context?.decisionRows ?? [:]

            for photo in affectedPhotos {
                let existing = existingRows[photo.id]
                let cache = cacheRows[photo.id]
                let existingState = rowToState(
                    photoId: photo.id, row: existing,
                    fallbackRating: cache?.rating ?? 0, fallbackLabel: cache?.label ?? "None"
                )
                beforeStates.append(existingState)
                let isPickTarget = pickTargets.contains(photo.id)
                let nextPickState = isPickTarget && patch.pickState != nil
                    ? patch.pickState!
                    : existingState.pickState
                let nextRating = patch.rating ?? existingState.rating
                let nextColorLabel = patch.colorLabel ?? existingState.colorLabel
                let nextRevision = existingState.revision + 1

                context?.historySink?.appendDecisionWrite(CullingDecisionWrite(
                    sessionId: sessionId,
                    photoId: photo.id,
                    groupId: groupMap[photo.id] ?? "ungrouped",
                    state: CullingDecisionState(
                        decision: pickStateToDecision(nextPickState).rawValue,
                        rating: Int64(nextRating),
                        colorLabel: nextColorLabel.rawValue,
                        revision: Int64(nextRevision)
                    )
                ))
                if patch.rating != nil {
                    context?.historySink?.appendCachePatch(
                        CullingCachePatch(photoId: photo.id, rating: Int64(nextRating)))
                }
                if patch.colorLabel != nil {
                    context?.historySink?.appendCachePatch(
                        CullingCachePatch(photoId: photo.id, label: nextColorLabel.rawValue))
                }
                resultStates.append(AssetCullingState(
                    photoId: photo.id,
                    pickState: nextPickState,
                    rating: nextRating,
                    colorLabel: nextColorLabel,
                    source: .manual,
                    revision: nextRevision,
                    updatedAt: nowISOString()
                ))
            }

            let fields = patchFields(patch)
            let historyEntries: [CullingHistoryEntry] = resultStates.enumerated().map { index, after in
                let before = beforeStates[index]
                return CullingHistoryEntry(
                    photoId: after.photoId,
                    before: CullingStateSnapshot(
                        pickState: before.pickState, rating: before.rating, colorLabel: before.colorLabel
                    ),
                    after: CullingStateSnapshot(
                        pickState: after.pickState, rating: after.rating, colorLabel: after.colorLabel
                    ),
                    expectedRevision: after.revision,
                    fields: fields
                )
            }
            if !metadataPatch.isEmpty {
                _ = try metadataMutations.queuePhotoValues(
                    sessionId: sessionId,
                    photoId: photoId,
                    values: metadataPatch,
                    source: .culling,
                    schedule: false
                )
            }
            if !historyEntries.isEmpty {
                // Store 写入无法进同步事务：调用方经 context.historySink 收集后
                // 用 commitHistory 落库（batchUpdate / 路由 culling.update）。
                context?.historySink?.append(historyEntries)
            }
        }

        if !metadataPatch.isEmpty {
            metadataSync.schedule(xmpPath: targetXmpPath)
        }

        let outboxRow = try metadataOutboxRepo.get(targetXmpPath)
        let syncStatus: MetadataSyncStatus
        if changesSharedMetadata {
            syncStatus = MetadataSyncStatus(rawValue: outboxRow?.status ?? "") ?? .pending
        } else {
            syncStatus = MetadataSyncStatus(rawValue: outboxRow?.status ?? "") ?? .clean
        }
        return CullingUpdateResult(
            states: resultStates,
            xmpPath: targetXmpPath,
            syncStatus: syncStatus,
            historyOperationId: historyOperationId
        )
    }

    /// TS: batchUpdate —— 批量更新；pick 按逻辑资产合并、shared metadata 按
    /// 共享侧车合并，整批单事务。
    public func batchUpdate(
        sessionId: String,
        photoIds: [String],
        patch: CullingUpdatePatch
    ) async throws -> [CullingUpdateResult] {
        try validatePatch(patch)
        var uniqueIds: [String] = []
        for photoId in photoIds where !uniqueIds.contains(photoId) {
            uniqueIds.append(photoId)
        }
        if uniqueIds.isEmpty { throw CullingServiceError.emptySelection }
        if uniqueIds.count > Self.batchMax { throw CullingServiceError.tooManyPhotoIds }
        let entry = getSessionUpdateContext(sessionId: sessionId)
        // 先在缓存索引里校验照片 id（任何相似度读之前，见 ensureUpdateExtras）。
        // 缺失可能是索引器刚加的照片（TTL 缓存不可见），先试一次新鲜读再拒绝。
        if uniqueIds.contains(where: { entry.photoById[$0] == nil }) {
            refreshSessionUpdateContext(sessionId: sessionId, entry: entry)
            if uniqueIds.contains(where: { entry.photoById[$0] == nil }) {
                throw CullingServiceError.photosNotInSession
            }
        }
        try ensureUpdateExtras(entry: entry, sessionId: sessionId)
        let photos = entry.photos
        let photoById = entry.photoById
        let groupMap = entry.groupMap!
        let linkedByXmp = entry.linkedByXmp!
        // pick 更新按逻辑资产合并（同一资产的变体只更新一次），否则按共享侧车
        // 合并（RAW+JPEG 对的 rating/label 一次入队）。
        var operationIds: [String] = []
        var operationKeys: Set<String> = []
        for photoId in uniqueIds {
            let photo = photoById[photoId]!
            let key = patch.pickState == nil
                ? TSPath.xmpSidecarPath(photo.filepath)
                : (photo.assetId ?? "photo:\(photo.id)")
            if operationKeys.insert(key).inserted {
                operationIds.append(photoId)
            }
        }
        var results: [CullingUpdateResult] = []
        let historySink = CullingHistorySink()
        // 一次 IN 查询预读全部操作目标的决策行，替代事务内逐项 getDecision
        //（N+1 单行查询）。预读与事务在同一同步 tick 内，且每个照片每批最多写
        // 一次（操作 id 按逻辑资产/侧车唯一），故预读的 revision 不会过期。
        let currentRows = Dictionary(
            uniqueKeysWithValues: try await (cullingStore?.decisions(sessionId: sessionId, photoIds: operationIds) ?? [])
                .map { ($0.photoId, $0) }
        )
        let batchCache = try await metadataStore.metadataBatch(photoIds: operationIds)
        let batchCacheRows = Dictionary(uniqueKeysWithValues: batchCache.map { ($0.photoId, $0) })
        try connection.transaction {
            for photoId in operationIds {
                let current = currentRows[photoId]
                results.append(try updateState(
                    sessionId: sessionId,
                    photoId: photoId,
                    expectedRevision: Int(current?.revision ?? 0),
                    patch: patch,
                    context: CullingUpdateContext(
                        photos: photos,
                        photoById: photoById,
                        photosByAssetId: entry.photosByAssetId,
                        groupMap: groupMap,
                        linkedByXmp: linkedByXmp,
                        historySink: historySink,
                        cacheRows: batchCacheRows,
                        currentDecision: current,
                        decisionRows: currentRows
                    )
                ))
            }
        }
        // 历史栈在 Store 连接上（跨连接不共享事务）；快照已随事务原子落地，
        // 历史行失败仅丢失 undo 能力，不影响决策结果。
        try await commitCachePatches(historySink.cachePatches)
        try await commitDecisionWrites(historySink.decisionWrites)
        if !historySink.entries.isEmpty {
            if let operationId = try await cullingStore?.appendHistory(
                sessionId: sessionId, entries: historySink.entries
            ).id {
                for index in results.indices {
                    results[index].historyOperationId = operationId
                }
            }
        }
        return results
    }

    /// TS: applyHistory —— 应用显式条目（renderer 重建的补丁）或历史栈操作
    /// （undo/redo，按操作 id 解析 entries）；带操作 id 时校验并发边界。
    /// 注：TS 参数 `historyOperationId` 在函数内被重新赋值（append 结果），
    /// 故 Swift 侧为 var。
    @discardableResult
    public func applyHistory(
        sessionId: String,
        requestedEntries: [CullingHistoryApplyEntry],
        historyOperationId: Int? = nil,
        direction: CullingHistoryDirection? = nil
    ) async throws -> [CullingUpdateResult] {
        var historyOperationId = historyOperationId
        var entries = requestedEntries
        var historicalFields: [String: [CullingUpdatePatchField]] = [:]
        if let historyOperationId, let direction {
            guard let operation = try await cullingStore?.historyOperation(sessionId: sessionId, operationId: historyOperationId) else {
                throw CullingServiceError.historyNotFound
            }
            if operation.undone != (direction == .redo) {
                throw direction == .undo
                    ? CullingServiceError.historyAlreadyUndone
                    : CullingServiceError.historyNotUndone
            }
            historicalFields = Dictionary(
                uniqueKeysWithValues: operation.entries.map { ($0.photoId, $0.fields) }
            )
            entries = operation.entries.map { entry in
                // 操作 id 与顺序是并发守卫。revision 从当前数据库状态解析，
                // 使连续 undo/redo 在插入中间历史操作与应用重启后仍然有效。
                CullingHistoryApplyEntry(
                    photoId: entry.photoId,
                    expectedRevision: -1,
                    patch: patchFromSnapshot(
                        fields: entry.fields,
                        snapshot: direction == .undo ? entry.before : entry.after
                    )
                )
            }
        }
        if entries.isEmpty { return [] }
        let unique = Set(entries.map(\.photoId))
        // ADR-017: internal-invariant diagnostic —— 损坏的历史载荷。
        if unique.count != entries.count {
            throw CullingServiceError.historyDuplicatePhotos
        }
        for entry in entries { try validatePatch(entry.patch) }
        let updateEntry = getSessionUpdateContext(sessionId: sessionId)
        // 与 updateState/batchUpdate 相同的 fresh-read 兜底：索引器刚加的照片
        // 可能缺席 TTL 缓存。
        if entries.contains(where: { updateEntry.photoById[$0.photoId] == nil }) {
            refreshSessionUpdateContext(sessionId: sessionId, entry: updateEntry)
        }
        let photoById = updateEntry.photoById
        let currentRows = Dictionary(
            uniqueKeysWithValues: try await (cullingStore?.decisions(
                sessionId: sessionId, photoIds: entries.map(\.photoId)) ?? [])
                .map { ($0.photoId, $0) }
        )
        let cacheRows = Dictionary(
            uniqueKeysWithValues: try await metadataStore.metadataBatch(photoIds: entries.map(\.photoId))
                .map { ($0.photoId, $0) }
        )
        for entry in entries {
            guard photoById[entry.photoId] != nil else {
                throw CullingServiceError.photoNotInSession
            }
            let currentRevision = currentRows[entry.photoId]?.revision ?? 0
            if historyOperationId == nil && currentRevision != Int64(entry.expectedRevision) {
                throw CullingServiceError.revisionConflict(
                    expected: entry.expectedRevision, current: Int(currentRevision)
                )
            }
        }
        if let historyOperationId, let direction {
            let operation = try await cullingStore?.historyOperation(sessionId: sessionId, operationId: historyOperationId)
            for historical in operation?.entries ?? [] {
                let row = currentRows[historical.photoId]
                let cache = cacheRows[historical.photoId]
                let current = rowToState(
                    photoId: historical.photoId, row: row,
                    fallbackRating: cache?.rating ?? 0, fallbackLabel: cache?.label ?? "None"
                )
                let expected = direction == .undo ? historical.after : historical.before
                for field in historical.fields {
                    if !matchesSnapshot(state: current, snapshot: expected, field: field) {
                        throw CullingServiceError.historyDiverged
                    }
                }
            }
        }
        try ensureUpdateExtras(entry: updateEntry, sessionId: sessionId)
        let groupMap = updateEntry.groupMap!

        // outbox 每会话读一次而非每条目两次（1 万次 undo 就是 2 万次单行查询）：
        // 行按 xmp 路径键控，事务内的 syncStatus 读取全部发生在
        // queuePhotoValues 写任何 outbox 行之前（写入在循环之后）。
        var outboxByPath = Dictionary(
            uniqueKeysWithValues: try metadataOutboxRepo
                .getBySession(sessionId)
                .map { ($0.xmpPath, $0) }
        )
        func outboxStatus(_ xmpPath: String) -> MetadataSyncStatus {
            MetadataSyncStatus(rawValue: outboxByPath[xmpPath]?.status ?? "") ?? .clean
        }

        var results: [CullingUpdateResult] = []
        var historyEntries: [CullingHistoryEntry] = []
        var xmpPatches: [String: (photoId: String, values: [String: JSONValue])] = [:]
        let writeSink = CullingHistorySink()
        try connection.transaction {
            for entry in entries {
                let photo = photoById[entry.photoId]!
                let existing = currentRows[entry.photoId]
                let cache = cacheRows[entry.photoId]
                let before = rowToState(
                    photoId: entry.photoId, row: existing,
                    fallbackRating: cache?.rating ?? 0, fallbackLabel: cache?.label ?? "None"
                )
                let after = AssetCullingState(
                    photoId: entry.photoId,
                    pickState: entry.patch.pickState ?? before.pickState,
                    rating: entry.patch.rating ?? before.rating,
                    colorLabel: entry.patch.colorLabel ?? before.colorLabel,
                    source: .manual,
                    revision: before.revision + 1,
                    updatedAt: nowISOString()
                )
                writeSink.appendDecisionWrite(CullingDecisionWrite(
                    sessionId: sessionId,
                    photoId: entry.photoId,
                    groupId: groupMap[entry.photoId] ?? "ungrouped",
                    state: CullingDecisionState(
                        decision: pickStateToDecision(after.pickState).rawValue,
                        rating: Int64(after.rating),
                        colorLabel: after.colorLabel.rawValue,
                        revision: Int64(after.revision)
                    )
                ))
                if entry.patch.rating != nil {
                    writeSink.appendCachePatch(
                        CullingCachePatch(photoId: entry.photoId, rating: Int64(after.rating)))
                }
                if entry.patch.colorLabel != nil {
                    writeSink.appendCachePatch(
                        CullingCachePatch(photoId: entry.photoId, label: after.colorLabel.rawValue))
                }
                let xmpPath = TSPath.xmpSidecarPath(photo.filepath)
                var values = xmpPatches[xmpPath]?.values ?? [:]
                if entry.patch.rating != nil { values["rating"] = .number(after.rating) }
                if entry.patch.colorLabel != nil {
                    values["label"] = .string(after.colorLabel == .none ? "" : after.colorLabel.rawValue)
                }
                if !values.isEmpty {
                    xmpPatches[xmpPath] = (photoId: entry.photoId, values: values)
                }
                historyEntries.append(CullingHistoryEntry(
                    photoId: entry.photoId,
                    before: CullingStateSnapshot(
                        pickState: before.pickState, rating: before.rating, colorLabel: before.colorLabel
                    ),
                    after: CullingStateSnapshot(
                        pickState: after.pickState, rating: after.rating, colorLabel: after.colorLabel
                    ),
                    expectedRevision: after.revision,
                    fields: historicalFields[entry.photoId] ?? patchFields(entry.patch)
                ))
                results.append(CullingUpdateResult(
                    states: [after],
                    xmpPath: xmpPath,
                    syncStatus: outboxStatus(xmpPath)
                ))
            }
            for (photoId, values) in xmpPatches.values {
                _ = try metadataMutations.queuePhotoValues(
                    sessionId: sessionId,
                    photoId: photoId,
                    values: values,
                    source: .culling,
                    schedule: false
                )
            }
        }
        // 历史/缓存列在 Store 连接上（跨连接不共享事务）；决策已原子落地。
        try await commitCachePatches(writeSink.cachePatches)
        try await commitDecisionWrites(writeSink.decisionWrites)
        if let operationId = historyOperationId, let direction {
            try await cullingStore?.setHistoryUndone(
                sessionId: sessionId,
                operationId: operationId,
                undone: direction == .undo
            )
        } else if let cullingStore, !historyEntries.isEmpty {
            historyOperationId = try await cullingStore.appendHistory(
                sessionId: sessionId, entries: historyEntries
            ).id
        }
        for xmpPath in xmpPatches.keys {
            metadataSync.schedule(xmpPath: xmpPath)
        }
        // queuePhotoValues 在事务内写 outbox（mergePatch 把状态 bump 到
        // 'pending'），预读快照再用一次批量读刷新——返回的状态必须反映写后行。
        for row in try metadataOutboxRepo.getBySession(sessionId) {
            outboxByPath[row.xmpPath] = row
        }
        for index in results.indices {
            results[index].syncStatus = outboxStatus(results[index].xmpPath)
            results[index].historyOperationId = historyOperationId
        }
        return results
    }

    /// TS: decideSimilarityGroup —— 整组批量 keep/reject（K 保留 + 其余拒绝）。
    public func decideSimilarityGroup(
        sessionId: String,
        groupId: String,
        keepPhotoIds: [String]
    ) async throws -> [CullingUpdateResult] {
        guard keepPhotoIds.count <= Self.batchMax else { throw CullingServiceError.tooManyKeepPhotoIds }
        guard let resultRow = try similarityResultRepo.getLatest(sessionId: sessionId) else {
            throw CullingServiceError.noSimilarity
        }
        // TS: `[...membership.entries()].filter(...)` —— Map 插入序即成员表行序；
        // Swift 侧经 getGroupMembers（ORDER BY m.rowid）保持同一顺序；组 id 与
        // 最新结果派生的完整 "resultId:index" 精确相等（旧结果的组 id 匹配不到）。
        let groupPhotoIds: [String]
        if let members = try similarityResultRepo.getGroupMembers(sessionId: sessionId, resultId: resultRow.id) {
            groupPhotoIds = members
                .filter { "\(resultRow.id):\($0.groupIndex)" == groupId }
                .map(\.photoId)
        } else {
            groupPhotoIds = []
        }
        if groupPhotoIds.count < 2 { throw CullingServiceError.groupTooSmall }

        var keepIds: [String] = []
        for photoId in keepPhotoIds where !keepIds.contains(photoId) {
            keepIds.append(photoId)
        }
        let groupIdSet = Set(groupPhotoIds)
        if keepIds.isEmpty || keepIds.count >= groupPhotoIds.count
            || keepIds.contains(where: { !groupIdSet.contains($0) }) {
            throw CullingServiceError.keepNotInGroup
        }
        let keepIdSet = Set(keepIds)
        let currentRows = Dictionary(
            uniqueKeysWithValues: try await (cullingStore?.decisions(
                sessionId: sessionId, photoIds: groupPhotoIds) ?? [])
                .map { ($0.photoId, $0) }
        )
        return try await applyHistory(
            sessionId: sessionId,
            requestedEntries: groupPhotoIds.map { photoId in
                CullingHistoryApplyEntry(
                    photoId: photoId,
                    expectedRevision: Int(currentRows[photoId]?.revision ?? 0),
                    patch: CullingUpdatePatch(
                        pickState: keepIdSet.contains(photoId) ? .picked : .rejected
                    )
                )
            }
        )
    }

    /// TS: getGroups —— 相似度分组（决策计数 + 成员轻投影）。
    public func getGroups(sessionId: String) async throws -> [CullingGroup] {
        guard let resultRow = try similarityResultRepo.getLatest(sessionId: sessionId) else {
            return []
        }
        // 轻投影：只取 id/filepath/filename，重 JSON 列跳过。
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .map { CullingPhotoRow(row: $0) }
        let photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        let membership = try similarityResultRepo.getPhotoGroupMap(sessionId: sessionId, resultId: resultRow.id)
        var membersByGroup: [String: [String]] = [:]
        for photo in photos {
            guard let groupId = membership[photo.id] else { continue }
            membersByGroup[groupId, default: []].append(photo.id)
        }
        let decisions = Dictionary(
            uniqueKeysWithValues: try await (cullingStore?.decisionsFull(sessionId: sessionId) ?? [])
                .map { ($0.photoId, $0.decision) }
        )

        var groups: [(index: Int, insertion: Int, group: CullingGroup)] = []
        var insertion = 0
        for (groupId, photoIds) in membersByGroup {
            // 损坏的遗留成员行不得产生打乱组排序的 NaN 键。
            let parsedIndex = Int(groupId.split(separator: ":").last ?? "") ?? 0
            var keepCount = 0
            var rejectCount = 0
            var pendingCount = 0
            var images: [CullingImage] = []
            for photoId in photoIds {
                guard let photo = photoById[photoId] else { continue }
                let decision = decisions[photoId] ?? "pending"
                if decision == "keep" { keepCount += 1 }
                else if decision == "reject" { rejectCount += 1 }
                else { pendingCount += 1 }
                images.append(CullingImage(
                    photoId: photoId,
                    filepath: photo.filepath,
                    filename: photo.filename,
                    decision: LegacyCullingDecision(rawValue: decision) ?? .pending
                ))
            }
            groups.append((index: parsedIndex, insertion: insertion, group: CullingGroup(
                groupId: groupId,
                groupIndex: parsedIndex,
                images: images,
                keepCount: keepCount,
                rejectCount: rejectCount,
                pendingCount: pendingCount
            )))
            insertion += 1
        }
        // 稳定排序（TS Array.sort 稳定；Swift sort 不保证稳定，同索引时按首见序）。
        return groups
            .sorted { $0.index == $1.index ? $0.insertion < $1.insertion : $0.index < $1.index }
            .map(\.group)
    }

    /// TS: decide —— 旧版 renderer 的单张决策命令。
    @discardableResult
    public func decide(
        sessionId: String, photoId: String, decision: LegacyCullingDecision
    ) async throws -> CullingUpdateResult {
        let current = try await cullingStore?.decision(sessionId: sessionId, photoId: photoId)
        return try await update(
            sessionId: sessionId,
            photoId: photoId,
            expectedRevision: Int(current?.revision ?? 0),
            patch: CullingUpdatePatch(pickState: decisionToPickState(decision))
        )
    }

    /// TS: batchDecide —— 旧版 renderer 的批量决策命令。
    public func batchDecide(sessionId: String, photoIds: [String], decision: LegacyCullingDecision) async throws {
        try await batchUpdate(
            sessionId: sessionId,
            photoIds: photoIds,
            patch: CullingUpdatePatch(pickState: decisionToPickState(decision))
        )
    }

    /// TS: getDecisions —— 写回计划的决策输入（photo_id, decision）。
    public func getDecisions(sessionId: String) async throws -> [CullingDecisionLite] {
        try await cullingStore?.decisions(sessionId: sessionId) ?? []
    }

    /// TS: getHistory —— 历史栈（limit 缺省 100，仓库内 clamp 到 500）。
    public func getHistory(sessionId: String, limit: Int = 100) async throws -> [CullingHistoryOperation] {
        try await cullingStore?.historyList(sessionId: sessionId, limit: limit) ?? []
    }

    /// TS: getSummary —— 徽标计数（决策 + 缓存 fallback + 相似度组数）。
    public func getSummary(sessionId: String) async throws -> CullingSummary {
        // 轻投影：计数只需照片 id。
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .map { CullingPhotoRow(row: $0) }
        let decisions = try await (cullingStore?.decisionsFull(sessionId: sessionId) ?? [])
        let decisionByPhoto = Dictionary(uniqueKeysWithValues: decisions.map { ($0.photoId, $0) })
        // 决策与缓存读每次调用保持新鲜：renderer 在每次 update/undo/redo 后重取
        // summary，徽标必须反映刚完成的写入，故每会话缓存永不在此复用。
        let cacheByPhoto = try loadSummaryCacheByPhoto(photos)
        var kept = 0
        var rejected = 0
        var rated = 0
        var labeled = 0
        for photo in photos {
            let row = decisionByPhoto[photo.id]
            let cache = cacheByPhoto[photo.id]
            if row?.decision == "keep" { kept += 1 }
            if row?.decision == "reject" { rejected += 1 }
            if ((row?.rating ?? cache?.rating ?? 0) > 0) { rated += 1 }
            let label = row?.colorLabel ?? cache?.label ?? "None"
            if let parsed = CaptureOneColorLabel(rawValue: label),
               Self.colorLabels.contains(parsed), parsed != .none {
                labeled += 1
            }
        }
        // 组数来自会话查找条目（版本键控）：stats_json.totalGroups 是小组件对象，
        // 替代多 MB 的 groups_json 解析，结果按 (session, result id) 缓存。
        let lookup = try getSessionLookup(sessionId: sessionId)
        var totalGroups = 0
        if lookup.resultRow != nil {
            if !lookup.groupCountResolved {
                lookup.groupCount = parseTotalGroups(lookup.resultRow!)
                lookup.groupCountResolved = true
            }
            totalGroups = lookup.groupCount
        }
        return CullingSummary(
            totalGroups: totalGroups,
            totalPhotos: photos.count,
            kept: kept,
            rejected: rejected,
            pending: max(0, photos.count - kept - rejected),
            rated: rated,
            labeled: labeled
        )
    }

    /// TS: reset —— 清空会话决策（可选按组）。
    public func reset(sessionId: String, groupId: String? = nil) async throws {
        if let groupId {
            try await cullingStore?.deleteDecisions(sessionId: sessionId, groupId: groupId)
        } else {
            try await cullingStore?.deleteDecisions(sessionId: sessionId)
        }
    }

    /// TS: invalidateSessionLookup —— 后台分析服务（quality/face-keyword）跑完
    /// 一轮后调用：缓存的质量/人脸/人物映射不得在 TTL 窗口内保持陈旧。
    public func invalidateSessionLookup(sessionId: String) {
        sessionLookupCache.removeValue(forKey: sessionId)
    }

    // MARK: - IPC 命令面（culling.ipc.ts 逐命令对齐）

    /// TS: culling.sync_status → metadataSync.getSummary。
    public func syncStatus(sessionId: String) throws -> MetadataSyncSummary {
        try metadataSync.getSummary(sessionId: sessionId)
    }

    /// TS: culling.flush → metadataSync.flushSession。
    public func flush(sessionId: String) async throws -> MetadataSyncSummary {
        try await metadataSync.flushSession(sessionId: sessionId)
    }

    /// TS: culling.retry_sync → metadataSync.retrySession。
    public func retrySync(sessionId: String) async throws -> MetadataSyncSummary {
        try await metadataSync.retrySession(sessionId: sessionId)
    }

    /// TS: culling.finalize_sync（confirmed 必须为 true，否则
    /// CULLING_FINALIZE_CONFIRM_REQUIRED）。
    public func finalizeSync(sessionId: String, confirmed: Bool) async throws -> MetadataSyncSummary {
        guard confirmed else { throw CullingServiceError.finalizeConfirmRequired }
        return try await metadataSync.finalizeSession(sessionId: sessionId)
    }

    /// TS: culling.writeback —— 决策计划 → preview → 属性合并 → execute。
    /// 写回引擎由注入的 WritebackService 承担，本方法只组装计划与合并关键词。
    public func writeback(
        sessionId: String,
        target: CullingWritebackTarget,
        confirmed: Bool
    ) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackConfirmRequired }
        let plan = buildCullingWritebackPlan(
            decisions: try await getDecisions(sessionId: sessionId)
                .map { (photoId: $0.photoId, decision: $0.decision) },
            target: target
        )
        if plan.isEmpty { throw CullingServiceError.noDecisions }

        let decidedPhotoIds = Set(plan.keys)
        let preview = try await writeback.preview(
            sessionId: sessionId,
            module: "culling",
            options: WritebackOptions(),
            photoIds: decidedPhotoIds,
            keywordAdditions: nil
        )
        var matchingItems = preview.items.filter { decidedPhotoIds.contains($0.photoId) }
        for index in matchingItems.indices {
            guard let attributes = plan[matchingItems[index].photoId],
                  matchingItems[index].id != nil else { continue }
            if let keywords = attributes.keywords {
                // TS: { keywords: [...new Set([...item.keywords, ...attributes.keywords])] }
                var merged: [String] = []
                for value in matchingItems[index].keywords + keywords
                where !merged.contains(value) {
                    merged.append(value)
                }
                matchingItems[index].attributes = WritebackAttributes(keywords: merged)
            } else {
                matchingItems[index].attributes = attributes
            }
        }
        try writeback.persistAttributes(items: matchingItems)
        return try await writeback.execute(sessionId: sessionId, module: "culling", items: matchingItems)
    }

    /// TS: culling.retry_failed_writeback（confirmed 必须为 true，否则
    /// WRITEBACK_RETRY_CONFIRM_REQUIRED）。
    public func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackRetryConfirmRequired }
        return try await writeback.retryFailed(sessionId: sessionId, module: "culling")
    }

    /// TS: culling.confirm_sync —— 协调器确认 + 写回项存在时的写回确认。
    public func confirmSync(sessionId: String) async throws {
        _ = try metadataSync.confirmSync(sessionId: sessionId, sourceModule: "culling")
        if try writeback.getItems(sessionId: sessionId, module: "culling", status: nil).count > 0 {
            try await writeback.confirmSync(sessionId: sessionId, module: "culling")
        }
    }

    /// TS: culling.cleanup（confirmed 必须为 true，否则
    /// WRITEBACK_CLEANUP_CONFIRM_REQUIRED）—— 协调器清理 + 写回清理的并集。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        guard confirmed else { throw CullingServiceError.writebackCleanupConfirmRequired }
        let backgroundResult = try await metadataSync.cleanup(sessionId: sessionId, sourceModule: "culling")
        let explicitResult = try await writeback.cleanup(sessionId: sessionId, module: "culling")
        return CleanupResult(
            deletedCount: backgroundResult.deletedCount + explicitResult.deletedCount,
            errors: backgroundResult.errors + explicitResult.errors
        )
    }

    /// TS: culling.reset（confirmed 必须为 true，否则
    /// CULLING_RESET_CONFIRM_REQUIRED）。
    public func resetCommand(sessionId: String, groupId: String? = nil, confirmed: Bool) async throws {
        guard confirmed else { throw CullingServiceError.resetConfirmRequired }
        try await reset(sessionId: sessionId, groupId: groupId)
    }

    // MARK: - 分页（TS pagePhotosQuery / loadAssetRows / preferredRowPredicate /
    // buildFilteredWhere / buildSimilarityClause / countForScope）

    /// TS: pagePhotosQuery —— 三 scope 共用的两步资产分组 keyset 页：
    /// 1. 取至多 limit 个资产组（按组首 rowid 排序，first_rowid > afterRowId）；
    /// 2. 取这些组的全部行（一页恒为完整资产）。
    /// afterRowId 是上一页的 nextRowId（其最后资产组的首 rowid）；cursor 是
    /// 当前页组查询的 first_rowid —— 绝非从已加载行推导的值（最小 rowid 可能
    /// 属于不匹配谓词的变体，重新推导会让下一页重复选中该资产）。
    private func pagePhotosQuery(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        afterRowId: Int64?,
        limit: Int
    ) throws -> (photos: [CullingPhotoRow], cursor: Int64?) {
        if scope == .filtered {
            let whereClause = buildFilteredWhere(sessionId: sessionId, filters: filters)
            let groups = try connection.prepare("""
                SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid, MIN(p.rowid) AS first_rowid
                FROM photos p
                LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
                LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
                WHERE \(whereClause.sql)
                GROUP BY COALESCE(NULLIF(p.asset_id, ''), p.id)
                HAVING MIN(p.rowid) > ?
                ORDER BY first_rowid
                LIMIT ?
              """).query(whereClause.params + [.int(afterRowId ?? 0), .int(Int64(limit))])
            let gids = groups.map { (gid: $0[0].textValue ?? "", firstRowid: $0[1].intValue ?? 0) }
            return (
                photos: try loadAssetRows(sessionId: sessionId, groups: gids),
                cursor: gids.last?.firstRowid
            )
        }
        if scope == .similarityGroup {
            let similarity = buildSimilarityClause(sessionId: sessionId, requestedGroupId: requestedGroupId)
            if let similarity {
                let groups = try connection.prepare("""
                    SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid, MIN(p.rowid) AS first_rowid
                    FROM photos p
                    WHERE p.session_id = ? AND \(similarity.sql) AND \(preferredRowPredicate())
                    GROUP BY COALESCE(NULLIF(p.asset_id, ''), p.id)
                    HAVING MIN(p.rowid) > ?
                    ORDER BY first_rowid
                    LIMIT ?
                  """).query(
                    [.text(sessionId)] + similarity.params
                        + [.int(afterRowId ?? 0), .int(Int64(limit))]
                )
                let gids = groups.map { (gid: $0[0].textValue ?? "", firstRowid: $0[1].intValue ?? 0) }
                return (
                    photos: try loadAssetRows(sessionId: sessionId, groups: gids),
                    cursor: gids.last?.firstRowid
                )
            }
        }
        let page = try photoRepo.getAssetPage(sessionId: sessionId, afterFirstRowid: afterRowId, limit: limit)
        return (photos: page.rows.map { CullingPhotoRow(row: $0) }, cursor: page.cursor)
    }

    /// TS: loadAssetRows —— 取给定资产组的全部行（分块，SQLite 参数上限内）。
    private func loadAssetRows(
        sessionId: String,
        groups: [(gid: String, firstRowid: Int64)]
    ) throws -> [CullingPhotoRow] {
        if groups.isEmpty { return [] }
        var rows: [CullingPhotoRow] = []
        for chunkStart in stride(from: 0, to: groups.count, by: Self.chunkSize) {
            let chunk = groups[chunkStart..<min(chunkStart + Self.chunkSize, groups.count)].map(\.gid)
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let chunkRows = try connection.prepare("""
                SELECT \(PhotoRepo.photoPageColumns)
                FROM photos p
                WHERE p.session_id = ? AND COALESCE(NULLIF(p.asset_id, ''), p.id) IN (\(placeholders))
                ORDER BY p.rowid
              """).query([.text(sessionId)] + chunk.map { .text($0) })
            rows.append(contentsOf: try chunkRows.map { try CullingPhotoRow(row: PhotoPageRow(row: $0)) })
        }
        return rows
    }

    /// TS: preferredRowPredicate —— 每个资产组限定到首选行的 SQL 谓词：RAW 变体
    /// 优先（与 JS 侧 assembleAssets 的偏好同一扩展名表），其次最小 rowid。谓词
    /// 对未分组照片是 no-op（gid = id ⇒ 子查询返回自身）。
    private func preferredRowPredicate() -> String {
        "p.id = (" +
            "SELECT p2.id FROM photos p2" +
            " WHERE p2.session_id = p.session_id" +
            " AND COALESCE(NULLIF(p2.asset_id, ''), p2.id) = COALESCE(NULLIF(p.asset_id, ''), p.id)" +
            " ORDER BY CASE WHEN \(PhotoRepo.rawExtensionLikeSQL) THEN 1 ELSE 0 END DESC, p2.rowid" +
            " LIMIT 1" +
        ")"
    }

    /// TS: buildFilteredWhere —— matchesFilters 的精确超集（除 metadataConflictOnly
    /// —— 它依赖 JS 计算的 XMP 侧车路径）。谓词作用于构建资产组的照片，页面游标
    /// 留在组查询的 HAVING 里。
    private func buildFilteredWhere(
        sessionId: String,
        filters: CullingFilters?
    ) -> (sql: String, params: [DBValue?]) {
        var clauses: [String] = ["p.session_id = ?"]
        var params: [DBValue?] = [.text(sessionId)]
        if let filters {
            if filters.unreviewedOnly == true {
                clauses.append("COALESCE(d.decision, 'pending') = 'pending'")
            }
            if let pickStates = filters.pickStates, !pickStates.isEmpty {
                let decisions = pickStates.map { state -> String in
                    switch state {
                    case .picked: "keep"
                    case .rejected: "reject"
                    case .unreviewed: "pending"
                    }
                }
                let placeholders = decisions.map { _ in "?" }.joined(separator: ",")
                clauses.append("COALESCE(d.decision, 'pending') IN (\(placeholders))")
                params.append(contentsOf: decisions.map { .text($0) })
            }
            if let ratings = filters.ratings, !ratings.isEmpty {
                let placeholders = ratings.map { _ in "?" }.joined(separator: ",")
                clauses.append("COALESCE(d.rating, c.rating, 0) IN (\(placeholders))")
                params.append(contentsOf: ratings.map { DBValue.real($0) })
            }
            if let colorLabels = filters.colorLabels, !colorLabels.isEmpty {
                let placeholders = colorLabels.map { _ in "?" }.joined(separator: ",")
                clauses.append("""
                    COALESCE(NULLIF(d.color_label, ''), NULLIF(c.label, ''), 'None') IN (\(placeholders))
                    """)
                params.append(contentsOf: colorLabels.map { .text($0.rawValue) })
            }
            if filters.qualityStatus == .analysed || filters.qualityStatus == .failed {
                // json_valid() 防护历史行 result_json 非法的情形：
                // json_extract() 否则会抛 malformed-JSON 错误使整页查询失败。
                clauses.append("""
                    json_extract(COALESCE((
                      SELECT a3.result_json
                      FROM asset_analysis a3
                      WHERE a3.asset_file_id = p.asset_file_id
                        AND a3.analysis_type = 'technical_quality'
                        AND json_valid(a3.result_json)
                      ORDER BY a3.updated_at DESC
                      LIMIT 1
                    ), '{}'), '$.status') = ?
                    """)
                params.append(.text(filters.qualityStatus == .analysed ? "succeeded" : "failed"))
            }
            if filters.qualityStatus == .unanalysed {
                // 只有合法 JSON 的行算作已分析；result_json 损坏视为无质量结果，
                // NOT EXISTS 守卫必须镜像该语义（见上方 analysed/failed 分支）。
                clauses.append("""
                    NOT EXISTS (
                      SELECT 1 FROM asset_analysis a3
                      WHERE a3.asset_file_id = p.asset_file_id
                        AND a3.analysis_type = 'technical_quality'
                        AND json_valid(a3.result_json)
                    )
                    """)
            }
        }
        clauses.append(preferredRowPredicate())
        return (clauses.joined(separator: " AND "), params)
    }

    /// TS: buildSimilarityClause —— 相似度组成员关系的 SQL 谓词。组 id 无法解析
    /// 时返回 nil（页面改经 JS 相似度映射过滤，仍精确、可能不满页）。
    private func buildSimilarityClause(
        sessionId: String,
        requestedGroupId: String?
    ) -> (sql: String, params: [DBValue?])? {
        if let requestedGroupId {
            let separator = requestedGroupId.lastIndex(of: ":")
            guard let separator else { return nil }
            // TS: Number(slice) —— 非整数（含 NaN）→ 无法解析 → nil 子句。
            guard let resultId = Int(requestedGroupId[requestedGroupId.startIndex..<separator]),
                  let groupIndex = Int(requestedGroupId[requestedGroupId.index(after: separator)...]) else {
                return nil
            }
            return (
                sql: """
                EXISTS (
                  SELECT 1 FROM similarity_result_members srm
                  WHERE srm.result_id = ? AND srm.group_index = ? AND srm.session_id = ?
                    AND srm.photo_id = p.id
                )
                """,
                params: [.int(Int64(resultId)), .int(Int64(groupIndex)), .text(sessionId)]
            )
        }
        // 预计算阈值层共享同一张表（stats_json 的标记，见 similarity-result.repo）：
        // 裸 MAX(id) 会选中最新层而非 getLatest 解析到的分析/重聚类行，故 JS 侧
        // 相似度映射与 SQL 谓词必须一致。
        return (
            sql: """
            EXISTS (
              SELECT 1 FROM similarity_result_members srm
              WHERE srm.session_id = ? AND srm.photo_id = p.id
                AND srm.result_id = (
                  SELECT MAX(id) FROM similarity_results
                  WHERE session_id = ? AND stats_json NOT LIKE '%"precomputed":true%'
                )
            )
            """,
            params: [.text(sessionId), .text(sessionId)]
        )
    }

    /// TS: countForScope —— scope/filters 的逻辑资产计数（total 匹配胶片条加载
    /// 全部页后的条目数：每资产一条，非每物理照片行一条）。
    private func countForScope(
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        similarityMap: [String: String]
    ) throws -> Int {
        if scope == .similarityGroup {
            let similarity = buildSimilarityClause(sessionId: sessionId, requestedGroupId: requestedGroupId)
            if let similarity {
                let row = try connection.prepare("""
                    SELECT COUNT(*) AS count
                    FROM (SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
                          FROM photos p
                          WHERE p.session_id = ? AND \(similarity.sql)
                            AND \(preferredRowPredicate())
                          GROUP BY gid)
                  """).get([.text(sessionId)] + similarity.params)
                return Int(row?[0].intValue ?? 0)
            }
            // 无法解析的组 id：无 SQL 谓词，按 JS 相似度映射计数（去重成员照片）。
            if let requestedGroupId {
                var count = 0
                for groupId in similarityMap.values where groupId == requestedGroupId {
                    count += 1
                }
                return count
            }
            return similarityMap.count
        }
        if scope == .filtered {
            let whereClause = buildFilteredWhere(sessionId: sessionId, filters: filters)
            let row = try connection.prepare("""
                SELECT COUNT(*) AS count
                FROM (SELECT COALESCE(NULLIF(p.asset_id, ''), p.id) AS gid
                      FROM photos p
                      LEFT JOIN culling_decisions d ON d.session_id = p.session_id AND d.photo_id = p.id
                      LEFT JOIN photo_metadata_cache c ON c.photo_id = p.id
                      WHERE \(whereClause.sql)
                      GROUP BY gid)
              """).get(whereClause.params)
            return Int(row?[0].intValue ?? 0)
        }
        return try photoRepo.countAssetsBySession(sessionId: sessionId)
    }

    // MARK: - 富查询（TS buildRichLookup 及支撑）

    /// TS: withChunkedIds。
    private func withChunkedIds<T>(
        _ ids: [String],
        query: ([String]) throws -> [T]
    ) throws -> [T] {
        var rows: [T] = []
        for chunkStart in stride(from: 0, to: ids.count, by: Self.chunkSize) {
            let chunk = Array(ids[chunkStart..<min(chunkStart + Self.chunkSize, ids.count)])
            rows.append(contentsOf: try query(chunk))
        }
        return rows
    }

    /// TS: loadOutboxByPaths —— 按 xmp 路径批量读 outbox 行。
    private func loadOutboxByPaths(
        sessionId: String,
        xmpPaths: [String]
    ) throws -> [String: MetadataOutboxRow] {
        let unique = Array(Set(xmpPaths))
        var rows: [MetadataOutboxRow] = []
        try withChunkedIds(unique) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try connection.prepare("""
                SELECT o.*
                FROM metadata_outbox o
                JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
                WHERE os.session_id = ? AND o.xmp_path IN (\(placeholders))
              """).query([.text(sessionId)] + chunk.map { .text($0) })
                .map { MetadataOutboxRow(row: $0) }
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.xmpPath, $0) })
    }

    /// TS: loadQualityByPhoto —— technical_quality 分析行 → 每照片质量对象。
    private func loadQualityByPhoto(photos: [CullingPhotoRow]) throws -> [String: CullingQuality] {
        var qualityByPhoto: [String: CullingQuality] = [:]
        if photos.isEmpty { return qualityByPhoto }
        struct QualityRow {
            let requestedPhotoId: String
            let resultJSON: String
        }
        let qualityRows: [QualityRow] = try withChunkedIds(photos.map(\.id)) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT p.id AS requested_photo_id, aa.result_json
                FROM photos p
                JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
                WHERE aa.analysis_type = 'technical_quality'
                  AND p.id IN (\(placeholders))
                ORDER BY aa.updated_at DESC
              """).query(chunk.map { .text($0) })
            return rows.map {
                QualityRow(
                    requestedPhotoId: $0[0].textValue ?? "",
                    resultJSON: $0[1].textValue ?? "{}"
                )
            }
        }
        for row in qualityRows {
            // 忽略损坏的历史分析行（TS try/catch）。
            guard let parsed = try? JSONValue.parse(row.resultJSON),
                  case .object(let dict) = parsed,
                  qualityByPhoto[row.requestedPhotoId] == nil else { continue }
            qualityByPhoto[row.requestedPhotoId] = CullingQuality(
                status: CullingQualityStatus(rawValue: dict["status"]?.stringValue ?? "succeeded")
                    ?? .succeeded,
                score: dict["qualityScore"]?.numberValue ?? 0,
                sharpness: dict["sharpness"]?.numberValue ?? 0,
                exposure: dict["exposure"]?.numberValue ?? 0,
                subjectSharpness: dict["subjectSharpness"]?.numberValue,
                closedEyeRisk: dict["closedEyeRisk"]?.numberValue
                    ?? dict["closedEyeProbability"]?.numberValue,
                closedEyeProbability: dict["closedEyeProbability"]?.numberValue,
                confidence: dict["confidence"]?.numberValue,
                relativeRank: dict["relativeRank"]?.numberValue,
                errorMessage: dict["errorMessage"]?.stringValue,
                warnings: dict["warnings"]?.arrayValue ?? []
            )
        }
        return qualityByPhoto
    }

    /// TS: loadFaces —— 人脸观测（bbox + 分析签名里的 previewMaxDimension）。
    private func loadFaces(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: LookupMode
    ) throws -> (facesByPhoto: [String: [[Double]]], analysisMaxByPhoto: [String: Double]) {
        struct FaceRow {
            let photoId: String
            let bbox: [Double]
            let analysisSignature: String
        }
        let faceRows: [FaceRow]
        if mode == .session {
            let rows = try connection.prepare("""
                SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
                FROM face_observations
                WHERE session_id = ?
                ORDER BY id
              """).query([.text(sessionId)])
            faceRows = rows.map {
                FaceRow(
                    photoId: $0[0].textValue ?? "",
                    bbox: [$0[1].doubleValue ?? 0, $0[2].doubleValue ?? 0,
                           $0[3].doubleValue ?? 0, $0[4].doubleValue ?? 0],
                    analysisSignature: $0[5].textValue ?? ""
                )
            }
        } else {
            faceRows = try withChunkedIds(photos.map(\.id)) { chunk in
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try connection.prepare("""
                    SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
                    FROM face_observations
                    WHERE session_id = ? AND photo_id IN (\(placeholders))
                    ORDER BY id
                  """).query([.text(sessionId)] + chunk.map { .text($0) })
                return rows.map {
                    FaceRow(
                        photoId: $0[0].textValue ?? "",
                        bbox: [$0[1].doubleValue ?? 0, $0[2].doubleValue ?? 0,
                               $0[3].doubleValue ?? 0, $0[4].doubleValue ?? 0],
                        analysisSignature: $0[5].textValue ?? ""
                    )
                }
            }
        }
        var facesByPhoto: [String: [[Double]]] = [:]
        var analysisMaxByPhoto: [String: Double] = [:]
        for face in faceRows {
            facesByPhoto[face.photoId, default: []].append(face.bbox)
            if analysisMaxByPhoto[face.photoId] == nil {
                // 老观测早于持久化分析签名（TS try/catch）。
                if let parsed = try? JSONValue.parse(face.analysisSignature),
                   case .object(let dict) = parsed,
                   let value = dict["previewMaxDimension"]?.numberValue,
                   value.isFinite {
                    analysisMaxByPhoto[face.photoId] = value
                }
            }
        }
        return (facesByPhoto, analysisMaxByPhoto)
    }

    /// TS: loadPeople —— 人物 → 照片映射（按名排序，去重）。
    private func loadPeople(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: LookupMode
    ) throws -> [String: [String]] {
        struct PersonRow {
            let photoId: String
            let name: String
        }
        let personRows: [PersonRow]
        if mode == .session {
            let rows = try connection.prepare("""
                SELECT pp.photo_id, p.name
                FROM person_photos pp
                JOIN persons p ON p.id = pp.person_id
                WHERE pp.session_id = ?
                ORDER BY p.name
              """).query([.text(sessionId)])
            personRows = rows.map { PersonRow(photoId: $0[0].textValue ?? "", name: $0[1].textValue ?? "") }
        } else {
            personRows = try withChunkedIds(photos.map(\.id)) { chunk in
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try connection.prepare("""
                    SELECT pp.photo_id, p.name
                    FROM person_photos pp
                    JOIN persons p ON p.id = pp.person_id
                    WHERE pp.session_id = ? AND pp.photo_id IN (\(placeholders))
                    ORDER BY p.name
                  """).query([.text(sessionId)] + chunk.map { .text($0) })
                return rows.map { PersonRow(photoId: $0[0].textValue ?? "", name: $0[1].textValue ?? "") }
            }
        }
        var peopleByPhoto: [String: [String]] = [:]
        for person in personRows {
            var names = peopleByPhoto[person.photoId] ?? []
            if !names.contains(person.name) { names.append(person.name) }
            peopleByPhoto[person.photoId] = names
        }
        return peopleByPhoto
    }

    /// TS: buildRichLookup —— 把原始照片集合富化为 CullingAssets 所需的全部
    /// 每照片查询。
    private func buildRichLookup(
        photos: [CullingPhotoRow],
        sessionId: String,
        mode: LookupMode
    ) async throws -> CullingRichLookup {
        let photoIds = photos.map(\.id)
        let decisions = Dictionary(
            uniqueKeysWithValues: try await (mode == .session
                ? (cullingStore?.decisionsFull(sessionId: sessionId) ?? [])
                : (cullingStore?.decisions(sessionId: sessionId, photoIds: photoIds) ?? []))
                .map { ($0.photoId, $0) }
        )
        let cacheRows = Dictionary(
            uniqueKeysWithValues: try await metadataStore.metadataBatch(photoIds: photoIds)
                .map { ($0.photoId, $0) }
        )
        let outboxByPath: [String: MetadataOutboxRow]
        if mode == .session {
            outboxByPath = Dictionary(
                uniqueKeysWithValues: try metadataOutboxRepo.getBySession(sessionId)
                    .map { ($0.xmpPath, $0) }
            )
        } else {
            outboxByPath = try loadOutboxByPaths(
                sessionId: sessionId,
                xmpPaths: photos.map { TSPath.xmpSidecarPath($0.filepath) }
            )
        }
        let similarityMap = try getLatestSimilarityMap(sessionId: sessionId)
        // 会话级分析表（质量/人脸/人物）只被后台分析重写，故会话模式复用
        // 版本键控缓存而不是每次调用全量重读；页模式保持每页范围查询。
        let sessionLookup = try getSessionLookup(sessionId: sessionId)
        var qualityByPhoto: [String: CullingQuality]
        let facesByPhoto: [String: [[Double]]]
        let analysisMaxByPhoto: [String: Double]
        let peopleByPhoto: [String: [String]]
        if mode == .session {
            if !sessionLookup.analysesLoaded {
                sessionLookup.analysesLoaded = true
                sessionLookup.qualityByPhoto = try loadQualityByPhoto(photos: photos)
                let faces = try loadFaces(photos: photos, sessionId: sessionId, mode: .session)
                sessionLookup.facesByPhoto = faces.facesByPhoto
                sessionLookup.analysisMaxByPhoto = faces.analysisMaxByPhoto
                sessionLookup.peopleByPhoto = try loadPeople(photos: photos, sessionId: sessionId, mode: .session)
            }
            qualityByPhoto = sessionLookup.qualityByPhoto
            facesByPhoto = sessionLookup.facesByPhoto
            analysisMaxByPhoto = sessionLookup.analysisMaxByPhoto
            peopleByPhoto = sessionLookup.peopleByPhoto
        } else {
            qualityByPhoto = try loadQualityByPhoto(photos: photos)
            let faces = try loadFaces(photos: photos, sessionId: sessionId, mode: .page)
            facesByPhoto = faces.facesByPhoto
            analysisMaxByPhoto = faces.analysisMaxByPhoto
            peopleByPhoto = try loadPeople(photos: photos, sessionId: sessionId, mode: .page)
        }
        var linkedCounts: [String: Int] = [:]
        for photo in photos {
            let xmpPath = TSPath.xmpSidecarPath(photo.filepath)
            linkedCounts[xmpPath, default: 0] += 1
        }

        // 组内相对排名：同一相似度组内成功质量按分数降序 → 1 起排名。TS 原地
        // 改 qualityByPhoto 里的对象引用；Swift 值类型按 photoId 回写。
        var qualityGroups: [String: [(photoId: String, quality: CullingQuality)]] = [:]
        for (photoId, quality) in qualityByPhoto {
            guard let groupId = similarityMap[photoId],
                  quality.status == .succeeded else { continue }
            qualityGroups[groupId, default: []].append((photoId, quality))
        }
        for (_, members) in qualityGroups {
            let sorted = members.sorted { $0.quality.score > $1.quality.score }
            for (index, member) in sorted.enumerated() {
                var updated = qualityByPhoto[member.photoId]!
                updated.relativeRank = Double(index + 1)
                qualityByPhoto[member.photoId] = updated
            }
        }
        return CullingRichLookup(
            decisions: decisions,
            cacheRows: cacheRows,
            outboxByPath: outboxByPath,
            similarityMap: similarityMap,
            qualityByPhoto: qualityByPhoto,
            facesByPhoto: facesByPhoto,
            analysisMaxByPhoto: analysisMaxByPhoto,
            peopleByPhoto: peopleByPhoto,
            linkedCounts: linkedCounts
        )
    }

    /// TS: assembleAssets —— 富化 + 按逻辑资产分组 + RAW 优先折叠变体。
    private func assembleAssets(
        photos: [CullingPhotoRow],
        lookup: CullingRichLookup
    ) -> [CullingAsset] {
        let assets: [CullingAsset] = photos.map { photo in
            let decision = lookup.decisions[photo.id]
            let cache = lookup.cacheRows[photo.id]
            let xmpPath = TSPath.xmpSidecarPath(photo.filepath)
            let outbox = lookup.outboxByPath[xmpPath]
            var metadataSource: MetadataMutationSource?
            if let parsed = try? JSONValue.parse(outbox?.patchJSON ?? "{}"),
               case .object(let dict) = parsed,
               let source = dict["source"]?.stringValue,
               ["culling", "face-keyword", "similarity", "template", "manual"].contains(source) {
                metadataSource = MetadataMutationSource(rawValue: source)
            }
            // 损坏的历史补丁由 sync status 呈现（TS try/catch）。
            let keywords: [String] = cache?.keywords ?? []
            let sourceWidth = max(1, photo.width)
            let sourceHeight = max(1, photo.height)
            let analysisMax = lookup.analysisMaxByPhoto[photo.id]
                ?? max(
                    getNumber("detect_input_size", 640),
                    getNumber("face_preview_max_dimension", 2048)
                )
            let analysisScale = min(1, analysisMax / Double(max(sourceWidth, sourceHeight)))
            let analysisWidth = Double(sourceWidth) * analysisScale
            let analysisHeight = Double(sourceHeight) * analysisScale
            // 当前检测器观测已归一化。老数据库存的是预览像素坐标，为范围外的
            // 值保留有界的兼容换算（TS 注释逐字语义）。
            let normalizedFaces = (lookup.facesByPhoto[photo.id] ?? []).map { face in
                let alreadyNormalized = face.count >= 4
                    && face[0] >= 0 && face[1] >= 0 && face[2] >= 0 && face[3] >= 0
                    && face[0] <= 1 && face[1] <= 1 && face[2] <= 1 && face[3] <= 1
                let values = alreadyNormalized
                    ? face
                    : [face[0] / analysisWidth, face[1] / analysisHeight,
                       face[2] / analysisWidth, face[3] / analysisHeight]
                return values.map { min(1, max(0, $0)) }
            }.sorted { ($0[2] * $0[3]) > ($1[2] * $1[3]) }

            return CullingAsset(
                photo: photoRowToData(
                    photo,
                    faceCount: lookup.facesByPhoto[photo.id]?.count ?? 0
                ),
                state: rowToState(
                    photoId: photo.id,
                    row: decision,
                    fallbackRating: cache?.rating ?? 0,
                    fallbackLabel: cache?.label ?? "None"
                ),
                xmpPath: xmpPath,
                syncStatus: MetadataSyncStatus(rawValue: outbox?.status ?? "") ?? .clean,
                people: lookup.peopleByPhoto[photo.id] ?? [],
                keywords: keywords,
                similarityGroupId: lookup.similarityMap[photo.id],
                linkedVariantCount: lookup.linkedCounts[xmpPath] ?? 1,
                faceBboxes: normalizedFaces,
                quality: lookup.qualityByPhoto[photo.id],
                metadataSource: metadataSource
            )
        }

        // 按逻辑资产 id 单遍分组（替代整数组每组的过滤，大会话下 O(n²)）。
        // TS 的 Map 保插入序；Swift Dictionary.values 顺序不定，故显式维护
        // 首见顺序，资产顺序与 TS `[...assetsByAssetId.values()]` 一致。
        var assetsByAssetId: [String: [CullingAsset]] = [:]
        var assetIdOrder: [String] = []
        for asset in assets {
            let assetId = asset.photo.assetId ?? "photo:\(asset.photo.id)"
            if assetsByAssetId[assetId] == nil { assetIdOrder.append(assetId) }
            assetsByAssetId[assetId, default: []].append(asset)
        }
        return assetIdOrder.compactMap { assetsByAssetId[$0] }.map { variants in
            let preferred = variants.first(where: {
                isPreferredRawVariant(filename: $0.photo.filename)
            }) ?? variants[0]
            var photo = preferred.photo
            photo.variantCount = variants.count
            photo.variants = variants.map { variant in
                PhotoVariant(
                    photoId: variant.photo.id,
                    filepath: variant.photo.filepath,
                    filename: variant.photo.filename,
                    role: variant.photo.id == preferred.photo.id ? "primary" : "variant"
                )
            }
            var asset = preferred
            asset.photo = photo
            return asset
        }
    }

    /// TS: filterVisible —— SQL 下推之上的最终安全网。已下推的过滤器
    /// （pick/rating/label/quality/similarity）SQL 谓词已作用在首选行，此 JS 遍
    /// 恒通过；未下推的 metadataConflictOnly 在这里应用。
    private func filterVisible(
        _ assets: [CullingAsset],
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?
    ) -> [CullingAsset] {
        assets.filter { asset in
            if scope == .similarityGroup {
                guard let similarityGroupId = asset.similarityGroupId else { return false }
                if let requestedGroupId, similarityGroupId != requestedGroupId { return false }
            }
            return scope != .filtered || matchesFilters(asset, filters: filters)
        }
    }

    /// TS: matchesFilters。
    private func matchesFilters(_ asset: CullingAsset, filters: CullingFilters?) -> Bool {
        guard let filters else { return true }
        if filters.unreviewedOnly == true && asset.state.pickState != .unreviewed { return false }
        if let ratings = filters.ratings, !ratings.isEmpty,
           !ratings.contains(asset.state.rating) { return false }
        if let pickStates = filters.pickStates, !pickStates.isEmpty,
           !pickStates.contains(asset.state.pickState) { return false }
        if let colorLabels = filters.colorLabels, !colorLabels.isEmpty,
           !colorLabels.contains(asset.state.colorLabel) { return false }
        if filters.qualityStatus == .analysed && asset.quality?.status != .succeeded { return false }
        if filters.qualityStatus == .failed && asset.quality?.status != .failed { return false }
        if filters.qualityStatus == .unanalysed && asset.quality != nil { return false }
        if filters.metadataConflictOnly == true && asset.syncStatus != .conflict { return false }
        return true
    }

    // MARK: - 会话更新上下文缓存（TS getSessionUpdateContext /
    // refreshSessionUpdateContext / ensureUpdateExtras / prune）

    /// TS: getSessionUpdateContext —— 会话照片 + id 索引，TTL 缓存。更新路径
    /// 用它让点击突发不再每次重读整个会话（轻投影跳过重 JSON 列）。
    private func getSessionUpdateContext(sessionId: String) -> SessionUpdateEntry {
        let now = Date()
        if let cached = sessionUpdateCache[sessionId], cached.expiresAt > now {
            return cached
        }
        let photos = loadSessionPhotos(sessionId: sessionId)
        let entry = SessionUpdateEntry(
            photos: photos,
            photoById: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) }),
            photosByAssetId: buildPhotosByAssetIndex(photos),
            groupMap: nil,
            groupMapResultId: nil,
            linkedByXmp: nil,
            refreshed: false,
            expiresAt: now.addingTimeInterval(Self.updateTTLSeconds)
        )
        sessionUpdateCache[sessionId] = entry
        pruneSessionUpdateCache()
        return entry
    }

    /// TS: refreshSessionUpdateContext —— TTL 缓存上下文漏照片时的一次新鲜读：
    /// 索引器的增删对缓存不可见，窗口内先试一次新鲜读（新导入的照片绝不能被
    /// 拒，真删除的第二次检查仍会被拒）。组索引、xmp 联动与会话查找随照片集
    /// 一起失效，下个 ensureUpdateExtras 对新生行重建。
    private func refreshSessionUpdateContext(sessionId: String, entry: SessionUpdateEntry) {
        if entry.refreshed { return }
        let photos = loadSessionPhotos(sessionId: sessionId)
        entry.photos = photos
        entry.photoById = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        entry.photosByAssetId = buildPhotosByAssetIndex(photos)
        entry.groupMap = nil
        entry.groupMapResultId = nil
        entry.linkedByXmp = nil
        entry.refreshed = true
        // 组索引可能按旧照片集解析过（groups_json 兜底），会话查找整体重建。
        sessionLookupCache.removeValue(forKey: sessionId)
    }

    /// TS: ensureUpdateExtras —— 懒填充缓存上下文里的相似度组索引与 xmp 联动
    /// 映射。组索引按相似度结果版本键控：每次访问重查版本，结果替换即重建，
    /// 绝不再写旧结果的无主 "${oldResultId}:${i}" 组 id。xmp 联动只依赖照片集，
    /// 与其一起重建（见 refreshSessionUpdateContext）。与照片加载分离，让调用方
    /// 能在任何相似度读之前校验照片 id，O(n) 侧车扫描每条目/每版本一次而非每次
    /// 点击一次。
    private func ensureUpdateExtras(entry: SessionUpdateEntry, sessionId: String) throws {
        let lookup = try getSessionLookup(sessionId: sessionId)
        // TS: `groupMap !== undefined && groupMapResultId === lookup.resultRow?.id`
        // —— 已解析且版本一致时直接复用（含空索引：无相似度结果时 groupMapResultId
        // 与 resultRow?.id 同为 nil，同样视为已解析）。
        if entry.groupMap != nil && entry.groupMapResultId == lookup.resultRow?.id {
            return
        }
        entry.groupMap = try buildPhotoGroupIndex(photos: entry.photos, sessionId: sessionId, lookup: lookup)
        entry.groupMapResultId = lookup.resultRow?.id
        var linkedByXmp: [String: [CullingPhotoRow]] = [:]
        for photo in entry.photos {
            let xmpPath = TSPath.xmpSidecarPath(photo.filepath)
            linkedByXmp[xmpPath, default: []].append(photo)
        }
        entry.linkedByXmp = linkedByXmp
    }

    private func pruneSessionUpdateCache() {
        let now = Date()
        sessionUpdateCache = sessionUpdateCache.filter { $0.value.expiresAt > now }
        while sessionUpdateCache.count > Self.updateCacheMax,
              let oldest = sessionUpdateCache.keys.first {
            sessionUpdateCache.removeValue(forKey: oldest)
        }
    }

    /// TS: loadSessionPhotos —— 热路径用轻投影；全行兜底保持只暴露 getBySession
    /// 的测试替身可用（TS 注释语义；Swift 侧仓库恒有投影，直接使用）。
    private func loadSessionPhotos(sessionId: String) -> [CullingPhotoRow] {
        (try? photoRepo.getBySessionProjection(sessionId: sessionId))?.map { CullingPhotoRow(row: $0) }
            ?? ((try? photoRepo.getBySession(sessionId: sessionId))?.map { CullingPhotoRow(row: $0) } ?? [])
    }

    // MARK: - 会话查找缓存（TS getSessionLookup / prune / getLatestSimilarityMap /
    // buildPhotoGroupIndex）

    /// TS: getSessionLookup —— 最新相似度结果行 + 由其派生的版本键控查询。
    /// 结果 id 即版本：替换即原子重建条目，一个结果的缓存行绝不与另一结果混杂。
    private func getSessionLookup(sessionId: String) throws -> SessionLookupEntry {
        let resultRow = try similarityResultRepo.getLatest(sessionId: sessionId)
        let now = Date()
        if let cached = sessionLookupCache[sessionId],
           cached.resultRow?.id == resultRow?.id, cached.expiresAt > now {
            return cached
        }
        let similarityMap: [String: String]
        if let resultRow {
            similarityMap = try similarityResultRepo.getPhotoGroupMap(
                sessionId: sessionId, resultId: resultRow.id
            )
        } else {
            similarityMap = [:]
        }
        let entry = SessionLookupEntry(
            resultRow: resultRow,
            similarityMap: similarityMap,
            groupIndex: similarityMap.isEmpty ? [:] : similarityMap,
            groupIndexResolved: !similarityMap.isEmpty,
            analysesLoaded: false,
            qualityByPhoto: [:],
            facesByPhoto: [:],
            analysisMaxByPhoto: [:],
            peopleByPhoto: [:],
            groupCount: 0,
            groupCountResolved: false,
            expiresAt: now.addingTimeInterval(Self.lookupTTLSeconds)
        )
        sessionLookupCache[sessionId] = entry
        pruneSessionLookupCache()
        return entry
    }

    private func pruneSessionLookupCache() {
        let now = Date()
        sessionLookupCache = sessionLookupCache.filter { $0.value.expiresAt > now }
        while sessionLookupCache.count > Self.lookupCacheMax,
              let oldest = sessionLookupCache.keys.first {
            sessionLookupCache.removeValue(forKey: oldest)
        }
    }

    /// TS: getLatestSimilarityMap。
    private func getLatestSimilarityMap(sessionId: String) throws -> [String: String] {
        try getSessionLookup(sessionId: sessionId).similarityMap
    }

    /// TS: buildPhotoGroupIndex —— 每张照片的组索引，每（会话, 结果版本）解析
    /// 一次并被每次更新点击复用：成员表在结果替换之间不可变，故只在版本变化时
    /// 重建。调用方可传入已解析的 lookup（见 ensureUpdateExtras），版本解析查询
    /// 每构建只跑一次。
    private func buildPhotoGroupIndex(
        photos: [CullingPhotoRow],
        sessionId: String,
        lookup: SessionLookupEntry
    ) throws -> [String: String] {
        if lookup.groupIndexResolved { return lookup.groupIndex }
        lookup.groupIndexResolved = true
        guard let resultRow = lookup.resultRow else { return lookup.groupIndex }

        // groups_json 是数据库内容；损坏或结构意外的行退化为空索引而不是让
        // updateState/batchUpdate 崩溃（TS 语义）。
        var groups: [[String: JSONValue]] = []
        if let parsed = try? JSONValue.parse(resultRow.groupsJson),
           case .object(let dict) = parsed,
           case .array(let items) = dict["groups"] {
            groups = items.compactMap {
                if case .object(let obj) = $0 { return obj }
                return nil
            }
        }
        let photoIdByPath = Dictionary(uniqueKeysWithValues: photos.map { ($0.filepath, $0.id) })
        var groupByPhotoId: [String: String] = [:]
        for (index, group) in groups.enumerated() {
            guard case .array(let images)? = group["images"] else { continue }
            for image in images {
                guard case .object(let imageObj) = image,
                      let path = imageObj["path"]?.stringValue,
                      let photoId = photoIdByPath[path] else { continue }
                groupByPhotoId[photoId] = "\(resultRow.id):\(index)"
            }
        }
        lookup.groupIndex = groupByPhotoId
        return lookup.groupIndex
    }

    // MARK: - Summary 支撑

    /// TS: loadSummaryCacheByPhoto —— getSummary 的轻 photo_metadata_cache 投影：
    /// 计数循环只需要 rating/label 兜底，跳过 getBatch 携带的重 keywords JSON 列。
    private func loadSummaryCacheByPhoto(
        _ photos: [CullingPhotoRow]
    ) throws -> [String: (rating: Int64, label: String?)] {
        var cacheByPhoto: [String: (rating: Int64, label: String?)] = [:]
        if photos.isEmpty { return cacheByPhoto }
        struct CacheLiteRow {
            let photoId: String
            let rating: Int64
            let label: String?
        }
        let rows: [CacheLiteRow] = try withChunkedIds(photos.map(\.id)) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try connection.prepare("""
                SELECT photo_id, rating, label
                FROM photo_metadata_cache
                WHERE photo_id IN (\(placeholders))
              """).query(chunk.map { .text($0) })
            return rows.map {
                CacheLiteRow(photoId: $0[0].textValue ?? "", rating: $0[1].intValue ?? 0, label: $0[2].textValue)
            }
        }
        for row in rows { cacheByPhoto[row.photoId] = (row.rating, row.label) }
        return cacheByPhoto
    }

    // MARK: - 状态/补丁支撑（TS rowToState / validatePatch / decisionToPickState /
    // pickStateToDecision / parseTotalGroups）

    /// TS: parseTotalGroups —— 相似度结果行的组计数。当前管线把 totalGroups 写进
    /// 小的 stats_json 对象，多 MB 的 groups_json 只为旧行解析。损坏行退化为 0
    /// （与旧 groups_json 解析相同）。
    private func parseTotalGroups(_ resultRow: SimilarityResultRow) -> Int {
        if let parsed = try? JSONValue.parse(resultRow.statsJson),
           case .object(let dict) = parsed,
           case .number(let value) = dict["totalGroups"],
           value.rounded() == value, value >= 0 {
            return Int(value)
        }
        if let parsed = try? JSONValue.parse(resultRow.groupsJson),
           case .object(let dict) = parsed,
           case .array(let groups) = dict["groups"] {
            return groups.count
        }
        return 0
    }

    /// TS: rowToState —— 决策行 + 缓存兜底 → AssetCullingState。
    private func rowToState(
        photoId: String,
        row: CullingDecisionRecord?,
        fallbackRating: Int64,
        fallbackLabel: String
    ) -> AssetCullingState {
        let colorLabel: CaptureOneColorLabel
        if let parsed = CaptureOneColorLabel(rawValue: fallbackLabel),
           Self.colorLabels.contains(parsed) {
            colorLabel = parsed
        } else {
            colorLabel = .none
        }
        let rating = (0...5).contains(fallbackRating) ? fallbackRating : 0
        let rowColorLabel: CaptureOneColorLabel
        if let parsed = CaptureOneColorLabel(rawValue: row?.colorLabel ?? ""),
           Self.colorLabels.contains(parsed) {
            rowColorLabel = parsed
        } else {
            rowColorLabel = .none
        }
        return AssetCullingState(
            photoId: photoId,
            pickState: decisionToPickState(row?.decision),
            rating: Double(row?.rating ?? rating),
            colorLabel: row != nil ? rowColorLabel : colorLabel,
            source: sourceFromDecisionRow(row),
            revision: Int(row?.revision ?? 0),
            updatedAt: row?.updatedAt ?? ""
        )
    }

    /// TS: rowToState 的 source 分支（决策行存在时取合法 decision_source，缺省
    /// manual；行缺失时为 imported）。
    private func sourceFromDecisionRow(_ row: CullingDecisionRecord?) -> CullingDecisionSource {
        guard let row else { return .imported }
        return CullingDecisionSource(rawValue: row.decisionSource) ?? .manual
    }

    /// TS: validatePatch —— 补丁校验；rating/pickState/colorLabel 的非法值是
    /// bug 守卫（renderer 只用共享常量构造补丁，ADR-017）。
    private func validatePatch(_ patch: CullingUpdatePatch) throws {
        if patch.rating == nil && patch.pickState == nil && patch.colorLabel == nil {
            throw CullingServiceError.patchInvalid
        }
        if let rating = patch.rating,
           !(rating.rounded() == rating && (0...5).contains(rating)) {
            throw CullingServiceError.ratingOutOfRange
        }
        if let pickState = patch.pickState,
           ![PickState.unreviewed, .picked, .rejected].contains(pickState) {
            throw CullingServiceError.invalidPickState
        }
        if let colorLabel = patch.colorLabel, !Self.colorLabels.contains(colorLabel) {
            throw CullingServiceError.invalidColorLabel
        }
    }

    /// TS: decisionToPickState。
    private func decisionToPickState(_ decision: String?) -> PickState {
        switch decision {
        case "keep": .picked
        case "reject": .rejected
        default: .unreviewed
        }
    }

    /// TS: decisionToPickState（LegacyCullingDecision 入参版，decide/batchDecide）。
    private func decisionToPickState(_ decision: LegacyCullingDecision) -> PickState {
        switch decision {
        case .keep: .picked
        case .reject: .rejected
        case .pending: .unreviewed
        }
    }

    /// TS: pickStateToDecision。
    private func pickStateToDecision(_ pickState: PickState) -> LegacyCullingDecision {
        switch pickState {
        case .picked: .keep
        case .rejected: .reject
        case .unreviewed: .pending
        }
    }

    /// TS: `Object.keys(patch)` —— 补丁非空字段（CullingUpdatePatch 声明序）。
    private func patchFields(_ patch: CullingUpdatePatch) -> [CullingUpdatePatchField] {
        var fields: [CullingUpdatePatchField] = []
        if patch.rating != nil { fields.append(.rating) }
        if patch.pickState != nil { fields.append(.pickState) }
        if patch.colorLabel != nil { fields.append(.colorLabel) }
        return fields
    }

    /// TS: `Object.fromEntries(fields.map(field => [field, snapshot[field]]))`。
    private func patchFromSnapshot(
        fields: [CullingUpdatePatchField],
        snapshot: CullingStateSnapshot
    ) -> CullingUpdatePatch {
        var patch = CullingUpdatePatch()
        for field in fields {
            switch field {
            case .rating: patch.rating = snapshot.rating
            case .pickState: patch.pickState = snapshot.pickState
            case .colorLabel: patch.colorLabel = snapshot.colorLabel
            }
        }
        return patch
    }

    /// TS: applyHistory 的 `current[field] !== expected[field]` 分歧比较。
    private func matchesSnapshot(
        state: AssetCullingState,
        snapshot: CullingStateSnapshot,
        field: CullingUpdatePatchField
    ) -> Bool {
        switch field {
        case .rating: state.rating == snapshot.rating
        case .pickState: state.pickState == snapshot.pickState
        case .colorLabel: state.colorLabel == snapshot.colorLabel
        }
    }

    /// TS: photoRowToData —— 照片行 → PhotoData。
    private func photoRowToData(_ row: CullingPhotoRow, faceCount: Int) -> PhotoData {
        PhotoData(
            id: row.id,
            sessionId: row.sessionId,
            filepath: row.filepath,
            filename: row.filename,
            checksum: row.checksum,
            hasExistingXmp: false,
            faceCount: faceCount,
            width: row.width,
            height: row.height,
            metadata: parseJsonRecord(row.metadata ?? "{}"),
            result: parseJsonRecord(row.result ?? "{}"),
            status: row.status,
            assetId: row.assetId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// TS: parseJsonRecord —— 解析 JSON 对象（损坏/非对象退化为空字典）。
    private func parseJsonRecord(_ value: String) -> [String: JSONValue] {
        guard let parsed = try? JSONValue.parse(value),
              case .object(let dict) = parsed else { return [:] }
        return dict
    }

    /// TS: isPreferredRawVariant —— 首选 RAW 变体探测（小写扩展名集合的 O(1)
    /// 探测替代 per-candidate `some(...endsWith)` 扫描）。
    private func isPreferredRawVariant(filename: String) -> Bool {
        let lower = filename.lowercased()
        guard let dot = lower.lastIndex(of: ".") else { return false }
        return Self.preferredRawExtensions.contains(String(lower[dot...]))
    }

    /// TS: buildPhotosByAssetIndex —— asset_id → 照片索引，每次缓存更新上下文
    /// 构建一次，updateState 的按资产变体扫描（pick-state 补丁）变成 map 查找。
    /// 无 asset_id 的照片跳过：扫描只匹配共享真实 asset_id 的照片。
    private func buildPhotosByAssetIndex(
        _ photos: [CullingPhotoRow]
    ) -> [String: [CullingPhotoRow]] {
        var photosByAssetId: [String: [CullingPhotoRow]] = [:]
        for photo in photos {
            guard let assetId = photo.assetId else { continue }
            photosByAssetId[assetId, default: []].append(photo)
        }
        return photosByAssetId
    }
}

// MARK: - 内部类型

/// TS: LookupMode。
private enum LookupMode {
    case session
    case page
}

/// TS: CullingRichLookup。
private struct CullingRichLookup {
    let decisions: [String: CullingDecisionRecord]
    let cacheRows: [String: MetadataCacheRecord]
    let outboxByPath: [String: MetadataOutboxRow]
    let similarityMap: [String: String]
    let qualityByPhoto: [String: CullingQuality]
    let facesByPhoto: [String: [[Double]]]
    let analysisMaxByPhoto: [String: Double]
    let peopleByPhoto: [String: [String]]
    let linkedCounts: [String: Int]
}

/// TS: SessionLookupEntry —— 版本键控缓存条目（可变，见 getSessionLookup）。
private final class SessionLookupEntry {
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
private final class SessionUpdateEntry {
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
