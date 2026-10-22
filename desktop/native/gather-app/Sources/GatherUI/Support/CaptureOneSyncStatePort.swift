// desktop/native/gather-app/Sources/GatherUI/Support/CaptureOneSyncStatePort.swift
// Cut 3 / 3b-3（E-19 相邻）：C1 会话同步状态的 UI 视图模型 + 聚合端口。
//
// 状态机与聚合函数（CaptureOneSessionState / aggregateSessionState）的真相源
// 在 GatherApplication（Sources/GatherApplication/Services/CaptureOneSyncState.swift）；
// GatherUI 不得 import 领域层，因此：
//   · UI 侧声明同名 rawValue 的枚举（供视图 switch）；
//   · 聚合仍由 Host 的适配器转发真实实现，避免复制 8 个分支的判定逻辑。
//
// 3b-4 记入剩余项：CaptureOneSessionState 上移 GatherProtocol 后可删除本文件。
import Foundation

/// C1 会话同步状态（rawValue 与 GatherApplication.CaptureOneSessionState 一致）。
public enum CaptureOneSyncState: String, CaseIterable, Equatable, Sendable {
    case disconnected
    case connected
    case syncing
    case c1Read
    case safeToCleanup
    case synced
    case failed
    case conflict
}

/// 行状态计数 → 会话同步状态（纯函数端口）。
public protocol CaptureOneSyncStateRules: Sendable {
    func aggregateSyncState(counts: [String: Int], reloadAckedAt: String?) -> CaptureOneSyncState
}

/// 进程级注册表（GatherHost 启动时安装；未安装时视图退化为「加载中」）。
public enum CaptureOneSyncStateRulesRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var rules: (any CaptureOneSyncStateRules)?

    public static func install(_ rules: any CaptureOneSyncStateRules) {
        lock.lock()
        self.rules = rules
        lock.unlock()
    }

    public static func current() -> (any CaptureOneSyncStateRules)? {
        lock.lock()
        let rules = self.rules
        lock.unlock()
        return rules
    }
}
