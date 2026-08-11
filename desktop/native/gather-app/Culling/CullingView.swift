// Phase 3.4：挑片、状态写回和同步控制 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Culling.tsx + culling.ipc.ts。
import SwiftUI
import GatherCore

@MainActor
@Observable
public final class CullingViewModel {
    public enum FilterMode: String, CaseIterable, Equatable {
        case all
        case unreviewed
        case picked
        case rejected
        case conflicts
        case qualityAnalysed
        case qualityUnanalysed
        case qualityFailed

        var title: String {
            switch self {
            case .all: return "全部"
            case .unreviewed: return "待挑选"
            case .picked: return "保留"
            case .rejected: return "拒绝"
            case .conflicts: return "元数据冲突"
            case .qualityAnalysed: return "已分析质量"
            case .qualityUnanalysed: return "未分析质量"
            case .qualityFailed: return "质量失败"
            }
        }
    }

    public enum ScopeMode: String, CaseIterable, Equatable {
        case all
        case filtered
        case similarityGroup

        var title: String {
            switch self {
            case .all: return "全部照片"
            case .filtered: return "按筛选"
            case .similarityGroup: return "相似度分组"
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
    public var filterMode: FilterMode = .all
    public private(set) var selectedPhotoIds: Set<String> = []
    private(set) public var navigationGroups: [NavigationGroup] = []
    private(set) public var isNavigationBusy = false
    public private(set) var selectedNavigationGroupId = ""
    public private(set) var selectedNavigationGroupIds: Set<String> = []
    private(set) public var similarityGroups: [CullingGroup] = []
    public var scopeMode: ScopeMode = .all
    public private(set) var selectedSimilarityGroupId = ""

    public init(sessionId: String, router: CommandRouter) {
        self.sessionId = sessionId
        self.client = NativeCommandClient(router: router)
        self.captureOne = CaptureOneBridge(router: router)
    }

    public func load() {
        loadNavigation()
        loadPage(reset: true)
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
            notice = "技术质量分析已排队"
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                let jobs = try client.execute("jobs.list", params: [:]).decoded(as: [AnalysisJobData].self)
                guard let latest = jobs.first(where: { $0.id == job.id }) else { return }
                qualityJob = latest
                switch latest.status {
                case .queued, .running, .cancelling:
                    continue
                case .succeeded:
                    notice = "技术质量分析已完成"
                    loadPage(reset: true)
                    return
                case .failed, .cancelled, .interrupted:
                    errorMessage = latest.errorMessage.isEmpty ? "技术质量分析未完成" : latest.errorMessage
                    loadPage(reset: true)
                    return
                }
            }
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
            notice = dryRun ? "已生成导航组预览，未写入工作区" : "导航组已分析并保存"
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
            errorMessage = "请选择导航组和拆分位置"
            return
        }
        do {
            navigationGroups = try client.execute("navigation.split", params: [
                "sessionId": .string(sessionId),
                "groupId": .string(selectedNavigationGroupId),
                "beforePhotoId": .string(beforePhotoId),
            ]).decoded(as: [NavigationGroup].self)
            normalizeNavigationSelection()
            notice = "导航组已拆分"
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func mergeSelectedNavigationGroups() {
        guard selectedNavigationGroupIds.count >= 2 else {
            errorMessage = "请选择至少两个导航组"
            return
        }
        do {
            navigationGroups = try client.execute("navigation.merge", params: [
                "sessionId": .string(sessionId),
                "groupIds": .array(selectedNavigationGroupIds.sorted().map(JSONValue.string)),
            ]).decoded(as: [NavigationGroup].self)
            selectedNavigationGroupIds = []
            normalizeNavigationSelection()
            notice = "导航组已合并"
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    private func normalizeNavigationSelection() {
        if !navigationGroups.contains(where: { $0.id == selectedNavigationGroupId }) {
            selectedNavigationGroupId = navigationGroups.first?.id ?? ""
        }
        let validIds = Set(navigationGroups.map(\.id))
        selectedNavigationGroupIds = selectedNavigationGroupIds.intersection(validIds)
    }

    public func loadMore() {
        guard !isLoading, page?.nextRowId != nil else { return }
        loadPage(reset: false)
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
            if scope == .filtered, let filters = filtersForCurrentMode() {
                params["filters"] = try JSONValue(from: filters)
            }
            if scope == .similarityGroup {
                guard !selectedSimilarityGroupId.isEmpty else {
                    page = CullingPage(assets: [], nextRowId: nil, total: 0)
                    return
                }
                params["groupId"] = .string(selectedSimilarityGroupId)
            }
            if !reset, let afterRowId = page?.nextRowId {
                params["afterRowId"] = .number(Double(afterRowId))
            }
            let nextPage = try client.execute("culling.list_page", params: params).decoded(as: CullingPage.self)
            if reset || page == nil {
                page = nextPage
                selectedPhotoIds = []
            } else if let oldPage = page {
                page = CullingPage(
                    assets: oldPage.assets + nextPage.assets,
                    nextRowId: nextPage.nextRowId,
                    total: nextPage.total
                )
            }
            summary = try client.execute("culling.summary", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: CullingSummary.self)
            similarityGroups = (try? client.execute("culling.groups", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [CullingGroup].self)) ?? []
            if !similarityGroups.contains(where: { $0.groupId == selectedSimilarityGroupId }) {
                selectedSimilarityGroupId = similarityGroups.first?.groupId ?? ""
            }
            syncStatus = try? client.execute("culling.sync_status", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: MetadataSyncSummary.self)
            history = (try? client.execute("culling.history", params: [
                "sessionId": .string(sessionId),
                "limit": .number(100),
            ]).decoded(as: [CullingHistoryOperation].self)) ?? []
            conflicts = (try? client.execute("metadata.conflicts", params: [
                "sessionId": .string(sessionId),
            ]).decoded(as: [MetadataConflict].self)) ?? []
            errorMessage = nil
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    private func filtersForCurrentMode() -> CullingFilters? {
        switch filterMode {
        case .all: return nil
        case .unreviewed: return CullingFilters(pickStates: [.unreviewed])
        case .picked: return CullingFilters(pickStates: [.picked])
        case .rejected: return CullingFilters(pickStates: [.rejected])
        case .conflicts: return CullingFilters(metadataConflictOnly: true)
        case .qualityAnalysed: return CullingFilters(qualityStatus: .analysed)
        case .qualityUnanalysed: return CullingFilters(qualityStatus: .unanalysed)
        case .qualityFailed: return CullingFilters(qualityStatus: .failed)
        }
    }

    public func setFilter(_ mode: FilterMode) {
        guard filterMode != mode || (mode == .all && scopeMode != .all) else { return }
        filterMode = mode
        scopeMode = mode == .all ? .all : .filtered
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

    public func decideSimilarityGroup(_ group: CullingGroup, keepPhotoIds: [String]) {
        let validIds = Set(group.images.map(\.photoId))
        guard !keepPhotoIds.isEmpty, Set(keepPhotoIds).isSubset(of: validIds) else {
            errorMessage = "请选择当前相似度组中的照片"
            return
        }
        do {
            _ = try client.execute("culling.decide_group", params: [
                "sessionId": .string(sessionId),
                "groupId": .string(group.groupId),
                "keepPhotoIds": .array(keepPhotoIds.map(JSONValue.string)),
            ])
            notice = "已更新相似度组挑片决策"
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
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

    public func update(_ asset: CullingAsset, patch: CullingUpdatePatch) {
        do {
            _ = try client.execute("culling.update", params: [
                "sessionId": .string(sessionId),
                "photoId": .string(asset.photo.id),
                "expectedRevision": .number(Double(asset.state.revision)),
                "patch": try JSONValue(from: patch),
            ])
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func batchUpdate(patch: CullingUpdatePatch) {
        guard !selectedPhotoIds.isEmpty else {
            errorMessage = "请选择至少一张照片"
            return
        }
        do {
            _ = try client.execute("culling.batch_update", params: [
                "sessionId": .string(sessionId),
                "photoIds": .array(selectedPhotoIds.sorted().map(JSONValue.string)),
                "patch": try JSONValue(from: patch),
            ])
            notice = "已更新 \(selectedPhotoIds.count) 张照片"
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func undo() {
        guard let operation = history.first(where: { !$0.undone }) else {
            notice = "没有可撤销的挑片操作"
            return
        }
        applyHistory(operation, direction: .undo)
    }

    public func redo() {
        guard let operation = history.first(where: { $0.undone }) else {
            notice = "没有可重做的挑片操作"
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
            _ = try client.execute("culling.apply_history", params: [
                "sessionId": .string(sessionId),
                "entries": .array(entries),
                "historyOperationId": .number(Double(operation.id)),
                "direction": .string(direction.rawValue),
            ])
            notice = direction == .undo ? "已撤销上一次挑片操作" : "已重做挑片操作"
            loadPage(reset: true)
        } catch {
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
            syncStatus = try? data.decoded(as: MetadataSyncSummary.self)
            notice = "已写回 \(targetLabel(target))；请让 Capture One 重新加载元数据后确认同步"
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
            syncStatus = try? data.decoded(as: MetadataSyncSummary.self)
            notice = retry ? "已重试同步队列" : "已刷新同步队列"
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
            syncStatus = try? data.decoded(as: MetadataSyncSummary.self)
            notice = "已重试失败写回项"
            loadPage(reset: true)
        } catch {
            errorMessage = NativeCommandClient.message(for: error)
        }
    }

    public func reloadCaptureOne() async {
        do {
            try await captureOne.reloadMetadata(sessionId: sessionId)
            notice = "Capture One 已重新加载元数据，现在可以确认同步"
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func confirmSync() {
        do {
            _ = try client.execute("culling.confirm_sync", params: ["sessionId": .string(sessionId)])
            notice = "已确认 Capture One 同步"
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
            notice = "已完成元数据同步"
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
            notice = "已清理可安全删除的备份"
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
            notice = "已重置挑片状态"
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
            notice = "已处理元数据冲突"
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
        case .rating: return "评分"
        case .colorLabel: return "颜色标签"
        case .keyword: return "关键字"
        }
    }
}

public struct CullingView: View {
    @State private var viewModel: CullingViewModel
    private let onBack: () -> Void
    @State private var writebackTarget: CullingWritebackTarget?
    @State private var confirmReset = false
    @State private var confirmCleanup = false
    @State private var confirmFinalize = false
    @State private var groupDecisionTarget: CullingGroup?
    @State private var groupDecisionKeepIds: [String] = []
    @State private var conflictChoices: [String: MetadataConflictChoice] = [:]
    @State private var viewerIndex: Int?

    public init(sessionId: String, router: CommandRouter, onBack: @escaping () -> Void = {}) {
        _viewModel = State(initialValue: CullingViewModel(sessionId: sessionId, router: router))
        self.onBack = onBack
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage { NativeBanner(text: error, color: .red) }
            if let notice = viewModel.notice { NativeBanner(text: notice, color: .green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filterCard
                    navigationCard
                    similarityGroupCard
                    syncCard
                    if let summary = viewModel.summary { summaryCard(summary) }
                    conflictCard
                    if let page = viewModel.page {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(Array(page.assets.enumerated()), id: \.element.photo.id) { index, asset in
                                assetCard(asset, index: index)
                            }
                        }
                        if page.nextRowId != nil {
                            Button("加载更多（已加载 \(page.assets.count) / \(page.total)）") {
                                viewModel.loadMore()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { viewModel.load() }
        .confirmationDialog(
            "确认写回 Capture One？",
            isPresented: Binding(
                get: { writebackTarget != nil },
                set: { if !$0 { writebackTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认写回") {
                guard let target = writebackTarget else { return }
                writebackTarget = nil
                Task { await viewModel.writeback(target: target) }
            }
            Button("取消", role: .cancel) { writebackTarget = nil }
        } message: {
            Text("这会把已排队的挑片元数据写入 XMP。写入后仍需重新加载 Capture One，再确认同步。")
        }
        .confirmationDialog("确认重置挑片状态？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) { viewModel.reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重置只清除 Gather 中的挑片决策，不删除照片文件。")
        }
        .confirmationDialog("确认清理写回备份？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("清理", role: .destructive) { Task { await viewModel.cleanup() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅在 Capture One 已重新加载并确认同步后清理备份。")
        }
        .confirmationDialog("确认完成元数据同步？", isPresented: $confirmFinalize, titleVisibility: .visible) {
            Button("完成同步", role: .destructive) { Task { await viewModel.finalizeSync() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只有在 Capture One 已重新加载并确认同步后，才应关闭本次同步记录。")
        }
        .confirmationDialog("确认更新相似度组决策？", isPresented: Binding(
            get: { groupDecisionTarget != nil },
            set: { if !$0 { groupDecisionTarget = nil; groupDecisionKeepIds = [] } }
        ), titleVisibility: .visible) {
            Button("确认更新", role: .destructive) {
                if let group = groupDecisionTarget {
                    viewModel.decideSimilarityGroup(group, keepPhotoIds: groupDecisionKeepIds)
                }
                groupDecisionTarget = nil
                groupDecisionKeepIds = []
            }
            Button("取消", role: .cancel) {
                groupDecisionTarget = nil
                groupDecisionKeepIds = []
            }
        } message: {
            Text("未选中的成员会被标记为拒绝；照片文件不会删除。")
        }
        .sheet(isPresented: Binding(
            get: { viewerIndex != nil },
            set: { if !$0 { viewerIndex = nil } }
        )) {
            if let viewerIndex, let assets = viewModel.page?.assets {
                CullingViewerView(
                    assets: assets,
                    initialIndex: viewerIndex,
                    onClose: { self.viewerIndex = nil }
                )
            }
        }
    }

    private var header: some View {
        HStack {
            Button("返回", systemImage: "chevron.left", action: onBack).buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text("挑片与写回").font(.system(size: 24, weight: .bold))
                Text("工作区 \(viewModel.sessionId.prefix(8))").foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新", systemImage: "arrow.clockwise") { viewModel.load() }
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filterCard: some View {
        HStack(spacing: 12) {
            Picker("筛选", selection: Binding(
                get: { viewModel.filterMode },
                set: { viewModel.setFilter($0) }
            )) {
                ForEach(CullingViewModel.FilterMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .frame(width: 170)
            Picker("范围", selection: Binding(
                get: { viewModel.scopeMode },
                set: { viewModel.setScope($0) }
            )) {
                ForEach(CullingViewModel.ScopeMode.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .frame(width: 150)
            if viewModel.scopeMode == .similarityGroup, !viewModel.similarityGroups.isEmpty {
                Picker("相似度组", selection: Binding(
                    get: { viewModel.selectedSimilarityGroupId },
                    set: { viewModel.selectSimilarityGroup($0) }
                )) {
                    ForEach(viewModel.similarityGroups, id: \.groupId) { group in
                        Text("组 \(group.groupIndex) · \(group.images.count) 张").tag(group.groupId)
                    }
                }
                .frame(width: 160)
            }
            if !viewModel.selectedPhotoIds.isEmpty {
                Text("已选 \(viewModel.selectedPhotoIds.count) 张")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Menu("批量操作") {
                    Button("批量保留") { viewModel.batchUpdate(patch: CullingUpdatePatch(pickState: .picked)) }
                    Button("批量拒绝") { viewModel.batchUpdate(patch: CullingUpdatePatch(pickState: .rejected)) }
                    Button("批量待定") { viewModel.batchUpdate(patch: CullingUpdatePatch(pickState: .unreviewed)) }
                    Divider()
                    Button("清除选择") { viewModel.clearSelection() }
                }
            }
            Button("全选已加载") { viewModel.selectAllLoaded() }
            Button("撤销") { viewModel.undo() }.disabled(viewModel.history.first(where: { !$0.undone }) == nil)
            Button("重做") { viewModel.redo() }.disabled(viewModel.history.first(where: { $0.undone }) == nil)
            Button(viewModel.isQualityBusy ? "技术质量分析中…" : "分析技术质量") {
                Task { await viewModel.analyzeQuality() }
            }
            .disabled(viewModel.isQualityBusy)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("元数据同步").font(.headline)
                    if let sync = viewModel.syncStatus {
                        Text("待处理 \(sync.pending) · 写入中 \(sync.writing) · 已写入 \(sync.written) · 失败 \(sync.failed) · 冲突 \(sync.conflict)")
                            .font(.caption)
                            .foregroundStyle(sync.failed + sync.conflict > 0 ? .red : .secondary)
                    } else {
                        Text("状态未知").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu("写回") {
                    Button("评分") { writebackTarget = .rating }
                    Button("颜色标签") { writebackTarget = .colorLabel }
                    Button("关键字") { writebackTarget = .keyword }
                }
                Button("刷新队列") { Task { await viewModel.flush() } }
                Button("重试同步") { Task { await viewModel.flush(retry: true) } }
                Button("重试失败写回") { Task { await viewModel.retryFailedWriteback() } }
            }
            HStack {
                Button("Capture One 重新加载") { Task { await viewModel.reloadCaptureOne() } }
                Button("确认已同步") { viewModel.confirmSync() }
                if viewModel.syncStatus?.synced ?? 0 > 0 {
                    Button("完成同步") { confirmFinalize = true }
                }
                Button("清理备份", role: .destructive) { confirmCleanup = true }
                Spacer()
                Button("重置挑片", role: .destructive) { confirmReset = true }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var navigationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("导航组").font(.headline)
                    Text("按连拍/场景组织照片，支持预览、拆分和合并。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { viewModel.loadNavigation() }
                Button("预览分析") {
                    Task { await viewModel.analyzeNavigation(dryRun: true) }
                }
                .disabled(viewModel.isNavigationBusy)
                Button("分析并保存") {
                    Task { await viewModel.analyzeNavigation(dryRun: false) }
                }
                .disabled(viewModel.isNavigationBusy)
            }
            if viewModel.navigationGroups.isEmpty {
                Text("暂无导航组；可先执行预览分析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("导航组（可多选合并）")
                            .font(.caption.weight(.semibold))
                        ForEach(viewModel.navigationGroups, id: \.id) { group in
                            HStack(spacing: 6) {
                                Toggle("", isOn: Binding(
                                    get: { viewModel.selectedNavigationGroupIds.contains(group.id) },
                                    set: { _ in viewModel.toggleNavigationGroup(group.id) }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                Button {
                                    viewModel.selectNavigationGroup(group.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(group.type.rawValue) · \(group.photoIds.count) 张")
                                            .font(.caption)
                                        Text(group.explanation.isEmpty ? group.source.rawValue : group.explanation)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button("合并已选（\(viewModel.selectedNavigationGroupIds.count)）") {
                            viewModel.mergeSelectedNavigationGroups()
                        }
                        .disabled(viewModel.selectedNavigationGroupIds.count < 2 || viewModel.isNavigationBusy)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("拆分当前组").font(.caption.weight(.semibold))
                        if let group = viewModel.navigationGroups.first(where: { $0.id == viewModel.selectedNavigationGroupId }) {
                            Text("可在下列照片之前拆分：")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(Array(group.photoIds.dropFirst()), id: \.self) { photoId in
                                Button("在 (photoId) 之前拆分") {
                                    viewModel.splitNavigation(beforePhotoId: photoId)
                                }
                                .font(.caption)
                                .disabled(viewModel.isNavigationBusy)
                            }
                        } else {
                            Text("请选择导航组")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 220, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var similarityGroupCard: some View {
        if !viewModel.similarityGroups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("相似度组决策").font(.headline)
                    Text("可保留一张并拒绝其余成员").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(viewModel.similarityGroups, id: \.groupId) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("组 \(group.groupIndex) · \(group.images.count) 张")
                                    .font(.caption.weight(.semibold))
                                Text("保留 \(group.keepCount) · 拒绝 \(group.rejectCount) · 待定 \(group.pendingCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    Button("只保留第一张") {
                                        groupDecisionTarget = group
                                        groupDecisionKeepIds = group.images.first.map { [$0.photoId] } ?? []
                                    }
                                    .disabled(group.images.count < 2)
                                    Button("查看组") {
                                        viewModel.selectSimilarityGroup(group.groupId)
                                    }
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }

    @ViewBuilder
    private var conflictCard: some View {
        if !viewModel.conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("元数据冲突（\(viewModel.conflicts.count)）").font(.headline)
                ForEach(viewModel.conflicts, id: \.xmpPath) { conflict in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: conflict.photoPath).lastPathComponent)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        ForEach(conflict.fields, id: \.field.rawValue) { field in
                            let key = "\(conflict.xmpPath)|\(field.field.rawValue)"
                            HStack(spacing: 8) {
                                Text(field.field.rawValue)
                                    .frame(width: 70, alignment: .leading)
                                Text("Gather：\(valueLabel(field.local))")
                                    .lineLimit(1)
                                Text("文件：\(valueLabel(field.remote))")
                                    .lineLimit(1)
                                Picker("处理", selection: Binding(
                                    get: { conflictChoices[key] ?? .keepLocal },
                                    set: { conflictChoices[key] = $0 }
                                )) {
                                    Text("保留 Gather").tag(MetadataConflictChoice.keepLocal)
                                    Text("使用文件").tag(MetadataConflictChoice.useRemote)
                                }
                                .pickerStyle(.menu)
                            }
                        }
                        Button("应用当前冲突选择") {
                            let choices = Dictionary(uniqueKeysWithValues: conflict.fields.map { field in
                                (field.field, conflictChoices["\(conflict.xmpPath)|\(field.field.rawValue)"] ?? .keepLocal)
                            })
                            viewModel.resolve(conflict, choices: choices)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        }
    }

    private func summaryCard(_ summary: CullingSummary) -> some View {
        HStack(spacing: 18) {
            summaryValue("总计", summary.totalPhotos)
            summaryValue("保留", summary.kept)
            summaryValue("拒绝", summary.rejected)
            summaryValue("待定", summary.pending)
            summaryValue("已评分", summary.rated)
            summaryValue("已标记", summary.labeled)
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func valueLabel(_ value: GatherCore.JSONValue) -> String {
        switch value {
        case .null: return "空"
        case .bool(let value): return value ? "是" : "否"
        case .number(let value): return String(value)
        case .string(let value): return value.isEmpty ? "空" : value
        case .array(let values): return values.map(valueLabel).joined(separator: ", ")
        case .object: return "对象"
        }
    }

    private func summaryValue(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.weight(.semibold))
        }
    }

    private func assetCard(_ asset: CullingAsset, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Button {
                    viewerIndex = index
                } label: {
                    PhotoThumbnailView(path: asset.photo.filepath, size: 300, placeholderSize: CGSize(width: 230, height: 160))
                }
                .buttonStyle(.plain)
                Toggle("", isOn: Binding(
                    get: { viewModel.selectedPhotoIds.contains(asset.photo.id) },
                    set: { _ in viewModel.toggleSelection(asset.photo.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(8)
            }
            Text(asset.photo.filename).font(.caption).lineLimit(1)
            HStack {
                Text(asset.state.pickState.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("★ \(Int(asset.state.rating))").font(.caption)
            }
            if let quality = asset.quality {
                Text(quality.status == .succeeded
                    ? "技术质量 \(Int(quality.score * 100))% · 清晰度 \(Int(quality.sharpness * 100))%"
                    : "技术质量分析失败\(quality.errorMessage.map { "：\($0)" } ?? "")")
                    .font(.caption2)
                    .foregroundStyle(quality.status == .succeeded ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                Button("保留") { viewModel.update(asset, patch: CullingUpdatePatch(pickState: .picked)) }
                Button("拒绝") { viewModel.update(asset, patch: CullingUpdatePatch(pickState: .rejected)) }
                Button("待定") { viewModel.update(asset, patch: CullingUpdatePatch(pickState: .unreviewed)) }
            }
            .buttonStyle(.bordered)
            HStack {
                Menu("评分") {
                    ForEach(0...5, id: \.self) { rating in
                        Button("★ \(rating)") { viewModel.update(asset, patch: CullingUpdatePatch(rating: Double(rating))) }
                    }
                }
                Menu("颜色") {
                    ForEach(CaptureOneColorLabel.allCases, id: \.self) { label in
                        Button(label.rawValue) { viewModel.update(asset, patch: CullingUpdatePatch(colorLabel: label)) }
                    }
                }
            }
            .font(.caption)
        }
        .nativeCard()
    }
}

/// 挑片预览器：保留主分支的前后浏览、缩放、拖拽、面部对齐和 1/2/4 张对比
/// 能力；状态修改仍由主页面的安全写回控件负责。
private struct CullingViewerView: View {
    let assets: [CullingAsset]
    let initialIndex: Int
    let onClose: () -> Void

    @State private var index: Int
    @State private var scale = 1.0
    @State private var gestureScale = 1.0
    @State private var offset = CGSize.zero
    @State private var compareCount = 1
    @State private var faceAlign = false

    init(assets: [CullingAsset], initialIndex: Int, onClose: @escaping () -> Void) {
        self.assets = assets
        self.initialIndex = initialIndex
        self.onClose = onClose
        _index = State(initialValue: min(max(0, initialIndex), max(0, assets.count - 1)))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(assets[index].photo.filename)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(index + 1) / \(assets.count) · \(assets[index].state.pickState.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("对比", selection: $compareCount) {
                    Text("单张").tag(1)
                    Text("两张").tag(2)
                    Text("四张").tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Toggle("面部对齐", isOn: $faceAlign)
                    .toggleStyle(.checkbox)
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            GeometryReader { geometry in
                let visible = Array(assets.dropFirst(index).prefix(compareCount))
                HStack(spacing: 8) {
                    ForEach(Array(visible.enumerated()), id: \.element.photo.id) { offsetIndex, asset in
                        ZStack(alignment: .bottomLeading) {
                            PhotoThumbnailView(path: asset.photo.filepath, size: 2048, preview: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .scaleEffect(faceAlign && !asset.faceBboxes.isEmpty ? max(2, scale) : scale)
                                .offset(offset)
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
                                            guard scale > 1 else { return }
                                            offset = value.translation
                                        }
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(offsetIndex == 0 ? "当前" : "对比 \(offsetIndex + 1)")
                                    .font(.caption2.weight(.semibold))
                                Text(asset.photo.filename)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.45))
                        }
                        .frame(width: max(240, geometry.size.width / CGFloat(max(1, visible.count)) - 8), height: geometry.size.height)
                        .clipped()
                        .background(Color.black.opacity(0.9))
                    }
                }
            }
            .background(Color.black.opacity(0.9))
            .clipped()

            HStack(spacing: 14) {
                Button("上一张") {
                    index = max(0, index - 1)
                    resetTransform()
                }
                .disabled(index == 0)
                Button("下一张") {
                    index = min(max(0, assets.count - 1), index + 1)
                    resetTransform()
                }
                .disabled(index >= assets.count - 1)
                Button("缩小") {
                    scale = max(1, scale - 0.25)
                    gestureScale = scale
                }
                Text("\(Int(scale * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 50)
                Button("放大") {
                    scale = min(8, scale + 0.25)
                    gestureScale = scale
                }
                Button("重置") { resetTransform() }
                Spacer()
                if let quality = assets[index].quality, quality.status == .succeeded {
                    Text("技术质量 \(Int(quality.score * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func resetTransform() {
        scale = 1
        gestureScale = 1
        offset = .zero
    }
}
