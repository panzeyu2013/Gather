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
    // P1 / C：facet 维（单值选择；空串 = 不限）
    public var camera = ""
    public var lens = ""
    public var iso = ""
    public var year = ""
    /// P1 / C：规则编辑器的高级条件（AND/OR + between/in）。空组 = 不参与筛选。
    public var rules = FilterGroup(logic: .and, conditions: [])

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
        // P1 / C：多字段搜索——文件名 / 标题 / 说明 / 关键词任意命中即可。
        // 必须是 OR 子组：并进外层 AND 会要求"文件名也命中"，等于没扩。
        // title/description 经 FilterEngine 的 jsonFields 映射到 iptc_json。
        conditions.append(.group(FilterGroup(logic: .or, conditions: [
            .rule(FilterRule(field: "filename", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "title", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "description", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "headline", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "creator", operator: .containsAny, value: .array([.string(search)]))),
            .rule(FilterRule(field: "copyright", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "city", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "country", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "location", operator: .contains, value: .string(search))),
            .rule(FilterRule(field: "keywords", operator: .contains, value: .string(search))),
        ])))
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
    // P1 / C：规则编辑器的高级条件（逻辑由 rules.logic 决定）。
    if !state.rules.conditions.isEmpty {
        conditions.append(.group(state.rules))
    }

    // P1 / C：facet 维 —— 与 FacetQuery 的维度与字段一一对应。
    let camera = state.camera.trimmingCharacters(in: .whitespaces)
    if !camera.isEmpty { add("camera_model", .eq, .string(camera)) }
    let lens = state.lens.trimmingCharacters(in: .whitespaces)
    if !lens.isEmpty { add("lens_model", .eq, .string(lens)) }
    if let iso = Int(state.iso) { add("iso", .eq, .number(Double(iso))) }
    let year = state.year.trimmingCharacters(in: .whitespaces)
    if !year.isEmpty { add("date_taken", .startsWith, .string(year)) }

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
/// GatherHost 的 async 数据适配器（临时 SQLite + typed API）。
/// Swift 6 迁移：协议继承 Sendable（Live 实现只持有不可变的各域 API），使
/// @MainActor ViewModel 可在 async 调用中安全地把 provider existential 送出。
/// WP4b：端口全面 async；同步核 / 同步端口 / SyncAPIPortBridge 已删除，
/// 生产实现移到 GatherHost。
public protocol LibraryDataProvider: Sendable {
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
    /// 破坏性：confirmed 必须由视图的确认动作注入，**不设默认值**——
    /// 编译期强制每个调用点说明它拿到的是用户确认还是取消。
    func deleteAlbum(albumId: String, confirmed: Bool) async throws

    /// TS: assetApi.candidates / acceptCandidate / rejectCandidate / volumes / relinkRoot。
    func listAssetCandidates() async throws -> [AssetLinkCandidateData]
    /// 破坏性（合并/拆分会改变资产结构）：confirmed 同上。
    func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) async throws
    func listAssetVolumes() async throws -> [AssetVolumeData]
    /// P1 / C：facet 计数（每维已排除自身条件）。sessionId == nil 表示全库。
    func facets(
        criteria: FilterGroup,
        sessionId: String?,
        dimensions: [String],
        limit: Int
    ) async throws -> [PhotoFacetGroup]
    /// 破坏性（改写该根下全部路径记录）：confirmed 同上。
    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) async throws -> Int

    /// TS: metadataApi.orphans / resolveOrphan（B6b 起走 MetadataAPI）。
    func listMetadataOrphans() async throws -> [MetadataOrphan]
    /// .restore 会用备份覆盖照片文件（不可撤销）：只接收 Confirmed<T>，
    /// 确认来源由 UI 的确认弹窗决定（D-011）。
    func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
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
        throw APIError.failed("ALBUM_NOT_SUPPORTED")
    }

    func updateAlbum(albumId: String, criteria: FilterGroup) async throws {
        throw APIError.failed("ALBUM_NOT_SUPPORTED")
    }

    func deleteAlbum(albumId: String, confirmed: Bool) async throws {
        throw APIError.failed("ALBUM_NOT_SUPPORTED")
    }

    func listAssetCandidates() async throws -> [AssetLinkCandidateData] { [] }

    func updateAssetCandidate(candidateId: String, accept: Bool, confirmed: Bool) async throws {
        throw APIError.failed("ASSET_LINK_NOT_SUPPORTED")
    }

    func listAssetVolumes() async throws -> [AssetVolumeData] { [] }

    /// P1 / C：stub 默认无 facet（面板隐藏）。
    func facets(
        criteria: FilterGroup,
        sessionId: String?,
        dimensions: [String],
        limit: Int
    ) async throws -> [PhotoFacetGroup] { [] }

    func relinkAssetRoot(oldRoot: String, newRoot: String, confirmed: Bool) async throws -> Int {
        throw APIError.failed("ASSET_RELINK_NOT_SUPPORTED")
    }

    func listMetadataOrphans() async throws -> [MetadataOrphan] { [] }

    func resolveMetadataOrphan(
        _ input: Confirmed<MetadataResolveOrphanInput>
    ) async throws -> [MetadataOrphan] {
        throw APIError.failed("METADATA_ORPHAN_NOT_SUPPORTED")
    }
}

/// 真实实现已移到 GatherHost：UI 只保留 async 数据端口，
/// 不再 import 任何 Live API 实现，也不再有同步核/同步端口。
///
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

    // MARK: - P1 / C：facet

    /// 各维计数（相机/镜头/ISO/年份/色标）；空 = 未加载或库为空。
    var facets: [PhotoFacetGroup] = []
    /// 每维最多展示的桶数（避免面板被长尾撑爆）。
    static let facetLimit = 40

    /// 重新计算 facet：基于**已提交**的筛选（与网格一致），不是正在编辑的草稿。
    func refreshFacets() async {
        let criteria = buildLibraryCriteria(committed)
        do {
            facets = try await provider.facets(
                criteria: criteria,
                sessionId: sessionFilter.isEmpty ? nil : sessionFilter,
                dimensions: ["camera", "lens", "iso", "year", "label"],
                limit: Self.facetLimit
            )
            actionError = nil
        } catch {
            facets = []
            actionError = CommandError(error)
        }
    }
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
