// desktop/native/gather-app/Sources/GatherApp/Library/LibraryViewModel.swift
// Phase 3.2 Library（全局图库）：视图模型（服务可注入，同进程直连路由）。
// TS 源: desktop/src/renderer/pages/Library/index.tsx（buildCriteria / PAGE_SIZE /
//       useDebouncedValue / 分页 offset 语义）
//       + api/filter.ts photosGlobal（filter.photos_global 形状）
//
// 差异说明（有意）：
// - TS 的 react-query 缓存 + criteriaKey/page 联动 → 显式防抖提交
//   （search/keyword/directory/person 四个自由文本字段 300ms，其余字段立即）；
// - 智能相册（album.* 未接线）与资产关联/离线卷侧栏（assets.* 未接线）不展示；
// - 分页为 offset 形态（filter.photos_global 的 limit/offset 钳制在路由内）。
import Foundation
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
    func listSessions() throws -> [SessionData]
    /// TS: filterApi.photosGlobal → { photos, total }。
    func globalPhotos(
        criteria: FilterGroup,
        sessionId: String?,
        limit: Int,
        offset: Int
    ) throws -> (photos: [GlobalPhotoResult], total: Int)
}

/// 真实实现：同进程直连 SessionCommandRouter（photo.list_page 等装配形状
/// 以路由为唯一事实源，避免复制资产装配逻辑）。
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
    ) throws -> (photos: [GlobalPhotoResult], total: Int) {
        let response = try router.execute("filter.photos_global", params: [
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
    /// 筛选表单（视图双向绑定；字段变更须经 onFilterChanged 提交）。
    public var filter = LibraryFilterState()
    /// 选中工作区（'' = 全部工作区，对齐 TS sessionFilter）。
    public var sessionFilter = ""

    /// debounceDelay 测试可注入（默认 300ms，对齐 TS useDebouncedValue）。
    public init(provider: LibraryDataProvider, debounceDelay: Duration = .milliseconds(300)) {
        self.provider = provider
        self.debounceDelay = debounceDelay
    }

    // MARK: 加载

    func load() async {
        phase = .loading
        await reloadSessions()
        await reload()
    }

    func reloadSessions() async {
        do {
            sessions = try provider.listSessions()
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
    public var rangeText: String {
        guard total > 0 else { return "第 0–0 张" }
        let start = min(page * Self.pageSize + 1, max(1, total))
        let end = min((page + 1) * Self.pageSize, total)
        return "第 \(start)–\(end) 张"
    }

    // MARK: 取数

    private func fetchPage(_ target: Int, isFirst: Bool) async {
        isFetching = true
        defer { isFetching = false }
        do {
            let result = try provider.globalPhotos(
                criteria: buildLibraryCriteria(committed),
                sessionId: sessionFilter.isEmpty ? nil : sessionFilter,
                limit: Self.pageSize,
                offset: target * Self.pageSize
            )
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

    // MARK: 错误 message（对齐 DashboardViewModel.message）

    static func message(for error: Error) -> String {
        if let sessionError = error as? SessionServiceError {
            return sessionError.gatherCode.rawValue
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
    }
}
