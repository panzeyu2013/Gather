// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/SimilarityOutputs.swift
// Cut 3 / 3a：SimilarityAPI 的结果类型（原声明在 Services/SimilarityService.swift，
// 随协议上移到 GatherProtocol，避免 Protocol → Domain 反向依赖；纯 Codable DTO）。
//
// 职责：sim.result / sim.recluster 的输出。
// 校验归属：无（纯输出）。

import Foundation

/// TS: SimilarityResult（相似度结果，非协议类型；sim.result / sim.recluster
/// 经 IPC 原样序列化 → Codable 合成 key 与 TS 逐字相同）。
public struct SimilarityResult: Codable, Equatable, Sendable {
    public let groups: [SimilarityGroup]
    public let ungrouped: [SimilarityImage]
    public let stats: SimilarityResultStats

    public init(groups: [SimilarityGroup], ungrouped: [SimilarityImage], stats: SimilarityResultStats) {
        self.groups = groups
        self.ungrouped = ungrouped
        self.stats = stats
    }
}
