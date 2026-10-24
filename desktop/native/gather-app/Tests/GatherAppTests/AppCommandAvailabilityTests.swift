// AppCommandAvailabilityTests.swift
// Phase 4 收口（复审修正）：菜单可执行性判据 = installed ∪ focused。
// installed 是权威来源，focused 集合只是场景投影——focused 快照落后于安装时
// 不得把菜单永久置灰（旧实现 focused 优先，会）。
import Foundation
import Testing
@testable import GatherUI

@MainActor
@Suite("AppCommandAvailability")
struct AppCommandAvailabilityTests {
    @Test("installed 已安装即启用：focused 为空集/nil 也不置灰")
    func installedWinsOverStaleFocusedSnapshot() {
        #expect(
            AppCommandAvailability.isEnabled(
                .importFolder, installed: [.importFolder], focused: []))
        #expect(
            AppCommandAvailability.isEnabled(
                .importFolder, installed: [.importFolder], focused: nil))
        #expect(
            AppCommandAvailability.isEnabled(
                .newWorkspace, installed: Set(AppCommand.allCases), focused: []))
    }

    @Test("focused 集合可作为补充来源：场景内可见但 installed 尚未刷新时仍可用")
    func focusedCanEnable() {
        #expect(
            AppCommandAvailability.isEnabled(
                .toggleSidebar, installed: [], focused: [.toggleSidebar]))
    }

    @Test("两个来源都没有该命令时禁用")
    func disabledWhenNeitherSourceHasIt() {
        #expect(!AppCommandAvailability.isEnabled(.newWorkspace, installed: [], focused: []))
        #expect(!AppCommandAvailability.isEnabled(.newWorkspace, installed: [], focused: nil))
        #expect(
            !AppCommandAvailability.isEnabled(
                .newWorkspace, installed: [.importFolder], focused: [.toggleSidebar]))
    }

    @Test("handler 清空且无 focused 投影时全部禁用（无窗口）")
    func clearingHandlersDisablesMenu() {
        let center = AppCommandCenter()
        for command in AppCommand.allCases {
            center.install(command) {}
            #expect(
                AppCommandAvailability.isEnabled(
                    command, installed: center.installed, focused: nil))
        }
        center.clearHandlers()
        for command in AppCommand.allCases {
            #expect(
                !AppCommandAvailability.isEnabled(
                    command, installed: center.installed, focused: nil),
                "\(command) 关闭窗口后应禁用")
        }
    }

    /// 已知取舍（fail-open）：窗口关闭后 focused 投影可能滞后一帧，此时菜单仍
    /// 显示可用，但 handler 已清空 → perform 是安全 no-op。反过来用交集会在
    /// 「focused 快照落后于安装」时让菜单全灰且没有恢复路径，因此选并集。
    @Test("focused 投影滞后于 clearHandlers 时仍可用，但 perform 是 no-op")
    func staleFocusedProjectionFailsOpen() {
        let center = AppCommandCenter()
        var calls = 0
        center.install(.importFolder) { calls += 1 }
        let staleProjection: Set<AppCommand> = [.importFolder]
        center.clearHandlers()
        #expect(
            AppCommandAvailability.isEnabled(
                .importFolder, installed: center.installed, focused: staleProjection),
            "并集语义下 stale 投影仍使能（fail-open）")
        center.perform(.importFolder)
        #expect(calls == 0, "handler 已清空：perform 必须是 no-op")
    }
}
