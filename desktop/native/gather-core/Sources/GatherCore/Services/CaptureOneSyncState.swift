// desktop/native/gather-core/Sources/GatherCore/Services/CaptureOneSyncState.swift
// TS 源: desktop/src/main/services/capture-one/sync-state.ts（会话级同步状态聚合，
// 设计文档 2.3.2 / 2.3.3，纯函数与 DB 重推导逐字移植）
//
// 机器状态在内存、App 重启后丢失；行状态（metadata_outbox + reload_acked_at）是
// 持久真相源，本模块跨重启从 DB 重推导，不落库机器状态。保守策略：不自动 reload、
// 不自动清理；safeToCleanup 仅在 reload_acked_at 已写入后才可恢复。
//
// C1BridgeProvider：capture-one osascript 桥的 Swift 侧契约。osascript 桥是 3.4
// 页面阶段的宿主职责（实现留在 gather-app）；本文件定义与本层写回/同步链对齐的
// 调用点：
// - recordReloadAck：TS reloadMetadata() 成功路径 —— 宿主 reload 成功后在桥内调用，
//   写入 sessions.reload_acked_at（MetadataSyncCoordinator 的 confirm/cleanup
//   主侧守卫数据源）。
// - deriveSessionState：TS CaptureOneSyncState.deriveSessionState（2.3.2 优先级：
//   conflict > failed > syncing > c1Read > …）。
// - getSessionView：TS c1:sync-state IPC 载荷（状态 + 持久 ack 标记）。

import Foundation

/// TS: CaptureOneSessionState。
public enum CaptureOneSessionState: String, Codable, CaseIterable, Equatable, Sendable {
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

/// TS: countOutboxStatuses —— 纯行归约：status → 计数。
public func countOutboxStatuses(rows: [String]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for status in rows {
        counts[status, default: 0] += 1
    }
    return counts
}

/// TS: aggregateSessionState —— 确定性聚合（2.3.2），纯函数，不依赖 DB。
public func aggregateSessionState(
    counts: [String: Int],
    reloadAckedAt: String?
) -> CaptureOneSessionState {
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

/// TS: CaptureOneSyncState —— 重启重推导 + 事件观测（只读观测，不触发任何
/// reload/cleanup）。
public final class CaptureOneSyncState {
    /// TS: observedStates（Map<sessionId, CaptureOneSessionState>）。
    private var observedStates: [String: CaptureOneSessionState] = [:]
    private let connection: DBConnection

    public init(connection: DBConnection) {
        self.connection = connection
    }

    /// TS: deriveSessionState —— 不存在的会话按 disconnected 处理（最保守）。
    public func deriveSessionState(sessionId: String) throws -> CaptureOneSessionState {
        let ackRow = try connection.prepare("SELECT reload_acked_at FROM sessions WHERE id = ?")
            .get([.text(sessionId)])
        guard let ackRow else { return .disconnected }
        let rows = try connection.prepare("""
            SELECT o.status
            FROM metadata_outbox o
            JOIN metadata_outbox_sessions os ON os.xmp_path = o.xmp_path
            WHERE os.session_id = ?
          """).query([.text(sessionId)])
        return aggregateSessionState(
            counts: countOutboxStatuses(rows: rows.map { $0[0].textValue ?? "" }),
            reloadAckedAt: ackRow[0].textValue
        )
    }

    /// TS: observeSummary —— P1 事件接线（2.5）：写回协调器每次 emitSummary 后
    /// 由组合根调用，从 DB 重推导并记录状态转换。
    public func observeSummary(_ summary: MetadataSyncSummary) throws -> CaptureOneSessionState {
        try reportTransition(sessionId: summary.sessionId)
    }

    /// TS: observeReloadAck —— reloadMetadata() 成功后由组合根调用，补上协调器
    /// 事件不覆盖的 ack 转换（ack 不产生 outbox 变更）。
    public func observeReloadAck(sessionId: String) throws -> CaptureOneSessionState {
        try reportTransition(sessionId: sessionId)
    }

    /// TS: getSessionView —— 单次全量视图（IPC c1:sync-state）。
    public func getSessionView(sessionId: String) throws -> (state: CaptureOneSessionState, reloadAckedAt: String?) {
        let ackRow = try connection.prepare("SELECT reload_acked_at FROM sessions WHERE id = ?")
            .get([.text(sessionId)])
        return (
            state: try deriveSessionState(sessionId: sessionId),
            reloadAckedAt: ackRow?[0].textValue
        )
    }

    private func reportTransition(sessionId: String) throws -> CaptureOneSessionState {
        let next = try deriveSessionState(sessionId: sessionId)
        let previous = observedStates[sessionId]
        observedStates[sessionId] = next
        if previous == nil {
            GatherLogger.log("[capture-one-sync] session \(sessionId) 初始状态: \(next.rawValue)", level: .info)
        } else if previous != next {
            GatherLogger.log("[capture-one-sync] session \(sessionId) 状态转换: \(previous!.rawValue) → \(next.rawValue)", level: .info)
        }
        return next
    }
}

/// TS: capture-one 桥（osascript）的 Swift 侧契约 —— 实现留在 gather-app
/// （osascript 桥是 3.4 页面阶段的宿主职责）；本层只定义调用点与契约形状。
public protocol C1BridgeProvider: Sendable {
    /// TS: reloadMetadata() 成功路径 —— 写入 reload_acked_at。
    func recordReloadAck(sessionId: String) throws
    /// TS: CaptureOneSyncState.deriveSessionState。
    func deriveSessionState(sessionId: String) throws -> CaptureOneSessionState
    /// TS: c1:sync-state IPC 载荷。
    func getSessionView(sessionId: String) throws -> (state: CaptureOneSessionState, reloadAckedAt: String?)
}

/// C1BridgeProvider 的 GatherCore 内置参考实现（宿主可直接使用，或自行实现
/// 协议接入自己的 osascript 桥）。
public struct DefaultC1BridgeProvider: C1BridgeProvider {
    private let sessionRepo: SessionRepo
    private let syncState: CaptureOneSyncState

    public init(sessionRepo: SessionRepo, syncState: CaptureOneSyncState) {
        self.sessionRepo = sessionRepo
        self.syncState = syncState
    }

    public func recordReloadAck(sessionId: String) throws {
        _ = try sessionRepo.setReloadAckedAt(sessionId: sessionId, iso: nowISOString())
    }

    public func deriveSessionState(sessionId: String) throws -> CaptureOneSessionState {
        try syncState.deriveSessionState(sessionId: sessionId)
    }

    public func getSessionView(sessionId: String) throws -> (state: CaptureOneSessionState, reloadAckedAt: String?) {
        try syncState.getSessionView(sessionId: sessionId)
    }
}
