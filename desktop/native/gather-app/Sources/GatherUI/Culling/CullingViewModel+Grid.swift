// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Grid.swift
// P0 / G0：网格布局的排序、分页大小与选择语义。
// 只扩充 VM 的 UI 状态；不改 core 契约/服务逻辑。
import AppKit
import Foundation
import GatherProtocol

extension CullingViewModel {
    /// 恢复上次排序：只改 UI 状态，由页面首次 load 使用；不额外发请求。
    public func applySort(_ sort: CullingSort) {
        isSortUserSet = true
        sortMode = sort
    }

    /// 切换排序：重置分页与游标，保留当前照片（若仍在新页）。
    public func setSort(_ sort: CullingSort) async {
        guard sortMode != sort else { return }
        isSortUserSet = true
        sortMode = sort
        // P0：排序变化后旧选择可能不可见；提交前必须清空。
        selectedPhotoIds.removeAll()
        invalidateSelectionSnapshot()
        await loadPage(reset: true)
        // Wave5 batch4：排序变化会重取服务端页；人物/组视图投影要在新基准上重放。
        await refreshClientProjectionAfterReload()
    }

    /// 切换布局导致的页大小变化：按「当前照片所在页」续页，不整页 reset。
    ///
    /// B2 / 浏览连续性（20-culling-viewer §2 P1 / §3-2）：网格 200 / 其余 500，
    /// 切布局会改页大小。旧实现无条件 loadPage(reset: true)：页变小后当前照片
    /// （例如第 300 张）不在新页内，被回退到第一张——每小时十几次的动作看起来
    /// 像"软件坏了"。分页是键集游标（没有 offset），所以「停在第 N 页」无法直接
    /// 请求；能保证连续性的做法是不动已加载窗口（见 CullingPageContinuation）。
    public func setPageLimit(_ limit: Int) async {
        let clamped = min(1_000, max(50, limit))
        guard pageLimit != clamped else { return }
        pageLimit = clamped
        // 不再无条件清空：跨页选择保留在 selectedPhotoIds（提交时再按可见性收窄），
        // 避免“切布局/翻页即丢选择”。
        let plan = CullingPageContinuation.plan(
            loadedCount: page?.assets.count ?? 0,
            currentIndex: currentLoadedIndex,
            newLimit: clamped)
        guard let reloadLimit = plan.reloadLimit else { return }
        await loadPage(reset: true, initialLimit: reloadLimit)
        // Wave5 batch4：页大小变化会重取页；客户端投影在服务端新页上重放。
        await refreshClientProjectionAfterReload()
    }

    /// 当前照片在已加载页里的下标（nil = 无当前照片 / 不在已加载页内）。
    var currentLoadedIndex: Int? {
        guard let currentPhotoId, let assets = page?.assets else { return nil }
        return assets.firstIndex { $0.photo.id == currentPhotoId }
    }

    /// 首屏加载前静默设置页大小（不触发第二次请求）。
    public func applyPageLimit(_ limit: Int) {
        pageLimit = min(1_000, max(50, limit))
    }

    /// T0：按建议 verdict 过滤；空数组表示取消。
    public func setTriageVerdicts(_ verdicts: [TriageVerdict]?) async {
        // Wave5 batch4：服务端筛选变化后保留人物/组视图投影（语义 = AND）。
        await setFilterStateKeepingClientProjection { state in
            state.triageVerdicts = (verdicts?.isEmpty == false) ? verdicts : nil
        }
    }

    public func selectAllLoaded() {
        guard !loadedPhotoIds.isEmpty else { return }
        selectedPhotoIds = loadedPhotoIds
        selectionAnchorId = nil
        invalidateSelectionSnapshot()
    }

    /// 任何手动选择变化都让服务端快照失效，防止用旧 hash 写新集合。
    func invalidateSelectionSnapshot() {
        selectionSnapshot = nil
        pendingCrossPageBatch = nil
    }

    /// P0 / A1：⌘A 选中**当前 scope/filters 的全部照片**（不只已加载页）。
    ///
    /// 失败时退回"已加载页"并提示：宁可少选，也不能假装全选。
    public func selectAllInScope() async {
        // Wave5 batch4：人物/组视图是客户端投影，服务端 selection 不含这些条件——
        // 若仍按 scope 全选，会把用户**看不见**的照片写进选择集（随后 P/X 会误伤）。
        // 投影期间全选收敛为"已加载的可见页"，与屏幕一致。
        if isClientProjectionActive {
            selectAllLoaded()
            return
        }
        // 进入时快照 scope 与加载代数：await 期间切筛选/scope 会清空选择并重新加载，
        // 旧 scope 的结果绝不能回填（P1：否则随后的移出会把当前视图看不到的
        // 旧选择整份提交给服务端，单向不可撤销）。
        let generation = loadGeneration
        let scope = currentAPIScope
        do {
            let query = try CullingSelectionQuery(
                sessionId: sessionId,
                scope: currentAPIScope,
                filters: currentAPIScope == .filtered ? filtersForCurrentState() : nil,
                // 相似度模式未选组时与 loadPage 同语义：nil = latest，不是空字符串。
                groupId: currentAPIScope == .similarityGroup && !selectedSimilarityGroupId.isEmpty
                    ? selectedSimilarityGroupId : nil
            )
            let result = try await cullingAPI.selection(query)
            guard generation == loadGeneration, scope == currentAPIScope else { return }
            selectedPhotoIds = Set(result.ids)
            selectionAnchorId = nil
            selectionSnapshot = CullingSelectionSnapshot(
                scope: scope,
                filters: query.filters,
                groupId: query.groupId,
                idsHash: result.idsHash ?? "",
                count: result.ids.count,
                truncated: result.truncated)
            if result.truncated {
                notice = CullingNotice(
                    "已选中前 %lld 张（超出单次上限，其余请先缩小筛选范围）",
                    params: ["\(result.ids.count)"])
            }
        } catch {
            // 旧 scope 的失败也不能回退成"已加载页"选择（那会把旧视图的
            // 选择集写进新 scope）。
            guard generation == loadGeneration, scope == currentAPIScope else { return }
            selectAllLoaded()
            errorMessage = CommandError(error)
        }
    }

    /// 胶片条 ⇧ 点击：从当前照片到目标照片的范围选择，并把当前移到目标。
    ///
    /// 与网格 shift 语义一致；锚点是 selectionAnchorId（普通/⌘ 点击更新），
    /// current 只跟随目标移动，连续 ⇧ 不会丢第一段。
    public func selectRangeFromCurrent(to photoId: String) {
        guard let current = currentPhotoId, current != photoId else {
            selectCurrent(photoId)
            return
        }
        // 锚点保持上一次普通/⌘ 点击的位置；current 只用于显示/决策目标。
        // 页切换后锚点可能已不可见：回落到 current，避免 ⇧ 无反应。
        let anchor = (selectionAnchorId.flatMap { candidate in
            page?.assets.contains(where: { $0.photo.id == candidate }) == true ? candidate : nil
        }) ?? current
        selectRange(from: anchor, to: photoId)
        currentPhotoId = photoId
    }

    /// ⇧ 范围选择：当前照片到目标照片（按当前页顺序）。
    public func selectRange(from anchor: String, to target: String) {
        guard let assets = page?.assets,
              let start = assets.firstIndex(where: { $0.photo.id == anchor }),
              let end = assets.firstIndex(where: { $0.photo.id == target }) else { return }
        let range = start <= end ? start...end : end...start
        // ⇧ 是“本次锚点区间”而不是并集：反复 ⇧ 不应累积区间外的旧选择。
        selectedPhotoIds = Set(range.map { assets[$0].photo.id })
        invalidateSelectionSnapshot()
    }

    /// 网格点击：⌘ 切换，⇧ 范围，否则单选并清空多选。
    public func gridClick(_ photoId: String, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift), let current = currentPhotoId {
            let anchor = (selectionAnchorId.flatMap { candidate in
                page?.assets.contains(where: { $0.photo.id == candidate }) == true
                    ? candidate : nil
            }) ?? current
            selectRange(from: anchor, to: photoId)
            currentPhotoId = photoId
            return
        }
        if modifiers.contains(.command) {
            toggleSelection(photoId)
            currentPhotoId = photoId
            return
        }
        selectedPhotoIds = [photoId]
        selectionAnchorId = photoId
        invalidateSelectionSnapshot()
        currentPhotoId = photoId
    }
}

// MARK: - 布局切换的续页计划（B2：浏览连续性）

/// 切布局导致页大小变化时，首页要不要重取、按多大取（纯函数，便于单测）。
///
/// 分页是**键集游标**（只有「下一页」，没有 offset），所以「停在第 N 页」无法直接
/// 请求；能保证浏览连续性的做法是不动已经加载的窗口——它是排序后的前缀，只要
/// 当前照片还在其中，切布局就不该把它踢回第一张。只有「页变大」才值得重取一次
/// 拿更多数据（当前照片必然仍在新的首页内）。
enum CullingPageContinuation: Equatable {
    /// 保持已加载窗口，只改后续页大小（不发请求）。
    case keepLoadedWindow
    /// 重取首页，请求 limit 条。
    case reload(limit: Int)

    /// 重取首页的 limit（nil = 不需要重取，保持已加载窗口）。
    var reloadLimit: Int? {
        if case .reload(let limit) = self { return limit }
        return nil
    }
}

extension CullingPageContinuation {
    /// index 在新页大小下所属页的「页尾」下标 = 覆盖那一页所需条数。
    ///
    /// 分页按页对齐（0..<limit、limit..<2×limit …），这样重取后网格/查看器的
    /// 翻页节奏与页大小一致；超出单次请求上限（service pageLimitMax = 2000）
    /// 时返回 nil（无法用一次请求覆盖）。
    static func pageAlignedLimit(
        covering index: Int,
        limit: Int,
        maxLimit: Int = 2_000
    ) -> Int? {
        guard index >= 0, limit > 0, maxLimit > 0 else { return nil }
        let aligned = ((index / limit) + 1) * limit
        guard aligned <= maxLimit else { return nil }
        return aligned
    }

    /// 页大小从旧值切到 newLimit 时的首页计划。
    ///
    /// - loadedCount == 0：没有可保留的窗口，按新页大小取首页；
    /// - 当前照片在已加载窗口内、且新页大小不大于窗口：只改后续页大小
    ///   （最常见：500 → 200 切网格），当前照片原地不动；
    /// - 页变大：重取一次把窗口扩到新页大小（当前照片必然仍在新页内）；
    /// - 当前照片不在已加载窗口（防御分支，例如页被别的路径整页换掉）：按新页
    ///   大小整页对齐后重取覆盖它的那一页；超出单次上限则退回新页大小。
    static func plan(
        loadedCount: Int,
        currentIndex: Int?,
        newLimit: Int,
        maxLimit: Int = 2_000
    ) -> CullingPageContinuation {
        let limit = min(maxLimit, max(1, newLimit))
        guard loadedCount > 0 else { return .reload(limit: limit) }
        if let currentIndex, currentIndex >= 0 {
            if currentIndex < loadedCount {
                // 窗口已经包含当前照片：页变小没必要重取（旧页是超集，多加载的
                // 部分不影响正确性）；页变大才为了「翻片窗口」补数据。
                return limit > loadedCount ? .reload(limit: limit) : .keepLoadedWindow
            }
            if let aligned = pageAlignedLimit(
                covering: currentIndex, limit: limit, maxLimit: maxLimit) {
                return .reload(limit: aligned)
            }
        }
        return .reload(limit: limit)
    }
}

// MARK: - Wave5 batch4：人物筛选 / 组视图的客户端投影

/// 进入投影前的服务端页基准（进程内，按会话）。
///
/// 为什么用 side table 而不是 VM 存储属性：CullingViewModel.swift 不在本批
/// 写作用域，而 FilterState 只存"选了什么"、不适合存整页快照。这里只被
/// MainActor 上的 VM 方法读写，退出投影时 take 清口。
@MainActor
enum CullingClientProjectionCache {
    private static var basePages: [String: CullingPage] = [:]

    static func hasBase(sessionId: String) -> Bool {
        basePages[sessionId] != nil
    }

    static func base(sessionId: String) -> CullingPage? {
        basePages[sessionId]
    }

    static func storeBase(sessionId: String, page: CullingPage?) {
        guard let page else {
            basePages.removeValue(forKey: sessionId)
            return
        }
        basePages[sessionId] = page
    }

    static func takeBase(sessionId: String) -> CullingPage? {
        basePages.removeValue(forKey: sessionId)
    }

    static func clear(sessionId: String) {
        basePages.removeValue(forKey: sessionId)
    }
}

/// 客户端投影纯函数（可单测）：人物精确过滤 + 导航组收窄 + 组内排序。
///
/// 排序规则（Narrative Scenes View 的最小口径）：
/// 1. lead 优先（navigation 服务端算出的最佳帧，不重算）；
/// 2. 其余按技术质量 score 降序（quality.status == .succeeded 才可比）；
/// 3. 质量相同/缺质量时按组内原始顺序（photoIds 顺序）稳定排序。
enum CullingClientProjection {
    static func project(
        assets: [CullingAsset],
        person: String?,
        group: NavigationGroup?
    ) -> [CullingAsset] {
        var result = assets
        if let person, !person.isEmpty {
            result = result.filter { $0.people.contains(person) }
        }
        guard let group else { return result }
        let groupIds = Set(group.photoIds)
        result = result.filter { groupIds.contains($0.photo.id) }
        // 组 photoIds 理论上唯一；重复 id 时保留首次出现，不能让
        // Dictionary(uniqueKeysWithValues:) 在渲染路径上 trap。
        let originalIndex = Dictionary(
            group.photoIds.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        result.sort { left, right in
            let leftIsLead = left.photo.id == group.leadPhotoId
            let rightIsLead = right.photo.id == group.leadPhotoId
            if leftIsLead != rightIsLead { return leftIsLead }
            let leftScore = qualityScore(left)
            let rightScore = qualityScore(right)
            if let leftScore, let rightScore, leftScore != rightScore {
                return leftScore > rightScore
            }
            let leftOrder = originalIndex[left.photo.id] ?? Int.max
            let rightOrder = originalIndex[right.photo.id] ?? Int.max
            return leftOrder < rightOrder
        }
        return result
    }

    /// 当前页是否已经是目标投影（外部刷新后的幂等重投影用，避免无限循环）。
    static func matches(
        _ assets: [CullingAsset],
        person: String?,
        group: NavigationGroup?
    ) -> Bool {
        let projected = project(assets: assets, person: person, group: group)
        return projected.map(\.photo.id) == assets.map(\.photo.id)
    }

    /// 质量可比才返回分数：失败/缺失不参与组内排序（不能拿 0 分顶掉最佳帧）。
    static func qualityScore(_ asset: CullingAsset) -> Double? {
        guard let quality = asset.quality, quality.status == .succeeded else { return nil }
        return quality.score
    }
}

extension CullingViewModel {
    /// 当前人物筛选（nil = 未启用）。
    var personFilter: String? { filterState.person }

    /// 当前是否处于客户端投影（人物筛选或组视图任一开启）。
    var isClientProjectionActive: Bool {
        filterState.person != nil || filterState.navigationGroupViewId != nil
    }

    /// 人物候选（服务端 person facet；未接线 PhotoAPI 时退回已加载页的 people 并集）。
    func personFilterNames() async -> [String] {
        guard let photoAPI else {
            return Array(Set((page?.assets ?? []).flatMap(\.people))).sorted()
        }
        do {
            let input = try PhotoFacetInput(
                sessionId: sessionId,
                criteria: FilterGroup(logic: .and, conditions: []),
                dimensions: ["person"],
                limit: 60
            )
            let groups = try await photoAPI.facets(input)
            let names = groups.first { $0.dimension == "person" }?
                .buckets.map(\.value) ?? []
            if !names.isEmpty { return names }
        } catch {
            // facet 失败不阻断：退回已加载页并集（人物筛选只是消费端投影）。
            GatherLogger.log("culling person facet failed: \(error)", level: .warn)
        }
        return Array(Set((page?.assets ?? []).flatMap(\.people))).sorted()
    }

    /// 设置/清除人物筛选（nil/空 = 清除）。服务端无 person 条件，因此只作用于
    /// **已加载窗口**：首次开启会先追加最多 4 页（约 800 张）再在客户端精确匹配。
    func setPersonFilter(_ person: String?) async {
        let trimmed = (person ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? nil : trimmed
        guard filterState.person != normalized else { return }
        filterState.person = normalized
        selectedPhotoIds.removeAll()
        selectionAnchorId = nil
        invalidateSelectionSnapshot()
        await applyClientProjection()
    }

    func clearPersonFilter() async {
        await setPersonFilter(nil)
    }

    /// 服务端筛选变化时保留客户端投影：先按服务端重载第一页，再在新基准上重投影。
    /// 语义 = 人物（AND）其它服务端筛选；清除人物后恢复服务端结果。
    func setFilterStateKeepingClientProjection(
        _ mutate: (inout FilterState) -> Void
    ) async {
        let person = filterState.person
        let groupId = filterState.navigationGroupViewId
        await setFilterState(mutate)
        filterState.person = person
        filterState.navigationGroupViewId = groupId
        CullingClientProjectionCache.clear(sessionId: sessionId)
        await applyClientProjection(forceBaseFromCurrentPage: true, loadAheadForPerson: false)
    }

    /// 重置筛选（含客户端投影）：先退出投影恢复基准页，再走既有 resetFilters。
    func resetFiltersIncludingClientProjection() async {
        filterState.person = nil
        filterState.navigationGroupViewId = nil
        await restoreClientProjectionBase()
        await resetFilters()
    }

    /// 计算并应用投影（内部入口：人物/组视图变化、服务端筛选/排序/页大小变化后调用）。
    func applyClientProjection(
        forceBaseFromCurrentPage: Bool = false,
        loadAheadForPerson: Bool = true
    ) async {
        guard isClientProjectionActive else {
            await restoreClientProjectionBase()
            return
        }
        if forceBaseFromCurrentPage || !CullingClientProjectionCache.hasBase(sessionId: sessionId) {
            // 人物筛选首次开启：先补几页，避免「第 1 页恰好没这个人 → 0 张」。
            if filterState.person != nil, loadAheadForPerson {
                var extraPages = 0
                while extraPages < 4, hasMore, (page?.assets.count ?? 0) < 800 {
                    await loadPage(reset: false)
                    extraPages += 1
                }
            }
            CullingClientProjectionCache.storeBase(sessionId: sessionId, page: page)
        }
        guard let base = CullingClientProjectionCache.base(sessionId: sessionId) else { return }
        let group = filterState.navigationGroupViewId.flatMap { id in
            navigationGroups.first { $0.id == id }
        }
        let projected = CullingClientProjection.project(
            assets: base.assets, person: filterState.person, group: group)
        let targetCurrent: String? = {
            if let lead = group?.leadPhotoId,
               projected.contains(where: { $0.photo.id == lead }) {
                return lead
            }
            if let current = currentPhotoId,
               projected.contains(where: { $0.photo.id == current }) {
                return current
            }
            return projected.first?.photo.id
        }()
        if projected.isEmpty, let group {
            notice = CullingNotice(
                "当前已加载页没有该组成员（%@ · %lld 张）；可先加载更多照片",
                params: [
                    group.type == .burst ? "连拍组" : "场景组",
                    "\(group.photoIds.count)",
                ])
        }
        page = CullingPage(assets: projected, total: projected.count, nextCursor: nil)
        pageVersion += 1
        loadedPhotoIds = Set(projected.map(\.photo.id))
        selectedPhotoIds = selectedPhotoIds.intersection(loadedPhotoIds)
        if let targetCurrent { currentPhotoId = targetCurrent }
    }

    /// 外部刷新（决策后 refreshSilently / loadPage）可能把投影页换回服务端页：
    /// 页面在 pageVersion 变化时调用本方法做幂等重投影。
    func reprojectIfNeeded() async {
        guard isClientProjectionActive else { return }
        let group = filterState.navigationGroupViewId.flatMap { id in
            navigationGroups.first { $0.id == id }
        }
        if CullingClientProjection.matches(
            page?.assets ?? [], person: filterState.person, group: group) {
            return
        }
        CullingClientProjectionCache.clear(sessionId: sessionId)
        await applyClientProjection(forceBaseFromCurrentPage: true, loadAheadForPerson: false)
    }

    /// 服务端页重取（排序/页大小/筛选变化）后：把新页当基准，重放客户端投影。
    func refreshClientProjectionAfterReload() async {
        guard isClientProjectionActive else {
            CullingClientProjectionCache.clear(sessionId: sessionId)
            return
        }
        CullingClientProjectionCache.clear(sessionId: sessionId)
        await applyClientProjection(forceBaseFromCurrentPage: true, loadAheadForPerson: false)
    }

    /// 退出投影：恢复进入前的服务端页（若基准已被外部刷新替换，则退化为空操作，
    /// 由下一次 loadPage 收敛）。
    private func restoreClientProjectionBase() async {
        guard let base = CullingClientProjectionCache.takeBase(sessionId: sessionId) else { return }
        page = base
        pageVersion += 1
        loadedPhotoIds = Set(base.assets.map(\.photo.id))
        if let current = currentPhotoId,
           !base.assets.contains(where: { $0.photo.id == current }) {
            currentPhotoId = base.assets.first?.photo.id
        }
    }
}
