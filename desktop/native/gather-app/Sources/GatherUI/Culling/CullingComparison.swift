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
}
