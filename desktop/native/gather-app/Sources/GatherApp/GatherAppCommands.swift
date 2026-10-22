// desktop/native/gather-app/Sources/GatherApp/GatherAppCommands.swift
// 应用菜单命令（N08）：只做 SwiftUI Commands 装配。
//
// 菜单文案 / L10n 键 / 通知名 / 快捷键数据自 P1-2 起在
// GatherUI/Support/MenuCopy.swift（GatherAppMenuCopy / GatherAppMenuItem /
// GatherMenuShortcut）；GatherUI 是测试 target 可 import 的库，菜单映射
// 因此有真实断言。本文件只保留三件事：
//   1. CommandGroup 的替换位置（文件 / 显示 / 帮助）；
//   2. 按钮动作（通知投递 / 帮助 URL）；
//   3. 把 item.shortcut 接到 SwiftUI .keyboardShortcut。
//
// 为什么必须走 SwiftUI Commands：SwiftUI 在场景装配时用**自己构建的主菜单**替换
// NSApp.mainMenu，AppDelegate.installMenu 里建的「文件/编辑」菜单在运行态根本
// 不存在——验收报告 N08 的现象（运行态只有 Gather/View/Window/Help，⌘N/⌘O
// 无响应）就是这条覆盖链造成的。快捷键与动作必须声明在 Commands 里，才会出现在
// 真正生效的那份菜单上。
//
// 动作仍然走通知（单一实现）：菜单只负责「发起意图」，具体流程在
// GatherAppDelegate 里，与工具栏按钮、深链共用同一条路径。
//
// Cut 4 / 4a-3a：删除 GatherApp.commandsLanguageVersion 计数。菜单语言改为
// GatherApp 读 LanguageStore.language 后传入本类型（唯一语言来源），文案由
// GatherAppMenuCopy 按值解析；语言切换 → Scene body 的 Observation 依赖失效 →
// .commands 用新值重建 → 菜单文案随之刷新。
import SwiftUI
import GatherUI

package struct GatherAppCommands: Commands {
    /// 菜单语言（4a-3a）：GatherApp 读 LanguageStore.language 传入。
    let language: L10n.Language

    package init(language: L10n.Language) {
        self.language = language
    }

    /// 当前语言下的菜单文案（body 只用这一份；映射本身由 GatherUI 单测覆盖）。
    var menuCopy: GatherAppMenuCopy { GatherAppMenuCopy(L10n(language: language)) }

    package var body: some Commands {
        let copy = menuCopy
        // 文件菜单：新建 / 导入 / C1 导入（替换 SwiftUI 默认的 New Item 组）。
        CommandGroup(replacing: .newItem) {
            notificationButton(.newWorkspace, copy: copy)
            notificationButton(.importFolder, copy: copy)
            notificationButton(.captureOneImport, copy: copy)
        }

        // 显示菜单：侧栏显隐（⌘⌥S），与 NavigationSplitView 的列可见性联动。
        CommandGroup(replacing: .sidebar) {
            notificationButton(.toggleSidebar, copy: copy)
        }

        // 帮助菜单：保留项目主页入口（AppKit 菜单被覆盖后不再有第二条路径）。
        CommandGroup(replacing: .help) {
            Button(copy.help) {
                if let url = URL(string: "https://github.com/panzeyu2013/Gather") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// 通知型菜单项：文案、快捷键、通知名都来自 GatherUI 的描述符。
    @ViewBuilder
    private func notificationButton(
        _ item: GatherAppMenuItem,
        copy: GatherAppMenuCopy
    ) -> some View {
        if let shortcut = item.shortcut {
            button(item, copy: copy)
                .keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.modifiers)
        } else {
            button(item, copy: copy)
        }
    }

    private func button(_ item: GatherAppMenuItem, copy: GatherAppMenuCopy) -> some View {
        Button(copy[item]) {
            if let name = item.notificationName {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
    }
}
