// desktop/native/gather-core/Sources/GatherDomain/Services/CullingService.swift
// TS 源: desktop/src/main/services/culling/culling.service.ts（1902 行，逐字移植）
// + culling.ipc.ts（387 行）的命令面（writeback/sync_status/flush/retry_sync/
// finalize_sync/retry_failed_writeback/confirm_sync/cleanup 的确认校验与委托）。
//
// Culling 服务：资产列表（含 RAW/JPEG 变体折叠与 asset 分组分页）、decide
// （星级/标签/关键词选择）、批量操作、summary、history/apply_history（undo/redo
// 历史栈）、reset、写回协作。写回引擎不在此重写——经 CullingWritebackPort
// （WritebackService 已移植接口）注入，测试可注入替身。
//
// S5c-2b-3b-2b-1：旧 MetadataSyncCoordinator 依赖已整段移除（CullingSyncPort
// 协议/扩展删除）。syncStatus/flush/retry/finalize/confirm/cleanup 只走交付模型；
// 同步态读 deliveries（交付行优先），手动 rating/label 的旧 outbox 队列不再读取。
//
// 注入点：
// - CullingWritebackPort = TS WritebackService 的 culling.ipc.ts 用到的最小面
//   （preview/persistAttributes/execute/retryFailed/getItems/confirmSync/cleanup）。
//   文件写入仍由它执行（execute/retryFailed）；getItems 供交付镜像读取行状态。
// - CullingDeliveryPort = DeliveryCoordinator 的 culling 面（S5c-2a 起）：
//   confirm/cleanup/finalize、syncStatus 读模型、flush/retry 的 replay、
//   writeback 结果镜像全部走它；宿主未注入时按 connection + 文件系统端口自建。
// - MetadataMutationPort = TS MetadataMutationService（queuePhotoValues）。
// - getNumber = TS SettingsService.getNumber（detect_input_size /
//   face_preview_max_dimension 兜底，测试注入）。
// - cullingHistoryRepo 与 TS 一样是可选依赖（老装配缺省时历史栈禁用）。
//
// 错误消息与 TS 逐字一致：CullingServiceError.description 即 TS `new Error(code)`
// 的 message；CULLING_REVISION_CONFLICT 带 expected/current 插值参数。
//
// 缓存注记：TTL 缓存（sessionLookup/sessionUpdate）与 TS 同语义——主进程单线程
// 同步 SQLite，Swift 侧服务实例同样按会话单线程使用，Map 无需加锁（与
// SimilarityResultRepo 的 photoGroupMapCache 同款决策）。
//
// ── 挑片状态单一真相源（禁止双真相源）────────────────────────────────
// 星级 / 色标：唯一真相源是 photo_metadata_cache（全应用范围的 XMP 投影）。
//   读取（rowToState / list / listPage / getSummary）、写入（updateState /
//   applyHistory）、reset、写回计划全部围绕它；culling_decisions.rating /
//   color_label 只是同事务写下的镜像列，任何读取路径都不得读它们
//   （见 CullingDecisionRepo 文件头注）。
// 取舍（pick/reject/pending）：唯一真相源是 culling_decisions.decision。
//
// ── 侧车/xmp 路径口径（写回内核已冻结）────────────────────────────
// 一切交付键、linkedByXmp 键统一走
// DeliveryPath.sidecar(photo) = TSPath.xmpSidecarPath(ScanPath.canonical(photo))
// （helper 名沿用旧 outbox 命名，但只做路径归一化，不读写旧表）。
// 禁止裸拼 TSPath.xmpSidecarPath（符号链接/相对路径/已是侧车三种输入下与内核键
// 不一致，会查不到行或造出重复行）。

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

/// TS: CullingService。
public final class CullingService {
    // MARK: - 常量（TS 文件头部）

    /// TS: COLOR_LABELS。
    private static let colorLabels: Set<CaptureOneColorLabel> = [
        .none, .red, .orange, .yellow, .green, .blue, .pink, .purple,
    ]

    /// TS: PREFERRED_RAW_EXTENSIONS —— RAW 判定只用共享表 PhotoRepo.rawExtensions
    ///（与 preferredRowOrderSQL 里 LIKE 链的同一份数据），本文件不另立扩展名表。
    /// 内存态代表行选择为何不能直接调用 SQL 排序，见 assembleAssets 的注释。
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
    private let cullingDecisionRepo: CullingDecisionRepo
    private let similarityResultRepo: SimilarityResultRepo
    private let metadataCacheRepo: MetadataCacheRepo
    private let connection: DBConnection
    private let metadataMutations: any MetadataMutationPort
    private let writeback: any CullingWritebackPort
    /// 交付模型的 culling 面（S5c-2a）：confirm/cleanup 的唯一出口。
    private let delivery: any CullingDeliveryPort
    private let cullingHistoryRepo: CullingHistoryRepo?
    private let getNumber: (String, Double) -> Double

    public init(
        photoRepo: PhotoRepo,
        cullingDecisionRepo: CullingDecisionRepo,
        similarityResultRepo: SimilarityResultRepo,
        metadataCacheRepo: MetadataCacheRepo,
        connection: DBConnection,
        metadataMutations: any MetadataMutationPort,
        writeback: any CullingWritebackPort,
        cullingHistoryRepo: CullingHistoryRepo? = nil,
        getNumber: @escaping (String, Double) -> Double = { _, defaultValue in defaultValue },
        delivery: (any CullingDeliveryPort)? = nil
    ) {
        self.photoRepo = photoRepo
        self.cullingDecisionRepo = cullingDecisionRepo
        self.similarityResultRepo = similarityResultRepo
        self.metadataCacheRepo = metadataCacheRepo
        self.connection = connection
        self.metadataMutations = metadataMutations
        self.writeback = writeback
        self.cullingHistoryRepo = cullingHistoryRepo
        self.getNumber = getNumber
        // S5c-2a 过渡默认：宿主未注入时按同一 connection 自建 coordinator。
        // 文件阶段用文件系统端口（restore = 备份覆盖写回侧车）；宿主接线在 S5c-2b
        // 改为显式注入共享实例 + XMPDeliveryFilePort。
        self.delivery = delivery ?? DeliveryCoordinator(
            connection: connection,
            files: FileSystemDeliveryFilePort()
        )
    }

    // MARK: - 同步态读模型（S5c-2b-3b-2a）

    /// 交付行 → 旧 MetadataSyncStatus 投影（culling 徽标/更新结果用）。
    static func syncStatus(from status: DeliveryStatus) -> MetadataSyncStatus {
        switch status {
        case .pending: .pending
        case .writing: .writing
        case .written: .written
        case .synced: .synced
        case .failed: .failed
        case .conflict: .conflict
        case .cleaned: .cleaned
        }
    }

    /// 同步态的唯一读模型是 deliveries（写回执行器直接维护）。
    /// 手动 rating/label 的旧 outbox 行不再读取：交付行尚未出现时返回调用方给出的
    /// 默认值（updateState 对共享元数据传 .pending，表达"已入队、尚未落交付"）。
    private func currentSyncStatus(
        xmpPath: String,
        fallback: MetadataSyncStatus
    ) throws -> MetadataSyncStatus {
        let repo = DeliveryRepo(connection: connection)
        if let row = try repo.get(xmpPath), let status = row.typedStatus {
            return Self.syncStatus(from: status)
        }
        return fallback
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
    ) throws -> [CullingAsset] {
        let photos = try photoRepo.getBySession(sessionId: sessionId).map { CullingPhotoRow(row: $0) }
        let lookup = try buildRichLookup(photos: photos, sessionId: sessionId, mode: .session)
        return filterVisible(
            assembleAssets(photos: photos, lookup: lookup),
            scope: scope,
            filters: filters,
            requestedGroupId: requestedGroupId,
            conflictingPhotoPaths: try conflictPhotoPaths(sessionId: sessionId, filters: filters)
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
    ) throws -> CullingPage {
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
        let lookup = try buildRichLookup(photos: page.photos, sessionId: sessionId, mode: .page)
        let assets = filterVisible(
            assembleAssets(photos: page.photos, lookup: lookup),
            scope: scope, filters: filters, requestedGroupId: requestedGroupId,
            conflictingPhotoPaths: try conflictPhotoPaths(sessionId: sessionId, filters: filters)
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
            // ensureUpdateExtras 保证两者已构建；这里显式兜底而不是强解包。
            groupMap: entry.groupMap ?? [:],
            linkedByXmp: entry.linkedByXmp ?? [:]
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

        let currentRow = try cullingDecisionRepo.getDecision(sessionId: sessionId, photoId: photoId)
        let currentRevision = currentRow?.revision ?? 0
        if currentRevision != Int64(expectedRevision) {
            throw CullingServiceError.revisionConflict(
                expected: expectedRevision, current: Int(currentRevision)
            )
        }

        let targetXmpPath = DeliveryPath.sidecar(target.filepath)
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
            let linkedByXmp = contextLinkedByXmp ?? entry.linkedByXmp ?? [:]
            for photo in linkedByXmp[targetXmpPath] ?? [] {
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
        if let rating = patch.rating { metadataPatch["rating"] = .number(rating) }
        if let colorLabel = patch.colorLabel {
            // TS: colorLabel === 'None' → ''（写盘标签语义）。
            metadataPatch["label"] = .string(colorLabel == .none ? "" : colorLabel.rawValue)
        }

        try connection.transaction {
            let existingRows = Dictionary(
                uniqueKeysWithValues: try cullingDecisionRepo
                    .getByPhotoIds(sessionId: sessionId, photoIds: affectedPhotos.map(\.id))
                    .map { ($0.photoId, $0) }
            )
            let cacheRows = Dictionary(
                uniqueKeysWithValues: try metadataCacheRepo
                    .getBatch(affectedPhotos.map(\.id))
                    .map { ($0.photoId, $0) }
            )

            for photo in affectedPhotos {
                let existing = existingRows[photo.id]
                let cache = cacheRows[photo.id]
                let existingState = rowToState(
                    photoId: photo.id, decisionRow: existing,
                    cachedRating: cache?.rating ?? 0, cachedLabel: cache?.label
                )
                beforeStates.append(existingState)
                let isPickTarget = pickTargets.contains(photo.id)
                let nextPickState = isPickTarget && patch.pickState != nil
                    ? patch.pickState!
                    : existingState.pickState
                let nextRating = patch.rating ?? existingState.rating
                let nextColorLabel = patch.colorLabel ?? existingState.colorLabel
                let nextRevision = existingState.revision + 1

                // 决策行的 rating/color_label 只是镜像列：真相源是同一事务里紧接着
                // 写入的 photo_metadata_cache（读取路径从不读这两列）。
                try cullingDecisionRepo.upsertState(
                    sessionId: sessionId,
                    photoId: photo.id,
                    groupId: groupMap[photo.id] ?? "ungrouped",
                    state: CullingDecisionStateInput(
                        decision: pickStateToDecision(nextPickState).rawValue,
                        rating: Int64(nextRating),
                        colorLabel: nextColorLabel.rawValue,
                        revision: Int64(nextRevision)
                    )
                )
                if patch.rating != nil {
                    try metadataCacheRepo.updateRating(photoId: photo.id, rating: Int64(nextRating))
                }
                if patch.colorLabel != nil {
                    try metadataCacheRepo.updateLabel(photoId: photo.id, label: nextColorLabel.rawValue)
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
                // 不再由 CullingService 直连 sync 端口排程：排程随变更入队
                // （MetadataMutationService 的 schedule=true）走同一条写回链。
                _ = try metadataMutations.queuePhotoValues(
                    sessionId: sessionId,
                    photoId: photoId,
                    values: metadataPatch,
                    source: .culling,
                    schedule: true
                )
            }
            if !historyEntries.isEmpty {
                if let sink = context?.historySink {
                    sink.append(historyEntries)
                } else if let cullingHistoryRepo {
                    historyOperationId = try cullingHistoryRepo.append(
                        sessionId: sessionId, entries: historyEntries
                    ).id
                }
            }
        }

        // S5c-2b-3b-2a：交付行是同步态的优先读模型（写回执行器直接维护它）；
        // 手动 rating/label 仍走旧 mutation 队列，交付行出现前用旧行兜底，
        // 2b 手动队列迁入交付后删除兜底（不让徽标在写入前谎报 clean）。
        let syncStatus = try currentSyncStatus(
            xmpPath: targetXmpPath,
            fallback: changesSharedMetadata ? .pending : .clean
        )
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
    ) throws -> [CullingUpdateResult] {
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
        let groupMap = entry.groupMap ?? [:]
        let linkedByXmp = entry.linkedByXmp ?? [:]
        // pick 更新按逻辑资产合并（同一资产的变体只更新一次），否则按共享侧车
        // 合并（RAW+JPEG 对的 rating/label 一次入队）。
        var operationIds: [String] = []
        var operationKeys: Set<String> = []
        for photoId in uniqueIds {
            // 上面已校验并刷新过上下文；这里仍显式处理，禁止对外部数据强解包。
            guard let photo = photoById[photoId] else {
                throw CullingServiceError.photosNotInSession
            }
            let key = patch.pickState == nil
                ? DeliveryPath.sidecar(photo.filepath)
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
            uniqueKeysWithValues: try cullingDecisionRepo
                .getByPhotoIds(sessionId: sessionId, photoIds: operationIds)
                .map { ($0.photoId, $0) }
        )
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
                        historySink: historySink
                    )
                ))
            }
            if !historySink.entries.isEmpty {
                if let operationId = try cullingHistoryRepo?.append(
                    sessionId: sessionId, entries: historySink.entries
                ).id {
                    for index in results.indices {
                        results[index].historyOperationId = operationId
                    }
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
    ) throws -> [CullingUpdateResult] {
        var historyOperationId = historyOperationId
        var entries = requestedEntries
        var historicalFields: [String: [CullingUpdatePatchField]] = [:]
        if let historyOperationId, let direction {
            guard let operation = try cullingHistoryRepo?.get(sessionId: sessionId, operationId: historyOperationId) else {
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
        // 历史载荷是**外部数据**（库行里的 operation_json，可能残留已删除照片的 id：
        // 迁移去重、用户删片）。禁止强解包，也禁止静默整条丢弃：
        // - 历史重放（undo/redo）→ 跳过缺失照片的条目，其余条目照常应用并记 warn；
        // - 直接调用（renderer 重建补丁）→ 契约错误 CULLING_PHOTO_NOT_IN_SESSION。
        // 存在性以**库**为准（photos.session_id），不依赖可能过期的 TTL 上下文：
        // 被删照片仍留在缓存里会让分歧判定误报，整条 undo 无谓失败。
        let existingPhotoIds = try existingSessionPhotoIds(
            sessionId: sessionId, photoIds: entries.map(\.photoId)
        )
        var applicableEntries: [CullingHistoryApplyEntry] = []
        var skippedHistoryPhotoIds: [String] = []
        for entry in entries {
            guard existingPhotoIds.contains(entry.photoId) else {
                if historyOperationId != nil {
                    skippedHistoryPhotoIds.append(entry.photoId)
                    continue
                }
                throw CullingServiceError.photoNotInSession
            }
            applicableEntries.append(entry)
        }
        if !skippedHistoryPhotoIds.isEmpty {
            GatherLogger.log(
                "culling.apply_history 跳过 \(skippedHistoryPhotoIds.count) 条照片已不存在的历史条目："
                    + skippedHistoryPhotoIds.joined(separator: ","),
                level: .warn
            )
        }
        if applicableEntries.isEmpty {
            // 全部条目都已失效：给出可读的分歧错误（「重置挑片」是清栈出口），
            // 绝不静默成功把栈推到无法解释的状态。
            throw CullingServiceError.historyDiverged
        }
        let currentRows = Dictionary(
            uniqueKeysWithValues: try cullingDecisionRepo
                .getByPhotoIds(sessionId: sessionId, photoIds: applicableEntries.map(\.photoId))
                .map { ($0.photoId, $0) }
        )
        let cacheRows = Dictionary(
            uniqueKeysWithValues: try metadataCacheRepo
                .getBatch(applicableEntries.map(\.photoId))
                .map { ($0.photoId, $0) }
        )
        for entry in applicableEntries {
            let currentRevision = currentRows[entry.photoId]?.revision ?? 0
            if historyOperationId == nil && currentRevision != Int64(entry.expectedRevision) {
                throw CullingServiceError.revisionConflict(
                    expected: entry.expectedRevision, current: Int(currentRevision)
                )
            }
        }
        if let historyOperationId, let direction {
            let operation = try cullingHistoryRepo?.get(sessionId: sessionId, operationId: historyOperationId)
            for historical in operation?.entries ?? [] {
                // 与上面的跳过规则一致：照片已不存在的历史条目不参与分歧判定
                //（否则会误报 CULLING_HISTORY_DIVERGED，让可应用的其余条目一起失败）。
                guard existingPhotoIds.contains(historical.photoId) else { continue }
                let row = currentRows[historical.photoId]
                let cache = cacheRows[historical.photoId]
                let current = rowToState(
                    photoId: historical.photoId, decisionRow: row,
                    cachedRating: cache?.rating ?? 0, cachedLabel: cache?.label
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
        let groupMap = updateEntry.groupMap ?? [:]

        // 每会话批量读一次而非每条目两次（1 万次 undo 就是 2 万次单行查询）：
        // 同步态只读交付行；无交付（手动队列尚未落交付）时按 .clean 呈现，
        // 2b-2 手动队列迁入交付后该默认值即唯一语义。
        let deliveryByPath = try DeliveryRepo(connection: connection).getMany(
            xmpPaths: photoById.values.map { DeliveryPath.sidecar($0.filepath) }
        )
        func deliveryStatus(_ xmpPath: String) -> MetadataSyncStatus {
            if let status = deliveryByPath[xmpPath]?.typedStatus {
                return Self.syncStatus(from: status)
            }
            return .clean
        }

        var results: [CullingUpdateResult] = []
        var historyEntries: [CullingHistoryEntry] = []
        var xmpPatches: [String: (photoId: String, values: [String: JSONValue])] = [:]
        try connection.transaction {
            for entry in applicableEntries {
                // applicableEntries 已保证照片存在；仍显式处理（外部数据不强解包）。
                guard let photo = photoById[entry.photoId] else { continue }
                let existing = currentRows[entry.photoId]
                let cache = cacheRows[entry.photoId]
                let before = rowToState(
                    photoId: entry.photoId, decisionRow: existing,
                    cachedRating: cache?.rating ?? 0, cachedLabel: cache?.label
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
                // rating/color_label 是镜像列（真相源为紧随其后的 cache 写入）。
                try cullingDecisionRepo.upsertState(
                    sessionId: sessionId,
                    photoId: entry.photoId,
                    groupId: groupMap[entry.photoId] ?? "ungrouped",
                    state: CullingDecisionStateInput(
                        decision: pickStateToDecision(after.pickState).rawValue,
                        rating: Int64(after.rating),
                        colorLabel: after.colorLabel.rawValue,
                        revision: Int64(after.revision)
                    )
                )
                if entry.patch.rating != nil {
                    try metadataCacheRepo.updateRating(photoId: entry.photoId, rating: Int64(after.rating))
                }
                if entry.patch.colorLabel != nil {
                    try metadataCacheRepo.updateLabel(photoId: entry.photoId, label: after.colorLabel.rawValue)
                }
                let xmpPath = DeliveryPath.sidecar(photo.filepath)
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
                    syncStatus: deliveryStatus(xmpPath)
                ))
            }
            for (photoId, values) in xmpPatches.values {
                // 排程随入队（不再由 CullingService 直连 sync 端口）。
                _ = try metadataMutations.queuePhotoValues(
                    sessionId: sessionId,
                    photoId: photoId,
                    values: values,
                    source: .culling,
                    schedule: true
                )
            }
            if let historyOperationId, let direction {
                try cullingHistoryRepo?.setUndone(
                    sessionId: sessionId,
                    operationId: historyOperationId,
                    undone: direction == .undo
                )
            } else if let cullingHistoryRepo, !historyEntries.isEmpty {
                historyOperationId = try cullingHistoryRepo.append(
                    sessionId: sessionId, entries: historyEntries
                ).id
            }
        }
        // 交付行不随手动队列变化（queuePhotoValues 仍写旧 outbox，2b-2 迁移），
        // 因此预读的交付快照就是本次返回的同步态；不再回读 outbox。
        for index in results.indices {
            results[index].historyOperationId = historyOperationId
        }
        return results
    }

    /// TS: decideSimilarityGroup —— 整组批量 keep/reject（K 保留 + 其余拒绝）。
    public func decideSimilarityGroup(
        sessionId: String,
        groupId: String,
        keepPhotoIds: [String]
    ) throws -> [CullingUpdateResult] {
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
            uniqueKeysWithValues: try cullingDecisionRepo
                .getByPhotoIds(sessionId: sessionId, photoIds: groupPhotoIds)
                .map { ($0.photoId, $0) }
        )
        return try applyHistory(
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
    public func getGroups(sessionId: String) throws -> [CullingGroup] {
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
            uniqueKeysWithValues: try cullingDecisionRepo.getBySession(sessionId)
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
                    decision: CullingDecisionValue(rawValue: decision) ?? .pending
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
    public func decide(sessionId: String, photoId: String, decision: CullingDecisionValue) throws {
        let current = try cullingDecisionRepo.getDecision(sessionId: sessionId, photoId: photoId)
        try updateState(
            sessionId: sessionId,
            photoId: photoId,
            expectedRevision: Int(current?.revision ?? 0),
            patch: CullingUpdatePatch(pickState: decisionToPickState(decision))
        )
    }

    /// TS: batchDecide —— 旧版 renderer 的批量决策命令。
    public func batchDecide(sessionId: String, photoIds: [String], decision: CullingDecisionValue) throws {
        _ = try batchUpdate(
            sessionId: sessionId,
            photoIds: photoIds,
            patch: CullingUpdatePatch(pickState: decisionToPickState(decision))
        )
    }

    /// TS: getDecisions —— 写回计划的决策输入（photo_id, decision）。
    public func getDecisions(sessionId: String) throws -> [CullingDecisionLiteRow] {
        try cullingDecisionRepo.getDecisions(sessionId)
    }

    /// TS: getHistory —— 历史栈（limit 缺省 100，仓库内 clamp 到 500）。
    ///
    /// 契约：返回数组（id DESC）**必然包含当前 undo/redo 栈顶**——窗口外只剩栈顶
    /// 时把它补进来。读取方据此可以用「MAX(id) 未撤销 / MIN(id) 已撤销」这条唯一
    /// 规则推导按钮可用性与目标操作；旧实现只给最近 limit 条，深度撤销后重做栈顶
    /// 落在窗口外，UI 会误报「没有可撤销/可重做的挑片操作」。
    public func getHistory(sessionId: String, limit: Int = 100) throws -> [CullingHistoryOperation] {
        guard let cullingHistoryRepo else { return [] }
        var operations = try cullingHistoryRepo.list(sessionId: sessionId, limit: limit)
        let tops = try cullingHistoryRepo.stackTops(sessionId: sessionId)
        let loaded = Set(operations.map(\.id))
        var extras: [CullingHistoryOperation] = []
        for id in [tops.undoId, tops.redoId].compactMap({ $0 }) where !loaded.contains(id) {
            if let operation = try cullingHistoryRepo.get(sessionId: sessionId, operationId: id) {
                extras.append(operation)
            }
        }
        if !extras.isEmpty {
            operations = (operations + extras).sorted { $0.id > $1.id }
        }
        return operations
    }

    /// TS: getSummary —— 徽标计数（决策 + 缓存 fallback + 相似度组数）。
    public func getSummary(sessionId: String) throws -> CullingSummary {
        // 轻投影：计数只需照片 id。
        let photos = try photoRepo.getBySessionProjection(sessionId: sessionId)
            .map { CullingPhotoRow(row: $0) }
        let decisions = try cullingDecisionRepo.getBySession(sessionId)
        let decisionByPhoto = Dictionary(uniqueKeysWithValues: decisions.map { ($0.photoId, $0) })
        // 决策与缓存读每次调用保持新鲜：renderer 在每次 update/undo/redo 后重取
        // summary，徽标必须反映刚完成的写入，故每会话缓存永不在此复用。
        let cacheByPhoto = try loadSummaryCacheByPhoto(photos)
        var kept = 0
        var rejected = 0
        var rated = 0
        var labeled = 0
        for photo in photos {
            // 取舍只读决策行；星级/色标只读唯一真相源 cache（决策行的 rating/
            // color_label 是镜像列，读取它们会造出第二真相源）。
            let row = decisionByPhoto[photo.id]
            let cache = cacheByPhoto[photo.id]
            if row?.decision == "keep" { kept += 1 }
            if row?.decision == "reject" { rejected += 1 }
            if (cache?.rating ?? 0) > 0 { rated += 1 }
            let label = cache?.label ?? "None"
            if let parsed = CaptureOneColorLabel(rawValue: label),
               Self.colorLabels.contains(parsed), parsed != .none {
                labeled += 1
            }
        }
        // 组数来自会话查找条目（版本键控）：stats_json.totalGroups 是小组件对象，
        // 替代多 MB 的 groups_json 解析，结果按 (session, result id) 缓存。
        let lookup = try getSessionLookup(sessionId: sessionId)
        var totalGroups = 0
        if let resultRow = lookup.resultRow {
            if !lookup.groupCountResolved {
                lookup.groupCount = parseTotalGroups(resultRow)
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
    ///
    /// 「挑片状态」= 取舍决策行 + 唯一真相源里的星级/色标投影 + 触及这些照片的
    /// 历史操作，三者必须一起清（旧实现只删决策行 → 页面仍显示旧星级、summary
    /// 仍报 rated/labeled）。单事务；只改 Gather 数据库，不写 XMP、不删文件：
    /// 磁盘上的外部值不变，后续导入扫描按 XMP 重建投影属预期。
    public func reset(sessionId: String, groupId: String? = nil) throws {
        try connection.transaction {
            let photoIds: [String]
            if let groupId {
                photoIds = try cullingDecisionRepo.deleteBySessionAndGroup(
                    sessionId: sessionId, groupId: groupId)
            } else {
                photoIds = try cullingDecisionRepo.deleteBySession(sessionId)
            }
            guard !photoIds.isEmpty else { return }
            try clearCullingProjection(photoIds: photoIds)
            try cullingHistoryRepo?.deleteOperationsTouching(
                sessionId: sessionId, photoIds: Set(photoIds)
            )
        }
        // 决策行/历史变了：照片级更新上下文整体失效一次（下次访问重建）。
        sessionUpdateCache.removeValue(forKey: sessionId)
    }

    /// 撤回挑片对唯一真相源（photo_metadata_cache 的 rating/label）的投影。
    /// 只清这两个字段，不触碰 cached_at（缓存新鲜度标记留给导入扫描判断）。
    private func clearCullingProjection(photoIds: [String]) throws {
        for chunk in photoIds.chunked(by: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            _ = try connection.prepare("""
                UPDATE photo_metadata_cache
                SET rating = 0, label = 'None'
                WHERE photo_id IN (\(placeholders))
              """).run(chunk.map { .text($0) })
        }
    }

    // MARK: - IPC 命令面（culling.ipc.ts 逐命令对齐）

    /// TS: culling.sync_status。
    ///
    /// S5c-2b-1 起改读交付模型（DeliverySummaryQuery 的 MetadataSyncSummary 投影），
    /// 只读 deliveries / delivery_items：计数按交付去重，item 的 pending/failed
    /// 会升级展示态；不再读 metadata_outbox。
    public func syncStatus(sessionId: String) throws -> MetadataSyncSummary {
        try delivery.cullingMetadataSummary(sessionId: sessionId)
    }

    /// TS: culling.flush。
    ///
    /// S5c-2b-1 起 flush 的动作是「回放未完成的 delivery intent」（cleanup/finalize
    /// 的崩溃恢复），不再触发旧 outbox 队列；写盘仍由 writeback/retryFailedWriteback
    /// 内的旧 WritebackService.execute 同步完成（S5c-2b-3 整体切换）。
    public func flush(sessionId: String) async throws -> MetadataSyncSummary {
        _ = try await delivery.replayPendingDeliveries()
        return try delivery.cullingMetadataSummary(sessionId: sessionId)
    }

    /// TS: culling.retry_sync。
    ///
    /// 与 flush 同一出口：按相位重放 intent（prepared 重做文件+DB，fileDone 只补 DB），
    /// 然后返回交付摘要。写回失败的逐项重试仍走 retryFailedWriteback。
    public func retrySync(sessionId: String) async throws -> MetadataSyncSummary {
        _ = try await delivery.replayPendingDeliveries()
        return try delivery.cullingMetadataSummary(sessionId: sessionId)
    }

    /// TS: culling.finalize_sync（confirmed 必须为 true，否则
    /// CULLING_FINALIZE_CONFIRM_REQUIRED）。
    ///
    /// S5c-2b-1：改由 DeliveryCoordinator.finalize(dropWithoutRestore) 执行——
    /// 「保留 XMP 并结束」：只处理 synced 交付，删除 items/links/delivery 与备份文件，
    /// **绝不 restore**；intent 前滚保证崩溃后可重试。不是 confirm 的别名。
    ///
    /// 门禁与 confirmSync 一致：Capture One 未 ack reload 时抛旧码
    /// XMP_CONFIRM_REQUIRES_SYNC（DeliveryError.confirmRequiresSync）。
    public func finalizeSync(sessionId: String, confirmed: Bool) async throws -> MetadataSyncSummary {
        guard confirmed else { throw CullingServiceError.finalizeConfirmRequired }
        do {
            let finalized = try await delivery.finalizeCulling(sessionId: sessionId)
            // 逐交付失败保留在 intent 里可重试；旧返回类型没有 errors 位，至少必须进日志
            //（禁止静默吞掉 XMP_FINALIZE_* —— 与 cleanup 的错误可见性同一纪律）。
            for error in finalized.errors {
                GatherLogger.log("culling finalize (\(sessionId)): \(error)", level: .warn)
            }
        } catch let error as DeliveryCoordinatorError {
            if case .reloadNotAcknowledged = error {
                throw DeliveryError.confirmRequiresSync
            }
            throw error
        }
        return try delivery.cullingMetadataSummary(sessionId: sessionId)
    }

    /// TS: culling.writeback —— 决策计划 → preview → 属性合并 → execute。
    /// 写回引擎由注入的 WritebackService 承担，本方法只组装计划与合并关键词。
    ///
    /// 计划的值来自唯一真相源：评分/色标读 photo_metadata_cache（用户设的 3 星就写
    /// 3 星，不是 keep→5/reject→1 的派生常量——execute 落盘后会按写入值刷新 cache，
    /// 写派生常量会反过来污染真相源），关键词来自决策本身。
    public func writeback(
        sessionId: String,
        target: CullingWritebackTarget,
        confirmed: Bool
    ) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackConfirmRequired }
        let decisions = try getDecisions(sessionId: sessionId).filter { $0.decision != "pending" }
        if decisions.isEmpty { throw CullingServiceError.noDecisions }
        let plan = try buildCullingWritebackPlan(decisions: decisions, target: target)
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
        var result = try await writeback.execute(sessionId: sessionId, module: "culling", items: matchingItems)
        // S5c-2b-1 过渡双写：XMP 已落盘，镜像失败不回滚文件，只把错误并入结果。
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId,
            executedIds: Set(matchingItems.compactMap(\.id)),
            fallbackItems: matchingItems,
            result: result
        )
        result.errors.append(contentsOf: mirrorErrors)
        return result
    }

    /// TS: culling.retry_failed_writeback（confirmed 必须为 true，否则
    /// WRITEBACK_RETRY_CONFIRM_REQUIRED）。
    ///
    /// 先记下「本次要重试的失败项 id」：retryFailed 只返回计数，镜像靠这些 id 收敛
    /// 范围，避免把早已 written 的旧项也推进一次 revision。
    public func retryFailedWriteback(sessionId: String, confirmed: Bool) async throws -> WritebackResult {
        guard confirmed else { throw CullingServiceError.writebackRetryConfirmRequired }
        let failedBefore: [Int]
        do {
            failedBefore = try writeback.getItems(
                sessionId: sessionId, module: "culling", status: "failed"
            ).compactMap(\.id)
        } catch {
            // 读不到失败集就不能安全收敛镜像范围：宁可不镜像，也不把旧 written 项再推一次 revision。
            GatherLogger.log(
                "culling retry mirror: failed to read failed items (\(sessionId)): \(error)",
                level: .warn
            )
            failedBefore = []
        }
        var result = try await writeback.retryFailed(sessionId: sessionId, module: "culling")
        guard !failedBefore.isEmpty else { return result }
        let mirrorErrors = mirrorWritebackOutcome(
            sessionId: sessionId,
            executedIds: Set(failedBefore),
            fallbackItems: [],
            result: result
        )
        result.errors.append(contentsOf: mirrorErrors)
        return result
    }

    /// 写回执行结果 → 交付镜像（S5c-2b-1 过渡双写）。
    ///
    /// 状态取执行器写进 delivery_items 的持久化行（getItems 已改读交付表）；
    /// 取不到时按 result.failedItems + result.written 推断（测试替身/无行场景）。
    /// 基线与备份直接回读 deliveries 行（S5c-2b-3b-2a 起执行器自己落库），
    /// 不再有任何 outbox 抄写。
    private func mirrorWritebackOutcome(
        sessionId: String,
        executedIds: Set<Int>,
        fallbackItems: [WritebackItem],
        result: WritebackResult
    ) -> [String] {
        var persistedById: [Int: WritebackItem] = [:]
        do {
            for row in try writeback.getItems(sessionId: sessionId, module: "culling", status: nil) {
                if let id = row.id { persistedById[id] = row }
            }
        } catch {
            // 旧表读失败时退回 result 的失败集/计数推断；镜像缺失会进 errors，不静默。
            GatherLogger.log(
                "culling writeback mirror: failed to read persisted items (\(sessionId)): \(error)",
                level: .warn
            )
        }
        var fallbackById: [Int: WritebackItem] = [:]
        for item in fallbackItems {
            if let id = item.id, executedIds.contains(id) {
                fallbackById[id] = item
            }
        }

        var mirrorItems: [DeliveryWritebackMirrorItem] = []
        for id in executedIds.sorted() {
            let persisted = persistedById[id]
            let candidate = persisted ?? fallbackById[id]
            guard let candidate else { continue }
            let failedResult = result.failedItems.first { $0.id == id }
            let status: DeliveryItemStatus
            switch persisted?.xmpStatus ?? "" {
            case "written":
                status = .written
            case "failed":
                status = .failed
            default:
                if failedResult != nil {
                    status = .failed
                } else if result.written > 0, persisted == nil {
                    status = .written
                } else {
                    // pending（未执行）或无法判定：不镜像，避免谎报写入。
                    continue
                }
            }
            var errorMessage = ""
            if status == .failed {
                if let message = persisted?.errorMessage, !message.isEmpty {
                    errorMessage = message
                } else if let failedResult, !failedResult.errorMessage.isEmpty {
                    errorMessage = failedResult.errorMessage
                } else {
                    errorMessage = result.errors.first {
                        $0.hasPrefix("\(id):") || $0.hasPrefix(candidate.photoPath)
                    } ?? "WRITEBACK_FAILED"
                }
            }

            // S5c-2b-3b-2a：基线/备份以执行器刚写进 deliveries 的行为准（execute
            // 已直接落 base_fingerprint/base_values/backup_path），不再从 outbox 抄。
            let deliveryRow = try? DeliveryRepo(connection: connection).get(candidate.xmpPath)
            let baseValues = deliveryRow?.baseValues ?? .object([:])
            var attributes: [String: JSONValue] = [:]
            if let rating = candidate.attributes?.rating {
                attributes["rating"] = .number(rating)
            }
            if let label = candidate.attributes?.label {
                attributes["label"] = .string(label)
            }
            let keywords = candidate.attributes?.keywords ?? candidate.keywords
            mirrorItems.append(DeliveryWritebackMirrorItem(
                photoId: candidate.photoId,
                photoPath: candidate.photoPath,
                xmpPath: candidate.xmpPath,
                keywords: keywords,
                attributes: attributes,
                status: status,
                errorMessage: errorMessage,
                backupPath: deliveryRow.flatMap { $0.backupPath.isEmpty ? nil : $0.backupPath }
                    ?? candidate.backupPath,
                baseFingerprint: deliveryRow?.baseFingerprint ?? "",
                baseValues: baseValues
            ))
        }

        do {
            let summary = try delivery.mirrorCullingWriteback(
                sessionId: sessionId, items: mirrorItems
            )
            return summary.errors
        } catch {
            return ["DELIVERY_MIRROR_FAILED: \(error)"]
        }
    }

    // MARK: - 确认 / 清理 / 收尾（Cut 2：接 DeliveryCoordinator，module = .culling）

    /// TS: culling.confirm_sync —— 交付确认（门禁读 + 单事务状态推进）。
    ///
    /// 旧链路（metadataSync.confirmSync + writeback.confirmSync）已由
    /// DeliveryCoordinator 取代；不再写 sessions.writeback_status（D-021，V1 已删列）。
    /// 错误语义保持旧 UI 认得的码：
    /// - 门禁不完整（pending/writing/failed/conflict）→ XMP_CONFIRM_INCOMPLETE；
    /// - 未 ack reload（§5.4-2）→ XMP_CONFIRM_REQUIRES_SYNC；
    /// - 跨会话未确认 → XMP_CONFIRM_OTHER_SESSION_PENDING:<sessionId>
    ///   （本会话 confirmed_at 已先落地，交付留在 written 等对方确认）。
    public func confirmSync(sessionId: String) async throws {
        _ = try confirmDelivery(sessionId: sessionId)
    }

    /// TS: culling.cleanup（confirmed 必须为 true，否则
    /// WRITEBACK_CLEANUP_CONFIRM_REQUIRED）。
    ///
    /// 由 DeliveryCoordinator 清理（module=.culling）——外部修改的交付标 conflict、
    /// 不恢复、不删行；文件/DB 失败保留 intent，下次 replay 可重试。
    /// 旧的「metadataSync.cleanup + writeback.cleanup 两路合并」已移除；
    /// S5c-2b-1 起 writeback 结果也已镜像到 delivery_items（过渡双写），
    /// 旧表和 execute 执行器在 S5c-2b-3 删除。
    public func cleanup(sessionId: String, confirmed: Bool) async throws -> CleanupResult {
        guard confirmed else { throw CullingServiceError.writebackCleanupConfirmRequired }
        let summary = try await delivery.cleanupCulling(sessionId: sessionId)
        return Self.cleanupResult(from: summary)
    }

    /// culling 确认的唯一出口（confirm 门禁错误 → 旧码；finalize 走同一 coordinator）。
    private func confirmDelivery(sessionId: String) throws -> DeliveryConfirmSummary {
        let summary: DeliveryConfirmSummary
        do {
            summary = try delivery.confirmCulling(sessionId: sessionId)
        } catch let error as DeliveryCoordinatorError {
            if case .confirmIncomplete(let blockers) = error {
                // 旧码保持可读；阻断项进日志（UI 文案只认码值）。
                GatherLogger.log(
                    "culling confirm blocked (\(sessionId)): " + blockers.joined(separator: ","),
                    level: .warn
                )
                throw DeliveryError.confirmIncomplete
            }
            if case .reloadNotAcknowledged = error {
                // §5.4-2：Capture One 未确认重载 → 旧 UI 认得的"还不能收口"码。
                throw DeliveryError.confirmRequiresSync
            }
            throw error
        }
        if let blocker = summary.unconfirmedSessionIds.first {
            throw DeliveryError.otherSessionNotConfirmed(sessionId: blocker)
        }
        return summary
    }

    /// DeliveryCleanupSummary → 旧 CleanupResult（协议/UI 契约不变）。
    /// - errors 原样保留（可重试失败，intent 已保留）；
    /// - 外部修改冲突按路径回填 XMP_EXTERNALLY_MODIFIED（旧链路 throw
    ///   externallyModified 产生的同码文案），用户仍能看到哪些侧车被改过。
    private static func cleanupResult(from summary: DeliveryCleanupSummary) -> CleanupResult {
        var errors = summary.errors
        for path in summary.conflictedXmpPaths {
            errors.append(
                MetadataWritebackFailure.from(
                    DeliveryError.externallyModified,
                    xmpPath: path
                ).description
            )
        }
        return CleanupResult(deletedCount: summary.deletedCount, errors: errors)
    }

    /// TS: culling.reset（confirmed 必须为 true，否则
    /// CULLING_RESET_CONFIRM_REQUIRED）。
    public func resetCommand(sessionId: String, groupId: String? = nil, confirmed: Bool) throws {
        guard confirmed else { throw CullingServiceError.resetConfirmRequired }
        try reset(sessionId: sessionId, groupId: groupId)
    }

    /// culling 写回计划：决策集 → 每照片的目标属性。
    /// 评分/色标的值来自唯一真相源 photo_metadata_cache；关键词来自决策本身。
    private func buildCullingWritebackPlan(
        decisions: [CullingDecisionLiteRow],
        target: CullingWritebackTarget
    ) throws -> [String: WritebackAttributes] {
        var cacheByPhoto: [String: MetadataCacheRow] = [:]
        if target != .keyword {
            cacheByPhoto = Dictionary(
                uniqueKeysWithValues: try metadataCacheRepo
                    .getBatch(decisions.map(\.photoId))
                    .map { ($0.photoId, $0) }
            )
        }
        var plan: [String: WritebackAttributes] = [:]
        for decision in decisions {
            switch target {
            case .rating:
                let cache = cacheByPhoto[decision.photoId]
                let rating = Swift.min(5, Swift.max(0, cache?.rating ?? 0))
                plan[decision.photoId] = WritebackAttributes(rating: Double(rating))
            case .colorLabel:
                let label = Self.colorLabel(cacheByPhoto[decision.photoId]?.label)
                // 写盘标签语义：None → 空串（清空色标），与 culling.update 一致。
                plan[decision.photoId] = WritebackAttributes(
                    label: label == .none ? "" : label.rawValue
                )
            case .keyword:
                plan[decision.photoId] = WritebackAttributes(
                    keywords: ["culling:\(decision.decision)"]
                )
            }
        }
        return plan
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
    /// 这里按 rowid（导入序）返回组内全部行，与 getAssetPage 一致：变体顺序在三个
    /// scope 下必须同一种（UI 切换器顺序不该随筛选变化），代表行由 assembleAssets
    /// 用共享 RAW 表选出并标 primary——代表行的 SQL 规则见 preferredRowPredicate。
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

    /// TS: preferredRowPredicate —— 每个资产组限定到首选行的 SQL 谓词。代表行
    /// 规则不再本地重写：唯一真相源是 PhotoRepo.preferredRowOrderSQL（RAW 变体
    /// 优先，其次最小 rowid），与图库/导出的代表行规则同源；各写一份会让同一资产
    /// 在不同页面显示成不同变体。谓词对未分组照片是 no-op
    ///（gid = id ⇒ 子查询返回自身）。
    private func preferredRowPredicate() -> String {
        "p.id = (" +
            "SELECT p2.id FROM photos p2" +
            " WHERE p2.session_id = p.session_id" +
            " AND COALESCE(NULLIF(p2.asset_id, ''), p2.id) = COALESCE(NULLIF(p.asset_id, ''), p.id)" +
            " ORDER BY \(PhotoRepo.preferredRowOrderSQL(alias: "p2"))" +
            " LIMIT 1" +
        ")"
    }

    /// TS: buildFilteredWhere —— matchesFilters 的精确下推。谓词作用于构建资产组的
    /// 首选行，页面游标留在组查询的 HAVING 里；total 用同一 WHERE（countForScope），
    /// 因此 filtered 范围的 total 与页内容永远同一口径。
    ///
    /// metadataConflictOnly 同样下推（旧实现只在 JS 层过滤 → total 虚高、可空页）：
    /// 判定规则与 matchesFilters 一致，都是「首选变体的 photo_path 有 status='conflict'
    /// 的 outbox 行」。
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
            // 星级/色标只读唯一真相源 c（photo_metadata_cache）；d.rating /
            // d.color_label 是镜像列，读它们会恢复双真相源。
            if let ratings = filters.ratings, !ratings.isEmpty {
                let placeholders = ratings.map { _ in "?" }.joined(separator: ",")
                clauses.append("COALESCE(c.rating, 0) IN (\(placeholders))")
                params.append(contentsOf: ratings.map { DBValue.real($0) })
            }
            if let colorLabels = filters.colorLabels, !colorLabels.isEmpty {
                let placeholders = colorLabels.map { _ in "?" }.joined(separator: ",")
                clauses.append("""
                    COALESCE(NULLIF(c.label, ''), 'None') IN (\(placeholders))
                    """)
                params.append(contentsOf: colorLabels.map { .text($0.rawValue) })
            }
            if filters.metadataConflictOnly == true {
                clauses.append("""
                    EXISTS (
                      SELECT 1 FROM deliveries d
                      JOIN delivery_sessions ds ON ds.delivery_id = d.id
                      WHERE ds.session_id = ? AND d.status = 'conflict'
                        AND d.photo_path = p.filepath
                    )
                    """)
                params.append(.text(sessionId))
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

    /// 交付项的 module → 旧 MetadataMutationSource 投影（每侧车取最近更新的 item）。
    ///
    /// 旧 outbox 的 patch_json.source 已无生产写入；V1 的归属由
    /// delivery_items.module 结构化表达（schema-v1-draft §5.3-3）。module 值不在
    /// MetadataMutationSource 里（如 "metadata"）时留空，不伪造来源。
    private func loadDeliveryMetadataSourceByPath(
        xmpPaths: [String]
    ) throws -> [String: MetadataMutationSource] {
        struct SourceRow {
            let xmpPath: String
            let module: String
        }
        let unique = Array(Set(xmpPaths))
        guard !unique.isEmpty else { return [:] }
        let rows: [SourceRow] = try withChunkedIds(unique) { chunk in
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            return try connection.prepare("""
                SELECT d.xmp_path, di.module
                FROM delivery_items di
                JOIN deliveries d ON d.id = di.delivery_id
                WHERE d.xmp_path IN (\(placeholders))
                ORDER BY di.updated_at DESC, di.id DESC
              """).query(chunk.map { .text($0) }).compactMap { row in
                guard let xmpPath = row[0].textValue, let module = row[1].textValue else {
                    return nil
                }
                return SourceRow(xmpPath: xmpPath, module: module)
            }
        }
        var result: [String: MetadataMutationSource] = [:]
        for row in rows where result[row.xmpPath] == nil {
            result[row.xmpPath] = MetadataMutationSource(rawValue: row.module)
        }
        return result
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
    ) throws -> CullingRichLookup {
        let photoIds = photos.map(\.id)
        let decisions = Dictionary(
            uniqueKeysWithValues: try (mode == .session
                ? cullingDecisionRepo.getBySession(sessionId)
                : cullingDecisionRepo.getByPhotoIds(sessionId: sessionId, photoIds: photoIds))
                .map { ($0.photoId, $0) }
        )
        let cacheRows = Dictionary(
            uniqueKeysWithValues: try metadataCacheRepo.getBatch(photoIds)
                .map { ($0.photoId, $0) }
        )
        // 同步态读交付行（不再读旧 outbox）：一次 IN 查询覆盖本次页/会话的照片；
        // 交付项 module 投影成旧 MetadataMutationSource 供 UI 显示来源。
        let xmpPaths = photos.map { DeliveryPath.sidecar($0.filepath) }
        let deliveryByPath = try DeliveryRepo(connection: connection).getMany(xmpPaths: xmpPaths)
        let metadataSourceByPath = try loadDeliveryMetadataSourceByPath(xmpPaths: xmpPaths)
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
            let xmpPath = DeliveryPath.sidecar(photo.filepath)
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
                guard var updated = qualityByPhoto[member.photoId] else { continue }
                updated.relativeRank = Double(index + 1)
                qualityByPhoto[member.photoId] = updated
            }
        }
        return CullingRichLookup(
            decisions: decisions,
            cacheRows: cacheRows,
            deliveryByPath: deliveryByPath,
            metadataSourceByPath: metadataSourceByPath,
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
            let xmpPath = DeliveryPath.sidecar(photo.filepath)
            let deliveryStatus = lookup.deliveryByPath[xmpPath]?.typedStatus
            // 来源由交付项 module 投影（旧 outbox patch_json.source 已无生产写入）。
            let metadataSource = lookup.metadataSourceByPath[xmpPath]
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
                    decisionRow: decision,
                    cachedRating: cache?.rating ?? 0,
                    cachedLabel: cache?.label
                ),
                xmpPath: xmpPath,
                syncStatus: deliveryStatus.map { Self.syncStatus(from: $0) } ?? .clean,
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
            // 代表行=「RAW 变体优先，其次最小 rowid」，与 SQL 的
            // PhotoRepo.preferredRowOrderSQL 是同一条规则，这里是它的内存态实现：
            // 输入数组按 rowid 升序（getBySession / getAssetPage / loadAssetRows 都
            // 是），故「首个 RAW，否则首个」≡「RAW 优先，其次最小 rowid」。
            // 不能直接调用 SQL 排序的原因：list() 走 getBySession 全量读、不经过
            // 任何组查询（scope: .all 的分页也不选代表行），shared 规则只有 SQL 串
            // 形态；RAW 判定本身已复用共享表 PhotoRepo.rawExtensions。
            // 两条路径的一致性由 CullingRepresentativeRowRuleTests 双向钉住
            //（list 与 filtered 分页在 JPEG 先入时都必须给 RAW）。
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
    /// （pick/rating/label/quality/similarity/metadataConflictOnly）SQL 谓词已作用
    /// 在首选行，此 JS 遍恒通过（同一 photo_path 判定规则，见 conflictPhotoPaths）。
    private func filterVisible(
        _ assets: [CullingAsset],
        scope: CullingScope,
        filters: CullingFilters?,
        requestedGroupId: String?,
        conflictingPhotoPaths: Set<String>
    ) -> [CullingAsset] {
        assets.filter { asset in
            if scope == .similarityGroup {
                guard let similarityGroupId = asset.similarityGroupId else { return false }
                if let requestedGroupId, similarityGroupId != requestedGroupId { return false }
            }
            return scope != .filtered
                || matchesFilters(asset, filters: filters, conflictingPhotoPaths: conflictingPhotoPaths)
        }
    }

    /// TS: matchesFilters。
    /// metadataConflictOnly 与 SQL 下推用**同一条规则**：该资产首选变体的 photo_path
    /// 存在 status='conflict' 的 outbox 行。用 syncStatus（每资产首选的侧车行）会让
    /// 两遍在「变体与首选不同行」时发散，故这里显式用同一集合。
    private func matchesFilters(
        _ asset: CullingAsset,
        filters: CullingFilters?,
        conflictingPhotoPaths: Set<String>
    ) -> Bool {
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
        if filters.metadataConflictOnly == true
            && !conflictingPhotoPaths.contains(asset.photo.filepath) { return false }
        return true
    }

    /// metadataConflictOnly 的冲突照片路径集合（SQL 下推与 JS 安全网共用的唯一规则）。
    /// 冲突态读统一交付模型（deliveries.status='conflict'），未启用该过滤时返回空集合。
    private func conflictPhotoPaths(
        sessionId: String,
        filters: CullingFilters?
    ) throws -> Set<String> {
        guard filters?.metadataConflictOnly == true else { return [] }
        let rows = try connection.prepare("""
            SELECT DISTINCT d.photo_path
            FROM deliveries d
            JOIN delivery_sessions ds ON ds.delivery_id = d.id
            WHERE ds.session_id = ? AND d.status = 'conflict'
          """).query([.text(sessionId)])
        return Set(rows.compactMap { $0[0].textValue })
    }

    // MARK: - 会话更新上下文缓存（TS getSessionUpdateContext /
    // refreshSessionUpdateContext / ensureUpdateExtras / prune）

    /// TS: getSessionUpdateContext —— 会话照片 + id 索引，TTL 缓存。更新路径
    /// 用它让点击突发不再每次重读整个会话（轻投影跳过重 JSON 列）。
    /// 库侧存在性查询（分块 IN，避免 SQLite 变量上限）：历史重放的跳过规则与
    /// 直接调用的契约错误共用。
    private func existingSessionPhotoIds(sessionId: String, photoIds: [String]) throws -> Set<String> {
        var found = Set<String>()
        for chunk in photoIds.chunked(by: 800) where !chunk.isEmpty {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try connection.prepare(
                "SELECT id FROM photos WHERE session_id = ? AND id IN (\(placeholders))"
            ).query([.text(sessionId)] + chunk.map { .text($0) })
            for row in rows {
                if let id = row[0].textValue { found.insert(id) }
            }
        }
        return found
    }

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
            let xmpPath = DeliveryPath.sidecar(photo.filepath)
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

    /// TS: rowToState —— 决策行（取舍/版本/来源）+ 唯一真相源（星级/色标）→
    /// AssetCullingState。
    ///
    /// 禁止在决策行存在时改读 row.rating / row.colorLabel：那两列是镜像列，
    /// 读取它们等于恢复「读 A 走 B」的双真相源（见文件头注）。
    private func rowToState(
        photoId: String,
        decisionRow: CullingDecisionRow?,
        cachedRating: Int64,
        cachedLabel: String?
    ) -> AssetCullingState {
        let rating = (0...5).contains(cachedRating) ? cachedRating : 0
        return AssetCullingState(
            photoId: photoId,
            pickState: decisionToPickState(decisionRow?.decision),
            rating: Double(rating),
            colorLabel: Self.colorLabel(cachedLabel),
            source: sourceFromDecisionRow(decisionRow),
            revision: Int(decisionRow?.revision ?? 0),
            updatedAt: decisionRow?.updatedAt ?? ""
        )
    }

    /// 合法色标解析：nil / 未知 / 非法值一律归 .none（唯一真相源里可能有历史脏值）。
    private static func colorLabel(_ raw: String?) -> CaptureOneColorLabel {
        guard let raw, let parsed = CaptureOneColorLabel(rawValue: raw),
              colorLabels.contains(parsed) else { return .none }
        return parsed
    }

    /// TS: rowToState 的 source 分支（决策行存在时取合法 decision_source，缺省
    /// manual；行缺失时为 imported）。
    private func sourceFromDecisionRow(_ row: CullingDecisionRow?) -> CullingDecisionSource {
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

    /// TS: decisionToPickState（CullingDecisionValue 入参版，decide/batchDecide）。
    private func decisionToPickState(_ decision: CullingDecisionValue) -> PickState {
        switch decision {
        case .keep: .picked
        case .reject: .rejected
        case .pending: .unreviewed
        }
    }

    /// TS: pickStateToDecision。
    private func pickStateToDecision(_ pickState: PickState) -> CullingDecisionValue {
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
    /// V1 的 photos 不再有 metadata/result 列（Cut 2 S5a）：PhotoData 的这两个
    /// 字段保留为协议形状，但不再从行读，恒为空对象（UI 亦不消费它们）。
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
            metadata: [:],
            result: [:],
            status: row.status,
            assetId: row.assetId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    /// TS: isPreferredRawVariant —— 首选 RAW 变体探测（小写扩展名集合的 O(1)
    /// 探测替代 per-candidate `some(...endsWith)` 扫描）。扩展名表来自共享的
    /// PhotoRepo.rawExtensions，与 preferredRowOrderSQL 的 LIKE 链同源。
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
