// desktop/native/gather-app/Sources/GatherUI/Culling/CullingComparison.swift
// P2-3：对比网格的选片规则（纯函数，便于测试）。
// 优先使用显式选中的 2/4 张；否则从当前照片向两侧取相邻，保持当前必在结果内。
// B1：对比/Survey 的**决策目标**解析（多选只是构造画面的手段，不是写入目标）。
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

// MARK: - 决策目标（B1：把「选片手段」和「写入目标」分开）

/// 一次挑片决策要写到哪些照片。
///
/// 对比/Survey 里多选是**构造画面**的手段（要让两张非相邻片同屏，只能先选 2–9 张）；
/// 旧实现把同一个选择集当成写入目标，于是「盯着 A 按 X」会标掉 B…I
/// （20-culling-viewer §2 P1 / §3-1）。这里把两个语义拆开：由 View 用本文件
/// 的纯函数解析出目标，再交给 CullingViewModel.commit(currentOnly:) 执行。
enum CullingDecisionTarget: Equatable {
    /// 只写当前照片（对比/Survey 的默认口径）。
    case current(photoId: String)
    /// 写整个选择集（网格/单图的原有口径，或用户显式打开开关时）。
    case selection
}

enum CullingDecisionScope {
    /// 对比类布局（2/3/4 图 + Survey）：多选用于构造画面，不默认批量写入。
    ///
    /// 查看器只有 compareCount/isSurvey 两个布局输入，用它判定；
    /// survey 的选择集驱动格数在 2 张时 compareCount 也是 2，仍然算对比类。
    static func isComparisonLayout(compareCount: Int, isSurvey: Bool) -> Bool {
        isSurvey || compareCount > 1
    }

    /// 同上，按布局枚举判定（信息条/工具栏等已持有布局值的地方用它）。
    static func isComparisonLayout(_ layout: CullingLayoutMode) -> Bool {
        switch layout {
        case .compare2, .compare3, .compare4, .survey: return true
        case .single, .grid: return false
        }
    }

    /// 解析本次决策的写入目标。
    ///
    /// - 对比类布局且「作用于全部选中 N 张」开关关闭：只写当前照片，**即使选择集
    ///   非空**（选择集只决定画面里放哪几张）。
    /// - 单图/网格，或开关显式打开：选择集非空则批量写选择集——批量入口保留给
    ///   网格/检查器这类「多选即目标」的界面。
    /// - 没有任何可写目标（无当前照片且无选择集）时返回 nil，调用方应 no-op。
    static func target(
        isComparisonLayout: Bool,
        currentPhotoId: String?,
        selectedPhotoIds: Set<String>,
        writesToSelection: Bool
    ) -> CullingDecisionTarget? {
        if (!isComparisonLayout || writesToSelection), !selectedPhotoIds.isEmpty {
            return .selection
        }
        guard let currentPhotoId else { return nil }
        return .current(photoId: currentPhotoId)
    }
}
