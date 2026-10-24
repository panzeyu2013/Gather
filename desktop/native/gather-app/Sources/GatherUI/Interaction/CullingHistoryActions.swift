// CullingHistoryActions.swift
// 挑片自建撤销栈的 focused-scope 动作。
//
// 挑片页没有文本输入框，历史操作在 CullingView 可见时注入 focusedSceneValue；
// Edit 菜单据此用「撤销/重做」替换系统 undo/redo（替换只在挑片页生效，其他页面
// 仍是系统文本撤销）。按钮与菜单共用同一份 canUndo/canRedo。
import SwiftUI

package struct CullingHistoryActions {
    package let canUndo: Bool
    package let canRedo: Bool
    package let undo: @MainActor () -> Void
    package let redo: @MainActor () -> Void

    package init(
        canUndo: Bool,
        canRedo: Bool,
        undo: @escaping @MainActor () -> Void,
        redo: @escaping @MainActor () -> Void
    ) {
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.undo = undo
        self.redo = redo
    }
}

package struct CullingHistoryKey: FocusedValueKey {
    package typealias Value = CullingHistoryActions
}

package extension FocusedValues {
    /// 当前场景里可见的挑片页历史操作；nil = 不在挑片页。
    var cullingHistory: CullingHistoryActions? {
        get { self[CullingHistoryKey.self] }
        set { self[CullingHistoryKey.self] = newValue }
    }
}

/// 侧栏当前是否展开：菜单「显示/隐藏侧栏」按真实状态取文案（旧 AppKit 菜单
/// 在 toggle 时改标题，SwiftUI 菜单用 focused-scope 值达到同一效果）。
package struct SidebarVisibilityKey: FocusedValueKey {
    package typealias Value = Bool
}

/// 当前场景已安装 handler 的命令集合：菜单禁用态经 focused-scope 读取，
/// focus/安装变化都会让 Commands 重新求值（Scene body 级快照会停在启动时）。
package struct CommandAvailabilityKey: FocusedValueKey {
    package typealias Value = Set<AppCommand>
}

package extension FocusedValues {
    var sidebarExpanded: Bool? {
        get { self[SidebarVisibilityKey.self] }
        set { self[SidebarVisibilityKey.self] = newValue }
    }

    var commandAvailability: Set<AppCommand>? {
        get { self[CommandAvailabilityKey.self] }
        set { self[CommandAvailabilityKey.self] = newValue }
    }
}
