// desktop/native/gather-app/Sources/GatherUI/Support/SessionStore.swift
// Cut 4 / 4a-0：活动工作区表 + LRU（§4.2/§4.3）。
//
// 职责边界（审计 §4.1）：只做"哪些 workspace 活着 / 哪个可见 / LRU 淘汰"，
// **不持有导航 destination**（RootNavigation 保持不动，避免重写 goBack 语义）。
//
// 工厂闭包注入：workspace 的 7 个 VM 由组合根构造（需要 AppServices 的 API），
// 本类不 import 任何 API 类型，因此可先在 GatherUI 落地而不用等 §4.6 的依赖包。
import Foundation
import Observation

@MainActor
@Observable
public final class SessionStore {
    /// 设计值 6（4a-2c 前的意图缓存为 8）：7 个 VM/workspace，必须限量（§4.7-1）。
    public static let defaultCapacity = 6

    /// 当前可见 workspace；nil = 非会话页（工作台/图库/设置…）。
    public private(set) var activeSessionId: String?
    /// 侧栏"当前会话"回退（迁自 RootNavigation.lastSessionId）。
    public private(set) var lastSessionId: String?
    /// 活动表。
    public private(set) var workspaces: [String: SessionWorkspace] = [:]
    /// LRU 顺序：最近访问在前。
    public private(set) var recent: [String] = []
    public let capacity: Int

    /// 工厂闭包：id → 已注入 7 个 VM 的 workspace。
    @ObservationIgnored private let makeWorkspace: (String) -> SessionWorkspace
    /// P1 / D：workspace 关闭（LRU 淘汰/删除会话）时通知宿主停掉目录监听。
    @ObservationIgnored public var onWorkspaceClosed: (@MainActor (String) -> Void)?

    public init(
        capacity: Int = SessionStore.defaultCapacity,
        make: @escaping (String) -> SessionWorkspace
    ) {
        self.capacity = max(1, capacity)
        self.makeWorkspace = make
    }

    // MARK: - 查/建

    /// 命中即提序；未命中用工厂创建。创建后按容量淘汰最久未用的非保护项。
    public func workspace(for id: String) -> SessionWorkspace {
        let workspace: SessionWorkspace
        if let existing = workspaces[id] {
            workspace = existing
        } else {
            workspace = makeWorkspace(id)
            workspaces[id] = workspace
        }
        noteAccess(id)
        enforceCapacity()
        return workspace
    }

    // MARK: - 可见性

    /// 切换可见 workspace：旧 workspace 隐藏（suspend）、新 workspace 可见
    /// （activate），再按 LRU 淘汰。传 nil 只 suspend，不淘汰（§4.4 失效边界）。
    @discardableResult
    public func activate(_ id: String?) -> SessionWorkspace? {
        guard let id else {
            if let activeSessionId {
                workspaces[activeSessionId]?.setVisible(false)
            }
            activeSessionId = nil
            return nil
        }
        if let activeSessionId, activeSessionId != id {
            workspaces[activeSessionId]?.setVisible(false)
        }
        // 复审 P2：先认领 active 再构造/淘汰。capacity==1 时 workspace(for:)
        // 内部的 enforceCapacity 保护的是**旧** active，会把刚建的新项淘汰掉。
        activeSessionId = id
        let workspace = workspace(for: id)
        workspace.setVisible(true)
        lastSessionId = id
        enforceCapacity()
        return workspace
    }

    // MARK: - 淘汰/结束

    /// 淘汰一个 workspace；当前可见的拒绝淘汰（no-op）。
    public func evict(_ id: String) {
        guard id != activeSessionId else { return }
        removeWorkspace(id)
    }

    /// 删除会话后的清理：无论是否 active 都必须清（会话已不存在）。
    public func endSession(_ id: String) {
        if activeSessionId == id { activeSessionId = nil }
        if lastSessionId == id { lastSessionId = nil }
        removeWorkspace(id)
    }

    // MARK: - 私有

    private func noteAccess(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
    }

    private func removeWorkspace(_ id: String) {
        if let workspace = workspaces.removeValue(forKey: id) {
            workspace.close()
        }
        onWorkspaceClosed?(id)
        recent.removeAll { $0 == id }
        if lastSessionId == id { lastSessionId = nil }
    }

    /// 容量兜底：优先淘汰 LRU 尾部；只剩受保护的 active 时放弃，不硬删。
    private func enforceCapacity() {
        while workspaces.count > capacity {
            guard let victim = recent.last(where: {
                $0 != activeSessionId && workspaces[$0] != nil
            }) else { return }
            evict(victim)
        }
    }
}
