// desktop/native/gather-app/Sources/GatherUI/Culling/CullingComparison.swift
// P2-3：对比网格的选片规则（纯函数，便于测试）。
// 优先使用显式选中的 2/4 张；否则从当前照片向两侧取相邻，保持当前必在结果内。
import Foundation
import GatherProtocol

enum CullingComparison {
    static func assets(
        current: CullingAsset?,
        assets: [CullingAsset],
        selectedIds: Set<String>,
        compareCount: Int
    ) -> [CullingAsset] {
        guard let current else { return [] }
        guard compareCount > 1 else { return [current] }

        let selected = assets.filter { selectedIds.contains($0.photo.id) }
        // 显式选择必须真的包含当前照片；否则（例如胶片条 ⌘选了两张、当前
        // 仍是第三张）对比视图会把当前照片排除在外。
        if selected.count == compareCount,
           selected.contains(where: { $0.photo.id == current.photo.id }) {
            return selected
        }
        guard let index = assets.firstIndex(where: { $0.photo.id == current.photo.id }) else {
            return [current]
        }
        let count = min(compareCount, assets.count)
        let half = (count - 1) / 2
        let maxStart = max(0, assets.count - count)
        let start = min(max(0, index - half), maxStart)
        return Array(assets[start..<(start + count)])
    }

    /// Survey（20-culling-browse #6）：一屏 N 张，N 由选择集决定（上限 9）。
    ///
    /// 选片规则（与单/2/4 图同一"当前照片必在结果内"的直觉）：
    /// - 显式选择 ≥2 张：按**页内顺序**展示选择集；当前照片在页内但未被选中时
    ///   补在首位（用户仍在看它，不能因为多选就消失）；
    /// - 显式选择不足 2 张：回退"当前照片 + 后续邻接"补足 N，到页尾再从前面补，
    ///   因此切到 Survey 永远不是空屏或单张。
    /// - N 超出 page 已加载张数时按已加载的给（与 2/4 图一致）。
    static func surveyAssets(
        current: CullingAsset?,
        assets: [CullingAsset],
        selectedIds: Set<String>,
        limit: Int
    ) -> [CullingAsset] {
        guard let current else { return [] }
        let cap = min(max(2, limit), CullingLayoutMode.surveyMaxCount)
        guard !assets.isEmpty else { return [current] }

        let selected = assets.filter { selectedIds.contains($0.photo.id) }
        if selected.count >= 2 {
            var result = selected
            if !result.contains(where: { $0.photo.id == current.photo.id }) {
                result.insert(current, at: 0)
                // 选择集已到上限时把当前照片补进来会变 N+1：按 Survey 的硬上限
                // 丢掉末尾一张，宁可比选择集少一张也不越上限。
                if result.count > cap { result.removeLast() }
            }
            return Array(result.prefix(cap))
        }

        guard let index = assets.firstIndex(where: { $0.photo.id == current.photo.id }) else {
            return [current]
        }
        var result: [CullingAsset] = []
        var cursor = index
        while result.count < cap, cursor < assets.count {
            result.append(assets[cursor])
            cursor += 1
        }
        cursor = index - 1
        while result.count < cap, cursor >= 0 {
            result.insert(assets[cursor], at: 0)
            cursor -= 1
        }
        return result
    }
}
