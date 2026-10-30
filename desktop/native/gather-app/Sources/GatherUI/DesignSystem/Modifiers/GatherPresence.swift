// GatherPresence.swift
// DesignSystem/Modifiers：状态条/横幅的"出现与消失"动效。
//
// 为什么收在这里：错误横幅是"有就有、没有就没有"的条件视图，直接 `if` 插入
// 会硬生生把下方内容顶下去。统一给一个 0.18s 的淡入淡出 + 尊重"减少动态"，
// 页面只声明"我在不在"，不各自写 animation。

import SwiftUI

/// 条件视图的在场动效：容器上挂 `gatherAnimatePresence(_:)`，
/// 内部条件分支的视图加 `.transition(.opacity)` 即可。
struct GatherPresenceAnimation: ViewModifier {
    let isVisible: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(
            reduceMotion ? nil : .easeOut(duration: GatherMetrics.Motion.standard),
            value: isVisible
        )
    }
}

extension View {
    /// 让条件出现的横幅/提示条淡入淡出，而不是"啪"地插进来。
    func gatherAnimatePresence(_ isVisible: Bool) -> some View {
        modifier(GatherPresenceAnimation(isVisible: isVisible))
    }
}
