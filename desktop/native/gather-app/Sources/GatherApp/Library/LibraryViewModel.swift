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
/// 真实路由（LiveLibraryDataProvider + 临时 SQLite）。
/// Swift 6 迁移：协议继承 Sendable（Live 实现仅持有不可变 router，命令客户端
/// 无状态只在调用点构造），使 @MainActor ViewModel 可在 async 调用中安全地把
/// provider existential 送出当前隔离域。
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

    /// TS: metadataApi.orphans / resolveOrphan。
    func listMetadataOrphans() throws -> [MetadataOrphan]
    /// .restore 会用备份覆盖照片文件（不可撤销）：confirmed 同上。
    func resolveMetadataOrphan(
        xmpPath: String,
        action: MetadataOrphanAction,
        confirmed: Bool
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
        throw NativeCommandError.failed("ALBUM_NOT_SUPPORTED")
    }

    func updateAlbum(albumId: String, criteria: FilterGroup) throws {
        throw NativeCommandError.failed("ALBUM_NOT_SUPPORTED")
    }

    func deleteAlbum(albumId: String, confirmed: Bool) throws {
        throw NativeCommandError.failed("ALBUM_NOT_SUPPORTED")
    }

    func listAssetCandidates() throws -> [AssetLinkCandidateData] { [] }

    func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) throws {
        throw NativeCommandError.failed("ASSET_LINK_NOT_SUPPORTED")
    }

    func listAssetVolumes() throws -> [AssetVolumeData] { [] }

    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) throws -> Int {
        throw NativeCommandError.failed("ASSET_RELINK_NOT_SUPPORTED")
    }

    func listMetadataOrphans() throws -> [MetadataOrphan] { [] }

    func resolveMetadataOrphan(
        xmpPath: String,
        action: MetadataOrphanAction,
        confirmed: Bool
    ) async throws -> [MetadataOrphan] {
        throw NativeCommandError.failed("METADATA_ORPHAN_NOT_SUPPORTED")
    }
}

/// 真实实现：同进程直连 SessionCommandRouter（photo.list_page 等装配形状
/// 以路由为唯一事实源，避免复制资产装配逻辑）。
/// Swift 6 迁移：本类经协议继承 Sendable —— 唯一存储属性 router 为不可变
/// （SessionCommandRouter 全 let 不可变）。命令客户端 NativeCommandClient 无
/// 状态，改为在调用点构造，避免再存一个非 Sendable 的引用。
public final class LiveLibraryDataProvider: LibraryDataProvider {
    private let router: SessionCommandRouter

    public init(router: SessionCommandRouter) {
        self.router = router
    }

    public func listSessions() throws -> [SessionData] {
        try router.sessionService.listSessions()
    }

    public func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let response = try await NativeCommandClient(router: router).executeAsync("filter.photos_global", params: [
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

    public func listAlbums() throws -> [SmartAlbumData] {
        let response = try router.execute("album.list", params: [:])
        return try response.decoded(as: [SmartAlbumData].self)
    }

    public func albumPhotos(
        albumId: String,
        limit: Int,
        offset: Int
    ) async throws -> (photos: [GlobalPhotoResult], total: Int) {
        let response = try await NativeCommandClient(router: router).executeAsync("album.get_photos", params: [
            "albumId": .string(albumId),
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset)),
        ])
        let object = response.objectValue ?? [:]
        let photos: [GlobalPhotoResult] = try (object["photos"] ?? .array([])).decoded(as: [GlobalPhotoResult].self)
        let total = Int(object["total"]?.numberValue ?? 0)
        return (photos, total)
    }

    public func createAlbum(name: String, criteria: FilterGroup) throws -> SmartAlbumData {
        let response = try router.execute("album.create", params: [
            "name": .string(name),
            "criteria": try JSONValue(from: criteria),
        ])
        return try response.decoded(as: SmartAlbumData.self)
    }

    public func updateAlbum(albumId: String, criteria: FilterGroup) throws {
        _ = try router.execute("album.update", params: [
            "albumId": .string(albumId),
            "criteria": try JSONValue(from: criteria),
        ])
    }

    public func deleteAlbum(albumId: String, confirmed: Bool) throws {
        _ = try router.execute("album.delete", params: [
            "albumId": .string(albumId),
            "confirmed": .bool(confirmed),
        ])
    }

    public func listAssetCandidates() throws -> [AssetLinkCandidateData] {
        let response = try router.execute("assets.candidates", params: [:])
        return try response.decoded(as: [AssetLinkCandidateData].self)
    }

    public func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) throws {
        _ = try router.execute(
            accept ? "assets.accept_candidate" : "assets.reject_candidate",
            params: [
                "candidateId": .string(candidateId),
                "confirmed": .bool(confirmed),
            ]
        )
    }

    public func listAssetVolumes() throws -> [AssetVolumeData] {
        let response = try router.execute("assets.volumes", params: [:])
        return try response.decoded(as: [AssetVolumeData].self)
    }

    public func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) throws -> Int {
        let response = try router.execute("assets.relink_root", params: [
            "oldRoot": .string(oldRoot),
            "newRoot": .string(newRoot),
            "confirmed": .bool(confirmed),
        ])
        return Int(response.numberValue ?? 0)
    }

    public func listMetadataOrphans() throws -> [MetadataOrphan] {
        let response = try router.execute("metadata.orphans", params: [:])
        return try response.decoded(as: [MetadataOrphan].self)
    }

    public func resolveMetadataOrphan(
        xmpPath: String,
        action: MetadataOrphanAction,
        confirmed: Bool
    ) async throws -> [MetadataOrphan] {
        let response = try await NativeCommandClient(router: router).executeAsync(
            "metadata.resolve_orphan",
            params: [
                "xmpPath": .string(xmpPath),
                "action": .string(action.rawValue),
                "confirmed": .bool(confirmed),
            ]
        )
        return try response.decoded(as: [MetadataOrphan].self)
    }
}

/// 全局图库视图模型：跨工作区照片浏览（filter.photos_global 分页 + 防抖）。
@MainActor
@Observable
public final class LibraryViewModel {
    /// TS: PAGE_SIZE = 60。
    public static let pageSize = 60

    private let provider: LibraryDataProvider
    private let debounceDelay: Duration
    private var debounceTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    /// 数据代数（D06）：筛选/相册/会话条件变化即递增，在途响应返回后代数不符就整份
    /// 作废。旧实现依赖 `fetchTask?.cancel()`，而 NativeCommandClient 的 continuation
    /// 请求无法被真正取消——慢的旧请求会覆盖新筛选的结果。
    private var fetchGeneration = 0
    /// 同代内的请求序号（P2-7）：最新请求胜出，旧响应不得回退用户翻页。
    private var requestSequence = 0
    private var latestRequestID = 0
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
        reloadSupport()
        await reload()
    }

    func reloadSessions() async {
        do {
            sessions = try provider.listSessions()
        } catch {
            actionError = Self.message(for: error)
        }
    }

    /// 加载 Library 页面除照片分页外的三组支持数据。
    /// 任一组失败不会阻塞图库主查询，但会保留可见错误，避免静默降级。
    public func reloadSupport() {
        do { albums = try provider.listAlbums() }
        catch { actionError = Self.message(for: error) }
        do { assetCandidates = try provider.listAssetCandidates() }
        catch { actionError = Self.message(for: error) }
        do { metadataOrphans = try provider.listMetadataOrphans() }
        catch { actionError = Self.message(for: error) }
        do { assetVolumes = try provider.listAssetVolumes() }
        catch { actionError = Self.message(for: error) }
    }

    /// 智能相册选择沿用 TS 的页码归零和 query key 语义。
    public func selectAlbum(_ albumId: String?) {
        guard selectedAlbumId != albumId else { return }
        selectedAlbumId = albumId
        page = 0
        // D06：相册与筛选共用同一个写入入口，条件变化同样要作废在途响应。
        fetchGeneration += 1
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchPage(0, isFirst: true)
        }
    }

    public func createAlbum(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await performSupportMutation {
            _ = try self.provider.createAlbum(
                name: trimmed,
                criteria: buildLibraryCriteria(self.committed)
            )
            self.albums = try self.provider.listAlbums()
            Self.postLibraryChange()
        }
    }

    public func updateSelectedAlbum() async {
        guard let albumId = selectedAlbumId else { return }
        await performSupportMutation {
            try self.provider.updateAlbum(
                albumId: albumId,
                criteria: buildLibraryCriteria(self.committed)
            )
            self.albums = try self.provider.listAlbums()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 删除智能相册（破坏性：删除相册规则本身，不删除照片文件）。
    /// confirmed 由视图确认弹窗注入：true 只能从确认分支到达（见 LibraryView
    /// 的 pendingDeleteAlbum + gatherDestructiveConfirm）。
    public func deleteAlbum(id: String, confirmed: Bool) async {
        await performSupportMutation {
            try self.provider.deleteAlbum(albumId: id, confirmed: confirmed)
            if self.selectedAlbumId == id { self.selectedAlbumId = nil }
            self.albums = try self.provider.listAlbums()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 关联候选决策（accept = 合并为一个资产；reject = 拒绝/拆分）。
    /// 两者都在命令层受 confirmed 门控，故同样由确认动作注入。
    public func updateCandidate(
        _ candidate: AssetLinkCandidateData,
        accept: Bool,
        confirmed: Bool
    ) async {
        await performSupportMutation {
            try self.provider.updateAssetCandidate(
                candidateId: candidate.id,
                accept: accept,
                confirmed: confirmed
            )
            self.assetCandidates = try self.provider.listAssetCandidates()
            self.assetVolumes = try self.provider.listAssetVolumes()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 孤立 XMP 处置。restore（恢复原片）会用备份覆盖照片文件、不可撤销 →
    /// 必须来自确认弹窗；retry/keep 是可逆决策，按下的按钮本身就是用户决定。
    public func resolveOrphan(
        _ orphan: MetadataOrphan,
        action: MetadataOrphanAction,
        confirmed: Bool
    ) async {
        await performSupportMutation {
            self.metadataOrphans = try await self.provider.resolveMetadataOrphan(
                xmpPath: orphan.xmpPath,
                action: action,
                confirmed: confirmed
            )
            Self.postMetadataChange()
        }
    }

    /// 只负责让用户选新根目录并返回结果，**不发命令**：调用方拿到新旧根后再弹
    /// 确认（确认文案需要同时写清 oldRoot → newRoot 与影响范围）。
    public func chooseRelinkRoot() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = GatherLocalization.l("选择新目录")
        // 第三轮审计 F：runModal 会阻塞主线程并开嵌套 runloop（同库其它面板
        // 早已改成 begin）。这里用 async 版本，等待期间界面保持响应。
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// 重新关联存储卷根（破坏性：改写该根下全部文件的路径记录）。
    public func relinkVolume(root oldRoot: String, newRoot: String, confirmed: Bool) async {
        await performSupportMutation {
            _ = try self.provider.relinkAssetRoot(
                oldRoot: oldRoot,
                newRoot: newRoot,
                confirmed: confirmed
            )
            self.assetVolumes = try self.provider.listAssetVolumes()
            Self.postLibraryChange()
            await self.reload()
        }
    }

    /// 本页发出的事件标识：监听方据此跳过自己触发的刷新（避免自触发重查）。
    public static let changeOrigin = "library"

    /// 库级写成功后的广播（相册/资产/离线卷）：常驻页按域刷新自己的数据。
    private static func postLibraryChange() {
        GatherEventCenter.postDomainChange(.library, sessionId: nil, origin: Self.changeOrigin)
    }

    /// 元数据写成功后的广播（孤立 XMP 处置等 XMP 写回族）。
    private static func postMetadataChange() {
        GatherEventCenter.postDomainChange(.metadata, sessionId: nil, origin: Self.changeOrigin)
    }

    /// 用户取消破坏性操作：写可见文案（不静默 return），且**不发任何命令**。
    public func reportActionCancelled() {
        actionError = GatherLocalization.l("已取消：未执行任何破坏性操作。")
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
        // D06：查询条件变化 → 在途响应作废（相册切换/事件刷新同理）。
        fetchGeneration += 1
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
        // D06：请求绑定数据代数。旧实现只 `fetchTask?.cancel()`——NativeCommandClient
        // 的 continuation 请求不会被真正取消，旧筛选（星级 1）的响应会在新筛选
        // （星级 5）之后返回并**无条件**覆盖 photos/total/page，界面筛选值是 5、
        // 计数却是 1 的结果。
        let generation = fetchGeneration
        // P2-7（审计 2）：同代内也要防乱序——goToPage 与事件刷新/load 并发时，
        // 旧请求返回会把用户刚翻到的页**静默回退**。用请求序号做「最新请求胜出」，
        // isFetching 也只由最新请求负责收尾（旧请求完成不得提前关掉新请求的指示器）。
        requestSequence += 1
        let requestID = requestSequence
        latestRequestID = requestID
        isFetching = true
        defer { if requestID == latestRequestID { isFetching = false } }
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
            guard generation == fetchGeneration, requestID == latestRequestID else { return }
            photos = result.photos
            total = result.total
            page = target
            if phase == .loading { phase = .loaded }
            actionError = nil
        } catch {
            guard generation == fetchGeneration, requestID == latestRequestID else { return }
            if photos.isEmpty && phase == .loading {
                phase = .failed(Self.message(for: error))
            } else {
                // P2-7：有旧数据时刷新失败必须回到 loaded——旧实现把 phase 留在
                // .loading，页面永久大 spinner，工具栏刷新按钮又因 phase == .loading
                // 被禁用，用户只能靠改筛选/等事件自愈。
                if phase == .loading { phase = .loaded }
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
        reloadSupport()
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchPage(self.page, isFirst: false)
        }
    }

    // MARK: 错误 message（对齐 DashboardViewModel.message）

    /// 用户可见文案的**唯一漏斗**：错误码 → 本地化模板；其余原始诊断只进
    /// 日志，界面回退通用文案（审查 P3：不得把非错误码诊断直显给用户）。
    static func message(for error: Error) -> String {
        if let sessionError = error as? SessionServiceError {
            return GatherLocalization.errorText(sessionError.gatherCode.rawValue)
        }
        if let routerError = error as? RouterCommandError {
            return userFacingText(for: routerError.message)
        }
        if let nativeError = error as? NativeCommandError {
            return userFacingText(for: nativeError.description)
        }
        if let bridgeError = error as? BridgeError {
            return userFacingText(for: bridgeError.description)
        }
        let nsError = error as NSError
        let raw = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
        return userFacingText(for: raw)
    }

    /// 错误码（全大写 ASCII + _ . : -）→ errorText 表；其它一律记日志 + 通用文案。
    static func userFacingText(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return GatherLocalization.l("发生未知错误，请稍后重试") }
        let code = trimmed.components(separatedBy: "::")[0]
        let looksLikeCode = !code.isEmpty
            && code.allSatisfy { $0.isUppercase || $0.isNumber || "_.:-".contains($0) }
        // 码形门槛只认大写 ASCII：Core 侧「已知码: 参数」（如
        // XMP_CONFIRM_OTHER_SESSION_PENDING: s1）会被误判成散文而丢掉 {{param}}
        // 插值，故补一条「首冒号前段命中错误表」的判定（与 errorText 同构）。
        // 未知码/散文仍不猜（负例见 LibraryViewModelTests 的两个参数化用例）。
        let parameterizedCode = GatherLocalization.isParameterizedErrorCode(trimmed)
        guard looksLikeCode || parameterizedCode else {
            GatherLogger.log("library error is not an error code: \(trimmed)", level: .warn)
            return GatherLocalization.l("发生未知错误，请稍后重试")
        }
        let generic = GatherLocalization.l("发生未知错误，请稍后重试")
        let text = GatherLocalization.errorText(trimmed)
        if text == generic {
            GatherLogger.log("library error code not mapped: \(trimmed)", level: .warn)
        }
        return text
    }
}
