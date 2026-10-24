// AppCommandCenterTests.swift
// Phase 4：菜单命令中心的最小契约——无 handler 不可执行，有 handler 才执行；
// installed 是可观察的 readiness 投影（菜单禁用态的数据源）。
import Foundation
import Observation
import Testing
@testable import GatherUI

@MainActor
@Suite("AppCommandCenter")
struct AppCommandCenterTests {
    @Test("没有 handler 时 canPerform=false，perform no-op")
    func emptyCenterDoesNothing() {
        let center = AppCommandCenter()
        #expect(!center.canPerform(.newWorkspace))
        #expect(center.installed.isEmpty)
        center.perform(.newWorkspace) // 不应崩溃
    }

    @Test("安装 handler 后 canPerform=true 且 perform 只调用对应命令")
    func performDispatchesToInstalledHandler() {
        let center = AppCommandCenter()
        var calls: [String] = []
        center.install(.newWorkspace) { calls.append("new") }
        center.install(.openSettings) { calls.append("settings") }

        #expect(center.canPerform(.newWorkspace))
        #expect(center.canPerform(.openSettings))
        #expect(!center.canPerform(.importFolder))
        #expect(center.installed == [.newWorkspace, .openSettings])

        center.perform(.newWorkspace)
        center.perform(.openSettings)
        center.perform(.importFolder) // 未安装：no-op

        #expect(calls == ["new", "settings"])
    }

    @Test("clearHandlers 清空所有命令且 perform 安全 no-op")
    func clearHandlersDisablesEverything() {
        let center = AppCommandCenter()
        for command in AppCommand.allCases {
            center.install(command) {}
        }
        #expect(center.installed == Set(AppCommand.allCases))

        center.clearHandlers()

        for command in AppCommand.allCases {
            #expect(!center.canPerform(command), "\(command) 应被 clear")
            center.perform(command)
        }
        #expect(center.installed.isEmpty)
    }

    @Test("installed 变化对 Observation 可见（菜单禁用态刷新）")
    func installedChangesAreObservable() {
        let center = AppCommandCenter()
        let probe = ObservationProbe()
        withObservationTracking {
            probe.record(center.installed.count)
        } onChange: {
            probe.markNotified()
        }
        center.install(.newWorkspace) {}
        #expect(probe.notified, "install 必须发出 Observation 变更")
        #expect(center.installed == [.newWorkspace])
    }

    /// onChange 是 @Sendable 且在写入前触发：用锁盒子承接，避免跨隔离域写。
    private final class ObservationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var _notified = false

        func record(_ value: Int) {
            lock.withLock { count = value }
        }

        func markNotified() {
            lock.withLock { _notified = true }
        }

        var notified: Bool {
            lock.withLock { _notified }
        }
    }
}
