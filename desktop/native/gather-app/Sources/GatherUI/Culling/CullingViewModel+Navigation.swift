// desktop/native/gather-app/Sources/GatherUI/Culling/CullingViewModel+Navigation.swift
// Cut 4 / 4c-2a：导航组加载/分析/拆分/合并（原 CullingView.swift 540-669 行，逐字搬移）。
import Foundation
import GatherProtocol

extension CullingViewModel {
    /// TS: navigationApi.list —— 挑片页保留自动/手工导航组的可见入口。
    public func loadNavigation() async {
        guard !sessionId.isEmpty else {
            navigationGroups = []
            normalizeNavigationSelection()
            return
        }
        do {
            navigationGroups = try await navigationAPI.list(sessionId)
            normalizeNavigationSelection()
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// TS: navigationApi.analyze(sessionId, ..., dryRun)。
    public func analyzeNavigation(dryRun: Bool) async {
        guard !isNavigationBusy else { return }
        isNavigationBusy = true
        defer { isNavigationBusy = false }
        do {
            navigationGroups = try await navigationAPI.analyze(
                NavigationAnalyzeParams(sessionId: sessionId, dryRun: dryRun)
            )
            normalizeNavigationSelection()
            notice = CullingNotice(dryRun ? "已生成导航组预览，未写入工作区" : "导航组已分析并保存")
            errorMessage = nil
        } catch {
            errorMessage = CommandError(error)
        }
    }

    public func selectNavigationGroup(_ groupId: String) {
        guard navigationGroups.contains(where: { $0.id == groupId }) else { return }
        selectedNavigationGroupId = groupId
    }

    // DOMAIN-EVENT: none — 导航组只在挑片页内展示，拆分后本页自刷
    private func splitNavigation(beforePhotoId: String) async {
        guard !selectedNavigationGroupId.isEmpty, !beforePhotoId.isEmpty else {
            errorMessage = CommandError.localized("请选择导航组和拆分位置")
            return
        }
        do {
            navigationGroups = try await navigationAPI.split(
                NavigationSplitParams(
                    sessionId: sessionId,
                    groupId: selectedNavigationGroupId,
                    beforePhotoId: beforePhotoId
                )
            )
            normalizeNavigationSelection()
            notice = CullingNotice("导航组已拆分")
            errorMessage = nil
        } catch {
            errorMessage = CommandError(error)
        }
    }

    // DOMAIN-EVENT: none — 导航组只在挑片页内展示，合并后本页自刷
    private func mergeSelectedNavigationGroups() async {
        guard selectedNavigationGroupIds.count >= 2 else {
            errorMessage = CommandError.localized("请选择至少两个导航组")
            return
        }
        do {
            navigationGroups = try await navigationAPI.merge(
                NavigationMergeParams(
                    sessionId: sessionId,
                    groupIds: selectedNavigationGroupIds.sorted()
                )
            )
            selectedNavigationGroupIds = []
            normalizeNavigationSelection()
            notice = CullingNotice("导航组已合并")
            errorMessage = nil
        } catch {
            errorMessage = CommandError(error)
        }
    }

    /// 对齐旧版工具栏"从当前照片拆分"：需要当前照片在选中组内且非首张。
    public func splitCurrentFromNavigationGroup() async {
        guard let current = currentPhotoId, !current.isEmpty,
              let group = navigationGroups.first(where: { $0.id == selectedNavigationGroupId }),
              let index = group.photoIds.firstIndex(of: current), index > 0 else {
            errorMessage = CommandError.localized("请先定位到组内非首张照片")
            return
        }
        await splitNavigation(beforePhotoId: current)
    }

    /// P1-8：先加载完整组员，生成“保留 K / 淘汰 N-K”的影响面快照。
    /// UI 必须在确认弹窗里展示这个快照，而不是只数当前页已加载的成员。
    func prepareGroupDecision(
        groupId: String,
        keepPhotoIds: [String]
    ) async -> CullingGroupDecisionPlan? {
        await refreshSimilarityGroups()
        guard let group = similarityGroups.first(where: { $0.groupId == groupId }) else {
            errorMessage = CommandError.localized("相似组已变化，请刷新后重试")
            return nil
        }
        let validIds = Set(group.images.map(\.photoId))
        var keep: [String] = []
        for id in keepPhotoIds where validIds.contains(id) && !keep.contains(id) {
            keep.append(id)
        }
        guard !keep.isEmpty, keep.count < group.images.count else {
            errorMessage = CommandError.localized(
                "请选择当前相似度组中 1 至 %lld 张照片",
                params: ["\(max(1, group.images.count - 1))"]
            )
            return nil
        }
        let keepSet = Set(keep)
        let visibleIds = Set(page?.assets
            .filter { $0.similarityGroupId == groupId }
            .map(\.photo.id) ?? [])
        let rejected = group.images.filter { !keepSet.contains($0.photoId) }
        return CullingGroupDecisionPlan(
            groupId: group.groupId,
            keepPhotoIds: keep,
            totalCount: group.images.count,
            visibleCount: visibleIds.count,
            sampleRejectedNames: Array(rejected.prefix(3).map(\.filename))
        )
    }

    /// 确认弹窗的确认分支：真正执行整组决策。
    func performGroupDecision(_ plan: CullingGroupDecisionPlan) async {
        await keepInGroupRejectRest(plan.groupId, keepPhotoIds: plan.keepPhotoIds)
    }

    /// 对齐旧版 keepInGroupRejectRest 的工具列入口：按相似组 id 定位组并决策。
    private func keepInGroupRejectRest(_ groupId: String, keepPhotoIds: [String], shouldAdvance: Bool = true) async {
        var group = similarityGroups.first(where: { $0.groupId == groupId })
        if group == nil {
            // groups 只在相似度范围预载；从“全部/筛选”直接按组决策时按需加载。
            await loadSimilarityGroupsIfNeeded(force: true)
            group = similarityGroups.first(where: { $0.groupId == groupId })
        }
        guard let group else {
            errorMessage = CommandError.localized("相似组已变化，请刷新后重试")
            return
        }
        await decideSimilarityGroup(group, keepPhotoIds: keepPhotoIds, shouldAdvance: shouldAdvance)
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
    public func mergeCurrentWithPreviousSameType() async {
        guard let selected = navigationGroups.first(where: { $0.id == selectedNavigationGroupId }),
              let index = navigationGroups.firstIndex(where: { $0.id == selected.id }),
              let previous = navigationGroups[..<index].reversed().first(where: { $0.type == selected.type }) else {
            errorMessage = CommandError.localized("没有可合并的前一个同类组")
            return
        }
        selectedNavigationGroupIds = [previous.id, selected.id]
        await mergeSelectedNavigationGroups()
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
}

// MARK: - Wave5 batch4：场景/连拍「组视图」与最佳帧决策

/// 导航组「保留最佳、淘汰其余」的影响面快照（Confirmed 由确认弹窗分支构造）。
struct CullingNavigationGroupDecisionPlan: Equatable, Sendable {
    let groupId: String
    let groupType: NavigationGroupType
    let keepPhotoId: String
    let keepFilename: String
    let rejectPhotoIds: [String]
    let totalCount: Int
    let visibleCount: Int

    var groupTypeTitleKey: LocalizedText {
        groupType == .burst ? LocalizedText("连拍组") : LocalizedText("场景组")
    }
}

extension CullingViewModel {
    /// 组视图当前组（nil = 未开启）。
    var navigationGroupViewGroup: NavigationGroup? {
        guard let id = filterState.navigationGroupViewId else { return nil }
        return navigationGroups.first { $0.id == id }
    }

    var isNavigationGroupViewActive: Bool {
        filterState.navigationGroupViewId != nil
    }

    /// 组视图置顶的最佳帧（lead）；网格用它画「最佳」徽标。
    var navigationGroupViewLeadPhotoId: String? {
        navigationGroupViewGroup?.leadPhotoId
    }

    /// 当前照片所属导航组（组员 >= 2 才返回）。
    func navigationGroup(forPhotoId photoId: String) -> NavigationGroup? {
        guard !photoId.isEmpty else { return nil }
        return navigationGroups.first {
            $0.photoIds.count >= 2 && $0.photoIds.contains(photoId)
        }
    }

    /// photoId -> 所属组组员数（网格「组 N 张」折叠计数；只收 >=2 的组）。
    var navigationGroupSizeByPhotoID: [String: Int] {
        var result: [String: Int] = [:]
        for group in navigationGroups where group.photoIds.count >= 2 {
            for id in group.photoIds { result[id] = group.photoIds.count }
        }
        return result
    }

    /// 进入当前选中导航组的「组视图」：把页收窄到该组并 lead 置顶、当前照片定位到 lead。
    func enterNavigationGroupView() async {
        let groupId = selectedNavigationGroupId
        guard !groupId.isEmpty, navigationGroups.contains(where: { $0.id == groupId }) else {
            errorMessage = CommandError.localized("请先选择一个场景/连拍组")
            return
        }
        filterState.navigationGroupViewId = groupId
        selectedPhotoIds.removeAll()
        selectionAnchorId = nil
        invalidateSelectionSnapshot()
        CullingClientProjectionCache.clear(sessionId: sessionId)
        await applyClientProjection(loadAheadForPerson: false)
    }

    func exitNavigationGroupView() async {
        guard filterState.navigationGroupViewId != nil else { return }
        filterState.navigationGroupViewId = nil
        await applyClientProjection()
    }

    func toggleNavigationGroupView() async {
        if isNavigationGroupViewActive {
            await exitNavigationGroupView()
        } else {
            await enterNavigationGroupView()
        }
    }

    /// 指定组进/出组视图（检查器按"当前照片所在组"调用，不依赖下拉选中项）。
    func enterNavigationGroupViewForGroup(_ groupId: String) async {
        guard navigationGroups.contains(where: { $0.id == groupId }) else { return }
        if filterState.navigationGroupViewId == groupId {
            await exitNavigationGroupView()
            return
        }
        selectedNavigationGroupId = groupId
        filterState.navigationGroupViewId = groupId
        selectedPhotoIds.removeAll()
        selectionAnchorId = nil
        invalidateSelectionSnapshot()
        CullingClientProjectionCache.clear(sessionId: sessionId)
        await applyClientProjection(loadAheadForPerson: false)
    }

    /// 保留最佳、淘汰其余：只准备影响面；Confirmed 由确认弹窗分支构造（D-011）。
    func prepareNavigationGroupDecision(
        groupId: String? = nil
    ) -> CullingNavigationGroupDecisionPlan? {
        let resolvedId = groupId
            ?? filterState.navigationGroupViewId
            ?? selectedNavigationGroupId
        guard !resolvedId.isEmpty,
              let group = navigationGroups.first(where: { $0.id == resolvedId }),
              group.photoIds.count >= 2 else {
            errorMessage = CommandError.localized("当前照片不在可决策的场景/连拍组内")
            return nil
        }
        let ordered = CullingClientProjection.project(
            assets: page?.assets ?? [], person: nil, group: group)
        let leadId = group.leadPhotoId.flatMap { lead in
            group.photoIds.contains(lead) ? lead : nil
        } ?? ordered.first?.photo.id ?? group.photoIds[0]
        let keepFilename = ordered.first { $0.photo.id == leadId }?.photo.filename
            ?? fileName(forPhotoId: leadId)
        let rejectIds = group.photoIds.filter { $0 != leadId }
        let visibleIds = Set(page?.assets.map(\.photo.id) ?? [])
        let visibleCount = group.photoIds.filter { visibleIds.contains($0) }.count
        return CullingNavigationGroupDecisionPlan(
            groupId: group.id,
            groupType: group.type,
            keepPhotoId: leadId,
            keepFilename: keepFilename,
            rejectPhotoIds: rejectIds,
            totalCount: group.photoIds.count,
            visibleCount: visibleCount)
    }

    /// 确认后执行：最佳 keep、其余 reject（两次批量提交，各自进撤销栈）。
    /// 组可能跨页：按 group.photoIds 全量提交，不只当前可见。
    func performNavigationGroupDecision(
        _ plan: Confirmed<CullingNavigationGroupDecisionPlan>
    ) async {
        let value = plan.value
        guard !value.keepPhotoId.isEmpty, !value.rejectPhotoIds.isEmpty else { return }
        await batchUpdate(
            patch: CullingUpdatePatch(pickState: .picked),
            targets: [value.keepPhotoId])
        await batchUpdate(
            patch: CullingUpdatePatch(pickState: .rejected),
            targets: Set(value.rejectPhotoIds))
        // 决策后服务端页/摘要已变：重取一页并在新页上重建组视图。
        await loadPage(reset: true)
        CullingClientProjectionCache.storeBase(sessionId: sessionId, page: page)
        await applyClientProjection(forceBaseFromCurrentPage: true, loadAheadForPerson: false)
        notice = CullingNotice(
            "已保留最佳帧、淘汰其余 %lld 张",
            params: ["\(value.rejectPhotoIds.count)"])
        postCullingChange()
    }

    private func fileName(forPhotoId photoId: String) -> String {
        page?.assets.first { $0.photo.id == photoId }?.photo.filename ?? photoId
    }
}
