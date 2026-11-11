// desktop/native/gather-app/Tests/GatherAppTests/GatherAppReopenPolicyTests.swift
// Wave4b / P2-16：Dock/激活重开主窗口的策略 + openWindow 桥回归。
//
// 旧实现先 guard !hasVisibleWindows：第二屏常驻时它恒为 true，⌘W 关掉主窗口后
// 点 Dock 直接返回，主窗口永远不回来。这里钉住新语义（只看主窗口是否存在）以及
// delegate 用的进程级桥（GatherApp 装 openWindow 闭包，delegate 调用）。
import Foundation
import Testing
@testable import GatherHost

@Suite("Dock 重开主窗口策略（Wave4b P2-16）", .serialized)
@MainActor
struct GatherAppReopenPolicyTests {
    @Test("第二屏可见但主窗口已关：仍然请求重开主窗口（旧实现会被 flag 吞掉）")
    func missingMainWindowRequestsOpen() {
        #expect(GatherReopenPolicy.action(hasMainWindow: false, hasVisibleWindows: true)
                == .requestMainWindowOpen)
        #expect(GatherReopenPolicy.action(hasMainWindow: false, hasVisibleWindows: false)
                == .requestMainWindowOpen)
    }

    @Test("主窗口存在：前置处理，与 hasVisibleWindows 无关")
    func existingMainWindowIsFocused() {
        #expect(GatherReopenPolicy.action(hasMainWindow: true, hasVisibleWindows: false)
                == .focusMainWindow)
        #expect(GatherReopenPolicy.action(hasMainWindow: true, hasVisibleWindows: true)
                == .focusMainWindow)
    }

    @Test("重开桥：安装后调用 handler；注销后静默")
    func reopenBridgeInvokesInstalledHandler() {
        let bridge = GatherReopenBridge.shared
        bridge.uninstall()
        var calls = 0
        bridge.reopenMainWindow()
        #expect(calls == 0, "未安装时不得崩/不得假装打开")

        bridge.install { calls += 1 }
        bridge.reopenMainWindow()
        #expect(calls == 1)

        bridge.uninstall()
        bridge.reopenMainWindow()
        #expect(calls == 1, "注销后不再调用")
    }
}
