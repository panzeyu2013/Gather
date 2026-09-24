// desktop/native/gather-app/Sources/GatherApp/Shell/AppNavigationState.swift
// R6 会话宿主：壳层轻量导航状态（当前会话 id + 当前工作区页签 + 五个导航出口）。
// 只保存状态并转发闭包，不持有路由层实现、不创建数据层；闭包缺省为空实现，
// 装配处接线后注入真实导航即可，未接线时壳层仍可独立编译。
import SwiftUI

/// 壳层导航状态：currentSessionId 为 nil 表示未选中会话（会话宿主回退占位）。
@MainActor
@Observable
final class AppNavigationState {
    /// 当前会话 id（工作区页签、浏览、相似度统一归属）。
    private(set) var currentSessionId: String?
    /// 当前工作区页签（对齐 SessionTab 的 5 个页签）。
    private(set) var selectedTab: SessionTab

    /// 打开会话出口：装配处接到根导航的 openSession。
    let onOpenSession: (String) -> Void
    /// 工作区页签切换出口（本状态同时更新当前会话与页签）。
    let onOpenTab: (String, SessionTab) -> Void
    /// 打开相似度出口。
    let onOpenSimilarity: (String) -> Void
    /// 打开浏览页出口。
    let onOpenGallery: (String) -> Void
    /// 打开设置出口。
    let onOpenSettings: () -> Void

    init(
        currentSessionId: String? = nil,
        selectedTab: SessionTab = .control,
        onOpenSession: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.currentSessionId = currentSessionId
        self.selectedTab = selectedTab
        self.onOpenSession = onOpenSession
        self.onOpenTab = onOpenTab
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    /// 是否已有选中的会话。
    var hasSelectedSession: Bool { currentSessionId != nil }

    /// 选中会话：入口统一落到控制中心（对齐既有工作区入口语义），并转发出口。
    func openSession(_ sessionId: String) {
        currentSessionId = sessionId
        selectedTab = .control
        onOpenSession(sessionId)
    }

    /// 仅切换壳层当前页签（侧栏选择用，不触发外部导航）。
    func selectTab(_ tab: SessionTab) {
        selectedTab = tab
    }

    /// 工作区页签切换：同步本地状态后转发出口（页签栏点击走这条）。
    func openTab(_ sessionId: String, _ tab: SessionTab) {
        currentSessionId = sessionId
        selectedTab = tab
        onOpenTab(sessionId, tab)
    }

    /// 打开相似度：保留当前会话，转发出口。
    func openSimilarity(_ sessionId: String) {
        currentSessionId = sessionId
        onOpenSimilarity(sessionId)
    }

    /// 打开浏览页：保留当前会话，转发出口。
    func openGallery(_ sessionId: String) {
        currentSessionId = sessionId
        onOpenGallery(sessionId)
    }

    /// 打开设置：不改变会话与页签，仅转发出口。
    func openSettings() {
        onOpenSettings()
    }

    /// 清空当前会话（回到未选中占位）。
    func clearSession() {
        currentSessionId = nil
    }
}
