// desktop/native/gather-app/Sources/GatherUI/Library/LibraryViewModel.swift
// Phase 3.2 Library（全局图库）：视图模型（服务可注入，同进程直连类型化 API）。
//
// Cut 1 / B6b：metadata.orphans / resolve_orphan 已迁移到 AppServices.metadata
// （MetadataAPI）；孤立 XMP 列表改 async 拉取，处置只经 Confirmed<T>。
// TS 源: desktop/src/renderer/pages/Library/index.tsx（buildCriteria / PAGE_SIZE /
//       useDebouncedValue / 分页 offset 语义）
//       + api/filter.ts photosGlobal（filter.photos_global 形状）
//
// 差异说明（有意）：
// - TS 的 react-query 缓存 + criteriaKey/page 联动 → 显式防抖提交
//   （search/keyword/directory/person 四个自由文本字段 300ms，其余字段立即）；
// - 智能相册、RAW/JPEG 资产关联、孤立 XMP 与离线卷操作均通过类型化 API 展示；
// - 分页为 offset 形态（filter.photos_global 的 limit/offset 钳制在路由内）。
//
// Cut 4 / 4c-2j：796 行 -> 7 文件（行为不变）。本文件只保留筛选状态/
// buildCriteria / Provider 协议与 Live 实现 / VM 状态与 init；行为按域拆到六个
// extension：+Load（加载/支持数据/破坏性动作）、+Filter（筛选提交/计数）、
// +Paging（分页/区间文案）、+Fetch（取数/代次守卫）、+EventRefresh（终态合并）、
// +ErrorText（错误码文案）。跨文件 extension 的写回属性由 private(set) 放宽为
// public internal(set)（模块外仍只读），私有存储/任务句柄由 private 放宽为
// internal；声明、默认值、判据与文案逐字未动。
import Foundation
import AppKit
import GatherProtocol

/// TS: Library/index.tsx 筛选表单状态（useState 组，字符串语义对齐
/// <option value>：'' = 未筛选）。
public struct LibraryFilterState: Equatable, Sendable {
    public var search = ""
    public var rating = ""
    public var label = ""
    public var status = ""
    public var keyword = ""
    public var directory = ""
    public var volume = ""
    public var person = ""
    public var duplicates = ""
    public var recentDays = ""

    public init() {}

    /// 需防抖的自由文本字段（TS useDebouncedValue 包裹的四个）。
    /// Swift 6 迁移：WritableKeyPath 非 Sendable，静态存储会触发
    /// MutableGlobalVariable；改为只读计算属性（每次构造新 Set，无共享存储，
    /// 调用点语义不变：仅做 contains 判定）。
    public static var debouncedFields: Set<WritableKeyPath<LibraryFilterState, String>> {
        [\.search, \.keyword, \.directory, \.person]
    }
}

/// TS: Library/index.tsx buildCriteria（Library.tsx:52-91）—— 逐字段映射为
/// FilterGroup（logic 'and'）。筛选值类型与 FilterEngine 契约对齐：
/// rating gte number / has_duplicates eq bool / keywords contains_any [String]。
public func buildLibraryCriteria(_ state: LibraryFilterState) -> FilterGroup {
    var conditions: [FilterCondition] = []

    func add(_ field: String, _ operator: FilterOperator, _ value: JSONValue) {
        conditions.append(.rule(FilterRule(field: field, operator: `operator`, value: value)))
    }

    let search = state.search.trimmingCharacters(in: .whitespaces)
    if !search.isEmpty {
        add("filename", .contains, .string(search))
    }
    if let rating = Int(state.rating) {
        add("rating", .gte, .number(Double(rating)))
    }
    if !state.label.isEmpty {
        add("label", .eq, .string(state.label))
    }
    if !state.status.isEmpty {
        // TS: online → status neq 'missing'；missing → status eq 'missing'。
        add("status", state.status == "online" ? .neq : .eq, .string("missing"))
    }
    let keyword = state.keyword.trimmingCharacters(in: .whitespaces)
    if !keyword.isEmpty {
        add("keywords", .containsAny, .array([.string(keyword)]))
    }
    let directory = state.directory.trimmingCharacters(in: .whitespaces)
    if !directory.isEmpty {
        add("directory", .startsWith, .string(directory))
    }
    if !state.volume.isEmpty {
        add("volume", .eq, .string(state.volume))
    }
    let person = state.person.trimmingCharacters(in: .whitespaces)
    if !person.isEmpty {
        add("person", .contains, .string(person))
    }
    if !state.duplicates.isEmpty {
        add("has_duplicates", .eq, .bool(state.duplicates == "yes"))
    }
    if let recentDays = Int(state.recentDays) {
        // TS: Date.now() - N 天 → ISO8601（毫秒精度字符串）。
        let since = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(recentDays) * 86_400)
        )
        add("created_at", .gte, .string(since))
    }
    return FilterGroup(logic: .and, conditions: conditions)
}

/// 数据访问抽象：ViewModel 依赖协议，测试可注入 stub（错误态）或
/// LiveLibraryDataProvider（临时 SQLite + typed API）。
/// Swift 6 迁移：协议继承 Sendable（Live 实现只持有不可变的各域 API），使
/// @MainActor ViewModel 可在 async 调用中安全地把 provider existential 送出。
public protocol LibraryDataProvider: Sendable {
    func listSessions() throws -> [SessionData]
    /// TS: filterApi.photosGlobal → { photos, total }。
    /// async：分页大查询经 executeAsync 走后台线程（避免 @MainActor 主线程阻塞）。
    func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int)

    /// TS: albumApi.list / getPhotos / create / update / delete。
    /// 默认实现保留测试 stub 与最小第三方 provider 的兼容性；真实 provider
    /// 必须覆盖这些方法，避免 Library 页面静默丢失智能相册能力。
    func listAlbums() throws -> [SmartAlbumData]
    func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int)
    func createAlbum(name: String, criteria: FilterGroup) throws -> SmartAlbumData
    func updateAlbum(albumId: String, criteria: FilterGroup) throws
    /// 破坏性：confirmed 必须由视图的确认动作注入，**不设默认值**——
    /// 编译期强制每个调用点说明它拿到的是用户确认还是取消。
    func deleteAlbum(albumId: String, confirmed: Bool) throws

    /// TS: assetApi.candidates / acceptCandidate / rejectCandidate / volumes / relinkRoot。
    func listAssetCandidates() throws -> [AssetLinkCandidateData]
    /// 破坏性（合并/拆分会改变资产结构）：confirmed 同上。
    func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) throws
    func listAssetVolumes() throws -> [AssetVolumeData]
    /// 破坏性（改写该根下全部路径记录）：confirmed 同上。
    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) throws -> Int

    /// TS: metadataApi.orphans / resolveOrphan（B6b 起走 MetadataAPI）。
    func listMetadataOrphans() async throws -> [MetadataOrphan]
    /// .restore 会用备份覆盖照片文件（不可撤销）：只接收 Confirmed<T>，
    /// 确认来源由 UI 的确认弹窗决定（D-011）。
    func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan]
}

public extension LibraryDataProvider {
    func listAlbums() throws -> [SmartAlbumData] { [] }

    func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        ([], 0)
    }

    func createAlbum(name: String, criteria: FilterGroup) throws -> SmartAlbumData {
        throw APIError.failed("ALBUM_NOT_SUPPORTED")
    }

    func updateAlbum(albumId: String, criteria: FilterGroup) throws {
        throw APIError.failed("ALBUM_NOT_SUPPORTED")
    }

    func deleteAlbum(albumId: String, confirmed: Bool) throws {
        throw APIError.failed("ALBUM_NOT_SUPPORTED")
    }

    func listAssetCandidates() throws -> [AssetLinkCandidateData] { [] }

    func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) throws {
        throw APIError.failed("ASSET_LINK_NOT_SUPPORTED")
    }

    func listAssetVolumes() throws -> [AssetVolumeData] { [] }

    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) throws -> Int {
        throw APIError.failed("ASSET_RELINK_NOT_SUPPORTED")
    }

    func listMetadataOrphans() async throws -> [MetadataOrphan] { [] }

    func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        throw APIError.failed("METADATA_ORPHAN_NOT_SUPPORTED")
    }
}

/// 真实实现：B2 已把 session.list / filter.photos_global / album.* / assets.*
/// 迁到 SessionAPI / PhotoAPI / AlbumAPI / AssetAPI；B6b 起 metadata.orphans /
/// resolve_orphan 走 MetadataAPI。Live 实现只做渲染形状与“bool 确认 ->
/// Confirmed<T>”的边界适配，不再派发字符串命令。
///
/// 同步方法保留：LibraryDataProvider 是同步协议（View 与既有测试共用），
/// LiveAlbumAPI/LiveAssetAPI/LiveSessionAPI 的同步核心让 UI 不必在 MainActor
/// 上阻塞等待 async API；异步分页/查询直接走协议方法。
public final class LiveLibraryDataProvider: LibraryDataProvider {
    private let sessionAPI: any SessionAPI
    private let photoAPI: any PhotoAPI
    private let assetAPI: any AssetAPI
    private let albumAPI: any AlbumAPI
    /// Cut 1 / B6b：元数据域（orphans / resolve_orphan）。
    private let metadataAPI: any MetadataAPI

    /// 显式装配：五个域 API 由调用方（AppServices / 测试）注入。
    /// B8.4 起不再提供字符串命令构造器；MetadataService/Coordinator 只能有
    /// 一份，因此 metadata 是必填依赖，不从组合根兜底构造。
    public init(
        session: any SessionAPI,
        photo: any PhotoAPI,
        asset: any AssetAPI,
        album: any AlbumAPI,
        metadata: any MetadataAPI
    ) {
        self.sessionAPI = session
        self.photoAPI = photo
        self.assetAPI = asset
        self.albumAPI = album
        self.metadataAPI = metadata
    }

    public func listSessions() throws -> [SessionData] {
        // SessionAPI 没有同步方法；生产只注入实现 SessionSyncAPI 的 Live
        // 适配器（B1）。非同步注入仅存在于测试夹具，显式失败而不是回退第二套
        // SessionService。
        guard let live = sessionAPI as? any SessionSyncAPI else {
            throw APIError.failed("SESSION_LIST_UNSUPPORTED")
        }
        return try live.listSessionsSync()
    }

    public func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let result = try await photoAPI.search(try PhotoQuery(
            criteria: criteria,
            sessionId: sessionId,
            limit: limit,
            offset: offset
        ))
        return (result.photos, result.total)
    }

    public func listAlbums() throws -> [SmartAlbumData] {
        try albumSyncAPI().listAlbumsSync()
    }

    public func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let page = try await albumAPI.photos(try AlbumPhotosQuery(
            albumId: albumId,
            limit: limit,
            offset: offset
        ))
        return (page.photos, page.total)
    }

    public func createAlbum(name: String, criteria: FilterGroup) throws -> SmartAlbumData {
        let detail = try albumSyncAPI().createAlbumSync(
            AlbumCreateParams(name: name, criteria: criteria)
        )
        return SmartAlbumData(
            id: detail.id,
            schemaVersion: detail.schemaVersion,
            name: detail.name,
            description: detail.description,
            filterCriteria: detail.filterCriteria,
            sortBy: detail.sortBy,
            sortOrder: detail.sortOrder,
            icon: detail.icon,
            createdAt: detail.createdAt,
            updatedAt: detail.updatedAt,
            validationError: detail.validationError
        )
    }

    public func updateAlbum(albumId: String, criteria: FilterGroup) throws {
        try albumSyncAPI().updateAlbumSync(AlbumUpdateParams(albumId: albumId, criteria: criteria))
    }

    public func deleteAlbum(albumId: String, confirmed: Bool) throws {
        // 确认来自视图弹窗的 bool；API 只接收 Confirmed。false 时根本不调用 API，
        // 保留旧命令“未确认 -> ALBUM_DELETE_CONFIRM_REQUIRED”的门禁语义。
        guard confirmed else { throw GatherError(code: .ALBUM_DELETE_CONFIRM_REQUIRED) }
        let input = try AlbumDeleteInput(albumId: albumId)
        try albumSyncAPI().deleteAlbumSync(input.albumId)
    }

    public func listAssetCandidates() throws -> [AssetLinkCandidateData] {
        try assetSyncAPI().assetCandidatesSync(nil)
    }

    public func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) throws {
        guard confirmed else {
            throw GatherError(code: accept ? .ASSET_LINK_ACCEPT_CONFIRM_REQUIRED
                                           : .ASSET_LINK_REJECT_CONFIRM_REQUIRED)
        }
        let reference = try AssetCandidateReference(candidateId: candidateId)
        if accept {
            _ = try assetSyncAPI().acceptCandidateSync(reference.candidateId)
        } else {
            _ = try assetSyncAPI().rejectCandidateSync(reference.candidateId)
        }
    }

    public func listAssetVolumes() throws -> [AssetVolumeData] {
        try assetSyncAPI().assetVolumesSync()
    }

    public func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) throws -> Int {
        guard confirmed else { throw GatherError(code: .ASSET_RELINK_CONFIRM_REQUIRED) }
        let input = try AssetRelinkInput(oldRoot: oldRoot, newRoot: newRoot)
        return try assetSyncAPI().assetRelinkRootSync(oldRoot: input.oldRoot, newRoot: input.newRoot)
    }

    // MARK: - Live API 同步核心（测试接缝）

    private func albumSyncAPI() throws -> any AlbumSyncAPI {
        guard let live = albumAPI as? any AlbumSyncAPI else {
            throw APIError.failed("ALBUM_NOT_SUPPORTED")
        }
        return live
    }

    private func assetSyncAPI() throws -> any AssetSyncAPI {
        guard let live = assetAPI as? any AssetSyncAPI else {
            throw APIError.failed("ASSET_LINK_NOT_SUPPORTED")
        }
        return live
    }

    public func listMetadataOrphans() async throws -> [MetadataOrphan] {
        try await metadataAPI.orphans()
    }

    public func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        try await metadataAPI.resolveOrphan(input)
    }
}

/// 全局图库视图模型：跨工作区照片浏览（filter.photos_global 分页 + 防抖）。
@MainActor
@Observable
public final class LibraryViewModel {
    /// TS: PAGE_SIZE = 60。
    public static let pageSize = 60

    let provider: LibraryDataProvider
    let debounceDelay: Duration
    var debounceTask: Task<Void, Never>?
    var fetchTask: Task<Void, Never>?
    var eventRefreshTask: Task<Void, Never>?
    /// 数据代数（D06）：筛选/相册/会话条件变化即递增，在途响应返回后代数不符就整份
    /// 作废。旧实现依赖 `fetchTask?.cancel()`，而旧字符串命令的 continuation
    /// 请求无法被真正取消——慢的旧请求会覆盖新筛选的结果。
    var fetchGeneration = 0
    /// 同代内的请求序号（P2-7）：最新请求胜出，旧响应不得回退用户翻页。
    var requestSequence = 0
    var latestRequestID = 0
    var committed: LibraryFilterState = LibraryFilterState()
    /// 当前已提交的 criteriaKey（TS criteriaKey = JSON.stringify(criteria)）。
    var criteriaKey = ""

    public internal(set) var phase: LoadPhase = .loading
    public internal(set) var sessions: [SessionData] = []
    public internal(set) var photos: [GlobalPhotoResult] = []
    public internal(set) var total = 0
    public internal(set) var page = 0
    public internal(set) var isFetching = false
    public internal(set) var actionError: CommandError?
    public internal(set) var albums: [SmartAlbumData] = []
    public internal(set) var assetCandidates: [AssetLinkCandidateData] = []
    public internal(set) var metadataOrphans: [MetadataOrphan] = []
    public internal(set) var assetVolumes: [AssetVolumeData] = []
    public internal(set) var isSupportBusy = false
    /// 筛选表单（视图双向绑定；字段变更须经 onFilterChanged 提交）。
    public var filter = LibraryFilterState()
    /// 选中工作区（'' = 全部工作区，对齐 TS sessionFilter）。
    public var sessionFilter = ""
    /// 选中智能相册；nil 表示全部照片（TS selectedAlbum）。
    public internal(set) var selectedAlbumId: String?

    /// debounceDelay 测试可注入（默认 300ms，对齐 TS useDebouncedValue）。
    public init(provider: LibraryDataProvider, debounceDelay: Duration = .milliseconds(300)) {
        self.provider = provider
        self.debounceDelay = debounceDelay
    }
}
