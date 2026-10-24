// desktop/native/gather-app/Sources/GatherApp/GatherAppCommands.swift
// 应用菜单命令（N08）：只做 SwiftUI Commands 装配。
//
// Phase 4 收口：菜单不再 post Notification，也不再有"handler 未安装就回退通知"
// 的第二条路径；可执行性完全由 AppCommandCenter.installed（可观察）决定，
// 菜单项因此能真正置灰。
import SwiftUI
import GatherUI

package struct GatherAppCommands: Commands {
    /// 菜单语言（4a-3a）：GatherApp 读 LanguageStore.language 传入。
    let language: L10n.Language
    /// RootView 安装 handler 的命令中心（SceneState 注入）。
    let commands: AppCommandCenter
    /// 已安装 handler 的命令集合；GatherApp 读可观察值后传入，菜单随之重建。
    let installed: Set<AppCommand>
    /// 挑片页可见时的自建历史栈；其他页面为 nil → 保留系统撤销/重做。
    @FocusedValue(\.cullingHistory) private var cullingHistory
    /// 侧栏是否展开：菜单标题按真实状态取「隐藏侧栏/显示侧栏」。
    @FocusedValue(\.sidebarExpanded) private var sidebarExpanded: Bool?
    /// 当前场景已安装 handler 的命令集合（RootView 注入，随安装/清理更新）。
    @FocusedValue(\.commandAvailability) private var focusedAvailability: Set<AppCommand>?
    /// 主窗口 scene 的重开入口（Window 场景关窗后应用内唯一的恢复路径）。
    @Environment(\.openWindow) private var openWindow

    package init(language: L10n.Language, commands: AppCommandCenter, installed: Set<AppCommand>) {
        self.language = language
        self.commands = commands
        self.installed = installed
    }

    var menuCopy: GatherAppMenuCopy { GatherAppMenuCopy(L10n(language: language)) }

    package var body: some Commands {
        let copy = menuCopy
        let l10n = L10n(language: language)
        // 挑片页的 focused-scope 撤销/重做：只在页面可见时替换系统 Edit 组，
        // 其余页面/文本框仍走系统 UndoManager。
        if let history = cullingHistory {
            CommandGroup(replacing: .undoRedo) {
                Button(l10n("撤销")) { history.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!history.canUndo)
                Button(l10n("重做")) { history.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!history.canRedo)
            }
        }

        // 文件菜单：新建 / 导入 / C1 导入（替换 SwiftUI 默认的 New Item 组）。
        CommandGroup(replacing: .newItem) {
            commandButton(.newWorkspace, copy: copy)
            commandButton(.importFolder, copy: copy)
            commandButton(.captureOneImport, copy: copy)
        }

        // 显示菜单：侧栏显隐（⌘⌥S），与 NavigationSplitView 的列可见性联动。
        CommandGroup(replacing: .sidebar) {
            commandButton(.toggleSidebar, copy: copy)
        }

        // 窗口菜单：单窗口场景关窗后（⌘W）应用内仍能重新打开主窗口；
        // Dock 点击的重开路径见 GatherAppDelegate.applicationShouldHandleReopen。
        CommandGroup(after: .windowList) {
            Button(l10n("显示主窗口")) {
                openWindow(id: GatherWindowID.main)
            }
        }

        // 帮助菜单：保留项目主页入口。
        CommandGroup(replacing: .help) {
            Button(copy.help) {
                if let url = URL(string: "https://github.com/panzeyu2013/Gather") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @ViewBuilder
    private func commandButton(_ item: GatherAppMenuItem, copy: GatherAppMenuCopy) -> some View {
        if let command = command(for: item) {
            if let shortcut = item.shortcut {
                button(item, command: command, copy: copy)
                    .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
            } else {
                button(item, command: command, copy: copy)
            }
        }
    }

    private func button(
        _ item: GatherAppMenuItem,
        command: AppCommand,
        copy: GatherAppMenuCopy
    ) -> some View {
        Button(title(for: item, copy: copy)) {
            commands.perform(command)
        }
        // 单一判据（AppCommandAvailability）：installed 是权威，focused 集合只做
        // 补充。取并集可避免 focused 快照落后于安装时把菜单永久置灰。
        .disabled(
            !AppCommandAvailability.isEnabled(
                command, installed: installed, focused: focusedAvailability))
    }

    /// 侧栏项按 focused-scope 的真实可见性取文案；其余项用静态菜单文案。
    private func title(for item: GatherAppMenuItem, copy: GatherAppMenuCopy) -> String {
        guard item == .toggleSidebar, let sidebarExpanded else { return copy[item] }
        let l10n = L10n(language: language)
        return sidebarExpanded ? l10n("隐藏侧栏") : l10n("显示侧栏")
    }

    private func command(for item: GatherAppMenuItem) -> AppCommand? {
        switch item {
        case .newWorkspace: return .newWorkspace
        case .importFolder: return .importFolder
        case .captureOneImport: return .captureOneImport
        case .toggleSidebar: return .toggleSidebar
        case .help: return nil
        }
    }
}
