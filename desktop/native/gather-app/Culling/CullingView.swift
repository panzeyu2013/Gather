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
    /// 隐藏期间收到领域变更只登记，回可见再补刷（外壳约定：隐藏页不发命令）。
    private(set) public var pendingDomainRefresh = false
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
    /// culling.sync_status 的唯一解码入口：摘要 + 耐久 reload-ack 字段。
    ///
    /// 路由器在摘要对象上附 `reloadAckedAt`（sessions.reload_acked_at）。旧实现只解
    /// MetadataSyncSummary（未知键被忽略）→ 内存 reloadAcked 冷启动即丢，确认同步
    /// 按钮永久不可用。这里必须把耐久字段解出来，内存值只是它的投影。
    nonisolated static func decodeSyncStatus(_ data: JSONValue) throws -> (summary: MetadataSyncSummary, reloadAckedAt: String?) {
        let summary = try data.decoded(as: MetadataSyncSummary.self)
        let ack = data.objectValue?["reloadAckedAt"]?.stringValue
        return (summary, (ack?.isEmpty == false) ? ack : nil)
    }

    /// 领域广播标识：监听端跳过自己发出的事件（GatherDomainChange.origin）。
    static let changeOrigin = "culling"

    /// 挑片决策写入成功后广播（图库/画廊的星级与色标消费）。
    private func postCullingChange() {
        GatherEventCenter.postDomainChange(.culling, sessionId: sessionId, origin: Self.changeOrigin)
    }

    /// 写回/结清/同步队列变化后广播（设置页/C1 胶囊/控制中心消费）。
    private func postMetadataChange() {
        GatherEventCenter.postDomainChange(.metadata, sessionId: sessionId, origin: Self.changeOrigin)
    }

    /// 跨页领域变更：命中本会话的挑片/元数据/图库变更时刷新自己的数据源；
    /// 隐藏或正忙时只登记，回可见/空闲后由 flushDeferredDomainRefresh 补刷
    ///（隐藏页不发命令是外壳既有约定）。自身 origin 跳过，避免自触发重查。
    public func handleDomainChange(_ change: GatherDomainChange) {
        guard change.matches(sessionId: sessionId),
              change.origin != Self.changeOrigin,
              [.culling, .metadata, .library].contains(change.domain) else { return }
        guard isActive, !isLoading else {
            pendingDomainRefresh = true
            return
        }
        refreshSilently()
    }

    /// 页面重新可见 / 当前刷新结束后的补刷出口（幂等）。
    public func flushDeferredDomainRefresh() {
        guard pendingDomainRefresh, isActive, !isLoading else { return }
        pendingDomainRefresh = false
        refreshSilently()
    }

    /// 已记过的质量失败诊断（去重；超过上限清空，避免无限增长）。
    private var loggedQualityDiagnostics: Set<String> = []

    /// 同步摘要统一入口：状态赋值 + 把失败/冲突行的**原始诊断**写日志
    ///（UI 只展示漏斗后的文案，见 CullingView.displayedReason）。
    private func applySyncStatus(_ summary: MetadataSyncSummary?) {
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
    private func logQualityFailures(_ page: CullingPage) {
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
    public func refreshSyncStatus() {
        var failure: String?
        do {
            let decoded = try Self.decodeSyncStatus(client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]))
            applySyncStatus(decoded.summary)
            reloadAcked = decoded.reloadAckedAt != nil
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

    /// 失败写回行（coordinator 写入的真实原因；UI 必须展示，不允许只报计数）。
    public var failedSyncItems: [MetadataSyncItem] {
        (syncStatus?.items ?? []).filter { $0.status == .failed }
    }

    /// 某个 xmp 行的失败/冲突原因（空串视为无原因）；上屏前走错误码漏斗。
    public func syncFailureReason(xmpPath: String) -> String? {
        guard let item = syncStatus?.items.first(where: { $0.xmpPath == xmpPath }),
              !item.errorMessage.isEmpty else { return nil }
        return Self.funnelErrorText(item.errorMessage)
    }

    /// 已决策（keep/reject）照片数：破坏性写回确认弹窗展示影响范围用。
    public var decidedPhotoCount: Int {
        guard let summary else { return 0 }
        return summary.kept + summary.rejected
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
                let jobs = try client.execute("jobs.list", params: ["includeCheckpoint": .bool(false)]).decoded(as: [AnalysisJobData].self)
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
        /// 耐久 reload-ack（sessions.reload_acked_at）；reloadAckResolved 区分
        /// 「未查询」与「查询到 nil」。
        var reloadAckedAt: String?
        var reloadAckResolved = false
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
        // 与 cullingHistoryRepo.append 同语义：新操作落地即删除已撤销分支
        //（redo 栈作废）。内存列表不同步会让重做指向已被删除的操作。
        history.removeAll { $0.undone }
        history.insert(CullingHistoryOperation(
            id: id,
            sessionId: sessionId,
            entries: entries,
            undone: false,
            createdAt: Date().ISO8601Format()
        ), at: 0)
    }

    /// 历史栈可见窗口：仓库 list 的 clamp 上限 = 路由器 culling.history 的 limit 上限
    ///（500）。读取方据此保证栈顶在窗口内（服务端还会补栈顶，见 CullingService.getHistory）。
    nonisolated private static let historyWindow = 500

    /// 撤销栈顶 = MAX(id) 未撤销（唯一规则，见 CullingHistoryRepo 文件头注）。
    public var undoOperation: CullingHistoryOperation? {
        history.filter { !$0.undone }.max { $0.id < $1.id }
    }

    /// 重做栈顶 = MIN(id) 已撤销（不是列表里第一个 undone —— 列表是 id DESC）。
    public var redoOperation: CullingHistoryOperation? {
        history.filter { $0.undone }.min { $0.id < $1.id }
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
            let snapshot = await Self.fetchSnapshot(
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
        client: NativeCommandClient,
        sessionId: String,
        scope: CullingScope,
        filters: CullingFilters?,
        groupId: String
    ) async -> RefreshSnapshot {
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
            let decoded = try Self.decodeSyncStatus(client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]))
            snapshot.syncStatus = decoded.summary
            snapshot.reloadAckedAt = decoded.reloadAckedAt
            snapshot.reloadAckResolved = true
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.history = try client.execute("culling.history", params: [
                "sessionId": .string(sessionId),
                "limit": .number(Double(Self.historyWindow)),
            ]).decoded(as: [CullingHistoryOperation].self)
        } catch {
            snapshot.auxError = snapshot.auxError ?? NativeCommandClient.message(for: error)
        }
        guard !Task.isCancelled else { return snapshot }
        do {
            snapshot.conflicts = try await client.executeAsync("metadata.conflicts", params: [
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
                let decoded = try Self.decodeSyncStatus(client.execute("culling.sync_status", params: [
                    "sessionId": .string(sessionId),
                ]))
                applySyncStatus(decoded.summary)
                reloadAcked = decoded.reloadAckedAt != nil
            } catch {
                applySyncStatus(nil)
                lastSyncError = NativeCommandClient.message(for: error)
            }
            do {
                history = try client.execute("culling.history", params: [
                    "sessionId": .string(sessionId),
                    "limit": .number(Double(Self.historyWindow)),
                ]).decoded(as: [CullingHistoryOperation].self)
            } catch {
                history = []
                lastSyncError = NativeCommandClient.message(for: error)
            }
            // P2-8（审计 2）：detached 任务必须带版本守卫（同 refreshSilently 的惯例）。
            // 连续改筛选会并发多个 conflicts 请求，旧请求后到会覆盖新列表；
            // 旧请求失败还会把 conflicts 清空并写入过期的 lastSyncError。
            let conflictsVersion = pageVersion
            Task { @MainActor in
                do {
                    let fetched = try await client.executeAsync("metadata.conflicts", params: [
                        "sessionId": .string(sessionId),
                    ]).decoded(as: [MetadataConflict].self)
                    guard conflictsVersion == pageVersion else { return }
                    conflicts = fetched
                } catch {
                    guard conflictsVersion == pageVersion else { return }
                    conflicts = []
                    lastSyncError = NativeCommandClient.message(for: error)
                }
            }
            if let page { logQualityFailures(page) }
            errorMessage = nil
            flushDeferredDomainRefresh()
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
            postCullingChange()
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
            postCullingChange()
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
            postCullingChange()
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
        // 唯一规则：撤销栈顶 = MAX(id) 未撤销（见 undoOperation）。
        guard let operation = undoOperation else {
            notice = GatherLocalization.l("没有可撤销的挑片操作")
            return
        }
        applyHistory(operation, direction: .undo)
    }

    public func redo() {
        // 唯一规则：重做栈顶 = MIN(id) 已撤销（见 redoOperation）。
        guard let operation = redoOperation else {
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
            postCullingChange()
            refreshSilently()
        } catch {
            pageVersion += 1
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// culling.writeback 的返回类型是 WritebackResult（不是 MetadataSyncSummary）。
    /// 旧实现按 MetadataSyncSummary 解码 → 成功写回也走 catch 并吞掉失败明细。
    public func writeback(target: CullingWritebackTarget, confirmed: Bool) async {
        guard confirmed else {
            errorMessage = GatherLocalization.l("写回必须先经确认")
            return
        }
        do {
            let data = try await client.executeAsync("culling.writeback", params: [
                "sessionId": .string(sessionId),
                "target": .string(target.rawValue),
                "confirmed": .bool(true),
            ])
            let result = try data.decoded(as: WritebackResult.self)
            // loadPage 末尾会清 errorMessage：先刷新页面，再落结果文案，
            // 否则「写回成功但 3 项失败」的原因会被刚刷新的页面清掉。
            postMetadataChange()
            loadPage(reset: true)
            applyWritebackResult(result, label: targetLabel(target))
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 写回结果逐项可见：失败数 > 0 或存在逐条原因时进 errorMessage（不吞），
    /// 全成功才进 notice。
    private func applyWritebackResult(_ result: WritebackResult, label: String) {
        let counts = String(
            format: GatherLocalization.l("%@：成功 %lld，失败 %lld，跳过 %lld"),
            label, result.written, result.failed, result.skipped
        )
        if result.failed > 0 || !result.errors.isEmpty {
            logWritebackFailures(label: label, errors: result.errors)
            notice = nil
            errorMessage = result.errors.isEmpty
                ? String(format: GatherLocalization.l("%@（请展开失败项查看原因）"), counts)
                : counts + "；" + Self.reasonSummary(result.errors)
        } else {
            errorMessage = nil
            notice = String(format: GatherLocalization.l("%@；请让 Capture One 重新加载元数据后确认同步"), counts)
        }
    }

    /// 写回失败明细写日志（原始诊断不上屏，界面只展示漏斗后的文案）。
    private func logWritebackFailures(label: String, errors: [String]) {
        guard !errors.isEmpty else { return }
        GatherLogger.log(
            "culling.writeback \(label) errors: \(errors.joined(separator: " | "))",
            level: .warn
        )
    }

    /// 原因摘要：最多 3 条漏斗后文案 + 其余计数（完整明细在日志与失败面板）。
    static func reasonSummary(_ reasons: [String]) -> String {
        let head = reasons.prefix(3).map { funnelErrorText($0) }
        var text = head.joined(separator: "；")
        if reasons.count > head.count {
            text += String(format: GatherLocalization.l("；另有 %lld 条"), reasons.count - head.count)
        }
        return text
    }

    /// 错误码漏斗：从「路径: XMP_WRITE_FAILED / 原因」这类结构化描述里抽出错误码
    /// token 走 GatherLocalization.errorText（本地化文案）；抽不到码值时交回
    /// errorText 的通用文案。诊断原文只进日志（见 applySyncStatus/applyWritebackResult），
    /// 不直接铺在界面上。
    static func funnelErrorText(_ raw: String) -> String {
        GatherLocalization.errorText(errorCode(in: raw) ?? raw)
    }

    private static func errorCode(in raw: String) -> String? {
        // 手工扫描最大的「大写 + 数字 + 下划线」连续段（≥4 字符）作为码值候选：
        // 比 split 的泛型重载更确定，且不会把路径/散文误当码值。
        var candidate = ""
        for character in raw {
            if character.isUppercase || character.isNumber || character == "_" {
                candidate.append(character)
            } else {
                if candidate.count >= 4 { return candidate }
                candidate = ""
            }
        }
        return candidate.count >= 4 ? candidate : nil
    }

    public func flush(retry: Bool = false) async {
        do {
            let data = try await client.executeAsync(retry ? "culling.retry_sync" : "culling.flush", params: [
                "sessionId": .string(sessionId),
            ])
            do {
                applySyncStatus(try data.decoded(as: MetadataSyncSummary.self))
                notice = retry ? GatherLocalization.l("已重试同步队列") : GatherLocalization.l("已刷新同步队列")
            } catch {
                applySyncStatus(nil)
                notice = retry ? GatherLocalization.l("已重试同步队列，但同步状态读取失败") : GatherLocalization.l("已刷新同步队列，但同步状态读取失败")
            }
            postMetadataChange()
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// retry_failed_writeback 同样返回 WritebackResult（旧实现按摘要解码 → 静默失败）。
    public func retryFailedWriteback(confirmed: Bool) async {
        guard confirmed else {
            errorMessage = GatherLocalization.l("重试失败写回必须先经确认")
            return
        }
        do {
            let data = try await client.executeAsync("culling.retry_failed_writeback", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            let result = try data.decoded(as: WritebackResult.self)
            postMetadataChange()
            loadPage(reset: true)
            applyWritebackResult(result, label: GatherLocalization.l("重试写回"))
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            // 桥接层已耐久写入 sessions.reload_acked_at；内存值只是投影，
            // 随后 refreshSyncStatus 会从耐久字段重建（冷启动同样有效）。
            reloadAcked = true
            notice = GatherLocalization.l("Capture One 已重新加载元数据，现在可以确认同步")
            postMetadataChange()
            refreshSyncStatus()
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func confirmSync() async {
        do {
            _ = try await client.executeAsync("culling.confirm_sync", params: ["sessionId": .string(sessionId)])
            notice = GatherLocalization.l("已确认 Capture One 同步")
            postMetadataChange()
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func finalizeSync(confirmed: Bool) async {
        guard confirmed else {
            errorMessage = GatherLocalization.l("结束同步必须先经确认")
            return
        }
        do {
            let data = try await client.executeAsync("culling.finalize_sync", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            let summary = try data.decoded(as: MetadataSyncSummary.self)
            applySyncStatus(summary)
            notice = String(format: GatherLocalization.l("已完成元数据同步（%lld 项已确认加载）"), summary.synced)
            postMetadataChange()
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// import 返回 CleanupResult：deletedCount 与逐条 errors 都必须呈现
    ///（旧实现丢弃返回值 → cleanup 标 conflict 后用户看不到任何原因）。
    public func cleanup(confirmed: Bool) async {
        guard confirmed else {
            errorMessage = GatherLocalization.l("清理备份必须先经确认")
            return
        }
        do {
            let data = try await client.executeAsync("culling.cleanup", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            let result = try data.decoded(as: CleanupResult.self)
            if !result.errors.isEmpty {
                GatherLogger.log(
                    "culling.cleanup errors: \(result.errors.joined(separator: " | "))",
                    level: .warn
                )
            }
            // 同上：先刷新页面再落文案。
            postMetadataChange()
            loadPage(reset: true)
            if result.errors.isEmpty {
                notice = String(format: GatherLocalization.l("已清理 %lld 项可安全删除的备份"), result.deletedCount)
                errorMessage = nil
            } else {
                notice = nil
                errorMessage = String(
                    format: GatherLocalization.l("清理了 %lld 项，%lld 项失败：%@"),
                    result.deletedCount, result.errors.count, Self.reasonSummary(result.errors)
                )
            }
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reset(confirmed: Bool) {
        guard confirmed else {
            errorMessage = GatherLocalization.l("重置挑片状态必须先经确认")
            return
        }
        do {
            _ = try client.execute("culling.reset", params: [
                "sessionId": .string(sessionId),
                "confirmed": .bool(true),
            ])
            notice = GatherLocalization.l("已重置挑片状态")
            postCullingChange()
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 冲突裁决（唯一出口）：confirmed 只能来自确认弹窗；choices 为空 =
    /// 显式结清（保留 Gather 值并以当前磁盘状态为新基线重写）。
    public func resolve(
        _ conflict: MetadataConflict,
        choices: [MetadataField: MetadataConflictChoice],
        confirmed: Bool
    ) async {
        guard confirmed else {
            errorMessage = GatherLocalization.l("冲突裁决必须先经确认")
            return
        }
        do {
            let rawChoices = Dictionary(uniqueKeysWithValues: choices.map {
                ($0.key.rawValue, JSONValue.string($0.value.rawValue))
            })
            _ = try await client.executeAsync("metadata.resolve_conflict", params: [
                "sessionId": .string(sessionId),
                "xmpPath": .string(conflict.xmpPath),
                "choices": .object(rawChoices),
                "confirmed": .bool(true),
            ])
            notice = GatherLocalization.l("已处理元数据冲突")
            errorMessage = nil
            postMetadataChange()
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    /// 逐字段选择一次应用（面板「应用选择」）。
    public func resolve(_ conflict: MetadataConflict, choice: MetadataConflictChoice, confirmed: Bool) async {
        await resolve(
            conflict,
            choices: Dictionary(uniqueKeysWithValues: conflict.fields.map { ($0.field, choice) }),
            confirmed: confirmed
        )
    }

    /// 确认弹窗取消时的可见文案（不静默 return，也不发命令）。
    public func noteCancelledAction(_ action: String) {
        errorMessage = nil
        notice = String(format: GatherLocalization.l("已取消：%@"), action)
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
    /// D10：「逐条裁决」入口意图（进入后把筛选收敛到 XMP 冲突）。
    private let conflictsIntent: Bool
    private let onConsumeConflictsIntent: () -> Void
    /// 破坏性命令的唯一确认载体：命令层的 confirmed:true 只能从确认弹窗分支到达。
    @State private var pendingAction: PendingCullingAction?
    @State private var conflictChoices: [String: MetadataConflictChoice] = [:]
    @State private var compareCount = 1
    @State private var faceAlign = false
    /// 右侧检查器（系统 .inspector）的展开状态：Bridge/Capture One 式，
    /// 选项面板默认可见，工具栏开关由系统提供。可见性用 @SceneStorage 按页
    /// 记忆（跨导航重建 / 新窗口保持；参考 darktable 各视图独立存储面板可见性）。
    @SceneStorage("culling.inspectorVisible") private var showInspector = true

    /// 外壳注入 VM（第三轮审计 D-P0）：挑片的范围/筛选/当前照片/多选/逐字段裁决
    /// 草稿都挂在 VM 上；页面按目的地条件构建，切页签会销毁页面，只有注入同一个
    /// VM 才能保住这些「用户已经投入过输入」的状态。
    init(
        viewModel: CullingViewModel,
        router: CommandRouter,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {},
        conflictsIntent: Bool = false,
        onConsumeConflictsIntent: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.router = router
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
        self.conflictsIntent = conflictsIntent
        self.onConsumeConflictsIntent = onConsumeConflictsIntent
    }

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
        self.conflictsIntent = false
        self.onConsumeConflictsIntent = {}
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage { NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: GatherTheme.success) }
            if viewModel.sessionId.isEmpty {
                emptyGuide(
                    title: GatherLocalization.l("未打开工作区"),
                    systemImage: "rectangle.stack",
                    message: GatherLocalization.l("请先打开一个工作区，再进入挑片页。")
                )
            } else if let page = viewModel.page {
                if page.assets.isEmpty {
                    // TS Culling.tsx:1157-1173：空列表时保留工具/筛选栏 + 空态文案。
                    VStack(spacing: 0) {
                        toolbarRow
                        emptyGuide(
                            title: GatherLocalization.l("当前范围没有照片"),
                            systemImage: "photo.on.rectangle.angled",
                            message: GatherLocalization.l("切换到「全部照片」或清除筛选条件。")
                        )
                    }
                } else {
                    workbench
                }
            } else if let error = viewModel.errorMessage {
                // 加载失败不留空面板/黑屏：系统空态 + 重试出口。
                ContentUnavailableView {
                    Label(GatherLocalization.l("载入挑片工作台失败"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button(GatherLocalization.l("重试")) { viewModel.load() }
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView(GatherLocalization.l("正在载入挑片工作台…"))
                        .controlSize(.large)
                        .padding(.vertical, 60)
                    Spacer()
                }
            }
        }
        .background(GatherTheme.windowBackground)
        .task {
            // D10：控制中心「N 个 XMP 冲突待裁决 → 逐条裁决」的入口意图。
            // 旧实现只切到挑片页，用户还得自己找冲突；有缓存状态时甚至回到上一次
            // 无关的筛选。这里在页面就位后把筛选一次性收敛到冲突，并消费意图
            //（事件语义：每次入口点击生效一次，不重复套用）。
            if conflictsIntent {
                // A2（审计 4）：入口语义是「收敛到冲突」，不是「与上次的筛选求交」。
                // 挑片 VM 跨页签缓存了上一次的未审/星级/色标等维度，只置位
                // metadataConflictOnly 会变成 AND（很可能 0 行，与同屏「N 个冲突」矛盾）。
                // 因此整份筛选重置为「只看冲突」再加载。
                // A3（审计 4）：setFilterState 内部已经触发一次 loadPage(reset:)，
                // 这里不再调用 load()，避免同一次进入跑两轮完整加载 + 两个 conflicts 请求。
                viewModel.setFilterState { state in
                    state = CullingViewModel.FilterState()
                    state.metadataConflictOnly = true
                }
                onConsumeConflictsIntent()
            } else {
                viewModel.load()
            }
        }
        // 可见性门控（审计 P1-并发）：条件渲染页离开即销毁，isActive=false
        // 让 analyzeQuality 轮询及时退出。
        .onAppear {
            viewModel.isActive = true
            // 隐藏期间登记的领域变更在这里补刷（隐藏页不发命令的约定）。
            viewModel.flushDeferredDomainRefresh()
        }
        .onDisappear {
            viewModel.isActive = false
        }
        // 写回协调器 emitSummary 后刷新同步状态（TS useEvent('culling:sync-status')）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            viewModel.refreshSyncStatus()
        }
        // 跨页领域变更（挑片/元数据/图库）：可见时按域补刷，隐藏时只登记，
        // 回可见由 onAppear 统一补一次；自身 origin 在 VM 内跳过。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.domainChanged)) { notification in
            guard let change = notification.object as? GatherDomainChange else { return }
            viewModel.handleDomainChange(change)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gatherMenuUndo)) { _ in
            viewModel.undo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gatherMenuRedo)) { _ in
            viewModel.redo()
        }
        // 破坏性命令（重置/清理/写回/重试失败项/结束同步/冲突裁决）一律先经真实
        // 确认弹窗，再由确认分支传 confirmed: true；不存在「无弹窗硬编码 true」。
        .gatherDestructiveConfirm(
            pending: $pendingAction,
            title: GatherLocalization.l("确认执行此操作？"),
            confirmLabel: { $0.actionLabel },
            confirmRole: { action in
                if case .resolveConflict(_, let choices) = action,
                   !choices.isEmpty, choices.values.allSatisfy({ $0 == .useRemote }) {
                    return nil
                }
                return .destructive
            },
            message: { confirmationMessage($0) },
            onConfirm: { perform($0) },
            onCancel: { viewModel.noteCancelledAction($0.actionLabel) }
        )
        // 会话页窗口 chrome：标题副标题走系统，子导航分段控件在工具栏 principal 位置。
        .sessionPageChrome(
            subtitle: GatherLocalization.l("挑片与写回"),
            selection: .tab(.culling),
            onBrowse: { onOpenGallery(viewModel.sessionId) },
            onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
            onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onBack()
                } label: {
                    Label(GatherLocalization.l("返回"), systemImage: "chevron.backward")
                }
                .help(GatherLocalization.l("返回到上一页"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, router: router, onOpenSettings: onOpenSettings)
                Button(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise") {
                    viewModel.load()
                }
                .disabled(viewModel.isLoading)
                .help(GatherLocalization.l("重新载入挑片工作台"))
            }
        }
        // Bridge / Capture One 式：图片保持居中，选项面板交给系统 .inspector
        // （工具栏开关由系统自动提供，不自绘按钮）。
        .inspector(isPresented: $showInspector) {
            inspectorContent
                // 约束循环修复（N01）：SwiftUI 把**理想列宽**计入承载视图的最小宽度
                //（实测 min 260 / ideal 300 时贡献 300pt）。收窄到 ideal 260，
                // 让最小窗口下「页签行 + 内容 + 检查器」仍能装进内容区。
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
    }

    /// 破坏性动作集合。id 参与弹窗身份判定，必须包含影响参数（目标/字段选择）。
    private enum PendingCullingAction: Identifiable {
        case reset
        case cleanup
        case writeback(CullingWritebackTarget)
        case retryFailedWriteback
        case finalizeSync
        case resolveConflict(MetadataConflict, [MetadataField: MetadataConflictChoice])

        var id: String {
            switch self {
            case .reset: "reset"
            case .cleanup: "cleanup"
            case .writeback(let target): "writeback:\(target.rawValue)"
            case .retryFailedWriteback: "retry_failed_writeback"
            case .finalizeSync: "finalize_sync"
            case .resolveConflict(let conflict, let choices):
                "resolve:\(conflict.xmpPath):" + choices
                    .map { "\($0.key.rawValue)=\($0.value.rawValue)" }
                    .sorted()
                    .joined(separator: ",")
            }
        }

        var actionLabel: String {
            switch self {
            case .reset: return GatherLocalization.l("重置挑片状态")
            case .cleanup: return GatherLocalization.l("清理写回备份")
            case .writeback(let target):
                switch target {
                case .rating: return GatherLocalization.l("写回评分到 XMP")
                case .colorLabel: return GatherLocalization.l("写回颜色标签到 XMP")
                case .keyword: return GatherLocalization.l("写回挑片关键词到 XMP")
                }
            case .retryFailedWriteback: return GatherLocalization.l("重试失败写回项")
            case .finalizeSync: return GatherLocalization.l("保留 XMP 并结束同步")
            case .resolveConflict: return GatherLocalization.l("裁决 XMP 冲突")
            }
        }
    }

    private func confirmationMessage(_ action: PendingCullingAction) -> String {
        switch action {
        case .reset:
            return String(
                format: GatherLocalization.l("将清空本会话 %lld 张照片的挑片决策、星级与色标（只改 Gather 数据库，不写 XMP、不删除照片文件）。"),
                viewModel.summary?.totalPhotos ?? 0
            )
        case .cleanup:
            return String(
                format: GatherLocalization.l("将删除 %lld 项已确认同步的备份；未确认的项会恢复原 XMP 并标记冲突，原因会显示在面板里。"),
                viewModel.syncStatus?.synced ?? 0
            )
        case .writeback(let target):
            switch target {
            case .rating:
                return String(
                    format: GatherLocalization.l("将把 %lld 张已决策照片的当前星级写入 XMP 侧车（会创建备份，可在同步完成后清理）。"),
                    viewModel.decidedPhotoCount
                )
            case .colorLabel:
                return String(
                    format: GatherLocalization.l("将把 %lld 张已决策照片的当前颜色标签写入 XMP 侧车（会创建备份）。"),
                    viewModel.decidedPhotoCount
                )
            case .keyword:
                return String(
                    format: GatherLocalization.l("将把 %lld 张已决策照片的 culling:keep / culling:reject 关键词合并进 XMP（不覆盖其它关键词）。"),
                    viewModel.decidedPhotoCount
                )
            }
        case .retryFailedWriteback:
            return String(
                format: GatherLocalization.l("将重试 %lld 个失败写回项并覆盖对应 XMP 侧车。"),
                viewModel.failedSyncItems.count
            )
        case .finalizeSync:
            return String(
                format: GatherLocalization.l("将确认同步并删除 %lld 项备份，之后无法再从备份恢复原 XMP。"),
                viewModel.syncStatus?.synced ?? 0
            )
        case .resolveConflict(let conflict, let choices):
            let name = URL(fileURLWithPath: conflict.xmpPath).lastPathComponent
            let usesRemote = !choices.isEmpty && choices.values.allSatisfy({ $0 == .useRemote })
            return usesRemote
                ? String(format: GatherLocalization.l("将丢弃 Gather 待写入值、采用外部值，结清 %@ 的冲突。"), name)
                : String(format: GatherLocalization.l("将把 Gather 的值写回 %@（覆盖外部修改）并结清冲突。"), name)
        }
    }

    private func perform(_ action: PendingCullingAction) {
        switch action {
        case .reset:
            viewModel.reset(confirmed: true)
        case .cleanup:
            Task { await viewModel.cleanup(confirmed: true) }
        case .writeback(let target):
            Task { await viewModel.writeback(target: target, confirmed: true) }
        case .retryFailedWriteback:
            Task { await viewModel.retryFailedWriteback(confirmed: true) }
        case .finalizeSync:
            Task { await viewModel.finalizeSync(confirmed: true) }
        case .resolveConflict(let conflict, let choices):
            Task { await viewModel.resolve(conflict, choices: choices, confirmed: true) }
        }
    }

    // MARK: 工作台（Bridge / Lightroom / darktable 式：查看器居中，
    // 胶片条横贯底部——darktable 文档即写明胶片条 "at the bottom"；
    // 原 214px 工具列已迁入系统 .inspector，顶部工具栏横贯内容区）。

    private var workbench: some View {
        VStack(spacing: 0) {
            toolbarRow
            // 竖向分割：查看器 + infoBar 占据上半区，全宽胶片条固定在底部。
            // （旧版把胶片条放在右侧，与右侧 .inspector 两栏夹击查看器。）
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                // 浮动冲突面板（对齐旧版 .conflictPanel 定位：右下、infoBar 之上；
                // 宽度不超过 540，且不超过窗口可用宽 - 32）。
                // 锚在「查看器 + infoBar」区域而非整页：胶片条移到最底部后，
                // 面板仍需浮在 infoBar 之上，不能压住胶片条。
                GeometryReader { geometry in
                    // 约束循环修复（F01）：geometry.size.width 在首帧/未定宽时为 0，
                    // min(540, 0 - 32) = -32 会安装**负宽度约束**，AppKit 必须再跑
                    // 一轮约束更新；叠加 .inspector 的列宽协商就耗尽 pass 预算。
                    // 这里钳到非负，并且只在真的有冲突面板时下固定宽度
                    //（conflicts 为空时 conflictPanel 是空视图，不该占宽度）。
                    if !viewModel.conflicts.isEmpty {
                        conflictPanel
                            .frame(width: max(0, min(540, geometry.size.width - 32)))
                            .padding(.trailing, 14)
                            .padding(.bottom, 52)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }
            filmstrip
        }
    }

    // MARK: 顶部工具栏（对齐旧版 Culling.tsx:1177-1309 的 toolbar：
    // 范围分段 + 筛选控件 + 视图操作区）。
    // 布局验收 P0 修复：拆为两行——第一行固定可见（撤销/重做 + 范围 +
    // 自动前进 + 对比 + 质量分析，高频操作不再被横向滚动隐藏）；第二行
    // 可横向滚动（筛选控件 + 导航分组操作，低频）。

    private var toolbarRow: some View {
        VStack(spacing: 0) {
            // 约束循环修复（N01）：本行原先是不带滚动的 HStack，它的最小宽度 =
            // 所有控件最小宽度之和（实测 ≈ 876pt）。这个最小宽度会经
            // SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)
            // 传给 NavigationSplitView；默认窗口减掉侧栏与检查器只剩 ≈720pt，
            // AppKit 于是反复重算约束 → NSGenericException → SIGABRT。
            // 放进横向滚动容器后，本行对外的**最小宽度**不再等于内容总宽
            //（与下面第二行筛选栏同一处理），页面最小宽度回到预算内。
            ScrollView(.horizontal) {
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
                        .fixedSize()

                    }

                    Toggle(GatherLocalization.l("自动前进"), isOn: autoAdvanceBinding)
                        .toggleStyle(.checkbox)
                        .fixedSize()


                    labeledPicker(GatherLocalization.l("对比")) {
                        Picker(GatherLocalization.l("对比"), selection: $compareCount) {
                            Text(GatherLocalization.l("单图")).tag(1)
                            Text(GatherLocalization.l("2 图")).tag(2)
                            Text(GatherLocalization.l("4 图")).tag(4)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .fixedSize()

                    }

                    Divider().frame(height: 18)

                    qualityAnalysisBlock
                        .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }

            // 筛选行在窄窗口下会超出，保留横向滚动但**不再隐藏滚动条**：
            // showsIndicators:false 会抹掉「右边还有控件」的唯一线索。
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    Toggle(GatherLocalization.l("仅未处理"), isOn: unreviewedOnlyBinding)
                        .toggleStyle(.checkbox)

                    labeledPicker(GatherLocalization.l("状态")) {
                        Picker(GatherLocalization.l("状态"), selection: pickStateBinding) {
                            Text(GatherLocalization.l("全部状态")).tag(PickState?.none)
                            ForEach(PickState.allCases, id: \.self) { state in
                                Text(pickStateTitle(state)).tag(PickState?.some(state))
                            }
                        }
                        .fixedSize()

                    }
                    labeledPicker(GatherLocalization.l("星级")) {
                        Picker(GatherLocalization.l("星级"), selection: ratingBinding) {
                            Text(GatherLocalization.l("全部星级")).tag(Int?.none)
                            ForEach(0...5, id: \.self) { rating in
                                Text(rating == 0 ? GatherLocalization.l("未评级") : String(format: GatherLocalization.l("%lld 星"), rating)).tag(Int?.some(rating))
                            }
                        }
                        .fixedSize()

                    }
                    labeledPicker(GatherLocalization.l("颜色")) {
                        Picker(GatherLocalization.l("颜色"), selection: colorFilterBinding) {
                            Text(GatherLocalization.l("全部颜色")).tag(CaptureOneColorLabel?.none)
                            ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                                Text(Self.colorLabelTitle(label)).tag(CaptureOneColorLabel?.some(label))
                            }
                        }
                        .fixedSize()

                    }
                    labeledPicker(GatherLocalization.l("质量")) {
                        Picker(GatherLocalization.l("质量"), selection: qualityStatusBinding) {
                            Text(GatherLocalization.l("全部分析状态")).tag(CullingFilterQualityStatus?.none)
                            Text(GatherLocalization.l("已分析")).tag(CullingFilterQualityStatus?.some(.analysed))
                            Text(GatherLocalization.l("未分析")).tag(CullingFilterQualityStatus?.some(.unanalysed))
                            Text(GatherLocalization.l("分析失败")).tag(CullingFilterQualityStatus?.some(.failed))
                        }
                        .fixedSize()

                    }
                    Toggle(GatherLocalization.l("仅 XMP 冲突"), isOn: conflictOnlyBinding)
                        .toggleStyle(.checkbox)

                    Button(GatherLocalization.l("重置")) { viewModel.resetFilters() }

                    Divider().frame(height: 18)

                    Toggle(GatherLocalization.l("人脸对齐"), isOn: $faceAlign)
                        .toggleStyle(.checkbox)


                    Button(GatherLocalization.l("保存 Burst/Scene 分组")) {
                        Task { await viewModel.analyzeNavigation(dryRun: false) }
                    }
                    .disabled(viewModel.isNavigationBusy)

                    Button(GatherLocalization.l("预览分组")) {
                        Task { await viewModel.analyzeNavigation(dryRun: true) }
                    }
                    .disabled(viewModel.isNavigationBusy)


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

                        }
                        Button(GatherLocalization.l("从当前照片拆分")) {
                            viewModel.splitCurrentFromNavigationGroup()
                        }
                        .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)

                        Button(GatherLocalization.l("与前组合并")) {
                            viewModel.mergeCurrentWithPreviousSameType()
                        }
                        .disabled(viewModel.isNavigationBusy || viewModel.selectedNavigationGroupId.isEmpty)

                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
        }
        .background(GatherTheme.contentBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            // ⌘Z / ⇧⌘Z 由宿主菜单（gatherMenuUndo/Redo 通知）承载，这里只做可见入口。
            Button { viewModel.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            // V2 审计：宿主菜单的 undo:/redo: 走 NSUndoManager，而挑片撤销是自建栈，
            // 只认 gatherMenuUndo/Redo 通知——那两个通知全仓没有发布者，tooltip 承诺
            // 的 ⌘Z/⇧⌘Z 从未生效。直接挂在可见按钮上（挑片页无文本输入框，不冲突）。
            .keyboardShortcut("z", modifiers: .command)
            .disabled(viewModel.undoOperation == nil || isBusy)
            .help(GatherLocalization.l("撤销（⌘Z）"))
            .accessibilityLabel(GatherLocalization.l("撤销"))

            Button { viewModel.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(viewModel.redoOperation == nil || isBusy)
            .help(GatherLocalization.l("重做（⇧⌘Z）"))
            .accessibilityLabel(GatherLocalization.l("重做"))
        }
    }

    private var qualityAnalysisBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(viewModel.isQualityBusy ? GatherLocalization.l("质量分析中…") : GatherLocalization.l("分析技术质量")) {
                Task { await viewModel.analyzeQuality() }
            }
            .disabled(viewModel.isQualityBusy)

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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(GatherLocalization.l("取消")) {
                        viewModel.cancelQualityAnalysis()
                    }
                    .controlSize(.small)
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
                .font(.callout)
                .foregroundStyle(.secondary)
            picker().labelsHidden()
        }
    }

    // MARK: 右侧检查器（Bridge / Capture One 式：选项面板交给系统 .inspector，
    // 内容区只留查看器 + 胶片；工具栏开关由系统自动提供，不自绘切换按钮）。

    private var inspectorContent: some View {
        // 约束循环修复（F01）：grouped Form 挂在 .inspector 上会在 AppKit 的
        // 约束更新阶段抛 NSGenericException（"more Update Constraints in
        // Window passes than there are views"）。LibraryView.libraryInspector
        // 已记录同一崩溃栈并改成 ScrollView + 分组容器，本页原先漏改。
        // 检查器只承载决策与选择，GroupBox 与 Form Section 同样清晰。
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 当前照片：决策条（对齐旧版 decisionBar：✓ 保留 P / × 淘汰 X / ○ 未处理 U）
                // + 星级 + 颜色。系统 bordered 按钮 + 裸键 .keyboardShortcut（取代手绘卡片描边）。
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.selectedPhotoIds.isEmpty ? GatherLocalization.l("当前照片") : String(format: GatherLocalization.l("批量 %lld 张"), viewModel.selectedPhotoIds.count))
                            .controlLabelStyle()
                        VStack(spacing: 6) {
                            decisionButton(icon: "checkmark", iconColor: GatherTheme.success, title: GatherLocalization.l("保留"), shortcut: "P", key: "p") {
                                viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
                            }
                            decisionButton(icon: "xmark", iconColor: GatherTheme.error, title: GatherLocalization.l("淘汰"), shortcut: "X", key: "x") {
                                viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected))
                            }
                            decisionButton(icon: "circle", iconColor: .secondary, title: GatherLocalization.l("未处理"), shortcut: "U", key: "u") {
                                viewModel.commit(patch: CullingUpdatePatch(pickState: .unreviewed), shouldAdvance: false)
                            }
                        }
                    }

                    // 星级：0–5 的**图标**按钮 + 累计填充的标准评分外观。
                    //
                    // 旧实现是 "1★"/"2★" 文字按钮：窄列宽下六个按钮会被压缩成「…」，
                    // 整行不可读。图标按钮只占约 22pt/个，检查器任意列宽下都完整可见。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(GatherLocalization.l("星级")).controlLabelStyle()
                        HStack(spacing: 2) {
                            let current = Int(viewModel.currentAsset?.state.rating ?? 0)
                            Button {
                                viewModel.commit(patch: CullingUpdatePatch(rating: 0))
                            } label: {
                                Image(systemName: "star.slash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.large)
                            .foregroundStyle(current == 0 ? GatherTheme.accent : Color.secondary)
                            .disabled(isBusy)
                            .help(GatherLocalization.l("清除评分"))
                            .accessibilityLabel(GatherLocalization.l("清除评分"))

                            ForEach(1...5, id: \.self) { rating in
                                Button {
                                    viewModel.commit(patch: CullingUpdatePatch(rating: Double(rating)))
                                } label: {
                                    Image(systemName: rating <= current ? "star.fill" : "star")
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.large)
                                .foregroundStyle(rating <= current ? GatherTheme.accent : Color.secondary)
                                .disabled(isBusy)
                                .help(String(format: GatherLocalization.l("评分 %lld"), rating))
                                .accessibilityLabel(String(format: GatherLocalization.l("评分 %lld"), rating))
                                .accessibilityAddTraits(rating == current ? .isSelected : [])
                            }
                        }
                    }

                    // 颜色标签：系统菜单选择器（取代手绘圆形色钮 + 选中外环）；
                    // C1 色标是数据本身（非状态色），沿用固定色值。
                    VStack(alignment: .leading, spacing: 6) {
                        Text(GatherLocalization.l("颜色")).controlLabelStyle()
                        Picker(GatherLocalization.l("颜色"), selection: colorSelectionBinding) {
                            ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                                Label {
                                    Text(Self.colorLabelTitle(label))
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(Self.colorDot(label))
                                }
                                .tag(CaptureOneColorLabel?.some(label))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(isBusy)
                        .help(GatherLocalization.l("设置当前照片的颜色标签"))
                        .accessibilityLabel(GatherLocalization.l("颜色标签"))
                    }
                } label: {
                    Text(GatherLocalization.l("当前照片"))
                }

                // 相似组决策（对齐旧版 groupDecision：仅当前照片所在组 >1 张时显示）。
                if currentGroupAssets.count > 1, let current = viewModel.currentAsset {
                    let groupIds = Set(currentGroupAssets.map(\.photo.id))
                    let selectedInGroup = viewModel.selectedPhotoIds.intersection(groupIds)
                    let keepValid = !selectedInGroup.isEmpty && selectedInGroup.count < currentGroupAssets.count
                    GroupBox {
                        Button(GatherLocalization.l("保留当前 1 张")) {
                            viewModel.keepInGroupRejectRest(
                                current.similarityGroupId ?? "",
                                keepPhotoIds: [current.photo.id]
                            )
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(isBusy)

                        Button(selectedInGroup.isEmpty ? GatherLocalization.l("保留已选 K 张") : String(format: GatherLocalization.l("保留已选 %lld 张"), selectedInGroup.count)) {
                            viewModel.keepInGroupRejectRest(
                                current.similarityGroupId ?? "",
                                keepPhotoIds: selectedInGroup.sorted()
                            )
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(!keepValid || isBusy)
                        .help(keepValid ? "" : GatherLocalization.l("按住 ⌘ 或 Ctrl 在胶片中选择要保留的照片"))
                    } label: {
                        Text(String(format: GatherLocalization.l("相似组 · %lld 张"), currentGroupAssets.count))
                        Text(GatherLocalization.l("其余照片自动淘汰"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                // 选择管理：批量决策对象（在胶片条中 ⌘/Ctrl 点选）。
                GroupBox {
                    if viewModel.selectedPhotoIds.isEmpty {
                        Text(GatherLocalization.l("未选择照片"))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(format: GatherLocalization.l("已选 %lld 张"), viewModel.selectedPhotoIds.count))
                            .controlLabelStyle()
                        Button(GatherLocalization.l("取消选择")) { viewModel.clearSelection() }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                } label: {
                    Text(GatherLocalization.l("选择管理"))
                }

                // 附加统计（对齐 summaryCard 的增强项：已评分/已标记）。
                if let summary = viewModel.summary {
                    GroupBox {
                        Text(String(format: GatherLocalization.l("评分 %lld"), summary.rated))
                        Text(String(format: GatherLocalization.l("标记 %lld"), summary.labeled))
                    } label: {
                        Text(GatherLocalization.l("统计"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private func decisionButton(
        icon: String,
        iconColor: Color,
        title: String,
        shortcut: String,
        key: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        DecisionButtonView(
            icon: icon,
            iconColor: iconColor,
            title: title,
            shortcut: shortcut,
            key: key,
            isBusy: isBusy,
            action: action
        )
    }

    // MARK: infoBar（grid-row 3：位置计数 + 保留/淘汰/未处理统计 + 同步状态 + 同步按钮）。

    private var infoBar: some View {
        // 约束循环修复（A1，与工具栏行同类）：本行原先是不带滚动的 HStack，
        // 最小宽度 = 子控件 + 长文本之和——同步失败时的错误文案 + 重试按钮 +
        // 「同名 RAW/JPEG 共用 XMP…」整句 + 4~5 位计数，这些**只在实际数据下
        // 出现**的内容一旦同时出现就会顶破最小窗口的 680pt 预算。
        // 放进横向滚动容器后，本行的最小宽度不再等于内容总宽。
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
            // 上一张/下一张：可见按钮承载 ←/→ 裸键快捷键（取代窗口级 NSEvent 监听）。
            HStack(spacing: 2) {
                Button { viewModel.retreatCurrent() } label: {
                    Image(systemName: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help(GatherLocalization.l("上一张（←）"))
                .accessibilityLabel(GatherLocalization.l("上一张"))
                Button { viewModel.advanceCurrent() } label: {
                    Image(systemName: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help(GatherLocalization.l("下一张（→）"))
                .accessibilityLabel(GatherLocalization.l("下一张"))
            }
            if let page = viewModel.page {
                Text("\(currentIndex + 1) / \(viewModel.page?.total ?? page.assets.count)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.primaryText)
                    .accessibilityLabel(String(format: GatherLocalization.l("第 %lld 张，共 %lld 张"), currentIndex + 1, viewModel.page?.total ?? page.assets.count))
            }
            if let summary = viewModel.summary {
                Text(String(format: GatherLocalization.l("保留 %lld"), summary.kept))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.success)
                Text(String(format: GatherLocalization.l("淘汰 %lld"), summary.rejected))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.error)
                Text(String(format: GatherLocalization.l("未处理 %lld"), summary.pending))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // linkedNotice：同名 RAW/JPEG 共享 XMP 提示（对齐旧版 Culling.tsx:1393-1397）。
            if let current = viewModel.currentAsset, current.linkedVariantCount > 1 {
                Text(String(format: GatherLocalization.l("同名 RAW/JPEG 共用 XMP，星级和颜色将同步到 %lld 个条目"), current.linkedVariantCount))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(1)
            }
            // 原为 Spacer()（把同步区推到最右）。横向滚动容器里 Spacer 没有
            // 可分配空间，改为固定分隔线：语义上把「照片信息」与「同步动作」分开。
            Divider().frame(height: 16)
            if let sync = viewModel.syncStatus {
                Text(syncStatusText(sync))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(sync.failed + sync.conflict > 0 ? GatherTheme.error : GatherTheme.success)
            }
            if let syncError = viewModel.lastSyncError {
                Text(syncError)
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(1)
                    .help(syncError)
                Button(GatherLocalization.l("重试")) { viewModel.load() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(GatherTheme.error)

            }
            Menu {
                Button(GatherLocalization.l("立即写入 XMP")) { Task { await viewModel.flush() } }
                    .disabled(isBusy)
                Menu {
                    Button(GatherLocalization.l("评分")) { pendingAction = .writeback(.rating) }
                    Button(GatherLocalization.l("颜色标签")) { pendingAction = .writeback(.colorLabel) }
                    Button(GatherLocalization.l("挑片关键词")) { pendingAction = .writeback(.keyword) }
                } label: {
                    Label(GatherLocalization.l("写回 XMP…"), systemImage: "square.and.arrow.up")
                }
                .disabled(!hasDecisions || isBusy)
                .help(GatherLocalization.l("把已决策照片的当前评分/色标/挑片关键词写回 XMP"))
                if (viewModel.syncStatus?.written ?? 0) > 0 {
                    Button(GatherLocalization.l("在 Capture One 中加载元数据")) { Task { await viewModel.reloadCaptureOne() } }
                        .disabled(!viewModel.canLoadMetadata || isBusy)
                        .help(syncLoadHint)
                    Button(GatherLocalization.l("已在 Capture One 加载")) { Task { await viewModel.confirmSync() } }
                        .disabled(!viewModel.canConfirmSync || isBusy)
                        .help(syncConfirmHint)
                }
                if (viewModel.syncStatus?.failed ?? 0) > 0 {
                    Button(GatherLocalization.l("重试失败项")) { pendingAction = .retryFailedWriteback }
                        .disabled(isBusy)
                }
                if (viewModel.syncStatus?.synced ?? 0) > 0 {
                    Button(GatherLocalization.l("保留 XMP 并结束")) { pendingAction = .finalizeSync }
                        .disabled(isBusy)
                    Button(GatherLocalization.l("恢复原 XMP"), role: .destructive) { pendingAction = .cleanup }
                        .disabled(!viewModel.canCleanup)
                        .help(syncCleanupHint)
                }
            } label: {
                Label(GatherLocalization.l("同步…"), systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)

            .help(GatherLocalization.l("先在 Capture One 中 Load Metadata，再返回 Gather 确认同步"))
            Button(GatherLocalization.l("重置挑片"), role: .destructive) { pendingAction = .reset }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(GatherTheme.error)

            }
            .font(.callout)
            .padding(.horizontal, 24)
            .frame(minHeight: 36)
        }
        .background(GatherTheme.contentBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var isBusy: Bool {
        viewModel.isLoading || viewModel.isNavigationBusy || viewModel.isQualityBusy
    }

    /// 写回入口可用性：没有已决策照片就没有可写回的计划（服务端会抛 CULLING_NO_DECISIONS）。
    private var hasDecisions: Bool {
        viewModel.decidedPhotoCount > 0
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

    // MARK: 胶片条（底部全宽横向条：122pt 缩略图 + 色标线 + 星级 + 决策圆点 + 文件名）。
    // 约束：这一层只允许存在一个 ScrollView（横向滚动）。再套一层竖向
    // ScrollView 会在 AppKit 约束更新阶段抛异常（与 Form(.grouped) 进
    // .inspector 的崩溃同源），所以缩略图必须留在同一条横向 LazyHStack 里。

    private var filmstrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text(GatherLocalization.l("胶片"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let page = viewModel.page {
                    Text("\(page.assets.count)\(page.total > page.assets.count ? " / \(page.total)" : "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(String(format: GatherLocalization.l("已载入 %lld 张，共 %lld 张"), page.assets.count, page.total))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(GatherTheme.contentBackground)
            .overlay(alignment: .bottom) { Divider() }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(Array((viewModel.page?.assets ?? []).enumerated()), id: \.element.photo.id) { index, asset in
                            CullingFilmThumbView(viewModel: viewModel, asset: asset)
                                .id(asset.photo.id)
                                // 横向滚动近尾自动续页（原竖向 scrollTop < 400px 的语义：
                                // 尾部 4 个缩略图出现即 loadMore；LazyHStack 的 onAppear
                                // 天然按横向可见性触发，无需改 VM）。
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
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(viewModel.isLoading)
                            // 横向 LazyHStack 里 maxWidth: .infinity 会撑满视口：
                            // 改为与缩略图等高的一格按钮（仍是同一行的行尾出口）。
                            .frame(width: 140, height: 122)
                        }
                    }
                    .padding(8)
                }
                // 当前照片自动滚动（对齐旧版 scrollIntoView block:nearest；横向居中）。
                .onChange(of: viewModel.currentPhotoId) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        // 固定条高 176pt（150–190 区间）：查看器吃掉剩余高度，胶片条保持单行。
        .frame(maxWidth: .infinity)
        .frame(height: 176)
        .background(GatherTheme.contentBackground)
        // 与上方 infoBar 的分隔线（旧版胶片条在右侧时该分隔线在 leading）。
        .overlay(alignment: .top) { Divider() }
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
        if viewModel.conflicts.first != nil || !viewModel.failedSyncItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let conflict = viewModel.conflicts.first {
                    conflictBlock(conflict)
                }
                if !viewModel.failedSyncItems.isEmpty {
                    if viewModel.conflicts.first != nil { Divider() }
                    failureBlock
                }
            }
            .gatherCard()
            .shadow(color: GatherTheme.shadowMd, radius: 12, y: 6)
        }
    }

    /// 单个冲突：展示逐字段差异 + 失败原因 + 两条无障碍出口
    /// （采用外部值 / 保留 Gather 并显式结清）。所有出口都经确认弹窗。
    @ViewBuilder
    private func conflictBlock(_ conflict: MetadataConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(GatherLocalization.l("XMP 字段冲突"), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(GatherTheme.error)
                Spacer()
                Text(URL(fileURLWithPath: conflict.xmpPath).lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(conflict.xmpPath)
            }
            if let reason = viewModel.syncFailureReason(xmpPath: conflict.xmpPath) {
                Text(String(format: GatherLocalization.l("原因：%@"), reason))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(3)
                    .help(reason)
            }
            if conflict.fields.isEmpty {
                Text(GatherLocalization.l("该冲突行没有可逐字段裁决的差异：直接结清即可（保留 Gather 值并以当前磁盘状态为新基线重写）。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    .accessibilityLabel(GatherLocalization.l("冲突处理方式"))
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                        .fill(GatherTheme.secondaryContentBackground)
                )
            }
            HStack {
                Text(viewModel.conflicts.count > 1
                    ? String(format: GatherLocalization.l("还有 %lld 个冲突"), viewModel.conflicts.count - 1)
                    : GatherLocalization.l("这是最后一个冲突"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(GatherLocalization.l("采用外部值")) {
                    pendingAction = .resolveConflict(conflict, choicesForConflict(conflict, .useRemote))
                }
                .help(GatherLocalization.l("丢弃 Gather 待写入值，接受磁盘上的外部修改"))
                Button(GatherLocalization.l("保留 Gather 并结清")) {
                    // 空 choices = 显式结清（coordinator 的第三条出口），字段为空时同样可达。
                    pendingAction = .resolveConflict(conflict, [:])
                }
                .help(GatherLocalization.l("把 Gather 的值写回 XMP，以当前磁盘状态为新基线"))
                if !conflict.fields.isEmpty {
                    Button(GatherLocalization.l("应用选择并继续写入")) {
                        pendingAction = .resolveConflict(conflict, selectedChoices(conflict))
                    }
                }
            }
        }
    }

    /// 失败写回清单：逐条展示路径与 coordinator 写入的真实原因 + 重试出口。
    private var failureBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: GatherLocalization.l("写回失败 %lld 项"), viewModel.failedSyncItems.count))
                    .font(.headline)
                    .foregroundStyle(GatherTheme.error)
                Spacer()
                Button(GatherLocalization.l("重试失败项")) { pendingAction = .retryFailedWriteback }
            }
            ForEach(Array(viewModel.failedSyncItems.prefix(3)), id: \.xmpPath) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                        .font(.callout.weight(.medium))
                    // 上屏走错误码漏斗；原始诊断已由 applySyncStatus 写日志。
                    Text(item.errorMessage.isEmpty
                        ? GatherLocalization.l("未记录原因")
                        : CullingViewModel.funnelErrorText(item.errorMessage))
                        .font(.callout)
                        .foregroundStyle(GatherTheme.error)
                        .lineLimit(3)
                        .help(item.errorMessage.isEmpty ? "" : CullingViewModel.funnelErrorText(item.errorMessage))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                        .fill(GatherTheme.secondaryContentBackground)
                )
            }
            if viewModel.failedSyncItems.count > 3 {
                Text(String(format: GatherLocalization.l("另有 %lld 项失败"), viewModel.failedSyncItems.count - 3))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choicesForConflict(
        _ conflict: MetadataConflict,
        _ choice: MetadataConflictChoice
    ) -> [MetadataField: MetadataConflictChoice] {
        Dictionary(uniqueKeysWithValues: conflict.fields.map { ($0.field, choice) })
    }

    private func selectedChoices(_ conflict: MetadataConflict) -> [MetadataField: MetadataConflictChoice] {
        Dictionary(uniqueKeysWithValues: conflict.fields.map { field in
            (field.field, conflictChoices["\(conflict.xmpPath)|\(field.field.rawValue)"] ?? .keepLocal)
        })
    }

    // MARK: 键盘快捷键（对齐 Culling.tsx:1109-1149 window keydown handler）。
    // 0-5 评分、P 保留、X 淘汰、U 未处理（不前进）、←/→ 翻页。
    // 原生实现：可见控件上的 .keyboardShortcut（任意焦点下窗口级生效），
    // 空格键由查看器的 .onKeyPress 处理；不再使用 NSEvent 局部监听，
    // 也不再需要屏蔽控件焦点的 nonFocusable —— Tab 遍历恢复可用。

    private func emptyGuide(title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .padding(.vertical, 48)
    }

    /// 颜色标签色点（供胶片条/工具列/筛选卡共用）。
    /// C1 色标本身是数据（非状态色），保留固定色值；「无」用语义标签色。
    fileprivate static func colorDot(_ label: CaptureOneColorLabel) -> Color {
        switch label {
        case .none: return Color(nsColor: .secondaryLabelColor)
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
    ///
    /// internal（非 private）供 SyncStatusCopyTests 直测。它与控制中心的
    /// syncStatusText 是**两个语域**（这里是紧凑计数，控制中心是状态句），
    /// 但结论必须一致——G 报告指出旧实现在 items 为空时**无条件**返回
    /// 「XMP 已同步」：若计数查询与行查询不同步（counts 非零而 items 为空），
    /// 同一份 outbox 状态会得到相反结论。
    func syncStatusText(_ sync: MetadataSyncSummary) -> String {
        let hasCounts = sync.conflict + sync.failed + sync.pending + sync.writing + sync.written + sync.synced > 0
        if sync.items.isEmpty && !hasCounts { return GatherLocalization.l("XMP 已同步") }
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

    /// 当前照片的颜色标签（工具列菜单选择器；选中即写入当前照片）。
    private var colorSelectionBinding: Binding<CaptureOneColorLabel?> {
        Binding(
            get: { viewModel.currentAsset?.state.colorLabel },
            set: { value in
                guard let value else { return }
                viewModel.commit(patch: CullingUpdatePatch(colorLabel: value))
            }
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

/// 决策按钮：系统 bordered 按钮（图标 + 标题 + 快捷键提示），
/// 裸键快捷键在按钮自身上声明（任意焦点下窗口级生效）。
private struct DecisionButtonView: View {
    let icon: String
    let iconColor: Color
    let title: String
    let shortcut: String
    let key: KeyEquivalent
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .imageScale(.medium)
                    .foregroundStyle(iconColor)
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        // 裸键由查看器的 onKeyPress 统一注册（见 CullingWorkbenchViewer），
        .disabled(isBusy)
        .help(String(format: GatherLocalization.l("%@（快捷键 %@）"), title, shortcut))
        .accessibilityLabel(title)
        .accessibilityHint(String(format: GatherLocalization.l("快捷键 %@"), shortcut))
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
        // 当前 = 品牌 accent；多选 = accent 半透明（不使用 warning 语义色）。
        if isCurrent { return GatherTheme.accent }
        if isSelected { return GatherTheme.accent.opacity(0.55) }
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
                    // 星级是内容语义（.callout），压在照片上时给深色底保证对比度。
                    Text("\(Int(asset.state.rating))★")
                        .font(.callout)
                        .foregroundStyle(GatherTheme.viewerTextPrimary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.8)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(4)
                }
                if asset.state.pickState != .unreviewed {
                    Circle()
                        .fill(asset.state.pickState == .picked ? GatherTheme.success : GatherTheme.error)
                        .frame(width: 9, height: 9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                        .accessibilityHidden(true)
                }
                Text(asset.photo.filename)
                    .font(.callout)
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
            if let url = finderURLForPath(asset.photo.filepath) {
                Divider()
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .frame(height: 122)
        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isCurrent ? 2.5 : 2)
        )
        .help(asset.photo.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(thumbAccessibilityLabel)
        .accessibilityValue(isSelected ? GatherLocalization.l("已选中") : GatherLocalization.l("未选中"))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var thumbAccessibilityLabel: String {
        let ratingText = asset.state.rating > 0
            ? String(format: GatherLocalization.l("%lld 星"), Int(asset.state.rating))
            : GatherLocalization.l("未评级")
        return "\(asset.photo.filename)，\(ratingText)，\(pickStateTitle(asset.state.pickState))"
    }
}

/// 查看器图片上的深色底徽标：照片背景不可控，内容色固定用 viewerTextPrimary、
/// 图标用语义色，底色用 viewerChrome，保证任何照片上都可读。
private struct ViewerBadge: View {
    let text: String
    let systemImage: String
    var tone: Color = GatherTheme.viewerTextPrimary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tone)
            Text(text)
                .foregroundStyle(GatherTheme.viewerTextPrimary)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
        .accessibilityElement(children: .combine)
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
/// 人脸对齐：把 bbox 中心搬到单元格中心所需的位移。
///
/// 坐标模型（必须与 cellView 的修饰符顺序一致）：
/// - 图像以 **aspect-fit 居中** 显示：显示尺寸 = fit(图像宽高比, 单元格)，两侧/上下留黑；
/// - 修饰符是 .scaleEffect(zoom).offset(d)，即先缩放后平移，d 处于**未缩放的
///   单元格空间**（不是图像空间）；
/// - 因此缩放后点 p 的渲染位置 = center + zoom·(p − center) + d。
/// 令 bbox 中心映射到 center，解得 d = zoom · (0.5 − face) ⊙ displayedFit。
///
/// 旧实现用 (0.5 − face) ⊙ cellSize 且不乘 zoom：竖构图欠平移约 1.6~2×，
/// 任何缩放级下脸都不在中心（审计 B-C1）。
enum FaceAlign {
    static func offset(imageSize: CGSize, cellSize: CGSize, face: [Double], zoom: Double) -> CGSize {
        guard face.count >= 4, cellSize.width > 0, cellSize.height > 0, zoom > 0 else { return .zero }
        let centerX = min(max(face[0] + face[2] / 2, 0), 1)
        let centerY = min(max(face[1] + face[3] / 2, 0), 1)
        let displayed: CGSize
        if imageSize.width > 0, imageSize.height > 0 {
            let fit = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
            displayed = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        } else {
            // 图像尺寸未知（老库/未索引）：退回单元格近似，保守且不放大误差。
            displayed = cellSize
        }
        return CGSize(
            width: zoom * (0.5 - centerX) * displayed.width,
            height: zoom * (0.5 - centerY) * displayed.height
        )
    }
}

/// 拖拽平移的累积（审计 B-C2）：手势 translation 相对**本次手势起点**，
/// 必须叠加本次手势开始时的位移，否则松手再拖会弹回原点。
enum PanOffset {
    static func apply(start: CGSize, translation: CGSize) -> CGSize {
        CGSize(width: start.width + translation.width, height: start.height + translation.height)
    }
}

private struct CullingWorkbenchViewer: View {
    let viewModel: CullingViewModel
    let compareCount: Int
    let faceAlign: Bool

    @State private var scale = 1.0
    /// 底层整图位图（基准档）：细节由可见区域层提供，底层不随缩放抬高。
    @State private var detailBaseSize = PhotoDetailTier.baseDimension
    /// 最近一次单元格布局尺寸（A-6：细节层几何必须按单元格而非整窗计算）。
    @State private var lastCellSize: CGSize = .zero
    /// 可见区域细节层（去抖 150ms 后更新；缩放与平移都会改动它）。
    @State private var detailTileState: PhotoViewerGeometry.DetailTile?
    @State private var detailTileTask: Task<Void, Never>?
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    /// 本次拖拽开始时的位移基线（B-C2）：DragGesture.translation 是相对手势起点
    /// 的累计量，直接赋给 offset 会让每次新手势从 0 起算——松手再拖就弹回原点。
    @State private var dragStartOffset = CGSize.zero
    @State private var hoveredCellId: String?
    @State private var wheelMonitor: Any?
    @State private var viewerWindow: NSWindow?
    /// 查看器区域的 AppKit 代理视图（.background(WindowBridge)）。
    ///
    /// 约束循环修复（F01）：滚轮命中原先比较 GeometryReader 写回 @State 的
    /// .global frame——每帧重排都写观察状态，持续放大约束更新次数。
    /// 改为直接问代理视图「这个点在你 bounds 里吗」：位置由 AppKit 自己维护，
    /// 不产生任何布局反馈。
    @State private var viewerProxy: NSView?

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
        }
        .background(GatherTheme.viewerChrome)
        .clipped()
        .overlay(alignment: .top) {
            // 缩放提示（对齐旧版 zoomHint：居中胶囊，百分比 + 操作提示）。
            Text(String(format: GatherLocalization.l("%lld%% 滚轮缩放 · 拖动平移 · 双击复位 · ⌘−/⌘= 缩放"), Int(effectiveScale * 100)))
                .font(.callout)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.9))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(GatherTheme.viewerSurface.opacity(0.85)))
                .padding(.top, 8)
        }
        .overlay(alignment: .bottomLeading) {
            // 可见缩放控件承载 ⌘−/⌘0/⌘= 快捷键（取代零尺寸全透明的隐藏按钮）。
            HStack(spacing: 4) {
                Button { zoomOut() } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                .help(GatherLocalization.l("缩小（⌘−）"))
                .accessibilityLabel(GatherLocalization.l("缩小"))

                Button { resetTransform() } label: {
                    Image(systemName: "1.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)
                .help(GatherLocalization.l("实际大小（⌘0）"))
                .accessibilityLabel(GatherLocalization.l("实际大小"))

                Button { zoomIn() } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
                .help(GatherLocalization.l("放大（⌘=）"))
                .accessibilityLabel(GatherLocalization.l("放大"))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // 浮在照片之上的功能层控件：macOS 26+ 用 **clear** 玻璃
            // （Apple：clear 专用于浮在照片/视频等媒体之上的组件），
            // 下面本来就有 viewerChrome 深色底，满足「亮媒体需暗化」的前提。
            // 低版本回退到原来的深色胶囊。
            .modifier(ViewerZoomChrome())
        }
        // 空格 = 保留当前照片（裸键不该占用系统快捷键，交给聚焦查看器的 onKeyPress）。
        .focusable()
        .focusEffectDisabled()
        // 裸键（空格 / P / X / U / 0–5）统一挂在这里。
        //
        // 这些键原先注册在检查器里的按钮上，检查器一旦折叠就全部失效——
        // 而 P/X/U 是挑片的主力操作，不能依赖某个面板是否展开。
        // 查看器是本页唯一**始终存在**的控件，且已经为空格使用 onKeyPress。
        .onKeyPress(phases: .down) { press in
            switch press.characters.lowercased() {
            case " ":
                viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
                return .handled
            case "p":
                viewModel.commit(patch: CullingUpdatePatch(pickState: .picked))
                return .handled
            case "x":
                viewModel.commit(patch: CullingUpdatePatch(pickState: .rejected))
                return .handled
            case "u":
                viewModel.commit(patch: CullingUpdatePatch(pickState: .unreviewed))
                return .handled
            case "0", "1", "2", "3", "4", "5":
                guard let value = Int(press.characters) else { return .ignored }
                viewModel.commit(patch: CullingUpdatePatch(rating: Double(value)))
                return .handled
            default:
                return .ignored
            }
        }
        .background(WindowBridge { window, view in
            // 只在身份真正变化时写状态：updateNSView 每次布局都会回调，
            // 无条件赋值等于每次布局都排一轮视图更新（又是新的反馈环）。
            if viewerWindow !== window { viewerWindow = window }
            if viewerProxy !== view { viewerProxy = view }
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
        // 可见区域细节层：缩放或平移停止 150ms 后重算「可见矩形」，只重解那一块。
        .onChange(of: scale) { _, _ in scheduleDetailTileUpdate() }
        .onChange(of: offset) { _, _ in scheduleDetailTileUpdate() }
    }

    /// 对比单元格：黑底 + 缩放/平移手势 + 底部字幕条 + 徽标 + hover 主色描边 + 双击复位。
    private func cellView(_ cell: ViewerCell) -> some View {
        let asset = cell.asset
        return GeometryReader { cellGeometry in
            // A-6：单元格尺寸只经生命周期回调写状态（**不在 body 求值期间写 @State**，
            // 否则触发 SwiftUI「Modifying state during view update」与额外布局循环）。
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear {
                    if cell.asset.photo.id == currentAsset?.photo.id { lastCellSize = cellGeometry.size }
                }
                .onChange(of: cellGeometry.size) { _, newSize in
                    if cell.asset.photo.id == currentAsset?.photo.id {
                        lastCellSize = newSize
                        // A-6 残余（第二轮验证）：尺寸变化（拖窗口/切对比模式）后
                        // 贴片几何也要重算，否则放大态下会错位到下次平移/缩放。
                        scheduleDetailTileUpdate()
                    }
                }
            // B-C1：人脸对齐必须按「fit 后的图像显示尺寸」算，并乘上缩放级。
            // 旧实现用单元格尺寸且漏乘 zoom → 竖构图两轴欠平移 1.6~2×，
            // 任何缩放级下脸都不在中心。
            let alignOffset: CGSize = {
                guard faceAlign, let face = asset.faceBboxes.first else { return .zero }
                return FaceAlign.offset(
                    imageSize: CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height)),
                    cellSize: cellGeometry.size,
                    face: face,
                    zoom: max(2, scale)
                )
            }()
            ZStack(alignment: .bottom) {
                // 整图适配（对齐旧版 .viewerImage object-fit: contain）：窄容器
                // 时整体缩放而非裁切，缩放级作用于完整画面。
                // allowsHitTesting(false)：scaleEffect 放大后命中区域会外溢到
                // 单元格之外（.clipped() 只裁剪渲染不裁剪命中），吞掉工具栏/
                // 工具列/胶片条的点击——人脸对齐开启后必须把命中限定在单元格内。
                // 底层：整图低分辨率位图（基准档），负责构图与手势，立即显示不闪。
                // 放大后的真实细节由下面的**可见区域细节层**负责（只解可见区域，
                // 不整图重解——Bridge / Capture One 的 tiled detail 语义）。
                PhotoThumbnailView(
                    path: asset.photo.filepath,
                    size: detailBaseSize,
                    preview: true,
                    contentMode: .fit
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(effectiveZoom)
                    .offset(x: offset.width + alignOffset.width, y: offset.height + alignOffset.height)
                    .allowsHitTesting(false)
                // 可见区域细节层：按同一套几何算出「真正可见的图像矩形」，
                // 只解码这一块（detailTileState 由缩放/平移变化去抖驱动）。
                // A-6 残余（第二轮验证）：detailTileState 是整页唯一状态，其几何来自
                // currentAsset；非当前格把「当前照片的可见区域」贴到别人的底图上会错位
                //（宽高比不同时明显）。只让当前格渲染贴片。
                if let tile = detailTileState, cell.asset.photo.id == currentAsset?.photo.id {
                    PhotoDetailTileView(
                        path: asset.photo.filepath,
                        normalizedRect: tile.normalizedRect,
                        targetPixel: PhotoViewerGeometry.tilePixelSize(
                            viewRect: tile.viewRect,
                            budgetDimension: PhotoDetailTier.budget(forVisibleCells: max(1, compareCount))
                        ),
                        onUnavailable: {
                            // 区域解码不可用 → 退回整图高档位（渐进档位逻辑保留为兜底）。
                            detailBaseSize = PhotoDetailTier.target(
                                fitPoints: Self.fitPoints(
                                    imageSize: CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height)),
                                    cellSize: cellGeometry.size
                                ),
                                zoom: effectiveZoom,
                                backingScale: Double(NSScreen.main?.backingScaleFactor ?? 2),
                                sourceMaxDimension: Int(max(asset.photo.width, asset.photo.height))
                            )
                        }
                    )
                    .frame(width: max(0, tile.viewRect.width), height: max(0, tile.viewRect.height))
                    .position(x: tile.viewRect.midX, y: tile.viewRect.midY)
                    .allowsHitTesting(false)
                }
                // 底部字幕条（文件名 / 来源 / 星级）。
                HStack(spacing: 8) {
                    Text(asset.photo.filename).lineLimit(1)
                    Spacer()
                    Text(sourceLabel(asset))
                        .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                    Text(asset.state.rating > 0 ? "\(Int(asset.state.rating))★" : GatherLocalization.l("未评级"))
                }
                .font(.callout)
                .foregroundStyle(GatherTheme.viewerTextPrimary.opacity(0.92))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(GatherTheme.viewerSurface.opacity(0.9))
                // 右上保留/淘汰徽标。
                if asset.state.pickState != .unreviewed {
                    ViewerBadge(
                        text: asset.state.pickState == .picked ? GatherLocalization.l("保留") : GatherLocalization.l("淘汰"),
                        systemImage: asset.state.pickState == .picked ? "checkmark" : "xmark",
                        tone: asset.state.pickState == .picked ? GatherTheme.success : GatherTheme.error
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                }
                // 左上无脸徽标（仅人脸对齐开启且该照片无检测结果时）。
                if faceAlign && asset.faceBboxes.isEmpty {
                    ViewerBadge(
                        text: GatherLocalization.l("未检测到人脸"),
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                }
                // 右下质量徽标（对齐旧版 qualityBadge + warnings ⚠）。
                if let quality = asset.quality {
                    ViewerBadge(
                        text: qualityBadgeText(quality),
                        systemImage: "sparkles",
                        tone: GatherTheme.info
                    )
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
                RoundedRectangle(cornerRadius: GatherTheme.Radius.panel, style: .continuous)
                    .stroke(hoveredCellId == cell.id ? GatherTheme.accent.opacity(0.65) : GatherTheme.viewerSurface, lineWidth: 1)
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
                        offset = PanOffset.apply(start: dragStartOffset, translation: value.translation)
                    }
                    .onEnded { _ in
                        // 提交本次位移作为下次拖拽的基线（累积平移）。
                        dragStartOffset = offset
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
            // 上屏走错误码漏斗（原始诊断已由 logQualityFailures 写日志），
            // 不把分析器的结构化描述直接铺在 tooltip 里。
            guard let raw = quality.errorMessage, !raw.isEmpty else {
                return GatherLocalization.l("质量分析失败")
            }
            return CullingViewModel.funnelErrorText(raw)
        }
        let sharpness = Int((quality.subjectSharpness ?? quality.sharpness) * 100)
        let exposure = Int(quality.exposure * 100)
        return String(format: GatherLocalization.l("AI 技术分析：清晰度 %lld%%，曝光 %lld%%"), sharpness, exposure)
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
        dragStartOffset = .zero
    }

    /// 缩放/平移停止后重算可见区域细节层（150ms 去抖：拖动过程不排重解码队列）。
    private func scheduleDetailTileUpdate() {
        // A-6（性能审计）：几何必须用**当前单元格**的尺寸与**当前照片**的宽高。
        // 旧实现取 viewerProxy 整窗尺寸 + page.assets.first：2×2 对比时可见区域
        // 按整窗算（面积最多 4 倍），并把第一张照片的宽高套到其它格（贴片错位）。
        let size = lastCellSize
        guard size.width > 0, size.height > 0, let asset = currentAsset else { return }
        let imageSize = CGSize(width: Double(asset.photo.width), height: Double(asset.photo.height))
        let zoom = effectiveZoom
        let pan = CGSize(
            width: offset.width + (faceAlign ? currentAlignOffset(imageSize: imageSize, cellSize: size).width : 0),
            height: offset.height + (faceAlign ? currentAlignOffset(imageSize: imageSize, cellSize: size).height : 0)
        )
        let budget = PhotoDetailTier.budget(forVisibleCells: max(1, compareCount))
        detailTileTask?.cancel()
        detailTileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let tile = PhotoViewerGeometry.detailTile(
                imageSize: imageSize,
                viewSize: size,
                zoom: Double(zoom),
                panOffset: pan,
                backingPixelBudget: detailBaseSize
            )
            // 缩回 1× 或细节层不再需要时清掉（避免留下过期贴片）。
            detailTileState = tile
        }
    }

    /// 当前渲染用的缩放级（人脸对齐时会把倍率抬到至少 2×）。
    private var effectiveZoom: Double {
        faceAlign ? max(2, scale) : scale
    }

    /// 当前人脸对齐位移（与 cellView 内计算的是同一个模型）。
    private func currentAlignOffset(imageSize: CGSize, cellSize: CGSize) -> CGSize {
        guard let asset = currentAsset, let face = asset.faceBboxes.first else { return .zero }
        return FaceAlign.offset(
            imageSize: imageSize,
            cellSize: cellSize,
            face: face,
            zoom: max(2, scale)
        )
    }

    /// 适配显示尺寸的最长边（pt）——与 contentMode .fit 的几何一致。
    /// 用于「区域解码不可用」时的整图高档位兜底（见 cellView 的 onUnavailable）。
    static func fitPoints(imageSize: CGSize, cellSize: CGSize) -> Double {
        guard imageSize.width > 0, imageSize.height > 0, cellSize.width > 0, cellSize.height > 0 else { return 0 }
        let fitScale = min(cellSize.width / imageSize.width, cellSize.height / imageSize.height)
        return Double(max(imageSize.width, imageSize.height) * fitScale)
    }

    // （原「整图渐进档位」的调度已由可见区域细节层取代；整图高档位仅在区域解码
    //   不可用时作为兜底，见 cellView 的 onUnavailable 回调。）

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
        // 仅响应查看器窗口内、指针位于查看器区域上的滚动事件。
        // 命中区域直接取代理视图的 bounds（AppKit 维护），不再读写
        // GeometryReader 的坐标（见 viewerProxy 注）。
        guard let window = viewerWindow, event.window === window,
              let proxy = viewerProxy, proxy.window === window else { return }
        let point = proxy.convert(event.locationInWindow, from: nil)
        guard proxy.bounds.contains(point) else { return }
        let next = min(8, max(1, scale * (event.scrollingDeltaY < 0 ? 1.15 : 0.87)))
        guard next != scale else { return }
        scale = next
        gestureScale = next
    }
}

/// 获取承载视图的 NSWindow（滚轮事件监听的窗口归属判断用）。
private struct WindowBridge: NSViewRepresentable {
    /// (window, proxyView)：proxyView 即本 representable 的宿主视图，
    /// 其 bounds 就是查看器区域（滚轮命中的坐标系来源）。
    let onResolve: (NSWindow?, NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window, view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window, nsView) }
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

/// 检查器 Section / 胶片条控制组标签样式（原生化：.callout 承载内容语义，中文不再加字距）。
private extension View {
    func controlLabelStyle() -> some View {
        font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

// 注：旧版为让窗口级 NSEvent 快捷键生效，曾对整个挑片页控件施加
// focusable(false)；快捷键已改为控件自身的 .keyboardShortcut + 查看器的
// .onKeyPress，焦点屏蔽全部移除，Tab 遍历恢复系统默认行为。


// MARK: - 查看器缩放控件的功能层材质

/// 缩放控件浮在照片之上，属于 Liquid Glass 的**功能层**。
/// macOS 26+ 用 `.glass(.clear)`；更早版本保留原来的深色胶囊。
private struct ViewerZoomChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.clear, in: .capsule)
                .padding(.leading, 12)
                .padding(.bottom, 40)
        } else {
            content
                .background(Capsule().fill(GatherTheme.viewerChrome.opacity(0.85)))
                .padding(.leading, 12)
                .padding(.bottom, 40)
        }
    }
}
