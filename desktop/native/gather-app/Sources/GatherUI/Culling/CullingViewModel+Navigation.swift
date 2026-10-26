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

    public func splitNavigation(beforePhotoId: String) async {
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

    public func mergeSelectedNavigationGroups() async {
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

    /// 对齐旧版 keepInGroupRejectRest 的工具列入口：按相似组 id 定位组并决策。
    public func keepInGroupRejectRest(_ groupId: String, keepPhotoIds: [String], shouldAdvance: Bool = true) async {
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
