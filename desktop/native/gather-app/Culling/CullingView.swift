// Phase 3.4：挑片、状态写回和同步控制 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Culling.tsx + culling.ipc.ts。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class CullingViewModel {
    /// 组合筛选状态：对齐 TS CullingFilters + FilterControls（Culling.tsx:1720-1817）——
    /// 未审/状态/星级/颜色/质量/冲突 六个维度可任意叠加，全部关闭即"全部"。
    public struct FilterState: Equatable {
        public var unreviewedOnly = false
        public var pickState: PickState?
        public var rating: Int?
        public var colorLabel: CaptureOneColorLabel?
        public var qualityStatus: CullingFilterQualityStatus?
        public var metadataConflictOnly = false

        public init() {}

        public var isActive: Bool {
            unreviewedOnly || pickState != nil || rating != nil || colorLabel != nil
                || qualityStatus != nil || metadataConflictOnly
        }
    }

    public enum ScopeMode: String, CaseIterable, Equatable {
        case all
        case filtered
        case similarityGroup

        var title: String {
            switch self {
            case .all: return GatherLocalization.l("全部照片")
            case .filtered: return GatherLocalization.l("按筛选")
            case .similarityGroup: return GatherLocalization.l("相似度分组")
            }
        }
    }

    /// 同步状态机（对齐旧版 c1-sync-controls.ts C1SyncState 语义，从
    /// MetadataSyncSummary 推导）：syncing=正在写入、c1Read=已写入待 C1 确认、
    /// safeToCleanup=全部行终态（synced>0）、synced=无行。
    public enum SyncFlowState: Equatable {
        case disconnected
        case conflict
        case failed
        case syncing
        case c1Read
        case safeToCleanup
        case synced
    }

    /// 纯函数版按钮可用性矩阵：对齐 TS deriveSyncControls({ syncState, hasWritten, acked })
    /// （tests/unit/renderer/c1-sync-controls.test.ts 的 8 组门控用例）。
    /// internal：CullingViewModelTests 直测。
    struct SyncFlowControls: Equatable {
        let canLoadMetadata: Bool
        let canConfirmSync: Bool
        let canCleanup: Bool
    }

    enum CullingSyncFlow {
        static func deriveControls(
            syncState: SyncFlowState,
            hasWritten: Bool,
            acked: Bool
        ) -> SyncFlowControls {
            switch syncState {
            case .syncing, .c1Read, .safeToCleanup:
                // syncing：可重载（无需 ack）；c1Read/safeToCleanup 同左。
                let canLoad = true
                let canConfirm: Bool
                switch syncState {
                case .safeToCleanup: canConfirm = true
                case .c1Read: canConfirm = acked && hasWritten
                default: canConfirm = false
                }
                return SyncFlowControls(
                    canLoadMetadata: canLoad,
                    canConfirmSync: canConfirm,
                    canCleanup: syncState == .safeToCleanup
                )
            case .disconnected, .conflict, .failed, .synced:
                // 保守：全部禁用。
                return SyncFlowControls(canLoadMetadata: false, canConfirmSync: false, canCleanup: false)
            }
        }
    }

    private let client: NativeCommandClient
    private let captureOne: CaptureOneBridge
    public let sessionId: String
    private(set) public var page: CullingPage?
    private(set) public var summary: CullingSummary?
    private(set) public var syncStatus: MetadataSyncSummary?
    private(set) public var history: [CullingHistoryOperation] = []
    private(set) public var conflicts: [MetadataConflict] = []
    private(set) public var isLoading = false
    private(set) public var isQualityBusy = false
    private(set) public var qualityJob: AnalysisJobData?
    private(set) public var errorMessage: String?
    private(set) public var notice: String?
    /// 同步状态/辅助查询（groups/sync_status/history/conflicts）失败时记录，
    /// 用于 UI 提示"同步状态加载失败"（业务查询失败不阻断主列表）。
    private(set) public var lastSyncError: String?
    /// reloadMetadata() 成功后才置位（对齐旧版"reload 成功才写 durable ack"语义）；
    /// confirm 按钮需 ack + written 才可用（deriveSyncControls 保守策略）。
    public private(set) var reloadAcked = false
    public var filterState = FilterState()
    public var autoAdvance = true
    /// 审计 P1-并发：可见性门控——analyzeQuality 500ms 轮询在页面离开
    /// （条件渲染销毁）后停止，避免隐藏期后台空转。
    public var isActive = true
    public private(set) var currentPhotoId: String?
    public var currentAsset: CullingAsset? {
        guard let currentPhotoId else { return page?.assets.first }
        return page?.assets.first { $0.photo.id == currentPhotoId } ?? page?.assets.first
    }
    public private(set) var selectedPhotoIds: Set<String> = []
    /// 本次会话已加载的全部 photoIds（loadMore 累加、整页刷新重置），
    /// 用于刷新时与选择集取交，避免跨页选择被静默清除。
    private var loadedPhotoIds: Set<String> = []
    private(set) public var navigationGroups: [NavigationGroup] = []
    private(set) public var isNavigationBusy = false
    public private(set) var selectedNavigationGroupId = ""
    public private(set) var selectedNavigationGroupIds: Set<String> = []
    private(set) public var similarityGroups: [CullingGroup] = []
    public var scopeMode: ScopeMode = .all
    public private(set) var selectedSimilarityGroupId = ""
    private var pageVersion = 0
    private var refreshTask: Task<Void, Never>?

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
        self.captureOne = CaptureOneBridge(router: router)
    }

    public func load() {
        loadNavigation()
        loadPage(reset: true)
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
    /// c1SyncStatus 事件（GatherEventCenter.c1SyncStatus，object 为 sessionId）的轻量刷新。
    public func refreshSyncStatus() {
        var failure: String?
        do {
            syncStatus = try client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: MetadataSyncSummary.self)
        } catch {
            failure = NativeCommandClient.message(for: error)
        }
        do {
            summary = try client.execute("culling.summary", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: CullingSummary.self)
        } catch {
            failure = failure ?? NativeCommandClient.message(for: error)
        }
        lastSyncError = failure
    }

    /// 测试注入：直接设置同步摘要，绕开命令层（CullingSyncFlowTests 直测状态机推导）。
    func applySyncSummaryForTesting(_ summary: MetadataSyncSummary?) {
        syncStatus = summary
    }

    /// TS: qualityApi.analyze + jobs.list 轮询。这里仅接入技术质量任务；
    /// 人脸推理质量按用户要求不作为本轮验收门。
    public func analyzeQuality() async {
        guard !isQualityBusy else { return }
        isQualityBusy = true
        defer { isQualityBusy = false }
        do {
            let data = try await client.executeAsync("quality.analyze", params: [
                "sessionId": .string(sessionId),
            ])
            let job = try data.decoded(as: AnalysisJobData.self)
            qualityJob = job
            notice = GatherLocalization.l("技术质量分析已排队")
            while !Task.isCancelled && isActive {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                if !isActive { return }
                let jobs = try client.execute("jobs.list", params: [:]).decoded(as: [AnalysisJobData].self)
                guard let latest = jobs.first(where: { $0.id == job.id }) else { return }
                qualityJob = latest
                switch latest.status {
                case .queued, .running, .cancelling:
                    continue
                case .succeeded:
                    notice = GatherLocalization.l("技术质量分析已完成")
                    loadPage(reset: true)
                    return
                case .failed, .interrupted:
                    errorMessage = GatherLocalization.jobErrorMessage(latest.errorMessage)
                    loadPage(reset: true)
                    return
                case .cancelled:
                    notice = GatherLocalization.l("质量分析已取消")
                    loadPage(reset: true)
                    return
                }
            }
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 取消技术质量分析任务（jobs.cancel 通道）。
    public func cancelQualityAnalysis() {
        guard let job = qualityJob else { return }
        do {
            _ = try client.execute("jobs.cancel", params: ["jobId": .string(job.id)])
            notice = GatherLocalization.l("已请求取消质量分析")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// TS: navigationApi.list —— 挑片页保留自动/手工导航组的可见入口。
    public func loadNavigation() {
        do {
            navigationGroups = try client.execute("navigation.list", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [NavigationGroup].self)
            normalizeNavigationSelection()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// TS: navigationApi.analyze(sessionId, ..., dryRun)。
    public func analyzeNavigation(dryRun: Bool) async {
        guard !isNavigationBusy else { return }
        isNavigationBusy = true
        defer { isNavigationBusy = false }
        do {
            let data = try await client.executeAsync("navigation.analyze", params: [
                "sessionId": .string(sessionId),
                "dryRun": .bool(dryRun),
            ])
            navigationGroups = try data.decoded(as: [NavigationGroup].self)
            normalizeNavigationSelection()
            notice = dryRun ? GatherLocalization.l("已生成导航组预览，未写入工作区") : GatherLocalization.l("导航组已分析并保存")
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func selectNavigationGroup(_ groupId: String) {
        guard navigationGroups.contains(where: { $0.id == groupId }) else { return }
        selectedNavigationGroupId = groupId
    }

    public func toggleNavigationGroup(_ groupId: String) {
        if selectedNavigationGroupIds.contains(groupId) {
            selectedNavigationGroupIds.remove(groupId)
        } else {
            selectedNavigationGroupIds.insert(groupId)
        }
    }

    public func splitNavigation(beforePhotoId: String) {
        guard !selectedNavigationGroupId.isEmpty, !beforePhotoId.isEmpty else {
            errorMessage = GatherLocalization.l("请选择导航组和拆分位置")
            return
        }
        do {
            navigationGroups = try client.execute("navigation.split", params: [
                "sessionId": .string(sessionId),
                "groupId": .string(selectedNavigationGroupId),
                "beforePhotoId": .string(beforePhotoId),
            ]).decoded(as: [NavigationGroup].self)
            normalizeNavigationSelection()
            notice = GatherLocalization.l("导航组已拆分")
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func mergeSelectedNavigationGroups() {
        guard selectedNavigationGroupIds.count >= 2 else {
            errorMessage = GatherLocalization.l("请选择至少两个导航组")
            return
        }
        do {
            navigationGroups = try client.execute("navigation.merge", params: [
                "sessionId": .string(sessionId),
                "groupIds": .array(selectedNavigationGroupIds.sorted().map(JSONValue.string)),
            ]).decoded(as: [NavigationGroup].self)
            selectedNavigationGroupIds = []
            normalizeNavigationSelection()
            notice = GatherLocalization.l("导航组已合并")
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 对齐旧版工具栏"从当前照片拆分"：需要当前照片在选中组内且非首张。
    public func splitCurrentFromNavigationGroup() {
        guard let current = currentPhotoId, !current.isEmpty,
              let group = navigationGroups.first(where: { $0.id == selectedNavigationGroupId }),
              let index = group.photoIds.firstIndex(of: current), index > 0 else {
            errorMessage = GatherLocalization.l("请先定位到组内非首张照片")
            return
        }
        splitNavigation(beforePhotoId: current)
    }

    /// 对齐旧版 keepInGroupRejectRest 的工具列入口：按相似组 id 定位组并决策。
    public func keepInGroupRejectRest(_ groupId: String, keepPhotoIds: [String], shouldAdvance: Bool = true) {
        guard let group = similarityGroups.first(where: { $0.groupId == groupId }) else {
            errorMessage = GatherLocalization.l("相似组已变化，请刷新后重试")
            return
        }
        decideSimilarityGroup(group, keepPhotoIds: keepPhotoIds, shouldAdvance: shouldAdvance)
    }

    private func normalizeNavigationSelection() {
        if !navigationGroups.contains(where: { $0.id == selectedNavigationGroupId }) {
            selectedNavigationGroupId = navigationGroups.first?.id ?? ""
        }
        let validIds = Set(navigationGroups.map(\.id))
        selectedNavigationGroupIds = selectedNavigationGroupIds.intersection(validIds)
    }

    /// 对齐旧版工具栏"与前组合并"：将当前选中的导航组与上一个同类型组合并。
    /// 旧版在导航组下拉选中组后提供与前一个同类型组（Burst/Scene）的合并按钮。
    public func mergeCurrentWithPreviousSameType() {
        guard let selected = navigationGroups.first(where: { $0.id == selectedNavigationGroupId }),
              let index = navigationGroups.firstIndex(where: { $0.id == selected.id }),
              let previous = navigationGroups[..<index].reversed().first(where: { $0.type == selected.type }) else {
            errorMessage = GatherLocalization.l("没有可合并的前一个同类组")
            return
        }
        selectedNavigationGroupIds = [previous.id, selected.id]
        mergeSelectedNavigationGroups()
    }

    /// 对齐旧版导航组下拉跳转：选中组后定位到该组的推荐首张照片。
    public func selectNavigationGroupAndJump(_ groupId: String) {
        guard let group = navigationGroups.first(where: { $0.id == groupId }) else { return }
        selectNavigationGroup(groupId)
        if let lead = group.leadPhotoId {
            selectCurrent(lead)
        } else if let first = group.photoIds.first {
            selectCurrent(first)
        }
    }

    public func loadMore() {
        guard !isLoading, page?.nextRowId != nil else { return }
        loadPage(reset: false)
    }

    private struct RefreshSnapshot: Sendable {
        var page: CullingPage?
        var summary: CullingSummary?
        var groups: [CullingGroup]?
        var syncStatus: MetadataSyncSummary?
        var history: [CullingHistoryOperation]?
        var conflicts: [MetadataConflict]?
        var pageError: String?
        var auxError: String?
    }

    private func applyDecisionStates(_ states: [AssetCullingState]) {
        guard let page else { return }
        let byId = Dictionary(uniqueKeysWithValues: states.map { ($0.photoId, $0) })
        var assets = page.assets
        for index in assets.indices where byId[assets[index].photo.id] != nil {
            assets[index].state = byId[assets[index].photo.id]!
        }
        pageVersion += 1
        self.page = CullingPage(assets: assets, nextRowId: page.nextRowId, total: page.total)
    }

    private func markHistoryOperation(_ id: Int, undone: Bool) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let operation = history[index]
        history[index] = CullingHistoryOperation(
            id: operation.id,
            sessionId: operation.sessionId,
            entries: operation.entries,
            undone: undone,
            createdAt: operation.createdAt
        )
    }

    private func prependHistoryOperation(
        id: Int,
        photoIds: [String],
        beforeByPhoto: [String: CullingStateSnapshot],
        afterByPhoto: [String: CullingStateSnapshot],
        revisionsByPhoto: [String: Int],
        fields: [CullingUpdatePatchField]
    ) {
        let entries: [CullingHistoryEntry] = photoIds.compactMap { photoId in
            guard let before = beforeByPhoto[photoId], let after = afterByPhoto[photoId] else { return nil }
            return CullingHistoryEntry(
                photoId: photoId,
                before: before,
                after: after,
                expectedRevision: revisionsByPhoto[photoId] ?? 0,
                fields: fields
            )
        }
        guard !entries.isEmpty else { return }
        history.insert(CullingHistoryOperation(
            id: id,
            sessionId: sessionId,
            entries: entries,
            undone: false,
            createdAt: Date().ISO8601Format()
        ), at: 0)
    }

    private func patchFields(_ patch: CullingUpdatePatch) -> [CullingUpdatePatchField] {
        var fields: [CullingUpdatePatchField] = []
        if patch.rating != nil { fields.append(.rating) }
        if patch.pickState != nil { fields.append(.pickState) }
        if patch.colorLabel != nil { fields.append(.colorLabel) }
        return fields
    }

    private func snapshot(of state: AssetCullingState) -> CullingStateSnapshot {
        CullingStateSnapshot(pickState: state.pickState, rating: state.rating, colorLabel: state.colorLabel)
    }

    private func refreshSilently() {
        refreshTask?.cancel()
        guard page != nil else { return }
        let version = pageVersion
        let client = self.client
        let sessionId = self.sessionId
        let scope: CullingScope
        switch scopeMode {
        case .all: scope = .all
        case .filtered: scope = .filtered
        case .similarityGroup: scope = .similarityGroup
        }
        let filters = filtersForCurrentState()
        let groupId = selectedSimilarityGroupId
        refreshTask = Task.detached { [client, sessionId, scope, filters, groupId, version] in
            let snapshot = Self.fetchSnapshot(
                client: client,
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
        if let syncStatus = snapshot.syncStatus { self.syncStatus = syncStatus }
        if let history = snapshot.history { self.history = history }
        if let conflicts = snapshot.conflicts { self.conflicts = conflicts }
    }

    nonisolated private static func fetchSnapshot(
        client: NativeCommandClient,
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        groupId: String
    ) -> RefreshSnapshot {
        var snapshot = RefreshSnapshot()
        var params: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "scope": .string(scope.rawValue),
            "limit": .number(500),
        ]
        if scope == .filtered, let filters {
            params["filters"] = try? JSONValue(from: filters)
        }
        if scope == .similarityGroup, !groupId.isEmpty {
            params["groupId"] = .string(groupId)
        }
        do {
            snapshot.page = try client.execute("culling.list_page", params: params).decoded(as: CullingPage.self)
        } catch {
            snapshot.pageError = NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.summary = try client.execute("culling.summary", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: CullingSummary.self)
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.groups = try client.execute("culling.groups", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [CullingGroup].self)
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.syncStatus = try client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: MetadataSyncSummary.self)
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.history = try client.execute("culling.history", params: [
                "sessionId": .string(sessionId),
                "limit": .number(100),
            ]).decoded(as: [CullingHistoryOperation].self)
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.conflicts = try client.execute("metadata.conflicts", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [MetadataConflict].self)
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        return snapshot
    }

    private func loadPage(reset: Bool) {
        isLoading = true
        defer { isLoading = false }
        do {
            let scope: CullingScope
            switch scopeMode {
            case .all: scope = .all
            case .filtered: scope = .filtered
            case .similarityGroup: scope = .similarityGroup
            }
            var params: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                "scope": .string(scope.rawValue),
                "limit": .number(500),
            ]
            if scope == .filtered, let filters = filtersForCurrentState() {
                params["filters"] = try JSONValue(from: filters)
            }
            // 对齐 TS：scope=similarity 不带 groupId 时请求全部相似组照片
            // （服务端 buildSimilarityClause(nil)）；仅显式选中某一组才下发 groupId。
            if scope == .similarityGroup, !selectedSimilarityGroupId.isEmpty {
                params["groupId"] = .string(selectedSimilarityGroupId)
            }
            if !reset, let afterRowId = page?.nextRowId {
                params["afterRowId"] = .number(Double(afterRowId))
            }
            let nextPage = try client.execute("culling.list_page", params: params).decoded(as: CullingPage.self)
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
            summary = try client.execute("culling.summary", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: CullingSummary.self)
            // 以下为辅助查询：失败保持降级（空结果）但不静默，写入 lastSyncError 由 UI 提示。
            lastSyncError = nil
            do {
                similarityGroups = try client.execute("culling.groups", params: [
                    "sessionId": .string(sessionId),
                ]).decoded(as: [CullingGroup].self)
            } catch {
                similarityGroups = []
                lastSyncError = NativeCommandClient.message(for: error)
            }
            // 对齐 TS：不自动选中第一组；未显式选组时保持空选，
            // 请求服务端全部相似组照片。
            if !similarityGroups.contains(where: { $0.groupId == selectedSimilarityGroupId }) {
                selectedSimilarityGroupId = ""
            }
            do {
                syncStatus = try client.execute("culling.sync_status", params: [
                    "sessionId": .string(sessionId),
                ]).decoded(as: MetadataSyncSummary.self)
            } catch {
                syncStatus = nil
                lastSyncError = NativeCommandClient.message(for: error)
            }
            do {
                history = try client.execute("culling.history", params: [
                    "sessionId": .string(sessionId),
                    "limit": .number(100),
                ]).decoded(as: [CullingHistoryOperation].self)
            } catch {
                history = []
                lastSyncError = NativeCommandClient.message(for: error)
            }
            do {
                conflicts = try client.execute("metadata.conflicts", params: [
                    "sessionId": .string(sessionId),
                ]).decoded(as: [MetadataConflict].self)
            } catch {
                conflicts = []
                lastSyncError = NativeCommandClient.message(for: error)
            }
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
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
    public func setFilterState(_ mutate: (inout FilterState) -> Void) {
        mutate(&filterState)
        scopeMode = filterState.isActive ? .filtered : .all
        loadPage(reset: true)
    }

    /// TS FilterControls 重置（setFilters({})）。
    public func resetFilters() {
        guard filterState.isActive || scopeMode != .all else { return }
        filterState = FilterState()
        scopeMode = .all
        loadPage(reset: true)
    }

    public func setScope(_ scope: ScopeMode) {
        guard scopeMode != scope else { return }
        scopeMode = scope
        loadPage(reset: true)
    }

    public func selectSimilarityGroup(_ groupId: String) {
        guard similarityGroups.contains(where: { $0.groupId == groupId }) else { return }
        selectedSimilarityGroupId = groupId
        scopeMode = .similarityGroup
        loadPage(reset: true)
    }

    public func decideSimilarityGroup(_ group: CullingGroup, keepPhotoIds: [String], shouldAdvance: Bool = true) {
        let validIds = Set(group.images.map(\.photoId))
        // 对齐 TS keepInGroupRejectRest：保留 1..组员数-1 张、且都在组内。
        guard !keepPhotoIds.isEmpty,
              keepPhotoIds.count < group.images.count,
              Set(keepPhotoIds).isSubset(of: validIds) else {
            errorMessage = String(format: GatherLocalization.l("请选择当前相似度组中 1 至 %lld 张照片"), max(1, group.images.count - 1))
            return
        }
        do {
            _ = try client.execute("culling.decide_group", params: [
                "sessionId": .string(sessionId),
                "groupId": .string(group.groupId),
                "keepPhotoIds": .array(keepPhotoIds.map(JSONValue.string)),
            ])
            notice = GatherLocalization.l("已更新相似度组挑片决策")
            loadPage(reset: true)
            if shouldAdvance && autoAdvance {
                jumpToNextGroup(after: group)
            }
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 对齐 TS keepInGroupRejectRest 的组前进：相似度组范围内直接切下一组；
    /// 其他范围对齐 TS（Culling.tsx:1063-1073）从当前照片之后查找第一个
    /// 不同相似度组的资产，避免跳到当前照片之前。
    private func jumpToNextGroup(after group: CullingGroup) {
        if scopeMode == .similarityGroup {
            let groups = similarityGroups
            guard let index = groups.firstIndex(where: { $0.groupId == group.groupId }),
                  let next = groups.dropFirst(index + 1).first else { return }
            selectSimilarityGroup(next.groupId)
            return
        }
        guard let assets = page?.assets, let current = currentPhotoId,
              let currentIndex = assets.firstIndex(where: { $0.photo.id == current }) else { return }
        let currentGroupId = assets[currentIndex].similarityGroupId
        guard let next = assets.dropFirst(currentIndex + 1)
            .first(where: { $0.similarityGroupId != currentGroupId }) else { return }
        currentPhotoId = next.photo.id
    }

    public func toggleSelection(_ photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
        } else {
            selectedPhotoIds.insert(photoId)
        }
    }

    public func selectAllLoaded() {
        selectedPhotoIds = Set(page?.assets.map { $0.photo.id } ?? [])
    }

    public func clearSelection() {
        selectedPhotoIds = []
    }

    /// 单张更新；nextPhotoId 非空时在刷新前预置当前照片（自动前进目标）。
    public func update(_ asset: CullingAsset, patch: CullingUpdatePatch, nextPhotoId: String? = nil) {
        do {
            let data = try client.execute("culling.update", params: [
                "sessionId": .string(sessionId),
                "photoId": .string(asset.photo.id),
                "expectedRevision": .number(Double(asset.state.revision)),
                "patch": try JSONValue(from: patch),
            ])
            let result = try data.decoded(as: CullingUpdateResult.self)
            let before = page?.assets
                .first(where: { $0.photo.id == asset.photo.id })
                .map { snapshot(of: $0.state) }
            applyDecisionStates(result.states)
            if let id = result.historyOperationId, let before {
                let afterByPhoto = Dictionary(
                    uniqueKeysWithValues: result.states.map { ($0.photoId, snapshot(of: $0)) }
                )
                let revisionsByPhoto = Dictionary(
                    uniqueKeysWithValues: result.states.map { ($0.photoId, $0.revision) }
                )
                prependHistoryOperation(
                    id: id,
                    photoIds: [asset.photo.id],
                    beforeByPhoto: [asset.photo.id: before],
                    afterByPhoto: afterByPhoto,
                    revisionsByPhoto: revisionsByPhoto,
                    fields: patchFields(patch)
                )
            }
            if let nextPhotoId { currentPhotoId = nextPhotoId }
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func batchUpdate(patch: CullingUpdatePatch) {
        guard !selectedPhotoIds.isEmpty else {
            errorMessage = GatherLocalization.l("请选择至少一张照片")
            return
        }
        do {
            let data = try client.execute("culling.batch_update", params: [
                "sessionId": .string(sessionId),
                "photoIds": .array(selectedPhotoIds.sorted().map(JSONValue.string)),
                "patch": try JSONValue(from: patch),
            ])
            let results = try data.decoded(as: [CullingUpdateResult].self)
            let beforeByPhoto = Dictionary(
                uniqueKeysWithValues: (page?.assets ?? []).compactMap { asset in
                    selectedPhotoIds.contains(asset.photo.id)
                        ? (asset.photo.id, snapshot(of: asset.state))
                        : nil
                }
            )
            applyDecisionStates(results.flatMap { $0.states })
            let afterByPhoto = Dictionary(
                uniqueKeysWithValues: results.flatMap(\.states).map { ($0.photoId, snapshot(of: $0)) }
            )
            let revisionsByPhoto = Dictionary(
                uniqueKeysWithValues: results.flatMap(\.states).map { ($0.photoId, $0.revision) }
            )
            if let id = results.first?.historyOperationId {
                prependHistoryOperation(
                    id: id,
                    photoIds: Array(beforeByPhoto.keys),
                    beforeByPhoto: beforeByPhoto,
                    afterByPhoto: afterByPhoto,
                    revisionsByPhoto: revisionsByPhoto,
                    fields: patchFields(patch)
                )
            }
            notice = String(format: GatherLocalization.l("已更新 %lld 张照片"), selectedPhotoIds.count)
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// TS commitTargets（Culling.tsx:828-906）：快捷键/工具栏决策作用于选中集，
    /// 无选中时作用于当前照片；U 待定不前进，其余决策按自动前进开关前进。
    public func commit(patch: CullingUpdatePatch, shouldAdvance: Bool = true) {
        guard !isLoading else { return }
        let targets = selectedPhotoIds.isEmpty
            ? (currentAsset.map { [$0.photo.id] } ?? [])
            : Array(selectedPhotoIds)
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            guard let asset = page?.assets.first(where: { $0.photo.id == targets[0] }) else { return }
            let nextId = shouldAdvance && autoAdvance ? nextPhotoId(after: targets[0]) : nil
            update(asset, patch: patch, nextPhotoId: nextId)
        } else {
            batchUpdate(patch: patch)
        }
    }

    public func nextPhotoId(after photoId: String) -> String? {
        guard let assets = page?.assets,
              let index = assets.firstIndex(where: { $0.photo.id == photoId }) else { return nil }
        return assets.indices.contains(index + 1) ? assets[index + 1].photo.id : nil
    }

    public func selectCurrent(_ photoId: String) {
        guard page?.assets.contains(where: { $0.photo.id == photoId }) == true else { return }
        currentPhotoId = photoId
    }

    /// TS advance：←/→ 翻页；到达已加载窗口末尾且还有下一页时后台加载。
    public func advanceCurrent() {
        guard let assets = page?.assets, !assets.isEmpty else { return }
        if let current = currentPhotoId, let index = assets.firstIndex(where: { $0.photo.id == current }) {
            if index < assets.count - 1 {
                currentPhotoId = assets[index + 1].photo.id
            } else if page?.nextRowId != nil {
                loadMore()
            }
        } else {
            currentPhotoId = assets.first?.photo.id
        }
    }

    public func retreatCurrent() {
        guard let assets = page?.assets, !assets.isEmpty else { return }
        if let current = currentPhotoId, let index = assets.firstIndex(where: { $0.photo.id == current }) {
            currentPhotoId = assets[max(0, index - 1)].photo.id
        } else {
            currentPhotoId = assets.first?.photo.id
        }
    }

    public func undo() {
        guard let operation = history.first(where: { !$0.undone }) else {
            notice = GatherLocalization.l("没有可撤销的挑片操作")
            return
        }
        applyHistory(operation, direction: .undo)
    }

    public func redo() {
        guard let operation = history.first(where: { $0.undone }) else {
            notice = GatherLocalization.l("没有可重做的挑片操作")
            return
        }
        applyHistory(operation, direction: .redo)
    }

    private func applyHistory(_ operation: CullingHistoryOperation, direction: CullingHistoryDirection) {
        do {
            let entries = try operation.entries.map { entry -> JSONValue in
                let snapshot = direction == .undo ? entry.before : entry.after
                let patch = CullingUpdatePatch(
                    rating: entry.fields.contains(.rating) ? snapshot.rating : nil,
                    pickState: entry.fields.contains(.pickState) ? snapshot.pickState : nil,
                    colorLabel: entry.fields.contains(.colorLabel) ? snapshot.colorLabel : nil
                )
                return .object([
                    "photoId": .string(entry.photoId),
                    "expectedRevision": .number(Double(entry.expectedRevision)),
                    "patch": try JSONValue(from: patch),
                ])
            }
            let data = try client.execute("culling.apply_history", params: [
                "sessionId": .string(sessionId),
                "entries": .array(entries),
                "historyOperationId": .number(Double(operation.id)),
                "direction": .string(direction.rawValue),
            ])
            let results = try data.decoded(as: [CullingUpdateResult].self)
            applyDecisionStates(results.flatMap { $0.states })
            markHistoryOperation(operation.id, undone: direction == .undo)
            notice = direction == .undo ? GatherLocalization.l("已撤销上一次挑片操作") : GatherLocalization.l("已重做挑片操作")
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func writeback(target: CullingWritebackTarget) async {
        do {
            let data = try await client.executeAsync("culling.writeback", params: [
                "sessionId": .string(sessionId),
                "target": .string(target.rawValue),
                "confirmed": .bool(true),
            ])
            do {
                syncStatus = try data.decoded(as: MetadataSyncSummary.self)
                notice = String(format: GatherLocalization.l("已写回 %@；请让 Capture One 重新加载元数据后确认同步"), targetLabel(target))
            } catch {
                syncStatus = nil
                notice = String(format: GatherLocalization.l("已写回 %@，但同步状态读取失败，请刷新页面确认"), targetLabel(target))
            }
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func flush(retry: Bool = false) async {
        do {
            let data = try await client.executeAsync(retry ? "culling.retry_sync" : "culling.flush", params: [
                "sessionId": .string(sessionId),
            ])
            do {
                syncStatus = try data.decoded(as: MetadataSyncSummary.self)
                notice = retry ? GatherLocalization.l("已重试同步队列") : GatherLocalization.l("已刷新同步队列")
            } catch {
                syncStatus = nil
                notice = retry ? GatherLocalization.l("已重试同步队列，但同步状态读取失败") : GatherLocalization.l("已刷新同步队列，但同步状态读取失败")
            }
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func retryFailedWriteback() async {
        do {
            let data = try await client.executeAsync("culling.retry_failed_writeback", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            do {
                syncStatus = try data.decoded(as: MetadataSyncSummary.self)
                notice = GatherLocalization.l("已重试失败写回项")
            } catch {
                syncStatus = nil
                notice = GatherLocalization.l("已重试失败写回项，但同步状态读取失败")
            }
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            reloadAcked = true
            notice = GatherLocalization.l("Capture One 已重新加载元数据，现在可以确认同步")
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func confirmSync() {
        do {
            _ = try client.execute("culling.confirm_sync", params: ["sessionId": .string(sessionId)])
            notice = GatherLocalization.l("已确认 Capture One 同步")
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func finalizeSync() async {
        do {
            _ = try client.execute("culling.finalize_sync", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            notice = GatherLocalization.l("已完成元数据同步")
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func cleanup() async {
        do {
            _ = try await client.executeAsync("culling.cleanup", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            notice = GatherLocalization.l("已清理可安全删除的备份")
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reset() {
        do {
            _ = try client.execute("culling.reset", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            notice = GatherLocalization.l("已重置挑片状态")
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func resolve(_ conflict: MetadataConflict, choices: [MetadataField: MetadataConflictChoice]) {
        do {
            let rawChoices = Dictionary(uniqueKeysWithValues: choices.map {
                ($0.key.rawValue, JSONValue.string($0.value.rawValue))
            })
            _ = try client.execute("metadata.resolve_conflict", params: [
                "sessionId": .string(sessionId),
                "xmpPath": .string(conflict.xmpPath),
                "choices": .object(rawChoices),
                "confirmed": .bool(true),
            ])
            notice = GatherLocalization.l("已处理元数据冲突")
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func resolve(_ conflict: MetadataConflict, choice: MetadataConflictChoice) {
        resolve(conflict, choices: Dictionary(uniqueKeysWithValues: conflict.fields.map { ($0.field, choice) }))
    }

    private func targetLabel(_ target: CullingWritebackTarget) -> String {
        switch target {
        case .rating: return GatherLocalization.l("评分")
        case .colorLabel: return GatherLocalization.l("颜色标签")
        case .keyword: return GatherLocalization.l("关键字")
        }
    }
}

public struct CullingView: View {
    @State private var viewModel: CullingViewModel
    private let router: CommandRouter
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void
    @State private var confirmReset = false
    @State private var confirmCleanup = false
    @State private var conflictChoices: [String: MetadataConflictChoice] = [:]
    @State private var compareCount = 1
    @State private var faceAlign = false
    /// 窗口级 keyDown 监听（对齐旧版 window keydown 与 Gallery 灯箱模式）：
    /// 快捷键不依赖 SwiftUI 焦点，任何控件抢焦点都不会让 P/X/U/空格/方向键失效。
    @State private var keyDownMonitor: Any?
    /// 承载本页的窗口（keyDown 监听命中判断用）。引用类型盒子保证监听闭包
    /// 读到的始终是最新窗口（struct 捕获副本无法感知后续赋值）。
    @State private var windowBox = WeakWindowBox()

    init(
        sessionId: String,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: CullingViewModel(sessionId: sessionId, router: router))
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            if viewModel.sessionId.isEmpty {
                emptyGuide(GatherLocalization.l("请先打开一个工作区，再进入挑片页。"))
            } else if viewModel.page == nil && viewModel.errorMessage == nil {
                HStack {
                    Spacer()
                    ProgressView(GatherLocalization.l("正在载入挑片工作台…"))
                        .controlSize(.large)
                        .padding(.vertical, 60)
                    Spacer()
                }
            } else if let page = viewModel.page, page.assets.isEmpty {
                // TS Culling.tsx:1157-1173：空列表时保留工具/筛选栏 + 空态文案。
                VStack(spacing: 0) {
                    toolbarRow
                    emptyGuide(GatherLocalization.l("当前范围没有照片。切换到\u{201c}全部照片\u{201d}或清除筛选条件。"))
                }
            } else {
                workbench
            }
        }
        .background(Color.gatherBackground)
        .background(WindowBridge { window in
            windowBox.window = window
        })
        .task {
            viewModel.load()
        }
        // 可见性门控（审计 P1-并发）：条件渲染页离开即销毁，isActive=false
        // 让 analyzeQuality 轮询及时退出。
        .onAppear {
            viewModel.isActive = true
            installKeyDownMonitor()
        }
        .onDisappear {
            viewModel.isActive = false
            removeKeyDownMonitor()
        }
        // 写回协调器 emitSummary 后刷新同步状态（TS useEvent('culling:sync-status')）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            viewModel.refreshSyncStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gatherMenuUndo)) { _ in
            viewModel.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gatherMenuRedo)) { _ in
            viewModel.redo()
        }
        // 对齐旧版 UX：写回/组决策等高频操作无确认弹窗（由 API 层 confirmed:true 承担）；
        // 仅保留两个破坏性操作的确认（重置挑片 / 清理备份）。
        .alert(GatherLocalization.l("确认重置挑片状态？"), isPresented: $confirmReset) {
            Button(GatherLocalization.l("重置"), role: .destructive) { viewModel.reset() }
            Button(GatherLocalization.l("取消"), role: .cancel) {}
        } message: {
            Text(GatherLocalization.l("重置只清除 Gather 中的挑片决策，不删除照片文件。"))
        }
        .alert(GatherLocalization.l("确认清理写回备份？"), isPresented: $confirmCleanup) {
            Button(GatherLocalization.l("清理"), role: .destructive) { Task { await viewModel.cleanup() } }
            Button(GatherLocalization.l("取消"), role: .cancel) {}
        } message: {
            Text(GatherLocalization.l("仅在 Capture One 已重新加载并确认同步后清理备份。"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(GatherLocalization.l("返回"), systemImage: "chevron.left", action: onBack).buttonStyle(.plain).nonFocusable()
                VStack(alignment: .leading, spacing: 3) {
                    Text(GatherLocalization.l("挑片与写回")).font(.largeTitle.weight(.bold))
                    Text(String(format: GatherLocalization.l("工作区 %@"), String(viewModel.sessionId.prefix(8)))).foregroundStyle(.secondary)
                }
                Spacer()
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings)
                Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") { viewModel.load() }.nonFocusable()
            }
            SessionTabBar(
                selection: .tab(.culling),
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
        }
        .padding(24)
        .background(Color.gatherSurface)
    }

    // MARK: 三栏工作台（对齐旧版 Culling.module.css:10-19 网格：
    // 214px 工具列 | 查看器+infoBar | 196px 胶片条；顶部工具栏横贯）。

    private var workbench: some View {
        VStack(spacing: 0) {
            toolbarRow
            GeometryReader { geometry in
                // 三栏宽度自适应（布局验收 P1 修复）：窄窗口下工具列/胶片条
                // 按比例收缩，保证查看器最小可用宽度；宽窗口维持旧版 214/196。
                // 下限 190/180：不破坏胶片条 180pt 缩略图与工具列按钮的最小宽度。
                let toolsWidth = min(214, max(190, geometry.size.width * 0.17))
                let stripWidth = min(196, max(180, geometry.size.width * 0.15))
                HStack(spacing: 0) {
                    toolsColumn
                        .frame(width: toolsWidth)
                    VStack(spacing: 0) {
                        // 查看器：对比/人脸对齐/翻页变化经 onChange 显式复位缩放
                        // （复用旧版 resetTransform 语义）。不使用 .id() 重建——
                        // 整树销毁会扰动窗口焦点/事件监听，导致快捷键与后续
                        // 点击异常。
                        CullingWorkbenchViewer(
                            viewModel: viewModel,
                            compareCount: compareCount,
                            faceAlign: faceAlign
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        infoBar
                    }
                    filmstrip
                        .frame(width: stripWidth)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // 浮动冲突面板（对齐旧版 .conflictPanel 定位：右下、infoBar 之上；
            // 宽度不超过 540，且不超过窗口可用宽 - 32）。
            GeometryReader { geometry in
                conflictPanel
                    .frame(width: min(540, geometry.size.width - 32))
                    .padding(.trailing, 14)
                    .padding(.bottom, 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    // MARK: 顶部工具栏（对齐旧版 Culling.tsx:1177-1309 的 toolbar：
    // 范围分段 + 筛选控件 + 视图操作区）。
    // 布局验收 P0 修复：拆为两行——第一行固定可见（撤销/重做 + 范围 +
    // 自动前进 + 对比 + 质量分析，高频操作不再被横向滚动隐藏）；第二行
    // 可横向滚动（筛选控件 + 导航分组操作，低频）。

    private var toolbarRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                undoRedoButtons

                Divider().frame(height: 18)

                labeledPicker(GatherLocalization.l("范围")) {
                    Picker(GatherLocalization.l("范围"), selection: scopeBinding) {
                        ForEach(CullingViewModel.ScopeMode.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .nonFocusable()
                }

                Toggle(GatherLocalization.l("自动前进"), isOn: autoAdvanceBinding)
                    .toggleStyle(.checkbox)
                    .nonFocusable()

                labeledPicker(GatherLocalization.l("对比")) {
                    Picker(GatherLocalization.l("对比"), selection: $compareCount) {
                        Text(GatherLocalization.l("单图")).tag(1)
                        Text(GatherLocalization.l("2 图")).tag(2)
                        Text(GatherLocalization.l("4 图")).tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .nonFocusable()
                }

                Spacer(minLength: 12)

                qualityAnalysisBlock
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Toggle(GatherLocalization.l("仅未处理"), isOn: unreviewedOnlyBinding)
                        .toggleStyle(.checkbox)
                        .nonFocusable()
                    labeledPicker(GatherLocalization.l("状态")) {
                        Picker(GatherLocalization.l("状态"), selection: pickStateBinding) {
                            Text(GatherLocalization.l("全部状态")).tag(PickState?.none)
                            ForEach(PickState.allCases, id: \.self) { state in
                                Text(pickStateTitle(state)).tag(PickState?.some(state))
                            }
                        }
                        .fixedSize()
                        .nonFocusable()
                    }
                    labeledPicker(GatherLocalization.l("星级")) {
                        Picker(GatherLocalization.l("星级"), selection: ratingBinding) {
                            Text(GatherLocalization.l("全部星级")).tag(Int?.none)
                            ForEach(0...5, id: \.self) { rating in
                                Text(rating == 0 ? GatherLocalization.l("未评级") : String(format: GatherLocalization.l("%lld 星"), rating)).tag(Int?.some(rating))
                            }
                        }
                        .fixedSize()
                        .nonFocusable()
                    }
                    labeledPicker(GatherLocalization.l("颜色")) {
                        Picker(GatherLocalization.l("颜色"), selection: colorFilterBinding) {
                            Text(GatherLocalization.l("全部颜色")).tag(CaptureOneColorLabel?.none)
                            ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                                Text(Self.colorLabelTitle(label)).tag(CaptureOneColorLabel?.some(label))
                            }
                        }
                        .fixedSize()
                        .nonFocusable()
                    }
                    labeledPicker(GatherLocalization.l("质量")) {
                        Picker(GatherLocalization.l("质量"), selection: qualityStatusBinding) {
                            Text(GatherLocalization.l("全部分析状态")).tag(CullingFilterQualityStatus?.none)
                            Text(GatherLocalization.l("已分析")).tag(CullingFilterQualityStatus?.some(.analysed))
                            Text(GatherLocalization.l("未分析")).tag(CullingFilterQualityStatus?.some(.unanalysed))
                            Text(GatherLocalization.l("分析失败")).tag(CullingFilterQualityStatus?.some(.failed))
                        }
                        .fixedSize()
                        .nonFocusable()
                    }
                    Toggle(GatherLocalization.l("仅 XMP 冲突"), isOn: conflictOnlyBinding)
                        .toggleStyle(.checkbox)
                        .nonFocusable()
                    Button(GatherLocalization.l("重置")) { viewModel.resetFilters() }.nonFocusable()

                    Divider().frame(height: 18)

                    Toggle(GatherLocalization.l("人脸对齐"), isOn: $faceAlign)
                        .toggleStyle(.checkbox)
                        .nonFocusable()

                    Button(GatherLocalization.l("保存 Burst/Scene 分组")) {
                        Task { await viewModel.analyzeNavigation(dryRun: false) }
                    }
                    .disabled(viewModel.isNavigationBusy)
                    .nonFocusable()
                    Button(GatherLocalization.l("预览分组")) {
                        Task { await viewModel.analyzeNavigation(dryRun: true) }
                    }
                    .disabled(viewModel.isNavigationBusy)
                    .nonFocusable()

                    if !viewModel.navigationGroups.isEmpty {
                        labeledPicker(String(format: GatherLocalization.l("导航组 (%lld)"), viewModel.navigationGroups.count)) {
                            Picker(String(format: GatherLocalization.l("导航组 (%lld)"), viewModel.navigationGroups.count), selection: navigationGroupBinding) {
                                ForEach(viewModel.navigationGroups, id: \.id) { group in
                                    let leadLabel = group.leadPhotoId
                                        .flatMap { lead in group.photoIds.firstIndex(of: lead) }
                                        .map { String(format: GatherLocalization.l(" · 推荐 %lld"), $0 + 1) } ?? ""
                                    Text(String(format: GatherLocalization.l("%@ · %lld 张%@"), group.type == .burst ? "Burst" : "Scene", group.photoIds.count, leadLabel)).tag(group.id)
                                }
                            }
                            .fixedSize()
                            .nonFocusable()
                        }
                        Button(GatherLocalization.l("从当前照片拆分")) {
                            viewModel.splitCurrentFromNavigationGroup()
                        }
                        .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)
                        .nonFocusable()
                        Button(GatherLocalization.l("与前组合并")) {
                            viewModel.mergeCurrentWithPreviousSameType()
                        }
                        .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)
                        .nonFocusable()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
        }
        .background(Color.gatherSurface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var undoRedoButtons: some View {
                HStack(spacing: 4) {
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .disabled(viewModel.history.first(where: { !$0.undone }) == nil || isBusy)
            .help(GatherLocalization.l("撤销（⌘Z）"))
            .nonFocusable()
            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .disabled(viewModel.history.first(where: { $0.undone }) == nil || isBusy)
            .help(GatherLocalization.l("重做（⇧⌘Z）"))
            .nonFocusable()
        }
    }

    private var qualityAnalysisBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(viewModel.isQualityBusy ? GatherLocalization.l("质量分析中…") : GatherLocalization.l("分析技术质量")) {
                Task { await viewModel.analyzeQuality() }
            }
            .disabled(viewModel.isQualityBusy)
            .nonFocusable()
            if let job = viewModel.qualityJob, job.progressTotal > 0,
               job.status == .queued || job.status == .running || job.status == .cancelling {
                ProgressView(
                    value: Double(min(job.progressCurrent, job.progressTotal)),
                    total: Double(job.progressTotal)
                )
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 150)
                HStack(spacing: 6) {
                    Text("\(qualityProgressPercent(job))% \(GatherLocalization.progressPhaseText(job.progressMessage))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(GatherLocalization.l("取消")) {
                        viewModel.cancelQualityAnalysis()
                    }
                    .font(.caption2)
                    .nonFocusable()
                }
            }
        }
    }

    private func labeledPicker<PickerView: View>(
        _ title: String,
        @ViewBuilder picker: () -> PickerView
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            picker().labelsHidden()
        }
    }

    // MARK: 工具列（grid-column 1：决策条 / 星级 / 颜色 / 相似组决策 / 选择管理）。

    private var toolsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(GatherLocalization.l("挑片工具"))
                    .font(.footnote.weight(.semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 决策条（对齐旧版 decisionBar：✓ 保留 P / × 淘汰 X / ○ 未处理 U）。
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.selectedPhotoIds.isEmpty ? GatherLocalization.l("当前照片") : String(format: GatherLocalization.l("批量 %lld 张"), viewModel.selectedPhotoIds.count))
                        .controlLabelStyle()
                    HStack(spacing: 6) {
                        decisionButton(icon: "checkmark", iconColor: GatherTheme.success, title: GatherLocalization.l("保留"), shortcut: "P") {
                            viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
                        }
                        decisionButton(icon: "xmark", iconColor: GatherTheme.error, title: GatherLocalization.l("淘汰"), shortcut: "X") {
                            viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected))
                        }
                        decisionButton(icon: "circle", iconColor: .secondary, title: GatherLocalization.l("未处理"), shortcut: "U") {
                            viewModel.commit(patch: CullingUpdatePatch(pickState: .unreviewed), shouldAdvance: false)
                        }
                    }
                }
                .controlGroupStyle()

                // 星级（对齐旧版 ratingButton 0-5 数字+星，当前照片星级高亮）。
                VStack(alignment: .leading, spacing: 6) {
                    Text(GatherLocalization.l("星级")).controlLabelStyle()
                    HStack(spacing: 6) {
                        ForEach(0...5, id: \.self) { rating in
                            let isCurrent = (viewModel.currentAsset?.state.rating ?? 0) == Double(rating)
                            Button(rating == 0 ? "0" : "\(rating)★") {
                                viewModel.commit(patch: CullingUpdatePatch(rating: Double(rating)))
                            }
                            .buttonStyle(.plain)
                            .font(.footnote)
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: GatherTheme.Radius.sm)
                                    .fill(isCurrent ? GatherTheme.primarySoft : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: GatherTheme.Radius.sm)
                                    .stroke(isCurrent ? GatherTheme.primary : Color.gatherBorder, lineWidth: 1)
                            )
                            .disabled(isBusy)
                            .help(String(format: GatherLocalization.l("评分 %lld"), rating))
                            .accessibilityLabel(String(format: GatherLocalization.l("评分 %lld"), rating))
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                            .nonFocusable()
                        }
                    }
                }
                .controlGroupStyle()

                // 颜色（对齐旧版 colorButton 圆形色钮 + 选中外环）。
                VStack(alignment: .leading, spacing: 6) {
                    Text(GatherLocalization.l("颜色")).controlLabelStyle()
                    HStack(spacing: 4) {
                        ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                            let isCurrent = viewModel.currentAsset?.state.colorLabel == label
                            Button {
                                viewModel.commit(patch: CullingUpdatePatch(colorLabel: label))
                            } label: {
                                Circle()
                                    .fill(Self.colorDot(label))
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle().stroke(Color.black.opacity(0.35), lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                            .overlay(
                                Circle()
                                    .stroke(isCurrent ? Color(nsColor: .secondaryLabelColor) : Color.clear, lineWidth: 2)
                                    .padding(-3)
                            )
                            .help(Self.colorLabelTitle(label))
                            .accessibilityLabel(Self.colorLabelTitle(label))
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                            .disabled(isBusy)
                            .nonFocusable()
                        }
                    }
                }
                .controlGroupStyle()

                // 相似组决策（对齐旧版 groupDecision：仅当前照片所在组 >1 张时显示）。
                if currentGroupAssets.count > 1, let current = viewModel.currentAsset {
                    let groupIds = Set(currentGroupAssets.map(\.photo.id))
                    let selectedInGroup = viewModel.selectedPhotoIds.intersection(groupIds)
                    let keepValid = !selectedInGroup.isEmpty && selectedInGroup.count < currentGroupAssets.count
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: GatherLocalization.l("相似组 · %lld 张"), currentGroupAssets.count)).controlLabelStyle()
                        Button(GatherLocalization.l("保留当前 1 张")) {
                            viewModel.keepInGroupRejectRest(
                                current.similarityGroupId ?? "",
                                keepPhotoIds: [current.photo.id]
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(isBusy)
                        .nonFocusable()
                        Button(selectedInGroup.isEmpty ? GatherLocalization.l("保留已选 K 张") : String(format: GatherLocalization.l("保留已选 %lld 张"), selectedInGroup.count)) {
                            viewModel.keepInGroupRejectRest(
                                current.similarityGroupId ?? "",
                                keepPhotoIds: selectedInGroup.sorted()
                            )
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(!keepValid || isBusy)
                        .nonFocusable()
                        .help(keepValid ? "" : GatherLocalization.l("按住 ⌘ 或 Ctrl 在胶片中选择要保留的照片"))
                        Text(GatherLocalization.l("其余照片自动淘汰"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .controlGroupStyle()
                    .padding(.top, 10)
                }

                if !viewModel.selectedPhotoIds.isEmpty {
                    Button(GatherLocalization.l("取消选择")) { viewModel.clearSelection() }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .nonFocusable()
                }

                Spacer(minLength: 12)

                // 附加统计（对齐 summaryCard 的增强项：已评分/已标记）。
                if let summary = viewModel.summary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: GatherLocalization.l("评分 %lld"), summary.rated)).controlLabelStyle()
                        Text(String(format: GatherLocalization.l("标记 %lld"), summary.labeled)).controlLabelStyle()
                    }
                    .controlGroupStyle()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .background(Color.gatherSurface)
        .overlay(alignment: .trailing) { Divider() }
    }

    private func decisionButton(
        icon: String,
        iconColor: Color,
        title: String,
        shortcut: String,
        action: @escaping () -> Void
    ) -> some View {
        DecisionButtonView(
            icon: icon,
            iconColor: iconColor,
            title: title,
            shortcut: shortcut,
            isBusy: isBusy,
            action: action
        )
        .nonFocusable()
    }

    // MARK: infoBar（grid-row 3：位置计数 + 保留/淘汰/未处理统计 + 同步状态 + 同步按钮）。

    private var infoBar: some View {
        HStack(spacing: 12) {
            if let page = viewModel.page {
                Text("\(currentIndex + 1) / \(viewModel.page?.total ?? page.assets.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.gatherTextPrimary)
            }
            if let summary = viewModel.summary {
                Text(String(format: GatherLocalization.l("保留 %lld"), summary.kept))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.success)
                Text(String(format: GatherLocalization.l("淘汰 %lld"), summary.rejected))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.error)
                Text(String(format: GatherLocalization.l("未处理 %lld"), summary.pending))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // linkedNotice：同名 RAW/JPEG 共享 XMP 提示（对齐旧版 Culling.tsx:1393-1397）。
            if let current = viewModel.currentAsset, current.linkedVariantCount > 1 {
                Text(String(format: GatherLocalization.l("同名 RAW/JPEG 共用 XMP，星级和颜色将同步到 %lld 个条目"), current.linkedVariantCount))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(1)
            }
            Spacer()
            if let sync = viewModel.syncStatus {
                Text(syncStatusText(sync))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(sync.failed + sync.conflict > 0 ? GatherTheme.error : GatherTheme.success)
            }
            if let syncError = viewModel.lastSyncError {
                Text(syncError)
                    .font(.footnote)
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(1)
                    .help(syncError)
                Button(GatherLocalization.l("重试")) { viewModel.load() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(GatherTheme.error)
                    .nonFocusable()
            }
            Menu {
                Button(GatherLocalization.l("立即写入 XMP")) { Task { await viewModel.flush() } }
                    .disabled(isBusy)
                if (viewModel.syncStatus?.written ?? 0) > 0 {
                    Button(GatherLocalization.l("在 Capture One 中加载元数据")) { Task { await viewModel.reloadCaptureOne() } }
                        .disabled(!viewModel.canLoadMetadata || isBusy)
                        .help(syncLoadHint)
                    Button(GatherLocalization.l("已在 Capture One 加载")) { viewModel.confirmSync() }
                        .disabled(!viewModel.canConfirmSync || isBusy)
                        .help(syncConfirmHint)
                }
                if (viewModel.syncStatus?.failed ?? 0) > 0 {
                    Button(GatherLocalization.l("重试失败项")) { Task { await viewModel.retryFailedWriteback() } }
                        .disabled(isBusy)
                }
                if (viewModel.syncStatus?.synced ?? 0) > 0 {
                    Button(GatherLocalization.l("保留 XMP 并结束")) { Task { await viewModel.finalizeSync() } }
                        .disabled(isBusy)
                    Button(GatherLocalization.l("恢复原 XMP"), role: .destructive) { confirmCleanup = true }
                        .disabled(!viewModel.canCleanup)
                        .help(syncCleanupHint)
                }
            } label: {
                Label(GatherLocalization.l("同步…"), systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .nonFocusable()
            .help(GatherLocalization.l("先在 Capture One 中 Load Metadata，再返回 Gather 确认同步"))
            Button(GatherLocalization.l("重置挑片"), role: .destructive) { confirmReset = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(GatherTheme.error)
                .nonFocusable()
        }
        .font(.footnote)
        .padding(.horizontal, 24)
        .frame(minHeight: 36)
        .background(Color.gatherSurface)
        .overlay(alignment: .top) { Divider() }
    }

    private var isBusy: Bool {
        viewModel.isLoading || viewModel.isNavigationBusy || viewModel.isQualityBusy
    }

    private func qualityProgressPercent(_ job: AnalysisJobData) -> Int {
        guard job.progressTotal > 0 else { return 0 }
        return min(100, max(0, Int((Double(job.progressCurrent) / Double(job.progressTotal) * 100).rounded())))
    }

    /// 逐按钮禁用 hint（对齐旧版 c1-sync-controls.ts 的独立 title 提示粒度）。
    private var syncLoadHint: String {
        switch viewModel.syncFlowState() {
        case .synced: return GatherLocalization.l("已完成同步，无需再次加载元数据")
        case .failed: return GatherLocalization.l("存在写入失败项，请先重试")
        case .conflict: return GatherLocalization.l("存在 XMP 冲突，请先裁决")
        default: return GatherLocalization.l("没有可加载的已写入元数据")
        }
    }

    private var syncConfirmHint: String {
        switch viewModel.syncFlowState() {
        case .synced: return GatherLocalization.l("已完成同步")
        default:
            return viewModel.reloadAcked
                ? GatherLocalization.l("请先等待写入完成或处理失败项")
                : GatherLocalization.l("请先在 Capture One 中加载元数据，再确认同步")
        }
    }

    private var syncCleanupHint: String {
        viewModel.syncFlowState() == .synced
            ? GatherLocalization.l("已完成清理")
            : GatherLocalization.l("请先加载元数据并确认同步，再执行清理")
    }

    // MARK: 胶片条（grid-column 3：122pt 缩略图 + 色标线 + 星级 + 决策圆点 + 文件名）。

    private var filmstrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text(GatherLocalization.l("胶片"))
                    .font(.footnote.weight(.semibold))
                    .kerning(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                if let page = viewModel.page {
                    Text("\(page.assets.count)\(page.total > page.assets.count ? " / \(page.total)" : "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.gatherSurface)
            .overlay(alignment: .bottom) { Divider() }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array((viewModel.page?.assets ?? []).enumerated()), id: \.element.photo.id) { index, asset in
                            CullingFilmThumbView(viewModel: viewModel, asset: asset)
                                .id(asset.photo.id)
                                // 滚动近底自动续页（对齐旧版胶片条 scrollTop < 400px 触发 loadMore）。
                                .onAppear {
                                    let count = viewModel.page?.assets.count ?? 0
                                    if index >= count - 4, viewModel.page?.nextRowId != nil {
                                        viewModel.loadMore()
                                    }
                                }
                        }
                        if viewModel.page?.nextRowId != nil {
                            Button(viewModel.isLoading ? GatherLocalization.l("加载中…") : GatherLocalization.l("加载更多")) {
                                viewModel.loadMore()
                            }
                            .disabled(viewModel.isLoading)
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                            .nonFocusable()
                        }
                    }
                    .padding(8)
                }
                // 当前照片自动滚动（对齐旧版 scrollIntoView block:nearest）。
                .onChange(of: viewModel.currentPhotoId) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .background(Color.gatherSurface)
        .overlay(alignment: .leading) { Divider() }
    }

    private var currentIndex: Int {
        guard let id = viewModel.currentPhotoId,
              let found = viewModel.page?.assets.firstIndex(where: { $0.photo.id == id }) else { return 0 }
        return found
    }

    /// 当前照片所在相似组（已加载范围内）成员，对齐 TS currentGroupAssets。
    private var currentGroupAssets: [CullingAsset] {
        guard let current = viewModel.currentAsset, let groupId = current.similarityGroupId else { return [] }
        return viewModel.page?.assets.filter { $0.similarityGroupId == groupId } ?? []
    }

    // MARK: 浮动冲突面板（对齐旧版 .conflictPanel：每次展示一个冲突，应用后进入下一个）。

    @ViewBuilder
    private var conflictPanel: some View {
        if let conflict = viewModel.conflicts.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(GatherLocalization.l("XMP 字段冲突")).font(.headline)
                    Spacer()
                    Text(URL(fileURLWithPath: conflict.xmpPath).lastPathComponent)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(conflict.xmpPath)
                }
                ForEach(conflict.fields, id: \.field.rawValue) { field in
                    let key = "\(conflict.xmpPath)|\(field.field.rawValue)"
                    HStack(spacing: 8) {
                        Text(metadataFieldTitle(field.field))
                            .font(.callout.weight(.semibold))
                            .frame(width: 44, alignment: .leading)
                        Text(String(format: GatherLocalization.l("Gather：%@"), valueLabel(field.local)))
                            .font(.callout)
                            .lineLimit(1)
                            .help(valueLabel(field.local))
                        Text(String(format: GatherLocalization.l("外部：%@"), valueLabel(field.remote)))
                            .font(.callout)
                            .lineLimit(1)
                            .help(valueLabel(field.remote))
                        Text(GatherLocalization.l("处理"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker(GatherLocalization.l("处理"), selection: Binding(
                            get: { conflictChoices[key] ?? .keepLocal },
                            set: { conflictChoices[key] = $0 }
                        )) {
                            Text(GatherLocalization.l("保留 Gather")).tag(MetadataConflictChoice.keepLocal)
                            Text(GatherLocalization.l("采用外部值")).tag(MetadataConflictChoice.useRemote)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .nonFocusable()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.gatherBackground))
                }
                HStack {
                    Text(viewModel.conflicts.count > 1
                        ? String(format: GatherLocalization.l("还有 %lld 个冲突"), viewModel.conflicts.count - 1)
                        : GatherLocalization.l("这是最后一个冲突"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(GatherLocalization.l("应用并继续写入")) {
                        let choices = Dictionary(uniqueKeysWithValues: conflict.fields.map { field in
                            (field.field, conflictChoices["\(conflict.xmpPath)|\(field.field.rawValue)"] ?? .keepLocal)
                        })
                        viewModel.resolve(conflict, choices: choices)
                    }
                    .font(.footnote)
                    .nonFocusable()
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gatherSurface))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(GatherTheme.error.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: GatherTheme.shadowMd, radius: 12, y: 6)
        }
    }

    // MARK: 键盘快捷键（对齐 Culling.tsx:1109-1149 window keydown handler）。
    // 0-5 评分、P/空格 保留、X 淘汰、U 未处理（不前进）、←/→ 翻页；
    // Cmd+Z / Shift+Cmd+Z 由宿主菜单 post gatherMenuUndo/gatherMenuRedo 通知驱动。
    // 实现为窗口级 NSEvent 局部监听（Gallery 灯箱同款模式）：与 SwiftUI 焦点
    // 系统解耦——点击勾选框/按钮/弹窗后快捷键依然生效，对齐旧版 window keydown。

    private func installKeyDownMonitor() {
        removeKeyDownMonitor()
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = self.windowBox.window,
                  event.window === window,
                  window.isKeyWindow else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeKeyDownMonitor() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

    /// 处理裸键快捷键；返回 nil 表示已消费该事件。
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard !viewModel.isLoading, !viewModel.isNavigationBusy, !viewModel.isQualityBusy else {
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.isEmpty else {
            return event
        }
        if event.keyCode == 123 {
            viewModel.retreatCurrent()
            return nil
        }
        if event.keyCode == 124 {
            viewModel.advanceCurrent()
            return nil
        }
        let character = (event.charactersIgnoringModifiers ?? "").lowercased()
        if character == " " || character == "p" {
            viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
            return nil
        }
        if character == "x" {
            viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected))
            return nil
        }
        if character == "u" {
            viewModel.commit(patch: CullingUpdatePatch(pickState: .unreviewed), shouldAdvance: false)
            return nil
        }
        if character.count == 1, let rating = Int(character), (0...5).contains(rating) {
            viewModel.commit(patch: CullingUpdatePatch(rating: Double(rating)))
            return nil
        }
        return event
    }

    private func emptyGuide(_ text: String) -> some View {
        GatherEmptyState(icon: "photo.on.rectangle.angled", message: text)
            .padding(.vertical, 48)
    }

    /// 颜色标签色点（供胶片条/工具列/筛选卡共用）。
    fileprivate static func colorDot(_ label: CaptureOneColorLabel) -> Color {
        switch label {
        case .none: return Color(hex: 0x777777)
        case .red: return Color(hex: 0xef5350)
        case .orange: return Color(hex: 0xff9800)
        case .yellow: return Color(hex: 0xfdd835)
        case .green: return Color(hex: 0x4caf50)
        case .blue: return Color(hex: 0x42a5f5)
        case .pink: return Color(hex: 0xec407a)
        case .purple: return Color(hex: 0xab47bc)
        }
    }

    /// 颜色标签中文文案（对齐 LibraryView.swift LibraryColorOption.label 表）。
    fileprivate static func colorLabelTitle(_ label: CaptureOneColorLabel) -> String {
        switch label {
        case .none: return GatherLocalization.l("无")
        case .red: return GatherLocalization.l("红")
        case .orange: return GatherLocalization.l("橙")
        case .yellow: return GatherLocalization.l("黄")
        case .green: return GatherLocalization.l("绿")
        case .blue: return GatherLocalization.l("蓝")
        case .pink: return GatherLocalization.l("粉")
        case .purple: return GatherLocalization.l("紫")
        }
    }

    private func metadataFieldTitle(_ field: MetadataField) -> String {
        switch field {
        case .rating: return GatherLocalization.l("星级")
        case .label: return GatherLocalization.l("颜色")
        case .keywords: return GatherLocalization.l("关键词")
        }
    }

    private func valueLabel(_ value: GatherCore.JSONValue) -> String {
        switch value {
        case .null: return GatherLocalization.l("空")
        case .bool(let value): return value ? GatherLocalization.l("是") : GatherLocalization.l("否")
        case .number(let value): return String(value)
        case .string(let value): return value.isEmpty ? GatherLocalization.l("空") : value
        case .array(let values): return values.map(valueLabel).joined(separator: ", ")
        case .object: return GatherLocalization.l("对象")
        }
    }

    /// 对齐旧版 syncLabel 六档文案：已同步 / N 个冲突 / N 个失败 /
    /// N 待写入 / N 已写入 / N 已载入。
    private func syncStatusText(_ sync: MetadataSyncSummary) -> String {
        if sync.items.isEmpty { return GatherLocalization.l("XMP 已同步") }
        if sync.conflict > 0 { return String(format: GatherLocalization.l("%lld 个 XMP 冲突"), sync.conflict) }
        if sync.failed > 0 { return String(format: GatherLocalization.l("%lld 个 XMP 写入失败"), sync.failed) }
        if sync.pending + sync.writing > 0 { return String(format: GatherLocalization.l("%lld 个 XMP 等待写入"), sync.pending + sync.writing) }
        if sync.written > 0 { return String(format: GatherLocalization.l("%lld 个 XMP 已写入，等待 Capture One 加载"), sync.written) }
        if sync.synced > 0 { return String(format: GatherLocalization.l("%lld 个 XMP 已确认加载"), sync.synced) }
        return GatherLocalization.l("XMP 已同步")
    }

    // MARK: 筛选/范围绑定（组合筛选状态，任意变化触发整页刷新）

    private var unreviewedOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filterState.unreviewedOnly },
            set: { value in viewModel.setFilterState { $0.unreviewedOnly = value } }
        )
    }

    private var pickStateBinding: Binding<PickState?> {
        Binding(
            get: { viewModel.filterState.pickState },
            set: { value in viewModel.setFilterState { $0.pickState = value } }
        )
    }

    private var ratingBinding: Binding<Int?> {
        Binding(
            get: { viewModel.filterState.rating },
            set: { value in viewModel.setFilterState { $0.rating = value } }
        )
    }

    private var colorFilterBinding: Binding<CaptureOneColorLabel?> {
        Binding(
            get: { viewModel.filterState.colorLabel },
            set: { value in viewModel.setFilterState { $0.colorLabel = value } }
        )
    }

    private var qualityStatusBinding: Binding<CullingFilterQualityStatus?> {
        Binding(
            get: { viewModel.filterState.qualityStatus },
            set: { value in viewModel.setFilterState { $0.qualityStatus = value } }
        )
    }

    private var conflictOnlyBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filterState.metadataConflictOnly },
            set: { value in viewModel.setFilterState { $0.metadataConflictOnly = value } }
        )
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoAdvance },
            set: { viewModel.autoAdvance = $0 }
        )
    }

    private var scopeBinding: Binding<CullingViewModel.ScopeMode> {
        Binding(
            get: { viewModel.scopeMode },
            set: { viewModel.setScope($0) }
        )
    }

    private var navigationGroupBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedNavigationGroupId },
            set: { viewModel.selectNavigationGroupAndJump($0) }
        )
    }
}

/// 决策按钮：SF Symbol 图标 + 快捷键字母，自绘卡片描边，hover 高亮。
private struct DecisionButtonView: View {
    let icon: String
    let iconColor: Color
    let title: String
    let shortcut: String
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                Text(shortcut)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.md)
                .fill(isHovering ? GatherTheme.primarySoft.opacity(0.4) : Color.gatherSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.md)
                .stroke(Color.gatherBorder, lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .disabled(isBusy)
        .help(title)
        .accessibilityLabel("\(title) \(shortcut)")
    }
}

/// 胶片缩略图：122pt 方图 + 4pt 色标线 + 左上星级 + 右上决策圆点 + 底部文件名。
/// 点击选择当前照片；⌘/Ctrl/Shift 点击切换多选（对齐旧版 Culling.tsx:1509-1530）。
private struct CullingFilmThumbView: View {
    let viewModel: CullingViewModel
    let asset: CullingAsset

    private var isCurrent: Bool {
        viewModel.currentPhotoId == asset.photo.id
    }

    private var isSelected: Bool {
        viewModel.selectedPhotoIds.contains(asset.photo.id)
    }

    private var borderColor: Color {
        if isCurrent { return GatherTheme.primary }
        if isSelected { return GatherTheme.warning }
        return .clear
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.intersection([.command, .control, .shift]) != [] {
                viewModel.toggleSelection(asset.photo.id)
            } else {
                viewModel.selectCurrent(asset.photo.id)
            }
        } label: {
            ZStack(alignment: .bottom) {
                PhotoThumbnailView(
                    path: asset.photo.filepath,
                    size: 256,
                    placeholderSize: CGSize(width: 180, height: 122)
                )
                .frame(width: 180, height: 122)
                .clipped()
                if asset.state.colorLabel != .none {
                    Rectangle()
                        .fill(CullingView.colorDot(asset.state.colorLabel))
                        .frame(height: 4)
                }
                if asset.state.rating > 0 {
                    Text("\(Int(asset.state.rating))★")
                        .font(.footnote)
                        .foregroundStyle(GatherTheme.warning)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(4)
                }
                if asset.state.pickState != .unreviewed {
                    Circle()
                        .fill(asset.state.pickState == .picked ? GatherTheme.success : GatherTheme.error)
                        .frame(width: 9, height: 9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                }
                Text(asset.photo.filename)
                    .font(.footnote)
                    .foregroundStyle(GatherTheme.viewerTextPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(GatherTheme.viewerBackground.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(GatherLocalization.l("保留")) {
                viewModel.update(
                    asset,
                    patch: CullingUpdatePatch(pickState: .picked),
                    nextPhotoId: viewModel.autoAdvance ? viewModel.nextPhotoId(after: asset.photo.id) : nil
                )
            }
            Button(GatherLocalization.l("淘汰")) {
                viewModel.update(
                    asset,
                    patch: CullingUpdatePatch(pickState: .rejected),
                    nextPhotoId: viewModel.autoAdvance ? viewModel.nextPhotoId(after: asset.photo.id) : nil
                )
            }
            Button(GatherLocalization.l("未处理")) {
                viewModel.update(asset, patch: CullingUpdatePatch(pickState: .unreviewed))
            }
            if let url = Self.finderURL(for: asset.photo.filepath) {
                Divider()
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .frame(height: 122)
        .nonFocusable()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 2))
        .opacity(isCurrent || isSelected ? 1 : 0.78)
        .help(asset.photo.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thumbAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 右键「在 Finder 中显示」的 URL：路径为空时返回 nil（跳过该项）。
    private static func finderURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    private var thumbAccessibilityLabel: String {
        let ratingText = asset.state.rating > 0
            ? String(format: GatherLocalization.l("%lld 星"), Int(asset.state.rating))
            : GatherLocalization.l("未评级")
        return "\(asset.photo.filename)，\(ratingText)，\(pickStateTitle(asset.state.pickState))"
    }
}

/// 查看器对比网格单元格：按已加载顺序（order 0 = 当前照片）。
private struct ViewerCell: Identifiable {
    let id: String
    let order: Int
    let asset: CullingAsset
}

/// 工作台内嵌查看器：对齐旧版查看器核心能力——1/2/4 张对比（4 张为 2x2 网格）、
/// 滚轮缩放（1.15/0.87，范围 1..8）+ 任意缩放级拖拽平移 + 双击复位 + zoomHint、
/// 每格字幕（文件名 + 来源 + 星级/未评级）+ 保留/淘汰徽标 + 无脸徽标 + 质量徽标。
private struct CullingWorkbenchViewer: View {
    let viewModel: CullingViewModel
    let compareCount: Int
    let faceAlign: Bool

    @State private var scale = 1.0
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    @State private var hoveredCellId: String?
    @State private var imageFrame: CGRect = .zero
    @State private var wheelMonitor: Any?
    @State private var viewerWindow: NSWindow?

    /// 当前已加载列表（viewModel.page 变化经 @Observable 自动回流）。
    private var assets: [CullingAsset] {
        viewModel.page?.assets ?? []
    }

    /// 当前项下标：按 photo.id 查找；找不到时回退 0（非空列表）。
    private var currentIndex: Int {
        guard let id = viewModel.currentPhotoId,
              let found = assets.firstIndex(where: { $0.photo.id == id }) else { return 0 }
        return found
    }

    /// 越界保护的下标访问；列表为空时返回 nil。
    private var currentAsset: CullingAsset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    /// 面部对齐时的有效缩放（旧版 faceAlign 下 scale 下限 2）。
    private var effectiveScale: Double {
        faceAlign ? max(2, scale) : scale
    }

    var body: some View {
        GeometryReader { geometry in
            let visible = comparisonAssets()
            let cellGroups = groupCells(visible)
            let columns = visible.count > 1 ? 2 : 1
            let cellWidth = columns > 1 ? (geometry.size.width - 8) / 2 : geometry.size.width
            let cellHeight = cellGroups.count > 1 ? (geometry.size.height - 8) / 2 : geometry.size.height
            VStack(spacing: 8) {
                ForEach(0..<cellGroups.count, id: \.self) { rowIndex in
                    HStack(spacing: 8) {
                        ForEach(cellGroups[rowIndex]) { cell in
                            cellView(cell)
                                .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                // 记录图像区域在窗口坐标系中的位置，用于滚轮事件命中判断。
                imageFrame = geometry.frame(in: .global)
            }
            .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                imageFrame = newFrame
            }
        }
        .background(GatherTheme.viewerChrome)
        .clipped()
        .overlay(alignment: .top) {
            // 缩放提示（对齐旧版 zoomHint：居中毛玻璃胶囊，百分比 + 操作提示）。
            Text(String(format: GatherLocalization.l("%lld%% 滚轮缩放 · 拖动平移 · 双击复位 · ⌘+/⌘− 缩放"), Int(effectiveScale * 100)))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(GatherTheme.viewerSurface.opacity(0.75)))
                .padding(.top, 8)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 0) {
                Button("") { zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("") { resetTransform() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("") { zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .focusable(false)
            .accessibilityHidden(true)
        }
        .background(WindowBridge { window in
            viewerWindow = window
        })
        .onAppear {
            startWheelMonitor()
        }
        .onDisappear {
            stopWheelMonitor()
        }
        // 复用旧版 resetTransform 语义：对比模式切换 / 人脸对齐开关 / 翻页
        // 均显式复位缩放与位移（替代旧的 .id() 整树重建，避免焦点与监听扰动）。
        .onChange(of: compareCount) { _, _ in
            resetTransform()
        }
        .onChange(of: faceAlign) { _, _ in
            resetTransform()
        }
        .onChange(of: viewModel.currentPhotoId) { _, _ in
            resetTransform()
        }
    }

    /// 对比单元格：黑底 + 缩放/平移手势 + 底部字幕条 + 徽标 + hover 主色描边 + 双击复位。
    private func cellView(_ cell: ViewerCell) -> some View {
        let asset = cell.asset
        return GeometryReader { cellGeometry in
            let face = asset.faceBboxes.first
            let faceX = face.map { min(max($0[0] + $0[2] / 2, 0), 1) } ?? 0.5
            let faceY = face.map { min(max($0[1] + $0[3] / 2, 0), 1) } ?? 0.5
            let alignOffset = faceAlign && face != nil
                ? CGSize(
                    width: (0.5 - faceX) * cellGeometry.size.width,
                    height: (0.5 - faceY) * cellGeometry.size.height
                )
                : .zero
            ZStack(alignment: .bottom) {
                // 整图适配（对齐旧版 .viewerImage object-fit: contain）：窄容器
                // 时整体缩放而非裁切，缩放级作用于完整画面。
                // allowsHitTesting(false)：scaleEffect 放大后命中区域会外溢到
                // 单元格之外（.clipped() 只裁剪渲染不裁剪命中），吞掉工具栏/
                // 工具列/胶片条的点击——人脸对齐开启后必须把命中限定在单元格内。
                PhotoThumbnailView(path: asset.photo.filepath, size: 2560, preview: true, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(faceAlign && face != nil ? max(2, scale) : scale)
                    .offset(x: offset.width + alignOffset.width, y: offset.height + alignOffset.height)
                    .allowsHitTesting(false)
                // 底部字幕条（文件名 / 来源 / 星级）。
                HStack(spacing: 8) {
                    Text(asset.photo.filename).lineLimit(1)
                    Spacer()
                    Text(sourceLabel(asset))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                    Spacer()
                    Text(asset.state.rating > 0 ? "\(Int(asset.state.rating))★" : GatherLocalization.l("未评级"))
                }
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(GatherTheme.viewerSurface.opacity(0.9))
                // 右上保留/淘汰徽标。
                if asset.state.pickState != .unreviewed {
                    Text(asset.state.pickState == .picked ? GatherLocalization.l("保留") : GatherLocalization.l("淘汰"))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(
                            asset.state.pickState == .picked ? GatherTheme.success : GatherTheme.error
                        ))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(10)
                }
                // 左上无脸徽标（仅人脸对齐开启且该照片无检测结果时）。
                if faceAlign && face == nil {
                    Text(GatherLocalization.l("未检测到人脸"))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.65)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                // 右下质量徽标（对齐旧版 qualityBadge + warnings ⚠）。
                if let quality = asset.quality {
                    Text(qualityBadgeText(quality))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.65)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                        .help(qualityHelpText(quality))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .background(GatherTheme.viewerBackground)
            .overlay(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.sm)
                    .stroke(hoveredCellId == cell.id ? GatherTheme.primary.opacity(0.65) : Color(white: 0.16), lineWidth: 1)
            )
            .onHover { hovering in
                hoveredCellId = hovering ? cell.id : nil
            }
            // 手势挂在单元格容器上（图片已 allowsHitTesting(false)，命中限定在
            // 单元格边界内；缩放/平移手势与双击复位语义不变）。
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(8, max(1, gestureScale * value))
                    }
                    .onEnded { _ in
                        gestureScale = scale
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // 对齐旧版 onPointerDown：任意缩放级均可拖拽平移。
                        offset = value.translation
                    }
            )
            .onTapGesture(count: 2) {
                resetTransform()
            }
        }
    }

    /// 对比网格按行分组（2 列；4 张 = 2x2，3 张 = 2+1）。
    private func groupCells(_ visible: [CullingAsset]) -> [[ViewerCell]] {
        var groups: [[ViewerCell]] = []
        var row: [ViewerCell] = []
        for (order, asset) in visible.enumerated() {
            row.append(ViewerCell(id: asset.photo.id, order: order, asset: asset))
            if row.count == 2 {
                groups.append(row)
                row = []
            }
        }
        if !row.isEmpty { groups.append(row) }
        return groups
    }

    /// 对齐 TS comparisonAssets（Culling.tsx:675-691）：单张对比直接返回当前；
    /// 对比来源优先取当前照片相似度组内的成员（按已加载顺序），无组时取
    /// 全列表；组内仅当前一张时返回 [current]，不取连续照片兜底。
    private func comparisonAssets() -> [CullingAsset] {
        guard let current = currentAsset else { return [] }
        guard compareCount > 1 else { return [current] }
        let pool = current.similarityGroupId.map { groupId in
            assets.filter { $0.similarityGroupId == groupId }
        } ?? assets
        let others = pool.filter { $0.photo.id != current.photo.id }.prefix(compareCount - 1)
        return [current] + Array(others)
    }

    /// 来源标签（对齐 TS sourceLabel：template/face-keyword/similarity/AI/导入/人工）。
    private func sourceLabel(_ asset: CullingAsset) -> String {
        switch asset.metadataSource {
        case .template: return GatherLocalization.l("模板元数据")
        case .faceKeyword: return GatherLocalization.l("人脸关键词")
        case .similarity: return GatherLocalization.l("相似组关键词")
        case .manual, .culling: break
        case .none: break
        }
        if asset.quality?.status == .succeeded { return GatherLocalization.l("AI 技术分析") }
        if asset.state.source == .imported { return GatherLocalization.l("导入元数据") }
        return GatherLocalization.l("人工调整")
    }

    private func qualityBadgeText(_ quality: CullingQuality) -> String {
        if quality.status == .failed { return GatherLocalization.l("分析失败") + (quality.warnings.isEmpty ? "" : " ⚠") }
        return String(format: GatherLocalization.l("质量 %lld"), Int(quality.score * 100)) + (quality.warnings.isEmpty ? "" : " ⚠")
    }

    private func qualityHelpText(_ quality: CullingQuality) -> String {
        if quality.status == .failed {
            return quality.errorMessage ?? GatherLocalization.l("质量分析失败")
        }
        let sharpness = Int((quality.subjectSharpness ?? quality.sharpness) * 100)
        let exposure = Int(quality.exposure * 100)
        return String(format: GatherLocalization.l("AI 技术分析：清晰度 %lld%%，曝光 %lld%%"), sharpness, exposure)
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
    }

    private func zoomIn() {
        let next = min(8, max(1, scale * 1.15))
        scale = next
        gestureScale = next
    }

    private func zoomOut() {
        let next = min(8, max(1, scale * (1 / 1.15)))
        scale = next
        gestureScale = next
    }

    // MARK: 滚轮缩放（对齐旧版 onWheel：向上 1.15、向下 0.87，范围 1..8）
    private func startWheelMonitor() {
        stopWheelMonitor()
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            self.handleWheel(event)
            return event
        }
    }

    private func stopWheelMonitor() {
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    private func handleWheel(_ event: NSEvent) {
        // 仅响应查看器窗口内、指针位于图像区域上的滚动事件。
        guard let window = viewerWindow, event.window === window,
              let contentView = window.contentView else { return }
        let flippedY = contentView.bounds.height - event.locationInWindow.y
        let point = CGPoint(x: event.locationInWindow.x, y: flippedY)
        guard imageFrame.contains(point) else { return }
        let next = min(8, max(1, scale * (event.scrollingDeltaY < 0 ? 1.15 : 0.87)))
        guard next != scale else { return }
        scale = next
        gestureScale = next
    }
}

/// 弱引用窗口盒：keyDown 监听闭包经它读取最新窗口（避免 struct 捕获副本陈旧）。
private final class WeakWindowBox {
    weak var window: NSWindow?
}

/// 获取承载视图的 NSWindow（滚轮事件监听的窗口归属判断用）。
private struct WindowBridge: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

extension Notification.Name {
    static let gatherMenuUndo = Notification.Name("gather.menu.undo")
    static let gatherMenuRedo = Notification.Name("gather.menu.redo")
}

/// 挑片状态中文文案（供主页面与胶片条共用）。
fileprivate func pickStateTitle(_ state: PickState) -> String {
    switch state {
    case .unreviewed: return GatherLocalization.l("未处理")
    case .picked: return GatherLocalization.l("保留")
    case .rejected: return GatherLocalization.l("淘汰")
    }
}

/// 工具列/胶片条控制组标签样式（对齐旧版 .controlLabel：10px/600/字距 0.04em）。
private extension View {
    func controlLabelStyle() -> some View {
        font(.footnote.weight(.semibold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
    }
}

/// 工具列控制组容器（对齐旧版 .controlGroup：下边框分隔 + 垂直间距）。
private extension View {
    func controlGroupStyle() -> some View {
        padding(.vertical, 12)
            .overlay(alignment: .bottom) { Divider() }
            .padding(.bottom, 12)
    }
}

/// 键盘焦点屏蔽：挑片页主视图持有 onKeyPress 键盘焦点；页内控件一律
/// 不可聚焦，避免点击按钮/勾选框后焦点被抢走导致快捷键失效
/// （文本输入控件不存在，焦点天然不会落在输入框上）。
private extension View {
    func nonFocusable() -> some View {
        focusable(false)
    }
}
