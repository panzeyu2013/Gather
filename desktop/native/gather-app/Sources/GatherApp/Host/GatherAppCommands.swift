// desktop/native/gather-app/Sources/GatherApp/Host/GatherAppCommands.swift
// 应用菜单命令（N08）。
//
// 为什么必须走 SwiftUI Commands：SwiftUI 在场景装配时用**自己构建的主菜单**替换
// NSApp.mainMenu，AppDelegate.installMenu 里建的「文件/编辑」菜单在运行态根本
// 不存在——验收报告 N08 的现象（运行态只有 Gather/View/Window/Help，⌘N/⌘O
// 无响应）就是这条覆盖链造成的。快捷键与动作必须声明在 Commands 里，才会出现在
// 真正生效的那份菜单上。
//
// 动作仍然走通知（单一实现）：菜单只负责「发起意图」，具体流程在
// GatherAppDelegate 里，与工具栏按钮、深链共用同一条路径。
import SwiftUI

struct GatherAppCommands: Commands {
    /// 语言版本号：值本身不参与渲染，只用于让 SwiftUI 在语言切换后重建这份
    /// Commands（菜单文案才会读到新的 GatherLocalization 语言）。
    var languageVersion: Int = 0

    var body: some Commands {
        // 文件菜单：新建 / 导入 / C1 导入（替换 SwiftUI 默认的 New Item 组）。
        CommandGroup(replacing: .newItem) {
            Button(GatherLocalization.l("新建工作区")) {
                NotificationCenter.default.post(name: GatherAppNotification.menuNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(GatherLocalization.l("导入文件夹")) {
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(GatherLocalization.l("从 Capture One 导入")) {
                NotificationCenter.default.post(name: GatherAppNotification.captureOneImportRequest, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        // 显示菜单：侧栏显隐（⌘⌥S），与 NavigationSplitView 的列可见性联动。
        CommandGroup(replacing: .sidebar) {
            Button(GatherLocalization.l("显示/隐藏侧栏")) {
                NotificationCenter.default.post(name: GatherAppNotification.menuToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }

        // 帮助菜单：保留项目主页入口（AppKit 菜单被覆盖后不再有第二条路径）。
        CommandGroup(replacing: .help) {
            Button(GatherLocalization.l("Gather 帮助")) {
                if let url = URL(string: "https://github.com/panzeyu2013/Gather") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
