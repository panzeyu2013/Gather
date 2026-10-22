// desktop/native/gather-app/Sources/GatherHost/CaptureOneSyncStateAdapter.swift
// Cut 3 / 3b-3（E-19 相邻）：GatherDomain 的聚合函数 → GatherUI 端口。
//
// 只做 rawValue 映射与转发；判定逻辑（冲突 > 失败 > 写入中 > 已写入 > 终态）
// 仍只有 GatherDomain/CaptureOneSyncState.swift 一份。
import GatherApplication
import GatherUI

public struct HostCaptureOneSyncStateRules: CaptureOneSyncStateRules {
    public init() {}

    public func aggregateSyncState(
        counts: [String: Int],
        reloadAckedAt: String?
    ) -> CaptureOneSyncState {
        let state = aggregateSessionState(
            counts: counts,
            reloadAckedAt: reloadAckedAt
        )
        // rawValue 两侧逐字一致；理论不可达的兜底取「未连接」保守值。
        return CaptureOneSyncState(rawValue: state.rawValue) ?? .disconnected
    }
}
