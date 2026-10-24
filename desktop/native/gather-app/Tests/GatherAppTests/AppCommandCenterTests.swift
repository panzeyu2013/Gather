// AppCommandCenterTests.swift
// Phase 4：菜单命令中心的最小契约——无 handler 不可执行，有 handler 才执行。
import Testing
@testable import GatherUI

@MainActor
@Suite("AppCommandCenter")
struct AppCommandCenterTests {
    @Test("没有 handler 时 canPerform=false，perform no-op")
    func emptyCenterDoesNothing() {
        let center = AppCommandCenter()
        #expect(!center.canPerform(.newWorkspace))
        center.perform(.newWorkspace) // 不应崩溃
    }

    @Test("安装 handler 后 canPerform=true 且 perform 只调用对应命令")
    func performDispatchesToInstalledHandler() {
        let center = AppCommandCenter()
        var calls: [String] = []
        center.onNewWorkspace = { calls.append("new") }
        center.onOpenSettings = { calls.append("settings") }

        #expect(center.canPerform(.newWorkspace))
        #expect(center.canPerform(.openSettings))
        #expect(!center.canPerform(.importFolder))

        center.perform(.newWorkspace)
        center.perform(.openSettings)
        center.perform(.importFolder) // 未安装：no-op

        #expect(calls == ["new", "settings"])
    }

    @Test("clearHandlers 清空所有命令且 perform 安全 no-op")
    func clearHandlersDisablesEverything() {
        let center = AppCommandCenter()
        center.onNewWorkspace = {}
        center.onImportFolder = {}
        center.onCaptureOneImport = {}
        center.onToggleSidebar = {}
        center.onOpenSettings = {}
        #expect(center.canPerform(.newWorkspace))

        center.clearHandlers()

        for command in AppCommand.allCases {
            #expect(!center.canPerform(command), "\(command) 应被 clear")
            center.perform(command)
        }
    }
}
