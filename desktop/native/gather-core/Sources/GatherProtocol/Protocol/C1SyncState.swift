// desktop/native/gather-core/Sources/GatherProtocol/Protocol/C1SyncState.swift
// TS 源: desktop/src/main/services/capture-one/sync-state.ts（会话级同步状态聚合，
// 设计文档 2.3.2 / 2.3.3，纯函数与 DB 重推导逐字移植）
//
// R7：从 GatherApplication 下沉到 GatherProtocol —— UI 直接消费判定结果，
// 不再经「UI 端口 + Host 适配器 + 进程级 registry」三跳；判定逻辑仍只有一份。
//
// 机器状态在内存、App 重启后丢失；行状态是持久真相源，本模块跨重启从 DB 重推导，
// 不落库机器状态。保守策略：不自动 reload、不自动清理；safeToCleanup 仅在
// reload_acked_at 已写入后才可恢复。
import Foundation

/// TS: CaptureOneSessionState。
public enum CaptureOneSyncState: String, Codable, CaseIterable, Equatable, Sendable {
    case disconnected
    case connected
    case syncing
    case c1Read = "c1Read"
    case safeToCleanup = "safeToCleanup"
    case synced
    case failed
    case conflict
}

/// TS: KNOWN_OUTBOX_STATUSES。
private let knownOutboxStatuses: Set<String> = [
    "pending", "writing", "written", "failed", "conflict", "synced", "clean", "cleaned",
]

/// TS: aggregateSessionState —— 确定性聚合（2.3.2），纯函数，不依赖 DB。
public func aggregateSessionState(
    counts: [String: Int],
    reloadAckedAt: String?
) -> CaptureOneSyncState {
    let conflict = counts["conflict"] ?? 0
    let failed = counts["failed"] ?? 0
    let pending = counts["pending"] ?? 0
    let writing = counts["writing"] ?? 0
    let written = counts["written"] ?? 0
    var other = 0
    var total = 0
    for (status, count) in counts {
        if !knownOutboxStatuses.contains(status) { other += count }
        total += count
    }

    if conflict > 0 { return .conflict }
    if failed > 0 { return .failed }
    if pending > 0 || writing > 0 { return .syncing }
    // written 行 = "Gather 已写入、C1 尚未 reload" —— 无论是否存在陈旧 reload ack
    // 都是 c1Read：用户尚未确认本次同步。
    if written > 0 { return .c1Read }
    // 未知状态保守处理：绝不声称 safeToCleanup。
    if other > 0 { return .c1Read }
    if total == 0 { return .synced }
    // 全部行都是终态（synced/clean/cleaned）：仅当 Capture One 确认过 reload
    // 后才可清理；否则 C1 可能仍持有旧元数据。
    return reloadAckedAt != nil ? .safeToCleanup : .c1Read
}
