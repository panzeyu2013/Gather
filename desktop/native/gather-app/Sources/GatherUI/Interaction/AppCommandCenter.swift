// AppCommandCenter.swift
// 应用级命令（菜单/按钮/快捷键共用）的唯一通道。
//
// Phase 4 收口：handler 不再暴露为 @ObservationIgnored 的五个可选闭包，而是
// 统一进 `install(_:handler:)` 的字典，并把"已安装集合"作为可观察的
// `installed` 投影发布给菜单——菜单禁用态随窗口 handler 的安装/卸载刷新。
import Foundation
import Observation

package enum AppCommand: String, CaseIterable, Sendable, Hashable {
    case newWorkspace
    case importFolder
    case captureOneImport
    case toggleSidebar
    case openSettings
}

/// 命令中心：菜单与 RootView 之间唯一的动作通道。
///
/// RootView 在 onAppear 安装 handler、onDisappear 清理；菜单只调用
/// `canPerform`/`perform`。`installed` 是唯一可观察的 readiness 投影，
/// Scene body 读它重建 Commands，于是无窗口时菜单项真正置灰（不是静默 no-op）。
@MainActor
@Observable
package final class AppCommandCenter {
    @ObservationIgnored private var handlers: [AppCommand: @MainActor () -> Void] = [:]

    /// 已安装 handler 的命令集合（菜单禁用态的唯一数据源）。
    package private(set) var installed: Set<AppCommand> = []

    package init() {}

    /// 安装命令 handler。重复安装以最后一次为准（同一窗口 onAppear 可能多次）。
    package func install(_ command: AppCommand, handler: @escaping @MainActor () -> Void) {
        handlers[command] = handler
        if !installed.contains(command) {
            installed.insert(command)
        }
    }

    /// 窗口离场时清掉 handler，避免菜单命令落到已销毁窗口的 @State binding。
    package func clearHandlers() {
        handlers.removeAll()
        if !installed.isEmpty {
            installed.removeAll()
        }
    }

    package func canPerform(_ command: AppCommand) -> Bool {
        handlers[command] != nil
    }

    package func perform(_ command: AppCommand) {
        handlers[command]?()
    }
}
