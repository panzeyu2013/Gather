// desktop/native/gather-app/Sources/GatherApp/GatherAppCommands.swift
// 应用菜单命令（N08）。
//
// WP4d：从 GatherHost 迁入 GatherApp（唯一 @main/Scene 的 target）——SwiftUI
// 只在 Scene 层使用，Host 不再 import SwiftUI。本文件只 import SwiftUI +
// GatherUI（菜单文案 L10n / 通知名），不触碰 core 四层。场景引用不变：
// GatherApp.body 的 .commands { GatherAppCommands(language:) }。
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

/// 菜单文案：按语言值解析的纯函数，便于单测（不必渲染 SwiftUI/AppKit 菜单）。
struct GatherAppMenuCopy: Equatable {
    let newWorkspace: String
    let importFolder: String
    let captureOneImport: String
    let toggleSidebar: String
    let help: String

    init(_ l10n: L10n) {
        self.newWorkspace = l10n("新建工作区")
        self.importFolder = l10n("导入文件夹")
        self.captureOneImport = l10n("从 Capture One 导入")
        self.toggleSidebar = l10n("显示/隐藏侧栏")
        self.help = l10n("Gather 帮助")
    }
}

package struct GatherAppCommands: Commands {
    /// 菜单语言（4a-3a）：GatherApp 读 LanguageStore.language 传入。
    let language: L10n.Language

    package init(language: L10n.Language) {
        self.language = language
    }

    /// 当前语言下的菜单文案（body 只用这一份；测试直接断言本值）。
    var menuCopy: GatherAppMenuCopy { GatherAppMenuCopy(L10n(language: language)) }

    package var body: some Commands {
        let copy = menuCopy
        // 文件菜单：新建 / 导入 / C1 导入（替换 SwiftUI 默认的 New Item 组）。
        CommandGroup(replacing: .newItem) {
            Button(copy.newWorkspace) {
                NotificationCenter.default.post(name: GatherAppNotification.menuNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button(copy.importFolder) {
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button(copy.captureOneImport) {
                NotificationCenter.default.post(name: GatherAppNotification.captureOneImportRequest, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        // 显示菜单：侧栏显隐（⌘⌥S），与 NavigationSplitView 的列可见性联动。
        CommandGroup(replacing: .sidebar) {
            Button(copy.toggleSidebar) {
                NotificationCenter.default.post(name: GatherAppNotification.menuToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
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
}