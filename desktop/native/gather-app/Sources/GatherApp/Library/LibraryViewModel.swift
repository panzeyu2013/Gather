// desktop/native/gather-app/Sources/GatherApp/Library/LibraryViewModel.swift
// Phase 3.2 Library（全局图库）：视图模型（服务可注入，同进程直连路由）。
// TS 源: desktop/src/renderer/pages/Library/index.tsx（buildCriteria / PAGE_SIZE /
//       useDebouncedValue / 分页 offset 语义）
//       + api/filter.ts photosGlobal（filter.photos_global 形状）
//
// 差异说明（有意）：
// - TS 的 react-query 缓存 + criteriaKey/page 联动 → 显式防抖提交
//   （search/keyword/directory/person 四个自由文本字段 300ms，其余字段立即）；
// - 智能相册、RAW/JPEG 资产关联、孤立 XMP 与离线卷操作均通过同一命令路由展示；
// - 分页为 offset 形态（filter.photos_global 的 limit/offset 钳制在路由内）。
import Foundation
import AppKit
import GatherCore

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
    public static let debouncedFields: Set<WritableKeyPath<LibraryFilterState, String>> = [
        \.search, \.keyword, \.directory, \.person,
    ]
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
/// 真实路由（LiveLibraryDataProvider + 临时 SQLite）。
public protocol LibraryDataProvider {
    func listSessions() async throws -> [SessionData]
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
    func listAlbums() async throws -> [SmartAlbumData]
    func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int)
    func createAlbum(name: String, criteria: FilterGroup) async throws -> SmartAlbumData
    func updateAlbum(albumId: String, criteria: FilterGroup) async throws
    func deleteAlbum(albumId: String) async throws

    /// TS: assetApi.candidates / acceptCandidate / rejectCandidate / volumes / relinkRoot。
    func listAssetCandidates() async throws -> [AssetLinkCandidateData]
    func updateAssetCandidate(candidateId: String, accept: Bool) async throws
    func listAssetVolumes() async throws -> [AssetVolumeData]
    func relinkAssetRoot(oldRoot: String, newRoot: String) async throws -> Int

    /// TS: metadataApi.orphans / resolveOrphan。
    func listMetadataOrphans() async throws -> [MetadataOrphan]
    func resolveMetadataOrphan(
        xmpPath: String,
        action: MetadataOrphanAction
    ) async throws -> [MetadataOrphan]
}

public extension LibraryDataProvider {
    func listAlbums() async throws -> [SmartAlbumData] { [] }

    func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        ([], 0)
    }

    func createAlbum(name: String, criteria: FilterGroup) async throws -> SmartAlbumData {
        throw NativeCommandError.failed("ALBUM_NOT_SUPPORTED")
    }

    func updateAlbum(albumId: String, criteria: FilterGroup) async throws {
        throw NativeCommandError.failed("ALBUM_NOT_SUPPORTED")
    }

    func deleteAlbum(albumId: String) async throws {
        throw NativeCommandError.failed("ALBUM_NOT_SUPPORTED")
    }

    func listAssetCandidates() async throws -> [AssetLinkCandidateData] { [] }

    func updateAssetCandidate(candidateId: String, accept: Bool) async throws {
        throw NativeCommandError.failed("ASSET_LINK_NOT_SUPPORTED")
    }

    func listAssetVolumes() async throws -> [AssetVolumeData] { [] }

    func relinkAssetRoot(oldRoot: String, newRoot: String) async throws -> Int {
        throw NativeCommandError.failed("ASSET_RELINK_NOT_SUPPORTED")
    }

    func listMetadataOrphans() async throws -> [MetadataOrphan] { [] }

    func resolveMetadataOrphan(
        xmpPath: String,
        action: MetadataOrphanAction
    ) async throws -> [MetadataOrphan] {
        throw NativeCommandError.failed("METADATA_ORPHAN_NOT_SUPPORTED")
    }
}

/// 真实实现：同进程直连 SessionCommandRouter（photo.list_page 等装配形状
/// 以路由为唯一事实源，避免复制资产装配逻辑）。
public final class LiveLibraryDataProvider: LibraryDataProvider {
    private let router: SessionCommandRouter
    private let client: NativeCommandClient

    public init(router: SessionCommandRouter) {
        self.router = router
        self.client = NativeCommandClient(router: router)
    }

    public func listSessions() async throws -> [SessionData] {
        try await router.sessionService.listSessions()
    }

    public func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let response = try await client.executeAsync("filter.photos_global", params: [
            "criteria": try JSONValue(from: criteria),
            "sessionId": sessionId.map { .string($0) } ?? .null,
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset)),
        ])
        let object = response.objectValue ?? [:]
        let photos: [GlobalPhotoResult] = try (object["photos"] ?? .array([])).decoded(as: [GlobalPhotoResult].self)
        let total = Int(object["total"]?.numberValue ?? 0)
        return (photos, total)
    }

    public func listAlbums() async throws -> [SmartAlbumData] {
        let response = try await client.executeAsync("album.list", params: [:])
        return try response.decoded(as: [SmartAlbumData].self)
    }

    public func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let response = try await client.executeAsync("album.get_photos", params: [
            "albumId": .string(albumId),
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset)),
        ])
        let object = response.objectValue ?? [:]
        let photos: [GlobalPhotoResult] = try (object["photos"] ?? .array([])).decoded(as: [GlobalPhotoResult].self)
        let total = Int(object["total"]?.numberValue ?? 0)
        return (photos, total)
    }

    public func createAlbum(name: String, criteria: FilterGroup) async throws -> SmartAlbumData {
        let response = try await client.executeAsync("album.create", params: [
            "name": .string(name),
            "criteria": try JSONValue(from: criteria),
        ])
        return try response.decoded(as: SmartAlbumData.self)
    }

    public func updateAlbum(albumId: String, criteria: FilterGroup) async throws {
        _ = try await client.executeAsync("album.update", params: [
            "albumId": .string(albumId),
            "criteria": try JSONValue(from: criteria),
        ])
    }

    public func deleteAlbum(albumId: String) async throws {
        _ = try await client.executeAsync("album.delete", params: [
            "albumId": .string(albumId),
            "confirmed": .bool(true),
        ])
    }

    /// 异步命令桥：executeAsync + 续体（assets.* 已迁异步路由）。
    private func asyncCommand(
        _ command: String,
        params: [String: GatherCore.JSONValue]
    ) async throws -> GatherCore.JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            router.executeAsync(command, params: params) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: NativeCommandError.failed(response.error ?? command))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    public func listAssetCandidates() async throws -> [AssetLinkCandidateData] {
        let data = try await asyncCommand("assets.candidates", params: [:])
        return try data.decoded(as: [AssetLinkCandidateData].self)
    }

    public func updateAssetCandidate(candidateId: String, accept: Bool) async throws {
        _ = try router.execute(
            accept ? "assets.accept_candidate" : "assets.reject_candidate",
            params: [
                "candidateId": .string(candidateId),
                "confirmed": .bool(true),
            ]
        )
    }

    public func listAssetVolumes() async throws -> [AssetVolumeData] {
        let response = try await asyncCommand("assets.volumes", params: [:])
        return try response.decoded(as: [AssetVolumeData].self)
    }

    public func relinkAssetRoot(oldRoot: String, newRoot: String) async throws -> Int {
        let response = try await asyncCommand("assets.relink_root", params: [
            "oldRoot": .string(oldRoot),
            "newRoot": .string(newRoot),
            "confirmed": .bool(true),
        ])
        return Int(response.numberValue ?? 0)
    }

    public func listMetadataOrphans() async throws -> [MetadataOrphan] {
        // metadata.orphans 已迁入异步路由（orphanOutbox 为 Store 读）。
        let response: GatherCore.JSONValue = try await withCheckedThrowingContinuation { continuation in
            router.executeAsync("metadata.orphans", params: [:]) { response in
                guard response.ok, let data = response.data else {
                    continuation.resume(throwing: RouterCommandError(message: response.error ?? "METADATA_ORPHANS_FAILED"))
                    return
                }
                continuation.resume(returning: data)
            }
        }
        return try response.decoded(as: [MetadataOrphan].self)
    }

    public func resolveMetadataOrphan(
        xmpPath: String,
        action: MetadataOrphanAction
    ) async throws -> [MetadataOrphan] {
        let response = try await NativeCommandClient(router: router).executeAsync(
            "metadata.resolve_orphan",
            params: [
                "xmpPath": .string(xmpPath),
                "action": .string(action.rawValue),
                "confirmed": .bool(true),
            ]
        )
        return try response.decoded(as: [MetadataOrphan].self)
    }
}

/// 全局图库视图模型：跨工作区照片浏览（filter.photos_global 分页 + 防抖）。
@MainActor
@Observable
public final class LibraryViewModel {
    /// 首屏加载阶段。
    public enum LoadPhase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// TS: PAGE_SIZE = 60。
    public static let pageSize = 60

    private let provider: LibraryDataProvider
    private let debounceDelay: Duration
    private var debounceTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var committed: LibraryFilterState = LibraryFilterState()
    /// 当前已提交的 criteriaKey（TS criteriaKey = JSON.stringify(criteria)）。
    private var criteriaKey = ""

    private(set) public var phase: LoadPhase = .loading
    private(set) public var sessions: [SessionData] = []
    private(set) public var photos: [GlobalPhotoResult] = []
    private(set) public var total = 0
    private(set) public var page = 0
    private(set) public var isFetching = false
    private(set) public var actionError: String?
    private(set) public var albums: [SmartAlbumData] = []
    private(set) public var assetCandidates: [AssetLinkCandidateData] = []
    private(set) public var metadataOrphans: [MetadataOrphan] = []
    private(set) public var assetVolumes: [AssetVolumeData] = []
    private(set) public var isSupportBusy = false
    /// 筛选表单（视图双向绑定；字段变更须经 onFilterChanged 提交）。
    public var filter = LibraryFilterState()
    /// 选中工作区（'' = 全部工作区，对齐 TS sessionFilter）。
    public var sessionFilter = ""
    /// 选中智能相册；nil 表示全部照片（TS selectedAlbum）。
    private(set) public var selectedAlbumId: String?

    /// debounceDelay 测试可注入（默认 300ms，对齐 TS useDebouncedValue）。
    public init(provider: LibraryDataProvider, debounceDelay: Duration = .milliseconds(300)) {
        self.provider = provider
        self.debounceDelay = debounceDelay
    }

    // MARK: 加载

    func load() async {
        phase = .loading
        await reloadSessions()
        await reloadSupport()
        await reload()
    }

    func reloadSessions() async {
        do {
            sessions = try await provider.listSessions()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// 加载 Library 页面除照片分页外的三组支持数据。
    /// 任一组失败不会阻塞图库主查询，但会保留可见错误，避免静默降级。
    public func reloadSupport() async {
        do { albums = try await provider.listAlbums() }
        catch { actionError = Self.message(for: error) }
        do { assetCandidates = try await provider.listAssetCandidates() }
        catch { actionError = Self.message(for: error) }
        do { metadataOrphans = try await provider.listMetadataOrphans() }
        catch { actionError = Self.message(for: error) }
        do { assetVolumes = try await provider.listAssetVolumes() }
        catch { actionError = Self.message(for: error) }
    }

    /// 智能相册选择沿用 TS 的页码归零和 query key 语义。
    public func selectAlbum(_ albumId: String?) {
        guard selectedAlbumId != albumId else { return }
        selectedAlbumId = albumId
        page = 0
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(0, isFirst: true)
        }
    }

    public func createAlbum(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await performSupportMutation {
            _ = try await self.provider.createAlbum(
                name: trimmed,
                criteria: buildLibraryCriteria(self.committed)
            )
            self.albums = try await self.provider.listAlbums()
        }
    }

    public func updateSelectedAlbum() async {
        guard let albumId = selectedAlbumId else { return }
        await performSupportMutation {
            try await self.provider.updateAlbum(
                albumId: albumId,
                criteria: buildLibraryCriteria(self.committed)
            )
            self.albums = try await self.provider.listAlbums()
            await self.reload()
        }
    }

    public func deleteSelectedAlbum() async {
        guard let albumId = selectedAlbumId else { return }
        await performSupportMutation {
            try await self.provider.deleteAlbum(albumId: albumId)
            self.selectedAlbumId = nil
            self.albums = try await self.provider.listAlbums()
            await self.reload()
        }
    }

    public func updateCandidate(_ candidate: AssetLinkCandidateData, accept: Bool) async {
        await performSupportMutation {
            try await self.provider.updateAssetCandidate(candidateId: candidate.id, accept: accept)
            self.assetCandidates = try await self.provider.listAssetCandidates()
            self.assetVolumes = try await self.provider.listAssetVolumes()
            await self.reload()
        }
    }

    public func resolveOrphan(_ orphan: MetadataOrphan, action: MetadataOrphanAction) async {
        await performSupportMutation {
            self.metadataOrphans = try await self.provider.resolveMetadataOrphan(
                xmpPath: orphan.xmpPath,
                action: action
            )
        }
    }

    /// 让用户选择新根目录后执行受确认保护的 relink_root。
    public func relinkVolume(root oldRoot: String) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = GatherLocalization.l("选择新目录")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await performSupportMutation {
            _ = try await self.provider.relinkAssetRoot(oldRoot: oldRoot, newRoot: url.path)
            self.assetVolumes = try await self.provider.listAssetVolumes()
            await self.reload()
        }
    }

    private func performSupportMutation(_ operation: @escaping () async throws -> Void) async {
        guard !isSupportBusy else { return }
        isSupportBusy = true
        defer { isSupportBusy = false }
        do {
            try await operation()
            actionError = nil
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// 按当前已提交筛选取第一页（offset 0）。
    private func reload() async {
        await fetchPage(0, isFirst: true)
    }

    // MARK: 筛选提交（TS useDebouncedValue + criteriaKey 联动）

    /// 任一筛选字段变更后调用：四个自由文本字段 300ms 防抖，其余立即提交。
    /// 提交后 criteriaKey 变化 → 页码归零并重新取数（TS useEffect setPage(0)）。
    public func onFilterChanged() {
        let debouncedTouched = LibraryFilterState.debouncedFields.contains {
            filter[keyPath: $0] != committed[keyPath: $0]
        }
        if debouncedTouched {
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: self?.debounceDelay ?? .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.commitFilter()
            }
        } else {
            debounceTask?.cancel()
            commitFilter()
        }
    }

    /// 会话筛选变更（TS select onChange → 立即生效 + 页码归零）。
    public func onSessionFilterChanged() {
        commitFilter()
    }

    public func clearFilters() {
        filter = LibraryFilterState()
        sessionFilter = ""
        debounceTask?.cancel()
        commitFilter()
    }

    /// TS: activeFilterCount / advancedFilterCount（trim 后非空的字段数）。
    public var activeFilterCount: Int {
        let values: [String] = [
            filter.search, filter.rating, filter.label, filter.status,
            filter.keyword, filter.directory, filter.volume, filter.person,
            filter.duplicates, filter.recentDays,
        ]
        return values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    public var advancedFilterCount: Int {
        let values: [String] = [
            filter.keyword, filter.directory, filter.volume, filter.person,
            filter.duplicates, filter.recentDays,
        ]
        return values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private func commitFilter() {
        let newKey = Self.criteriaKey(filter: filter, sessionFilter: sessionFilter)
        committed = filter
        guard newKey != criteriaKey else { return }
        criteriaKey = newKey
        page = 0
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(0, isFirst: true)
        }
    }

    /// TS: criteriaKey = JSON.stringify(criteria)（会话筛选并入键，保证页码归零）。
    static func criteriaKey(filter: LibraryFilterState, sessionFilter: String) -> String {
        let criteria = buildLibraryCriteria(filter)
        let encoded = (try? JSONEncoder().encode(criteria)) ?? Data()
        return "\(sessionFilter)|\(String(data: encoded, encoding: .utf8) ?? "")"
    }

    // MARK: 分页（TS prevPage/nextPage + toolbar range 语义）

    public func nextPage() {
        goToPage(page + 1)
    }

    public func prevPage() {
        goToPage(max(0, page - 1))
    }

    public func goToPage(_ target: Int) {
        // TS 分页边界：下一页按钮在 (page+1)*PAGE >= total 时禁用。
        let maxPage = max(0, Int(ceil(Double(total) / Double(Self.pageSize))) - 1)
        guard target >= 0, target <= maxPage, target != page else { return }
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(target, isFirst: false)
        }
    }

    public var hasNextPage: Bool {
        (page + 1) * Self.pageSize < total
    }

    /// TS: toolbar range —— 第 min(page*PAGE+1, max(1,total)) – min((page+1)*PAGE, total) 张。
    /// total==0 时旧版输出「第 1–0 张」（start 下界 1）；此处把 start 下界改为 0，
    /// 统一输出「第 0–0 张」，其余分支与旧版逐字一致。
    public var rangeText: String {
        let start = min(page * Self.pageSize + 1, max(0, total))
        let end = min((page + 1) * Self.pageSize, total)
        return String(format: GatherLocalization.l("第 %lld–%lld 张"), start, end)
    }

    // MARK: 取数

    private func fetchPage(_ target: Int, isFirst: Bool) async {
        isFetching = true
        defer { isFetching = false }
        do {
            let result: (photos: [GlobalPhotoResult], total: Int)
            if let selectedAlbumId {
                result = try await provider.albumPhotos(
                    albumId: selectedAlbumId,
                    limit: Self.pageSize,
                    offset: target * Self.pageSize
                )
            } else {
                result = try await provider.globalPhotos(
                    criteria: buildLibraryCriteria(committed),
                    sessionId: sessionFilter.isEmpty ? nil : sessionFilter,
                    limit: Self.pageSize,
                    offset: target * Self.pageSize
                )
            }
            photos = result.photos
            total = result.total
            page = target
            if phase == .loading { phase = .loaded }
        } catch {
            if photos.isEmpty && phase == .loading {
                phase = .failed(Self.message(for: error))
            } else {
                actionError = Self.message(for: error)
            }
        }
    }

    // MARK: 终态事件刷新（对齐 TS 事件失效语义）

    /// 终态事件驱动的按需刷新：任意终态事件重载支持数据（相册/关联候选/
    /// 孤立 XMP/离线卷）与当前页照片列表；500ms 合并连续终态帧，避免风暴。
    public func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshOnEvent()
        }
    }

    /// 就地刷新当前页（react-query invalidate 语义：不跳页、不闪 loading）。
    func refreshOnEvent() async {
        await reloadSupport()
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchPage(self.page, isFirst: false)
        }
    }

    // MARK: 错误 message（对齐 DashboardViewModel.message）

    static func message(for error: Error) -> String {
        if let sessionError = error as? SessionServiceError {
            return GatherLocalization.errorText(sessionError.gatherCode.rawValue)
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }
}
