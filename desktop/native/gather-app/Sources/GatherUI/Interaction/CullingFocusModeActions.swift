// desktop/native/gather-app/Sources/GatherUI/Interaction/CullingFocusModeActions.swift
// 挑片页「专注模式」（20-culling-browse #1：无干扰单图）的 focused-scope 动作。
//
// 与 CullingHistoryActions.swift 同一模式：「显示」菜单项只在挑片页可见时出现，
// F 裸键在查看器内触发；两者共用同一份 isActive/toggle —— 不新建通知、
// 不建全局单例、也不把菜单文案硬编码在可执行 target 里。
//
// 网格布局没有"单图专注"语义 → canToggle = false，菜单项置灰；
// 专注模式本身也不改变网格的既有布局行为。
import SwiftUI

package struct CullingFocusModeActions {
    /// 是否已处于专注模式（菜单标题「专注模式 / 退出专注模式」据此切换）。
    package let isActive: Bool
    /// 当前布局是否支持专注模式（网格布局传 false）。
    package let canToggle: Bool
    package let toggle: @MainActor () -> Void

    package init(
        isActive: Bool,
        canToggle: Bool,
        toggle: @escaping @MainActor () -> Void
    ) {
        self.isActive = isActive
        self.canToggle = canToggle
        self.toggle = toggle
    }
}

package struct CullingFocusModeKey: FocusedValueKey {
    package typealias Value = CullingFocusModeActions
}

package extension FocusedValues {
    /// 当前场景挑片页的专注模式动作；nil = 不在挑片页。
    var cullingFocusMode: CullingFocusModeActions? {
        get { self[CullingFocusModeKey.self] }
        set { self[CullingFocusModeKey.self] = newValue }
    }
}
