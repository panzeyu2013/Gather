// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Load.swift
// Cut 4 / 4c-2a：整页加载 / 快照刷新 / 组合筛选（原 CullingView.swift 671-1037 行）。
// 纯搬移：方法是原实现逐字复制，只有 `private` -> internal（跨文件调用）。
import Foundation
import GatherProtocol

extension CullingViewModel {
    public func loadMore() async {
        guard !isLoading, page?.nextRowId != nil else { return }
        await loadPage(reset: false)
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

    func refreshSilently() {
        refreshTask?.cancel()
        guard page != nil else { return }
        let version = pageVersion
        let api = cullingAPI
        let metadata = metadataAPI
        let sessionId = self.sessionId
        let scope = currentAPIScope
        let filters = filtersForCurrentState()
        let groupId = selectedSimilarityGroupId
        refreshTask = Task.detached { [api, metadata, sessionId, scope, filters, groupId, version] in
            let snapshot = await Self.fetchSnapshot(
                api: api,
                metadata: metadata,
                sessionId: sessionId,
                scope: scope,
                filters: filters,
                groupId: groupId
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
            selectedPhotoIds.formIntersection(loadedPhotoIds)
            loadedPhotoIds = Set(page.assets.map(\.photo.id))
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
        groupId: String
    ) async -> RefreshSnapshot {
        var snapshot = RefreshSnapshot()
        do {
            let query = try CullingPageQuery(
                sessionId: sessionId,
                scope: scope,
                filters: scope == .filtered ? filters : nil,
                groupId: scope == .similarityGroup && !groupId.isEmpty ? groupId : nil,
                limit: 500
            )
            snapshot.page = try await api.page(query)
        } catch {
            snapshot.pageError = CommandError(error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.summary = try await api.summary(sessionId)
        } catch {
            snapshot.auxError = snapshot.auxError ?? CommandError(error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.groups = try await api.groups(sessionId)
        } catch {
            snapshot.auxError = snapshot.auxError ?? CommandError(error)
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
    private var currentAPIScope: CullingScope {
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
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let scope = currentAPIScope
            let query = try CullingPageQuery(
                sessionId: sessionId,
                scope: scope,
                filters: scope == .filtered ? filtersForCurrentState() : nil,
                groupId: scope == .similarityGroup && !selectedSimilarityGroupId.isEmpty
                    ? selectedSimilarityGroupId : nil,
                afterRowId: reset ? nil : page?.nextRowId.map(Int64.init),
                limit: 500
            )
            let nextPage = try await cullingAPI.page(query)
            guard generation == loadGeneration else { return }
            let newIds = Set(nextPage.assets.map { $0.photo.id })
            pageVersion += 1
            if reset || page == nil {
                // 对齐 TS：update/batchUpdate/undo/redo 后整页刷新不清空选择，
                // 仅在选择已失效（不在本次会话已加载的照片全集）时清空对应条目。
                selectedPhotoIds.formIntersection(loadedPhotoIds)
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
                    nextRowId: nextPage.nextRowId,
                    total: nextPage.total
                )
                loadedPhotoIds.formUnion(newIds)
            }
            let fetchedSummary = try await cullingAPI.summary(sessionId)
            guard generation == loadGeneration else { return }
            summary = fetchedSummary
            // 以下为辅助查询：失败保持降级（空结果）但不静默，写入 lastSyncError 由 UI 提示。
            lastSyncError = nil
            do {
                similarityGroups = try await cullingAPI.groups(sessionId)
            } catch {
                guard generation == loadGeneration else { return }
                similarityGroups = []
                lastSyncError = CommandError(error)
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
                let historyQuery = try CullingHistoryQuery(sessionId: sessionId, limit: Self.historyWindow)
                let fetchedHistory = try await cullingAPI.history(historyQuery)
                guard generation == loadGeneration else { return }
                history = fetchedHistory
            } catch {
                guard generation == loadGeneration else { return }
                history = []
                lastSyncError = CommandError(error)
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
            errorMessage = nil
            flushDeferredDomainRefresh()
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = CommandError(error)
        }
    }
    private func filtersForCurrentState() -> CullingFilters? {
        var filters = CullingFilters()
        var active = false
        if filterState.unreviewedOnly { filters.unreviewedOnly = true; active = true }
        if let state = filterState.pickState { filters.pickStates = [state]; active = true }
        if let rating = filterState.rating { filters.ratings = [Double(rating)]; active = true }
        if let label = filterState.colorLabel { filters.colorLabels = [label]; active = true }
        if let quality = filterState.qualityStatus { filters.qualityStatus = quality; active = true }
        if filterState.metadataConflictOnly { filters.metadataConflictOnly = true; active = true }
        return active ? filters : nil
    }

    /// 任意维度变化入口：更新组合筛选状态并整页刷新；
    /// 无活跃筛选时回到"全部"范围（与原 all → scope .all 行为一致）。
    public func setFilterState(_ mutate: (inout FilterState) -> Void) async {
        mutate(&filterState)
        scopeMode = filterState.isActive ? .filtered : .all
        await loadPage(reset: true)
    }

    /// TS FilterControls 重置（setFilters({})）。
    public func resetFilters() async {
        guard filterState.isActive || scopeMode != .all else { return }
        filterState = FilterState()
        scopeMode = .all
        await loadPage(reset: true)
    }

    public func setScope(_ scope: ScopeMode) async {
        guard scopeMode != scope else { return }
        scopeMode = scope
        await loadPage(reset: true)
    }

    public func selectSimilarityGroup(_ groupId: String) async {
        guard similarityGroups.contains(where: { $0.groupId == groupId }) else { return }
        selectedSimilarityGroupId = groupId
        scopeMode = .similarityGroup
        await loadPage(reset: true)
    }
}
