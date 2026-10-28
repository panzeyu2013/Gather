// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Load.swift
// Cut 4 / 4c-2a：整页加载 / 快照刷新 / 组合筛选（原 CullingView.swift 671-1037 行）。
// 纯搬移：方法是原实现逐字复制，只有 `private` -> internal（跨文件调用）。
import Foundation
import GatherProtocol

extension CullingViewModel {
    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        await loadPage(reset: false)
    }

    /// 静默刷新可安全重取的页大小；nil = 已加载超过单次上限（service pageLimitMax），
    /// 此时跳过页刷新、只刷新摘要等辅助数据，避免折叠页面与选择。
    nonisolated static func silentRefreshPageLimit(pageLimit: Int, loadedCount: Int) -> Int? {
        guard loadedCount <= 2_000 else { return nil }
        return min(2_000, max(pageLimit, loadedCount))
    }

    private struct RefreshSnapshot: Sendable {
        var page: CullingPage?
        var summary: CullingSummary?
        var groups: [CullingGroup]?
        var syncStatus: MetadataSyncSummary?
        /// 耐久 reload-ack（sessions.reload_acked_at）；reloadAckResolved 区分
        /// 「未查询」与「查询到 nil」。
        var reloadAckedAt: String?
        var reloadAckResolved = false
        var history: [CullingHistoryOperation]?
        var conflicts: [MetadataConflict]?
        var pageError: CommandError?
        var auxError: CommandError?
    }

    /// 历史栈可见窗口：仓库 list 的 clamp 上限 = 路由器 culling.history 的 limit 上限
    ///（500）。读取方据此保证栈顶在窗口内（服务端还会补栈顶，见 CullingService.getHistory）。
    nonisolated private static let historyWindow = 500

    func refreshSilently(forcePage: Bool = false) {
        refreshTask?.cancel()
        guard page != nil else { return }
        let version = pageVersion
        let api = cullingAPI
        let metadata = metadataAPI
        let sessionId = self.sessionId
        let scope = currentAPIScope
        let filters = filtersForCurrentState()
        let groupId = selectedSimilarityGroupId
        let sort = sortMode
        // 决策后的本地状态已由 applyDecisionStates 更新：无筛选且不是 rating/T0 排序时，
        // 页不需要重取；只刷 summary/aux。这样深翻/大页不会每次 P/X 重建整页。
        let pageOrderDependsOnDecision = sort == .ratingDesc || sort == .triageConfidenceAsc
        let needsPage = forcePage || filters?.hasAnyFilter == true || pageOrderDependsOnDecision
        // 保留已加载范围：静默刷新不得把多页翻页折叠成首页（会导致当前照片跨页丢失、
        // 选择变为“不可见”，进而让 P/X 误伤当前照片）。
        let loaded = page?.assets.count ?? 0
        let limit = needsPage
            ? Self.silentRefreshPageLimit(pageLimit: pageLimit, loadedCount: loaded)
            : nil
        refreshTask = Task.detached { [api, metadata, sessionId, scope, filters, groupId, sort, limit, version] in
            let snapshot = await Self.fetchSnapshot(
                api: api,
                metadata: metadata,
                sessionId: sessionId,
                scope: scope,
                filters: filters,
                groupId: groupId,
                sort: sort,
                limit: limit
            )
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard !cancelled else { return }
                self.applySnapshot(snapshot, version: version)
            }
        }
    }

    private func applySnapshot(_ snapshot: RefreshSnapshot, version: Int) {
        guard version == pageVersion else { return }
        lastSyncError = snapshot.auxError ?? snapshot.pageError
        if let page = snapshot.page {
            let ids = Set(page.assets.map(\.photo.id))
            loadedPhotoIds = ids
            // P0 / A1：不再按"当前页"裁剪选择集——跨页选择必须保留到提交时。
            // 批量决策仍与已加载页求交（宁可漏杀）；移出用完整选择集，由服务端逐张校验。
            // 内容版本：网格布局缓存/在途 conflicts 守卫都据此判断“页已变”。
            pageVersion += 1
            self.page = page
            logQualityFailures(page)
            if let current = currentPhotoId, !page.assets.contains(where: { $0.photo.id == current }) {
                currentPhotoId = page.assets.first?.photo.id
            }
            if currentPhotoId == nil {
                currentPhotoId = page.assets.first?.photo.id
            }
            errorMessage = nil
        }
        if let summary = snapshot.summary { self.summary = summary }
        if let groups = snapshot.groups { similarityGroups = groups }
        if !similarityGroups.contains(where: { $0.groupId == selectedSimilarityGroupId }) {
            selectedSimilarityGroupId = ""
        }
        if let syncStatus = snapshot.syncStatus { applySyncStatus(syncStatus) }
        if snapshot.reloadAckResolved { reloadAcked = snapshot.reloadAckedAt != nil }
        if let history = snapshot.history { self.history = history }
        if let conflicts = snapshot.conflicts { self.conflicts = conflicts }
    }

    nonisolated private static func fetchSnapshot(
        api: any CullingAPI,
        metadata: any MetadataAPI,
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        groupId: String,
        sort: CullingSort,
        limit: Int?
    ) async -> RefreshSnapshot {
        var snapshot = RefreshSnapshot()
        if let limit {
            do {
            let query = try CullingPageQuery(
                sessionId: sessionId,
                scope: scope,
                filters: scope == .filtered ? filters : nil,
                groupId: scope == .similarityGroup && !groupId.isEmpty ? groupId : nil,
                sort: sort,
                limit: limit
            )
                snapshot.page = try await api.page(query)
            } catch {
                snapshot.pageError = CommandError(error)
            }
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.summary = try await api.summary(sessionId)
        } catch {
            snapshot.auxError = snapshot.auxError ?? CommandError(error)
        }
        guard !Task.isCancelled else { return snapshot }
        // 相似度分组只在相似度范围需要；默认网格每次决策刷新不应全量读 groups。
        if scope == .similarityGroup {
            do {
                snapshot.groups = try await api.groups(sessionId)
            } catch {
                snapshot.auxError = snapshot.auxError ?? CommandError(error)
            }
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            let status = try await api.syncStatus(sessionId)
            snapshot.syncStatus = status.summary
            snapshot.reloadAckedAt = status.reloadAckedAt
            snapshot.reloadAckResolved = true
        } catch {
            snapshot.auxError = snapshot.auxError ?? CommandError(error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            let query = try CullingHistoryQuery(sessionId: sessionId, limit: Self.historyWindow)
            snapshot.history = try await api.history(query)
        } catch {
            snapshot.auxError = snapshot.auxError ?? CommandError(error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.conflicts = try await metadata.conflicts(sessionId)
        } catch {
            snapshot.auxError = snapshot.auxError ?? CommandError(error)
        }
        return snapshot
    }
    var currentAPIScope: CullingScope {
        switch scopeMode {
        case .all: return .all
        case .filtered: return .filtered
        case .similarityGroup: return .similarityGroup
        }
    }

    func loadPage(reset: Bool) async {
        guard !sessionId.isEmpty else {
            page = nil
            summary = nil
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        if reset { loadMoreFailed = false }
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let scope = currentAPIScope
            let cursor = reset ? nil : page?.nextCursor
            let query = try CullingPageQuery(
                sessionId: sessionId,
                scope: scope,
                filters: scope == .filtered ? filtersForCurrentState() : nil,
                groupId: scope == .similarityGroup && !selectedSimilarityGroupId.isEmpty
                    ? selectedSimilarityGroupId : nil,
                sort: sortMode,
                cursor: cursor,
                limit: pageLimit
            )
            let nextPage = try await cullingAPI.page(query)
            guard generation == loadGeneration else { return }
            let newIds = Set(nextPage.assets.map { $0.photo.id })
            pageVersion += 1
            if reset || page == nil {
                // P0 / A1：整页刷新不再丢弃"不在当前页"的选择。筛选/scope/排序变化
                // 都有显式 removeAll；这里保留跨页选择，提交时再按可见性收窄。
                loadedPhotoIds = newIds
                page = nextPage
                if let current = currentPhotoId, !newIds.contains(current) {
                    currentPhotoId = nextPage.assets.first?.photo.id
                }
                if currentPhotoId == nil {
                    currentPhotoId = nextPage.assets.first?.photo.id
                }
            } else if let oldPage = page {
                page = CullingPage(
                    assets: oldPage.assets + nextPage.assets,
                    total: nextPage.total,
                    nextCursor: nextPage.nextCursor
                )
                loadedPhotoIds.formUnion(newIds)
            }
            // 翻页只追加页数据；summary/groups/sync/history 不随页变化，
            // 避免 20k 会话每 loadMore 都做 O(session) 查询。
            if reset {
                let fetchedSummary = try await cullingAPI.summary(sessionId)
                guard generation == loadGeneration else { return }
                summary = fetchedSummary
                // 以下为辅助查询：失败保持降级（空结果）但不静默，写入 lastSyncError 由 UI 提示。
                lastSyncError = nil
                // 相似度分组只在相似度范围需要；默认网格/翻页不拉全量 groups。
                if scopeMode == .similarityGroup, similarityGroups.isEmpty {
                    do {
                        similarityGroups = try await cullingAPI.groups(sessionId)
                    } catch {
                        guard generation == loadGeneration else { return }
                        similarityGroups = []
                        lastSyncError = CommandError(error)
                    }
                }
                guard generation == loadGeneration else { return }
                // 对齐 TS：不自动选中第一组；未显式选组时保持空选，
                // 请求服务端全部相似组照片。
                if !similarityGroups.contains(where: { $0.groupId == selectedSimilarityGroupId }) {
                    selectedSimilarityGroupId = ""
                }
                do {
                    let status = try await cullingAPI.syncStatus(sessionId)
                    guard generation == loadGeneration else { return }
                    applySyncStatus(status.summary)
                    reloadAcked = status.reloadAckedAt != nil
                } catch {
                    guard generation == loadGeneration else { return }
                    applySyncStatus(nil)
                    lastSyncError = CommandError(error)
                }
                do {
                    let historyQuery = try CullingHistoryQuery(
                        sessionId: sessionId, limit: Self.historyWindow)
                    let fetchedHistory = try await cullingAPI.history(historyQuery)
                    guard generation == loadGeneration else { return }
                    history = fetchedHistory
                } catch {
                    guard generation == loadGeneration else { return }
                    history = []
                    lastSyncError = CommandError(error)
                }
            }


            // P2-8（审计 2）：detached 任务必须带版本守卫（同 refreshSilently 的惯例）。
            // 连续改筛选会并发多个 conflicts 请求，旧请求后到会覆盖新列表；
            // 旧请求失败还会把 conflicts 清空并写入过期的 lastSyncError。
            let conflictsVersion = pageVersion
            let metadata = metadataAPI
            Task { @MainActor in
                do {
                    let fetched = try await metadata.conflicts(sessionId)
                    guard conflictsVersion == pageVersion, generation == loadGeneration else { return }
                    conflicts = fetched
                } catch {
                    guard conflictsVersion == pageVersion, generation == loadGeneration else { return }
                    conflicts = []
                    lastSyncError = CommandError(error)
                }
            }
            if let page { logQualityFailures(page) }
            loadMoreFailed = false
            errorMessage = nil
            flushDeferredDomainRefresh()
        } catch {
            guard generation == loadGeneration else { return }
            // 续页失败要留重试入口：sentinel 已出现不会再 onAppear。
            if !reset { loadMoreFailed = true }
            errorMessage = CommandError(error)
        }
    }
    func filtersForCurrentState() -> CullingFilters? {
        var filters = CullingFilters()
        var active = false
        if filterState.unreviewedOnly { filters.unreviewedOnly = true; active = true }
        if let state = filterState.pickState { filters.pickStates = [state]; active = true }
        if let rating = filterState.rating { filters.ratings = [Double(rating)]; active = true }
        if let label = filterState.colorLabel { filters.colorLabels = [label]; active = true }
        if let quality = filterState.qualityStatus { filters.qualityStatus = quality; active = true }
        if filterState.metadataConflictOnly { filters.metadataConflictOnly = true; active = true }
        if let verdicts = filterState.triageVerdicts, !verdicts.isEmpty {
            filters.triageVerdicts = verdicts
            active = true
        }
        return active ? filters : nil
    }

    /// 任意维度变化入口：更新组合筛选状态并整页刷新；
    /// 无活跃筛选时回到"全部"范围（与原 all → scope .all 行为一致）。
    public func setFilterState(_ mutate: (inout FilterState) -> Void) async {
        mutate(&filterState)
        scopeMode = filterState.isActive ? .filtered : .all
        // P0：筛选变化后旧选择可能不可见；提交前必须清空。
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    /// TS FilterControls 重置（setFilters({})）。
    public func resetFilters() async {
        guard filterState.isActive || scopeMode != .all else { return }
        filterState = FilterState()
        scopeMode = .all
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    public func setScope(_ scope: ScopeMode) async {
        guard scopeMode != scope else { return }
        scopeMode = scope
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }

    /// 相似度分组是 O(session) 查询；只在进入相似度范围/需要选组时加载。
    /// force 用于“从全部范围直接选组”：此时 scope 还不是 similarityGroup。
    public func loadSimilarityGroupsIfNeeded(force: Bool = false) async {
        guard (force || scopeMode == .similarityGroup), similarityGroups.isEmpty else { return }
        do {
            similarityGroups = try await cullingAPI.groups(sessionId)
        } catch {
            similarityGroups = []
            lastSyncError = CommandError(error)
        }
    }

    public func selectSimilarityGroup(_ groupId: String) async {
        await loadSimilarityGroupsIfNeeded(force: true)
        guard similarityGroups.contains(where: { $0.groupId == groupId }) else { return }
        selectedSimilarityGroupId = groupId
        scopeMode = .similarityGroup
        selectedPhotoIds.removeAll()
        await loadPage(reset: true)
    }
}
