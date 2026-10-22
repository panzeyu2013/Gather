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
        result = newResult
        selectedGroupIds = []
        // C-1：结果替换后旧的展开态没有意义（分组 id 可能已变）。
        expandedGroupIds = []
        showAllMemberGroupIds = []
        threshold = Int(newResult.stats.threshold)
        if newResult.stats.precomputed != true {
            minGroupSize = newResult.stats.minGroupSize
            groupingMode = newResult.stats.groupingMode
        }
        // B-2：记录产出这份结果的参数（可能与上面的阈值同步后的草稿一致）。
        resultParams = SimilarityResultParams(
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode
        )
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
