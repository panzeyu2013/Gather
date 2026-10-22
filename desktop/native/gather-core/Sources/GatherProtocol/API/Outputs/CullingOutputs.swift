// desktop/native/gather-core/Sources/GatherProtocol/API/Outputs/CullingOutputs.swift
// Cut 1 / 阶段 1A：CullingAPI 的结果类型。
//
// 职责：culling.sync_status 的旧响应是 MetadataSyncSummary + reloadAckedAt
// （Router 在 JSON 层临时补键），这里把两段收敛成一个稳定输出类型。
// 校验归属：无（纯输出）。

import Foundation

public struct CullingSyncStatus: Codable, Equatable, Sendable {
    public let summary: MetadataSyncSummary
    /// session.reload_acked_at；nil 表示尚未确认过外部重载。
    public let reloadAckedAt: String?

    public init(summary: MetadataSyncSummary, reloadAckedAt: String? = nil) {
        self.summary = summary
        self.reloadAckedAt = reloadAckedAt
    }
}
