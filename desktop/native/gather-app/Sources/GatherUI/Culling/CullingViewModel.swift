// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel.swift
// Cut 4 / 4c-2a：从 CullingView.swift 第 83-538 行移出（VM 主体/状态/生命周期/同步状态机）。
// 拆分口径：状态与生命周期留本文件；整页加载 -> +Load，导航 -> +Navigation，
// 挑片决策/历史 -> +Actions，写回/同步/冲突 -> +Writeback。
//
// 跨文件 extension 只能访问 internal 成员：原 `private` 依赖/可写状态改为 internal
// （`public internal(set)` 保留只读对外语义），行为与访问路径不变。
import Foundation
import Observation
import SwiftUI
import GatherProtocol


@MainActor
@Observable
public final class CullingViewModel: SessionPageModel {
    /// 组合筛选状态：对齐 TS CullingFilters + FilterControls（Culling.tsx:1720-1817）——
    /// 未审/状态/星级/颜色/质量/冲突 六个维度可任意叠加，全部关闭即"全部"。


    /// 同步状态机（对齐旧版 c1-sync-controls.ts C1SyncState 语义，从
    /// MetadataSyncSummary 推导）：syncing=正在写入、c1Read=已写入待 C1 确认、
    /// safeToCleanup=全部行终态（synced>0）、synced=无行。

    // Cut 1 / B3b：挑片域依赖（19 条 culling.* 命令 / 17 个方法）。
    let cullingAPI: any CullingAPI
    // Cut 1 / B3b：navigation.* 已迁移到 NavigationAPI。
    let navigationAPI: any NavigationAPI
    // Cut 1 / B6b：元数据冲突走类型化 API（conflicts / resolve_conflict）。
    let metadataAPI: any MetadataAPI
    /// P0/K0：关键词自动补全（会话级 suggestions）；预览/写入仍走 metadataAPI。
    let photoAPI: (any PhotoAPI)?
    // Cut 1 / B8.2b：质量分析建任务与轮询/取消走类型化 API。
    let jobAPI: any JobAPI
    let qualityAPI: any QualityAPI
    /// Cut 3 / 3b-3（E-17）：只持 Protocol 能力面（CaptureOneBridging）。
    let captureOne: any CaptureOneBridging
    public let sessionId: String
    /// 页内容。`didSet` 完成两件事（perf-ui task-22）：
    /// 1. `pageAssignmentCount` 自增——**任何赋值路径**（含扩展/测试 internal 赋值、
    ///    不 bump pageVersion 的直接赋值）都能让 `currentAsset` 索引走一次惰性校验；
    /// 2. `selectionSummaryCache = nil`——state 变化会影响摘要（必须失效）。
    ///
    /// 位置索引**不再盲目清空**：决策回显用同 id 序列的新 page 替换（只改 state），
    /// 位置索引仍有效，由 `pageAssetIndex` 做 O(n) id 序列比较后复用（见下）。
    public internal(set) var page: CullingPage? {
        didSet {
            pageAssignmentCount &+= 1
            selectionSummaryCache = nil
            // 评审 R2-A14：关键词目标索引按 (selectionKey, pageVersion) 失效；存在
            // "直接赋值 page 但不 bump pageVersion" 的测试/未来路径，这里一并清空。
            keywordTargetIndexCache = nil
            if page == nil { pageAssetIndexCache = nil }
        }
    }
    public internal(set) var summary: CullingSummary?
    public internal(set) var syncStatus: MetadataSyncSummary?
    public internal(set) var history: [CullingHistoryOperation] = []
    public internal(set) var conflicts: [MetadataConflict] = []
    public internal(set) var isLoading = false
    private(set) public var isQualityBusy = false
    private(set) public var qualityJob: AnalysisJobData?
    /// P0/T0：初筛生成/应用忙碌与最近一次错误（卡片内展示，不进全局 banner）。
    public internal(set) var isTriageBusy = false
    public internal(set) var triageError: CommandError?
    /// P0/K0：关键词草稿（只影响当前选择集；切换选择时由面板重置）。
    public internal(set) var keywordAdded: [String] = []
    public internal(set) var keywordRemoved: [String] = []
    public internal(set) var keywordSuggestions: [String] = []
    /// 目标集关键词索引缓存（selection + pageVersion 失效），避免每帧 O(资产×词)。
    @ObservationIgnored var keywordTargetIndexCache: KeywordTargetIndex?
    /// 决策提交的串行链（L1 核心循环）：挑片是 2–3 拍/秒的工作流，并发提交会在
    /// 同一张照片上带着过期 `expectedRevision` 撞冲突。见 `commit(patch:shouldAdvance:)`。
    @ObservationIgnored var commitChain: Task<Void, Never>?
    /// P0-4 单槽 pending commit：加载/翻页期间按下的决策先登记在这里，加载结束
    /// 补执行最后一次（后到覆盖先到）。不再静默丢键（见 `commit(patch:shouldAdvance:)`）。
    var pendingCommit: PendingCullingCommit?
    /// 有排队未执行的按键：工作台忙碌角标据此显示「按键已排队」。
    var hasPendingCommit: Bool { pendingCommit != nil }
    /// 决策提交链正在执行（含排队等待）：工作台细进度条/角标据此显示。
    var isCommitting = false
    /// commit() 的 latest-wins 代数：只有最后一拍结束才复位 isCommitting。
    @ObservationIgnored var commitGeneration = 0
    /// 邻张预取任务（P0-4）：去抖后为当前照片 ±2 预热；切图/退出/隐藏时取消。
    @ObservationIgnored var preloadTask: Task<Void, Never>?
    /// 已向宿主发过预取命令的路径：同一页内不重复发（换页/关闭时清空）。
    @ObservationIgnored var hostPreloadedPaths: Set<String> = []
    /// 邻张预取去抖（毫秒）：连按 → 只在停顿后为最后一张调度（测试可调小）。
    var preloadDebounceMilliseconds = 120
    public internal(set) var isKeywordBusy = false
    public internal(set) var keywordError: CommandError?
    public internal(set) var keywordPreview: WritebackPreview?
    /// 预览对应的“选择 + 草稿”签名；apply 前必须仍一致（旧预览不能写到新照片）。
    var keywordPreviewSignature = ""
    public internal(set) var keywordResult: MetadataKeywordApplyResult?
    /// 续页失败后置位：网格底部据此显示重试入口（否则 sentinel 不再 onAppear）。
    public internal(set) var loadMoreFailed = false
    public internal(set) var errorMessage: CommandError?
    /// Cut 4 / 4b-2a：延迟提示文案（key/计数，渲染期解析；见 CullingNotice）。
    public internal(set) var notice: CullingNotice?
    /// 隐藏期间收到领域变更只登记，回可见再补刷（外壳约定：隐藏页不发命令）。
    private(set) public var pendingDomainRefresh = false
    /// 同步状态/辅助查询（groups/sync_status/history/conflicts）失败时记录，
    /// 用于 UI 提示"同步状态加载失败"（业务查询失败不阻断主列表）。
    public internal(set) var lastSyncError: CommandError?
    /// reloadMetadata() 成功后才置位（对齐旧版"reload 成功才写 durable ack"语义）；
    /// confirm 按钮需 ack + written 才可用（deriveSyncControls 保守策略）。
    public internal(set) var reloadAcked = false
    public var filterState = FilterState()

    /// P2-3：活跃筛选维度数（检查器与工具栏 chip 同一真相源）。
    /// task-22：旧实现每次读取构造 7 元素数组再 filter（检查器/工具栏每帧读）；
    /// 改为直接计数，零分配，结果不变。
    public var activeFilterCount: Int {
        var count = 0
        if filterState.unreviewedOnly { count += 1 }
        if filterState.pickState != nil { count += 1 }
        if filterState.rating != nil { count += 1 }
        if filterState.colorLabel != nil { count += 1 }
        if filterState.qualityStatus != nil { count += 1 }
        if filterState.metadataConflictOnly { count += 1 }
        if filterState.triageVerdicts?.isEmpty == false { count += 1 }
        return count
    }
    public var autoAdvance = true
    /// 审计 P1-并发：可见性门控——画质分析 500ms 轮询在页面离开
    /// （条件渲染销毁）后停止，避免隐藏期后台空转。
    ///
    /// Cut 4 / 4a-2b：唯一写入口是 `setVisible(_:)`（View 不再直接写），
    /// 字段本身保留（审计 §1.4 / 4a-2 验收）。
    /// WP4d：默认不可见（false）——首次挂载的 setPageVisible(true) 才恢复
    /// 轮询/补刷；重复 true 由 PageVisibility 契约幂等。
    public private(set) var isActive = false
    /// 关闭终态：shutdown() 之后 setVisible(true) 明确 no-op，轮询不得复活。
    /// 4a-2c：对外只读，供 SessionWorkspace.close 的扇出测试断言。
    public private(set) var isShutdown = false
    /// 画质分析 500ms 轮询任务（可随可见性启停；旧实现把循环内联在
    /// analyzeQuality 里，隐藏即永久退出）。
    private var qualityPollTask: Task<Void, Never>?
    /// 生产轮询间隔；测试可注入更短间隔，避免用 1.2s 负向窗口证明轮询已停。
    public static let defaultQualityPollIntervalMilliseconds = 500
    private let qualityPollIntervalMilliseconds: Int
    public internal(set) var currentPhotoId: String?
    /// `currentAsset` 的 O(1) 索引缓存（perf-ui task-10 / P0；task-22 增加复用）。
    ///
    /// 旧实现每次读取都线性扫 `page.assets.first(where:)`：CullingInspector 一帧
    /// 直接/间接读 ~18 次、CullingWorkbenchViewer 25 处、InfoBar/SecondDisplay 等
    /// 也读，页 500 张时每帧上万次 id 比较。
    ///
    /// task-22：缓存键从 `pageVersion` 换成 `pageAssignmentCount`（page.didSet 自增），
    /// 且 page 被**同 id 序列**替换（决策回显只改 state）时不再重建字典——只做一次
    /// O(n) id 序列比较（500 张约 1-2µs）后沿用位置索引；重排/换页才重建
    /// （500 张页实测约 84µs）。返回的资产始终从当前 page 现取，state 不会过期。
    @ObservationIgnored private var pageAssetIndexCache: PageAssetIndex?
    /// page 的赋值代数（didSet 自增；任何赋值路径都覆盖，包括不 bump pageVersion 的直接赋值）。
    /// 评审 round-2：+Preload.swift 的过期守卫要读它，故改 internal（与 navigationGroupsVersion 同口径）。
    @ObservationIgnored private(set) var pageAssignmentCount = 0

    /// 页内 photoId→下标索引（位置索引，而不是复制整页资产）。
    ///
    /// 取舍（Linux Swift 6.2 实测，500 张页、每帧 18 次读取，仅供参考）：
    /// - 旧实现 18 次 `first(where:)`：~20µs/帧；
    /// - `[photoId: CullingAsset]` 索引重建 + 18 次读取：~121µs（整页资产复制/释放主导）；
    /// - 位置索引重建 + 18 次读取：~77-84µs；
    /// - 同 id 序列替换（决策回显）只做 O(n) id 比较（~µs 级）；
    /// - 命中（同赋值代数）：~0.7µs/帧。
    private struct PageAssetIndex {
        var pageAssignmentCount: Int
        /// 建索引时的完整 id 序列（用于判断"只改 state"的同序列替换）。
        let orderedPhotoIDs: [String]
        /// 重复 photoId 保留**首个**（与旧实现 `first(where:)` 同义）。
        let assetIndexByPhotoID: [String: Int]
    }

    private var pageAssetIndex: PageAssetIndex {
        if let cached = pageAssetIndexCache, cached.pageAssignmentCount == pageAssignmentCount {
            return cached
        }
        if let cached = pageAssetIndexCache, pageAssetIDsMatch(cached.orderedPhotoIDs) {
            // state-only 替换（决策回显/同页刷新）：位置索引仍然有效，只更新代数。
            var reused = cached
            reused.pageAssignmentCount = pageAssignmentCount
            pageAssetIndexCache = reused
            return reused
        }
        let assets = page?.assets ?? []
        var byPhotoID: [String: Int] = [:]
        var orderedIDs: [String] = []
        byPhotoID.reserveCapacity(assets.count)
        orderedIDs.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            orderedIDs.append(asset.photo.id)
            // 重复 id 保留首个（与旧实现 `first(where:)` 同义）。
            if byPhotoID[asset.photo.id] == nil { byPhotoID[asset.photo.id] = index }
        }
        let index = PageAssetIndex(
            pageAssignmentCount: pageAssignmentCount,
            orderedPhotoIDs: orderedIDs,
            assetIndexByPhotoID: byPhotoID
        )
        pageAssetIndexCache = index
        return index
    }

    /// 当前 page 的 id 序列是否与缓存一致（O(n) 指针/字符串比较；只用于 page 赋值后的
    /// 一次校验，命中缓存时完全不调用）。
    private func pageAssetIDsMatch(_ cachedIDs: [String]) -> Bool {
        guard let page else { return cachedIDs.isEmpty }
        let assets = page.assets
        guard assets.count == cachedIDs.count else { return false }
        for index in assets.indices where assets[index].photo.id != cachedIDs[index] {
            return false
        }
        return true
    }

    /// 当前照片资产（O(1) 读取；语义与旧实现完全一致）：
    /// - currentPhotoId 为空 → page 首张；
    /// - currentPhotoId 不在当前页 → page 首张（旧实现 `?? page?.assets.first`）；
    /// - 页为空 → nil。
    public var currentAsset: CullingAsset? {
        let index = pageAssetIndex
        guard let page else { return nil }
        guard let currentPhotoId,
              let position = index.assetIndexByPhotoID[currentPhotoId],
              page.assets.indices.contains(position) else {
            return page.assets.first
        }
        return page.assets[position]
    }

    /// O(1)：photoId 在**当前页**的下标（nil = 无页/不在当前页；重复 id 取首个）。
    /// 语义等价于旧的 `page?.assets.firstIndex(where: { $0.photo.id == photoId })`。
    func pageIndex(ofPhotoId photoId: String) -> Int? {
        guard let page else { return nil }
        let index = pageAssetIndex
        guard let position = index.assetIndexByPhotoID[photoId],
              page.assets.indices.contains(position) else { return nil }
        return position
    }

    /// O(1)：按 photoId 取当前页资产（nil = 无页/不在当前页）。
    func pageAsset(forPhotoId photoId: String) -> CullingAsset? {
        guard let position = pageIndex(ofPhotoId: photoId) else { return nil }
        return page?.assets[position]
    }

    /// 当前页中属于指定相似组的成员（按页顺序）。
    ///
    /// task-22：inspector 的 currentGroupAssets 旧实现每次 body 都 filter 整页
    /// （组视图/相似组决策打开时每帧 O(page)）。缓存键 = page 赋值代数 + groupId：
    /// 选择/当前照片变化不重建；页被替换（含决策回显）才重算一次。
    @ObservationIgnored private var similarGroupAssetsCache: (assignment: Int, groupId: String, assets: [CullingAsset])?

    func similarGroupAssets(inCurrentPage groupId: String) -> [CullingAsset] {
        // 评审 R2-A1 同型防御：命中路径先无条件读 page，保留 Observation 依赖。
        _ = page?.assets.count
        if let cached = similarGroupAssetsCache,
           cached.assignment == pageAssignmentCount,
           cached.groupId == groupId {
            return cached.assets
        }
        let assets = page?.assets.filter { $0.similarityGroupId == groupId } ?? []
        similarGroupAssetsCache = (pageAssignmentCount, groupId, assets)
        return assets
    }

    /// O(1)：当前照片在当前页的下标；无页/空页 → nil；currentPhotoId 为空/不在页内
    /// → 0（与各查看器既有 `currentIndex` 的回退口径一致）。
    func currentPageIndex() -> Int? {
        guard let page, !page.assets.isEmpty else { return nil }
        guard let currentPhotoId, let index = pageIndex(ofPhotoId: currentPhotoId) else {
            return 0
        }
        return index
    }

    /// selectionSummary 缓存键的"选择代数"：selectedPhotoIds 每次写入由 didSet 自增。
    @ObservationIgnored private(set) var selectionVersion = 0
    /// 选择集的稳定排序快照缓存（场景标签种子等 body 派生用）。
    @ObservationIgnored var sortedSelectionCache: (version: Int, ids: [String])?

    /// 选择集的稳定排序快照（按 id 升序、去重、去空串；场景标签种子等 body 派生用）。
    ///
    /// task-22：旧实现每帧 `selectedPhotoIds.sorted()`（最大 2 万条选择集）；
    /// 缓存键 = selectionVersion（O(1)）。Observation 依赖：即使命中缓存也先读
    /// `selectedPhotoIds.count`，保证"只改选择集"时 body 会重算。
    var sortedSelectedIds: [String] {
        let selectionCount = selectedPhotoIds.count
        if let cached = sortedSelectionCache, cached.version == selectionVersion {
            return cached.ids
        }
        // 与旧 SceneTagsEntryPolicy.seedPhotoIds 的"去空串后排序"同口径，缓存后每帧 O(1)。
        let ids = selectionCount == 0
            ? []
            : selectedPhotoIds.filter { !$0.isEmpty }.sorted()
        sortedSelectionCache = (selectionVersion, ids)
        return ids
    }
    /// `selectionSummary` 的缓存（key = pageVersion + selectionVersion；见 +Actions getter）。
    @ObservationIgnored var selectionSummaryCache: SelectionSummaryCache?
    public internal(set) var selectedPhotoIds: Set<String> = [] {
        // 选择集每次写入（含 insert/remove/formIntersection 等 mutate）都自增，
        // 供 selectionSummary / 后续派生缓存做 O(1) 失效键（见 +Actions）。
        didSet { selectionVersion &+= 1 }
    }
    /// ⇧ 范围选择的稳定锚点：普通/⌘ 点击更新，⇧ 点击只移动 current，不改锚点。
    /// 旧实现用 currentPhotoId 当锚点，第二次 ⇧ 会丢掉第一次的范围。
    var selectionAnchorId: String?
    /// P1-7：最近一次服务端全选快照；手动改选择必须失效。
    var selectionSnapshot: CullingSelectionSnapshot?
    /// 跨页批量待确认计划（由 CullingView 观察并弹确认）。
    var pendingCrossPageBatch: CullingCrossPageBatchPlan?
    /// 本次会话已加载的全部 photoIds（loadMore 累加、整页刷新重置）。
    var loadedPhotoIds: Set<String> = []
    /// P0 / A2：triage 星级策略（产品未拍板前显式暴露；默认保持 3/1 不改现状）。
    public var triageRatingMode: TriageRatingMode = .keep3Reject1
    public internal(set) var navigationGroups: [NavigationGroup] = [] {
        didSet { navigationGroupsVersion &+= 1 }
    }
    /// navigationGroups 的赋值代数（给 navigationGroupSizeByPhotoID 做 O(1) 失效）。
    /// 评审 round-2：+Navigation.swift 跨文件读取，故 internal 只读（@ObservationIgnored 保持）。
    @ObservationIgnored private(set) var navigationGroupsVersion = 0
    /// photoId→组员数 缓存（见 +Navigation；旧实现每次读取重建整个字典）。
    @ObservationIgnored var navigationGroupSizeCache: (version: Int, sizes: [String: Int])?
    public internal(set) var isNavigationBusy = false
    public internal(set) var selectedNavigationGroupId = ""
    public internal(set) var selectedNavigationGroupIds: Set<String> = []
    public internal(set) var similarityGroups: [CullingGroup] = []
    public var scopeMode: ScopeMode = .all
    /// P0/G0：排序（所有排序统一走 nextCursor）。
    public var sortMode: CullingSort = .importOrder
    /// 用户在本窗口内显式改过排序：设置默认值不得覆盖。
    var isSortUserSet = false
    /// 设置 `grid_density` 的窗口默认值（SceneStorage 未设置时使用）。
    var defaultGridDensity: CullingGridDensity = .m
    /// Host 注入：读取 grid_default_sort / grid_density 的原始字符串（async SettingsAPI）。
    public var gridDefaultsProvider: (@MainActor () async -> (sortRaw: String?, densityRaw: String?))?
    /// P0/G0：网格 200/页；单图/对比/胶片条沿用 500。
    public var pageLimit: Int = 500
    /// P0/T0：Beta 开关来自 settings.triage_enabled；默认 true 仅用于直接构造 VM 的测试/预览。
    public internal(set) var triageEnabled = true
    /// 质量分析成功后是否自动生成建议；默认关闭（设置 triage_auto_generate）。
    public internal(set) var triageAutoGenerate = false
    /// W1：当前照片的模型级初审信号（nil = 尚未分析 / 未接线）。
    public internal(set) var currentModelReview: ModelReviewResult?
    /// 已打开会话内设置变更后重读；nil 时保持构造时状态。
    public var triageEnabledProvider: (@MainActor () async -> Bool)?
    /// triage_auto_apply=1：生成成功后按策略门槛自动应用 keep/reject（默认关）。
    public var triageAutoApplyProvider: (@MainActor () async -> Bool)?
    public var triageAutoGenerateProvider: (@MainActor () async -> Bool)?
    /// 本次生成结果已经应用过；避免重复 apply 产生无意义 upsert/history。
    public internal(set) var triageApplied = false
    /// T0 应用产生的 history operation id：撤销它时必须按 source=ai 回写，
    /// 否则资产会变成 manual+pending，之后永远被“人工决策”跳过。
    public internal(set) var triageHistoryOperationId: Int?
    /// P1 / E：最近一次"建议写回 XMP"的批次 id（nil = 没有可撤销的写回）。
    public internal(set) var lastTriageWritebackBatchId: String?

    /// Host（跨模块）读取设置后回填 Beta 开关；不暴露任意 setter。
    public func refreshTriageSettings() async {
        if let provider = triageEnabledProvider {
            let enabled = await provider()
            if enabled != triageEnabled { setTriageEnabled(enabled) }
        }
        if let provider = triageAutoGenerateProvider {
            triageAutoGenerate = await provider()
        }
        // 门限/policy 变更会改指纹：开关打开时静默重取当前页，避免旧徽标与
        // “可应用”状态落后于设置。
        if triageEnabled, page != nil {
            refreshSilently(forcePage: true)
        }
    }

    /// 应用设置默认值：排序只在用户未手动改过时生效；密度只影响未设置过的窗口。
    public func refreshGridDefaults() async {
        guard let provider = gridDefaultsProvider else { return }
        let defaults = await provider()
        if let raw = defaults.densityRaw,
           let density = CullingGridDensity(rawValue: raw) {
            defaultGridDensity = density
        }
        guard let raw = defaults.sortRaw,
              let sort = CullingSort(rawValue: raw),
              !isSortUserSet, sortMode != sort else { return }
        sortMode = sort
        // 首屏还没加载时只设置排序，由页面 .task 的那次 load 使用它；
        // 否则会在 applyPageLimit 之前多发一次 500 页请求。
        guard page != nil else { return }
        await loadPage(reset: true)
    }

    public func setTriageEnabled(_ enabled: Bool) {
        triageEnabled = enabled
        guard !enabled else { return }
        // 关闭后不能留下 triage 过滤/排序，否则用户会看到空网格且无入口恢复。
        let hadTriageFilter = filterState.triageVerdicts != nil
            || sortMode == .triageConfidenceAsc
        filterState.triageVerdicts = nil
        if sortMode == .triageConfidenceAsc { sortMode = .importOrder }
        if hadTriageFilter, page != nil {
            Task { @MainActor [weak self] in await self?.loadPage(reset: true) }
        }
    }

    /// 是否还有下一页：唯一凭据是 nextCursor。
    public var hasMore: Bool { page?.nextCursor != nil }
    public internal(set) var selectedSimilarityGroupId = ""
    var pageVersion = 0
    /// 整页加载的 latest-wins 代数：旧请求返回后不得覆盖新筛选/新会话的结果。
    var loadGeneration = 0
    /// refreshSyncStatus 的 latest-wins 代数（事件风暴下只落最后一次）。
    private var syncStatusRequestID = 0
    /// 上次已通知自动 reload 的 written 计数（避免每次刷新重复触发同一批）。
    private var lastAutoReloadWritten: Int?
    var refreshTask: Task<Void, Never>?

    // MARK: - B3 / 浏览状态恢复（筛选 / 范围 / 排序 / 当前照片 / 参考槽）

    /// 按 sessionId 持久化查看状态（UserDefaults + JSON；见 CullingViewStateStore）。
    @ObservationIgnored var viewStateStore = CullingViewStateStore()
    /// 保存节流：只保留最新一份待写状态（防每按一键写盘）。
    @ObservationIgnored var viewStateSaveThrottle = CullingViewStateSaveThrottle()
    @ObservationIgnored var viewStateSaveTask: Task<Void, Never>?
    /// 保存去抖（毫秒）；测试可调小/置 0，不真等 0.5s。
    var viewStateDebounceMilliseconds = CullingViewStateSaveThrottle.defaultDebounceMilliseconds
    /// 睡眠注入（测试传立即返回，避免真实等待）。
    @ObservationIgnored var viewStateSleep: @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
    }
    /// 页面级 chrome（布局/密度/检查器/胶片条）：保存时与业务状态一起落盘。
    @ObservationIgnored var savedViewLayout: CullingLayoutMode = .single
    @ObservationIgnored var savedViewDensity: CullingGridDensity = .m
    @ObservationIgnored var savedViewInspectorVisible = true
    @ObservationIgnored var savedViewFilmstripExpanded = true
    /// 参考槽（观察属性）：查看器 onAppear/onChange 据此恢复，R 切换后回写。
    var viewerReference: CullingViewReference?
    /// 待定位的当前照片 / 是否已读过存档 / 恢复是否完成（完成前不写盘）。
    @ObservationIgnored var pendingRestoredCurrentPhotoId: String?
    @ObservationIgnored var hasAttemptedViewStateRestore = false
    @ObservationIgnored var isViewStateRestorationFinished = false
    @ObservationIgnored var isRestoringViewState = false

    /// 生产装配（RootView）：挑片 / 导航 / 元数据 / 任务 / 画质全部走
    /// AppServices 的类型化 API；captureOne 必传（组合根构造，reload ack 写
    /// 唯一 AppRuntime）。E-17：删除默认自建 CaptureOneBridge() 的兜底。
    public init(
        sessionId: String,
        culling: any CullingAPI,
        navigation: any NavigationAPI,
        metadata: any MetadataAPI,
        jobs: any JobAPI,
        quality: any QualityAPI,
        captureOne: any CaptureOneBridging,
        photo: (any PhotoAPI)? = nil,
        session: (any SessionAPI)? = nil,
        qualityPollIntervalMilliseconds: Int = CullingViewModel.defaultQualityPollIntervalMilliseconds
    ) {
        self.sessionId = sessionId
        self.cullingAPI = culling
        self.navigationAPI = navigation
        self.metadataAPI = metadata
        self.photoAPI = photo
        self.sessionAPI = session
        self.jobAPI = jobs
        self.qualityAPI = quality
        self.captureOne = captureOne
        self.qualityPollIntervalMilliseconds = max(1, qualityPollIntervalMilliseconds)
    }

    /// 首次 / 重试加载：导航组与主列表保持旧顺序（先导航、再整页）。
    ///
    /// B3：首载完成后定位存档里的当前照片（分页是键集游标，必须先有首页才能
    /// 往前续读）。首载失败时保留待恢复目标，重试 load() 会继续定位。
    public func load() async {
        guard !sessionId.isEmpty else { return }
        // Wave3 / G6：识别 C1 Session 三目录（只读标注；会话源路径取一次即可）。
        await loadCaptureOneSessionLayout()
        await loadNavigation()
        await loadPage(reset: true)
        if isRestoringViewState, page != nil {
            await resolveRestoredCurrentPhoto()
            finishViewStateRestore()
        } else if isRestoringViewState, page == nil, errorMessage == nil {
            // 空会话（0 张）：没有目标可定位，按已知状态收尾，避免永远不写盘。
            finishViewStateRestore()
        }
    }
    /// 从 MetadataSyncSummary 推导同步状态机（优先级对齐旧版 syncLabel：
    /// 冲突 > 失败 > 写入中 > 已写入 > 已载入 > 空）。
    public func syncFlowState() -> SyncFlowState {
        guard let syncStatus else { return .disconnected }
        if syncStatus.conflict > 0 { return .conflict }
        if syncStatus.failed > 0 { return .failed }
        if syncStatus.pending + syncStatus.writing > 0 { return .syncing }
        if syncStatus.written > 0 { return .c1Read }
        if syncStatus.synced > 0 { return .safeToCleanup }
        return .synced
    }

    // MARK: - P1 / A3：只读元数据面板

    /// 当前照片的只读元数据详情（缓存投影）。nil = 尚未加载或未选中。
    /// P1 / D：会话域（摄取登记用）。nil = 未接线，摄取入口报错而不是静默失败。
    var sessionAPI: (any SessionAPI)?
    /// Wave3 / G6：会话源路径与 C1 Session 三目录识别结果。
    /// 只用于 UI 标注（Capture/Selects/Trash 角色）；导入范围的重定向在导入入口完成。
    public internal(set) var sessionSourcePath: String?
    public internal(set) var captureOneSessionLayout: C1SessionLayout?
    /// A5：会话实际扫描根是否已是 Capture 子目录（true = Trash/Selects 不会被扫进图库）。
    /// 旧入口（历史会话/未重定向）为 false —— UI 不得宣称"仅导入 Capture"。
    public internal(set) var captureOneSessionScanIsCaptureOnly = false

    public var metadataDetail: PhotoMetadataDetail?
    /// latest-wins 代数：快速翻页时只落最后一次请求的结果。
    private var metadataDetailRequestID = 0

    /// 面板数据加载：只读缓存（photo.metadata 不触发磁盘解析）。
    public func loadMetadataDetail() {
        guard let photoId = currentAsset?.photo.id else {
            metadataDetail = nil
            return
        }
        metadataDetailRequestID += 1
        let requestID = metadataDetailRequestID
        // 先清空：切图后不得继续渲染上一张的路径/IPTC（请求返回前也不显示旧值）。
        metadataDetail = nil
        Task { [weak self] in
            guard let self else { return }
            let detail = try? await self.metadataAPI.metadata(photoId)
            guard self.metadataDetailRequestID == requestID,
                  detail?.photoId == photoId else { return }
            self.metadataDetail = detail
        }
    }

    /// 对齐 deriveSyncControls：syncing/c1Read/safeToCleanup 才可重载元数据。
    public var canLoadMetadata: Bool {
        CullingSyncFlow.deriveControls(
            syncState: syncFlowState(),
            hasWritten: (syncStatus?.written ?? 0) > 0,
            acked: reloadAcked
        ).canLoadMetadata
    }

    /// 对齐 deriveSyncControls：确认需（c1Read + 存在 written 行 + ack）或 safeToCleanup。
    public var canConfirmSync: Bool {
        CullingSyncFlow.deriveControls(
            syncState: syncFlowState(),
            hasWritten: (syncStatus?.written ?? 0) > 0,
            acked: reloadAcked
        ).canConfirmSync
    }

    /// 对齐 deriveSyncControls：清理仅 safeToCleanup 可用。
    public var canCleanup: Bool {
        CullingSyncFlow.deriveControls(
            syncState: syncFlowState(),
            hasWritten: (syncStatus?.written ?? 0) > 0,
            acked: reloadAcked
        ).canCleanup
    }
    // Cut 4 / 4a-3b-1：删除 VM 内的文案漏斗（`Self.message(for:)`）——
    // 错误只以 `CommandError`（码/参数/诊断）落地，文案统一在 View 渲染期
    // 经 `L10n` 解析；原始诊断只进日志。
    /// 领域广播标识：监听端跳过自己发出的事件（GatherApplicationChange.origin）。
    static let changeOrigin = "culling"

    /// 挑片决策写入成功后广播（图库/画廊的星级与色标消费）。
    func postCullingChange() {
        GatherEventCenter.postDomainChange(.culling, sessionId: sessionId, origin: Self.changeOrigin)
    }

    /// 写回/结清/同步队列变化后广播（设置页/C1 胶囊/控制中心消费）。
    func postMetadataChange() {
        GatherEventCenter.postDomainChange(.metadata, sessionId: sessionId, origin: Self.changeOrigin)
    }

    /// 跨页领域变更：命中本会话的挑片/元数据/图库变更时刷新自己的数据源；
    /// 隐藏或正忙时只登记，回可见/空闲后由 flushDeferredDomainRefresh 补刷
    ///（隐藏页不发命令是外壳既有约定）。自身 origin 跳过，避免自触发重查。
    public func handleDomainChange(_ change: GatherApplicationChange) {
        guard change.matches(sessionId: sessionId),
              change.origin != Self.changeOrigin,
              [.culling, .metadata, .library].contains(change.domain) else { return }
        guard isActive, !isLoading else {
            pendingDomainRefresh = true
            return
        }
        refreshSilently(forcePage: true)
    }

    /// 页面重新可见 / 当前刷新结束后的补刷出口（幂等）。
    public func flushDeferredDomainRefresh() {
        guard pendingDomainRefresh, isActive, !isLoading else { return }
        pendingDomainRefresh = false
        refreshSilently(forcePage: true)
    }

    // MARK: - 可见性 / 关闭（Cut 4 / 4a-2b）

    /// 可见性唯一入口（PageVisibility）：View 的 onAppear/onDisappear 只调这里。
    /// - 幂等：与当前状态相同直接返回（重复 onAppear 不重复补刷/重启轮询）；
    /// - visible=false：置 isActive=false，画质 500ms 轮询在下一拍退出/暂停；
    /// - visible=true：置 isActive=true，补刷隐藏期登记的领域变更并恢复轮询；
    /// - shutdown 之后明确 no-op（关闭是终态）。
    // MARK: - SessionPageModel（生命周期注册表契约）

    /// 可见性真相的只读桥（存储属性与写入口仍归本 VM 所有）。
    public var isPageVisible: Bool { isActive }
    /// 关闭终态的只读桥（关闭动作仍走 shutdown()）。
    public var hasShutDown: Bool { isShutdown }
    public func setVisible(_ visible: Bool) {
        guard !isShutdown, transitionVisibility(&isActive, to: visible) else { return }
        guard visible else {
            qualityPollTask?.cancel()
            qualityPollTask = nil
            // 隐藏页不再预取：未完成的邻张预取立即取消（避免隐藏期占解码名额）。
            preloadTask?.cancel()
            preloadTask = nil
            // B3：隐藏 = 页面离开，把 0.5s 节流里还没落盘的浏览状态写掉。
            flushViewStateSave()
            return
        }
        flushDeferredDomainRefresh()
        if let qualityJob, Self.isQualityJobActive(qualityJob.status) {
            startQualityPolling(job: qualityJob)
        }
        // 页面可见即补一次邻张预取：查看器的 onAppear 早于页面级 setPageVisible
        // 时就可能被 isActive 门禁挡掉，这里保证"进入页面后一定有预热"。
        scheduleNeighborPreload()
    }

    /// 关闭：取消本 VM 持有的长生命周期 Task（刷新 + 画质轮询）。
    /// 关闭后 setVisible(true) 不重启，避免会话结束/淘汰后隐藏页空转。
    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isActive = false
        refreshTask?.cancel()
        refreshTask = nil
        qualityPollTask?.cancel()
        qualityPollTask = nil
        // 关闭是终态：未完成的邻张预取与排队按键一并清掉，避免会话结束后再写盘。
        preloadTask?.cancel()
        preloadTask = nil
        pendingCommit = nil
        isCommitting = false
        // B3：会话关闭是最后一次落盘机会（flush 内部会取消节的保存任务）。
        viewStateSaveTask?.cancel()
        viewStateSaveTask = nil
        flushViewStateSave()
        pendingRestoredCurrentPhotoId = nil
    }

    private static func isQualityJobActive(_ status: AnalysisJobStatus) -> Bool {
        [.queued, .running, .cancelling].contains(status)
    }

    /// 已记过的质量失败诊断（去重；超过上限清空，避免无限增长）。
    private var loggedQualityDiagnostics: Set<String> = []

    /// 同步摘要统一入口：状态赋值 + 把失败/冲突行的**原始诊断**写日志
    ///（UI 只展示漏斗后的文案，见 CullingView.displayedReason）。
    func applySyncStatus(_ summary: MetadataSyncSummary?) {
        syncStatus = summary
        guard let summary else { return }
        for item in summary.items where item.status == .failed || item.status == .conflict {
            guard !item.errorMessage.isEmpty else { continue }
            GatherLogger.log(
                "culling sync \(item.status.rawValue) \(item.xmpPath): \(item.errorMessage)",
                level: .warn
            )
        }
    }

    /// 质量分析失败行的原始诊断写日志（每次页面落地一次；UI 只显示漏斗文案，
    /// 见 qualityHelpText / CullingViewModel.funnelErrorText）。
    func logQualityFailures(_ page: CullingPage) {
        for asset in page.assets {
            guard let quality = asset.quality, quality.status == .failed,
                  let raw = quality.errorMessage, !raw.isEmpty else { continue }
            // 去重：页面每次落地都会走这里，同一照片的同一条诊断只记一次。
            if loggedQualityDiagnostics.count > 200 { loggedQualityDiagnostics.removeAll() }
            let key = "\(asset.photo.id)|\(raw)"
            guard loggedQualityDiagnostics.insert(key).inserted else { continue }
            GatherLogger.log("culling quality failed \(asset.photo.id): \(raw)", level: .warn)
        }
    }

    /// c1SyncStatus 事件（GatherEventCenter.c1SyncStatus，object 为 sessionId）的轻量刷新。
    public func refreshSyncStatus() async {
        syncStatusRequestID &+= 1
        let requestID = syncStatusRequestID
        var failure: CommandError?
        do {
            let status = try await cullingAPI.syncStatus(sessionId)
            guard requestID == syncStatusRequestID else { return }
            applySyncStatus(status.summary)
            reloadAcked = status.reloadAckedAt != nil
            // P1：写回批次收敛后交给自动 reload 协调器（debounce/串行/抑制在协调器内）。
            // 同一 written 计数只通知一次：确认前的普通刷新/页面出现不重复触发 reload。
            let written = status.summary.written
            if written > 0, written != lastAutoReloadWritten,
               let roundTrip = captureOne as? any C1RoundTripReloading {
                roundTrip.noteDeliveryStateChanged(sessionId: sessionId)
            }
            lastAutoReloadWritten = written
        } catch {
            guard requestID == syncStatusRequestID else { return }
            failure = CommandError(error)
        }
        do {
            let summary = try await cullingAPI.summary(sessionId)
            guard requestID == syncStatusRequestID else { return }
            self.summary = summary
        } catch {
            guard requestID == syncStatusRequestID else { return }
            failure = failure ?? CommandError(error)
        }
        lastSyncError = failure
    }
    /// 失败写回行（coordinator 写入的真实原因；UI 必须展示，不允许只报计数）。
    public var failedSyncItems: [MetadataSyncItem] {
        (syncStatus?.items ?? []).filter { $0.status == .failed }
    }

    /// 某个 xmp 行的失败/冲突原因（空串视为无原因）；上屏前走错误码漏斗。
    public func syncFailureReason(xmpPath: String, with l10n: L10n) -> String? {
        guard let item = syncStatus?.items.first(where: { $0.xmpPath == xmpPath }),
              !item.errorMessage.isEmpty else { return nil }
        return Self.funnelErrorText(item.errorMessage, with: l10n)
    }

    /// 已决策（keep/reject）照片数：破坏性写回确认弹窗展示影响范围用。
    public var decidedPhotoCount: Int {
        guard let summary else { return 0 }
        return summary.kept + summary.rejected
    }

#if DEBUG
    /// 测试注入：直接设置同步摘要，绕开命令层（CullingSyncFlowTests 直测状态机推导）。
    func applySyncSummaryForTesting(_ summary: MetadataSyncSummary?) {
        syncStatus = summary
    }

    /// 测试注入：直接设置质量任务，绕开建单（取消通道/文案的纯逻辑测试用）。
    func applyQualityJobForTesting(_ job: AnalysisJobData?) {
        qualityJob = job
    }
#endif

    /// TS: qualityApi.analyze + jobs.list 轮询。这里仅接入技术质量任务；
    /// 人脸推理质量按用户要求不作为本轮验收门。
    /// B8.2b：建单走 QualityAPI.analyze（返回 AnalysisJobData）；轮询走
    /// JobAPI.list(includeCheckpoint:false)（与旧 jobs.list 参数逐字一致，
    /// 避免把每个任务的 checkpoint 解析到主线程）。
    public func analyzeQuality() async {
        guard !isQualityBusy else { return }
        isQualityBusy = true
        defer { isQualityBusy = false }
        do {
            let job = try await qualityAPI.analyze(
                try QualityAnalyzeInput(sessionId: sessionId)
            )
            qualityJob = job
            notice = CullingNotice("技术质量分析已排队")
            startQualityPolling(job: job)
            // 可见时保持旧的“analyzeQuality 等到轮询终态才返回”语义；
            // 隐藏时 setVisible(false) 取消轮询，这里立即返回（不再空转）。
            await qualityPollTask?.value
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 500ms 画质任务轮询：由 analyzeQuality 启动，setVisible(false)/shutdown()
    /// 取消，setVisible(true) 对仍在排队的任务重新启动（进度不丢）。
    private func startQualityPolling(job: AnalysisJobData) {
        guard !isShutdown, isActive else { return }
        qualityPollTask?.cancel()
        qualityPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isActive {
                do {
                    try await Task.sleep(for: .milliseconds(self.qualityPollIntervalMilliseconds))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isActive else { return }
                do {
                    let jobs = try await self.jobAPI.list(JobListFilter(includeCheckpoint: false))
                    guard let latest = jobs.first(where: { $0.id == job.id }) else { return }
                    self.qualityJob = latest
                    switch latest.status {
                    case .queued, .running, .cancelling:
                        continue
                    case .succeeded:
                        self.notice = CullingNotice("技术质量分析已完成")
                        await self.loadPage(reset: true)
                        // P2：可选自动生成；默认关闭，避免 20k 会话分析完成时突然重算。
                        if self.triageEnabled && self.triageAutoGenerate {
                            await self.generateTriage()
                        }
                        return
                    case .failed, .interrupted:
                        self.errorMessage = CommandError(apiText: latest.errorMessage)
                        await self.loadPage(reset: true)
                        return
                    case .cancelled:
                        self.notice = CullingNotice("质量分析已取消")
                        await self.loadPage(reset: true)
                        return
                    }
                } catch {
                    self.errorMessage = CommandError(error)
                    return
                }
            }
        }
    }

    /// 取消技术质量分析任务（B8.2b：jobs.cancel -> JobAPI.cancel）。
    /// 入口保持同步签名（工具栏按钮直接回调）；请求在内部 Task 发出，
    /// 成功/失败文案与旧的同步路径一致。
    public func cancelQualityAnalysis() {
        guard let job = qualityJob else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.jobAPI.cancel(job.id)
                self.notice = CullingNotice("已请求取消质量分析")
            } catch {
                self.errorMessage = CommandError(error)
            }
        }
    }
}
