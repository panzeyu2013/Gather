// desktop/native/gather-app/Sources/GatherApp/GatherAppCommands.swift
// 应用菜单命令（N08）：只做 SwiftUI Commands 装配。
//
// Phase 4：菜单不再 post Notification；统一调用 AppCommandCenter.perform。
// 文案/快捷键仍在 GatherUI/MenuCopy（测试 target 可 import 并断言）。
import SwiftUI
import GatherUI

package struct GatherAppCommands: Commands {
    /// 菜单语言（4a-3a）：GatherApp 读 LanguageStore.language 传入。
    let language: L10n.Language
    /// RootView 安装 handler 的命令中心（SceneState 注入）。
    let commands: AppCommandCenter

    package init(language: L10n.Language, commands: AppCommandCenter) {
        self.language = language
        self.commands = commands
    }

    var menuCopy: GatherAppMenuCopy { GatherAppMenuCopy(L10n(language: language)) }

    package var body: some Commands {
        let copy = menuCopy
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
        Button(copy[item]) {
            // 正常路径走 CommandCenter；handler 未安装（bootstrap 早期/无窗口）
            // 时回退旧通知，保证导入/C1 在 loading 期仍可用。
            if commands.canPerform(command) {
                commands.perform(command)
            } else if let name = item.notificationName {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
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
