// desktop/native/gather-core/Sources/GatherCore/Runtime/Similarity/SimilarityClusterPlan.swift
// W2c 步骤 1：聚类决策与邻域阈值档（纯函数）。
//
// 来源：Services/SimilarityService.swift
// - clusterEntries 的决策部分（672-749 行）→ decision
//   （global 模式 + 状态参数指纹匹配 + 连续增量次数 < 收敛间隔 → 增量；
//     否则全量并重建状态，版本 = 旧版本 + 1、增量计数清零；状态落库失败属加速
//     设施、sequential 模式清状态等执行语义留在 Runtime。）
// - precomputeNeighborTiers 的档位决策（851-899 行）→ neighborTierSteps /
//   neighborTiers（clamp 到 [0, 30]、去重、保序）。
//
// 设计 §1.1 语义修正 ⑤：邻域档 best-effort 保持且 multiCluster 只调一次 ——
// neighborTiers 一次算出全部待算档位，Runtime 以一次 multiClusterProvider 调用
// 覆盖（不再逐档 O(n²)）。
//
// 边界：无 IO、无 SQL、无 Store 依赖。

import Foundation

/// TS: clusterEntries 的决策结果（版本号语义与旧实现逐字一致）：
/// - incremental：增量成功路径，落库 version + 1、incremental_updates + 1；
/// - full：全量重聚类路径（首次 / 参数指纹不匹配 / 达到收敛间隔 / sequential /
///   增量失败回退），落库 version = 旧版本 + 1、incremental_updates = 0。
public enum SimilarityClusterDecision: Equatable, Sendable {
    case incremental(version: Int, incrementalUpdates: Int)
    case full(version: Int)
}

/// TS: similarity.service.ts 的聚类决策面（纯函数）。
public enum SimilarityClusterPlan {
    /// TS: NEIGHBOR_TIER_STEPS。
    public static let neighborTierSteps = [8, 4, -4, -8]

    /// 邻域档 clamp 边界（旧实现 max(0, min(30, threshold + step))）。
    public static let neighborTierMin = 0
    public static let neighborTierMax = 30

    /// TS: SettingsService.getNumber("similarity_cluster_convergence_interval", 10)。
    public static let defaultConvergenceInterval: Double = 10

    /// 收敛间隔整数化：max(1, Int(value))。畸形设置（NaN/∞/越界）在旧实现会直接
    /// Int(_:) 陷阱；此处防御性退化为 1（等价于「几乎每轮全量」，不崩溃）。
    public static func convergenceInterval(_ raw: Double) -> Int {
        guard let value = Int(exactly: raw.rounded(.towardZero)) else { return 1 }
        return max(1, value)
    }

    /// TS: precomputeNeighborTiers 的档位集合 —— 以主 threshold 为已保存档，
    /// 按 neighborTierSteps 顺序对各步 clamp 到 [0, 30]，跳过与已保存档重复者。
    /// 一次 pairwise 距离遍历服务全部档位（距离与阈值无关）。
    public static func neighborTiers(threshold: Int) -> [Int] {
        var savedTiers = Set<Int>([threshold])
        var candidates: [Int] = []
        for step in neighborTierSteps {
            let tier = max(neighborTierMin, min(neighborTierMax, threshold + step))
            if !savedTiers.contains(tier) {
                savedTiers.insert(tier)
                candidates.append(tier)
            }
        }
        return candidates
    }

    /// TS: clusterEntries 的决策 —— 状态存在、参数指纹（阈值 / 组大小 / 模式）
    /// 全等、连续增量次数 < 收敛间隔且模式为 global 时才走增量；其余（含增量
    /// 失败后的回退）走全量。
    public static func decision(
        snapshot: SimilarityClusterSnapshotRecord?,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        convergenceInterval: Int
    ) -> SimilarityClusterDecision {
        let interval = max(1, convergenceInterval)
        if groupingMode == .global,
           let snapshot,
           snapshot.matches(
                threshold: threshold,
                minGroupSize: minGroupSize,
                groupingMode: groupingMode.rawValue
           ),
           snapshot.meta.incrementalUpdates < interval {
            return .incremental(
                version: snapshot.meta.version + 1,
                incrementalUpdates: snapshot.meta.incrementalUpdates + 1
            )
        }
        return .full(version: (snapshot?.meta.version ?? 0) + 1)
    }

    /// 便捷重载：设置原始值（Double）→ convergenceInterval → decision。
    public static func decision(
        snapshot: SimilarityClusterSnapshotRecord?,
        threshold: Int,
        minGroupSize: Int,
        groupingMode: SimilarityGroupingMode,
        convergenceIntervalSetting: Double
    ) -> SimilarityClusterDecision {
        decision(
            snapshot: snapshot,
            threshold: threshold,
            minGroupSize: minGroupSize,
            groupingMode: groupingMode,
            convergenceInterval: convergenceInterval(convergenceIntervalSetting)
        )
    }
}
