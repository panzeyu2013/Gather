// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityViewModel+Result.swift
// Cut 4 / 4c-2h：从 SimilarityViewModel.swift 移出结果采纳与分组选择
// （原 633-675 行）。纯搬移：结果代自增、采纳后清空选择/展开态、
// 阈值/组大小/分组模式同步与参数指纹记录逐字未动。
import Foundation
import GatherProtocol

extension SimilarityViewModel {

    // MARK: 结果采纳（TS lastSyncedResult 同步语义 + onResultAdopted 清空选择）

    /// 新结果对象到达时同步草稿参数：阈值总是跟随；非预计算档（analyze/
    /// recluster 实时计算）时组大小与分组模式也跟随。每次采纳推进结果代
    /// （审计 3 的单调序）。
    func adoptResult(_ newResult: SimilarityResult, syncThreshold: Bool) {
        guard syncThreshold else { return }
        resultRequestID += 1
        let previousGroupIds = Set(result?.groups.map(\.id) ?? [])
        let newGroupIds = Set(newResult.groups.map(\.id))
        // 同一批分组（回页、切页签回来、同参数重进）不该清掉用户刚勾的选择：
        // 之前每次 adoptResult 无条件清空，导致「确认同步/清理」的唯一入口消失，
        // 而界面还在指引用户去点（D-P1-1）。只有分组集合真的变了才重置。
        let keepsBrowseState = !previousGroupIds.isEmpty && previousGroupIds == newGroupIds
        result = newResult
        if keepsBrowseState {
            selectedGroupIds.formIntersection(newGroupIds)
            expandedGroupIds.formIntersection(newGroupIds)
            showAllMemberGroupIds.formIntersection(newGroupIds)
        } else {
            // 结果代变化后旧预览/旧失败项不再对应任何分组。
            markWritebackDraftChanged()
            selectedGroupIds = []
            // C-1：结果替换后旧的展开态没有意义（分组 id 可能已变）。
            expandedGroupIds = []
            showAllMemberGroupIds = []
        }
        threshold = Int(newResult.stats.threshold)
        if newResult.stats.precomputed != true {
            minGroupSize = newResult.stats.minGroupSize
            groupingMode = newResult.stats.groupingMode
        }
        // B-2 / D-P1-2：记录**产出这份结果的参数**，不是当时草稿。
        //
        // 预计算档只按阈值索引，组大小/分组模式来自上一次分析：草稿可能与之不同，
        // 而那正是 isResultStale 要提示的"面板参数 ≠ 结果参数"。旧实现把草稿
        // 写进指纹，于是永远"不过期"，界面上两组参数却对不上。
        if newResult.stats.precomputed == true {
            resultParams = SimilarityResultParams(
                threshold: Int(newResult.stats.threshold),
                minGroupSize: newResult.stats.minGroupSize,
                groupingMode: newResult.stats.groupingMode
            )
        } else {
            resultParams = SimilarityResultParams(
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode
            )
        }
    }

    // MARK: 分组选择（对齐 onSelectedChange / onSelectAll）

    public func toggleGroupSelection(_ groupId: Int) {
        if selectedGroupIds.contains(groupId) {
            selectedGroupIds.remove(groupId)
        } else {
            selectedGroupIds.insert(groupId)
        }
        markWritebackDraftChanged()
    }

    public func setAllGroupsSelected(_ selected: Bool) {
        selectedGroupIds = selected
            ? Set(result?.groups.map(\.id) ?? [])
            : []
        markWritebackDraftChanged()
    }
}
