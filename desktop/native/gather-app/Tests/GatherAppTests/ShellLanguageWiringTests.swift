// desktop/native/gather-app/Tests/GatherAppTests/ShellLanguageWiringTests.swift
// Cut 4 / 4a-3a：LanguageStore 唯一写入口接线后的外壳/菜单文案驱动。
//
// 不渲染 SwiftUI/AppKit（无 UI 快照）：断言的是**驱动文案的值**——
// 1. RootView 用的 RootShellCopy 从 store.l10n 取值，切语言即换文案；
// 2. 菜单映射（GatherAppMenuCopy / GatherAppMenuItem）在 GatherUI：断言
//    5 个菜单项的 L10n 键、zh/en 文案、通知名与快捷键；GatherAppCommands
//    只做 SwiftUI Commands 装配（P1-2 修复，测试 target 直接 import GatherUI）；
// 3. 读 l10n/language 会建立 Observation 依赖（视图与 Scene body 的重渲染前提）。
//
// Cut 4 / 4b-2g：外壳/菜单文案都是显式 L10n（RootShellCopy / GatherAppMenuCopy
// 的 init 收 L10n），所以断言直接换语言实例、不再切进程全局，避免与并行中文
// 断言互撞。只有「LanguageStore.set 建立 Observation 依赖」一例仍需
// AppLanguageLock 包裹（set 会同步写旧全局 GatherLocalization.appLanguage）。
// NotificationCenter 每例独立。
import Foundation
import Observation
import SwiftUI
import Testing
@testable import GatherUI
@testable import GatherHost

/// Observation 回调的记录位（Boolean key path 不存在，用 struct 承载）。
private struct ObservationFlag {
    var fired = false
}

@MainActor
@Suite("外壳语言接线（4a-3a）", .serialized)
struct ShellLanguageWiringTests {
    private func makeStore(_ language: L10n.Language = .zhCN) -> LanguageStore {
        // 独立中心：不订阅进程级 languageChanged，也不向全局广播。
        LanguageStore(language: language, notificationCenter: NotificationCenter())
    }

    @Test("RootView 外壳文案：store.l10n 驱动，zh → en 四条全换")
    func rootShellCopyFollowsStore() {
        let zh = RootShellCopy(makeStore(.zhCN).l10n)
        #expect(zh.workbench == "工作台")
        #expect(zh.currentSession == "当前会话")
        #expect(zh.globalLibrary == "全局图库")
        #expect(zh.importFolder == "导入文件夹")

        // Cut 4 / 4b-2g：语言来自显式 L10n 值，不切进程全局。
        let en = RootShellCopy(makeStore(.en).l10n)
        #expect(en.workbench == "Workbench")
        #expect(en.currentSession == "Current Session")
        #expect(en.globalLibrary == "Global Library")
        #expect(en.importFolder == "Import Folder")
        #expect(en.workbench != zh.workbench)
    }

    // P1-2：菜单映射已下沉到 GatherUI（GatherAppMenuCopy / GatherAppMenuItem /
    // GatherMenuShortcut），这里断言**生产类型**的键 → 文案/通知/快捷键，
    // 不再对 L10n 字面量自证。GatherAppCommands 仅做 Commands 装配。
    @Test("Commands 菜单映射：5 项 L10n 键/文案/通知/快捷键（GatherUI 真实类型）")
    func menuCopyFollowsStore() {
        // 5 个菜单项：顺序、L10n 键（键错接会在下面的文案断言暴露）。
        #expect(GatherAppMenuItem.allCases == [
            .newWorkspace, .importFolder, .captureOneImport, .toggleSidebar, .help,
        ])
        #expect(GatherAppMenuItem.newWorkspace.titleKey == "新建工作区")
        #expect(GatherAppMenuItem.importFolder.titleKey == "导入文件夹")
        #expect(GatherAppMenuItem.captureOneImport.titleKey == "从 Capture One 导入")
        #expect(GatherAppMenuItem.toggleSidebar.titleKey == "显示/隐藏侧栏")
        #expect(GatherAppMenuItem.help.titleKey == "Gather 帮助")

        // 文案映射：GatherAppCommands 用 subscript，5 个属性名也必须一一对应。
        let zh = GatherAppMenuCopy(makeStore(.zhCN).l10n)
        #expect(zh.newWorkspace == "新建工作区")
        #expect(zh.importFolder == "导入文件夹")
        #expect(zh.captureOneImport == "从 Capture One 导入")
        #expect(zh.toggleSidebar == "显示/隐藏侧栏")
        #expect(zh.help == "Gather 帮助")
        #expect(zh[.newWorkspace] == "新建工作区")
        #expect(zh[.importFolder] == "导入文件夹")
        #expect(zh[.captureOneImport] == "从 Capture One 导入")
        #expect(zh[.toggleSidebar] == "显示/隐藏侧栏")
        #expect(zh[.help] == "Gather 帮助")

        // 语言驱动（store.language 是唯一输入）：zh → en 全换。
        let en = GatherAppMenuCopy(makeStore(.en).l10n)
        #expect(en.newWorkspace == "New Workspace")
        #expect(en.importFolder == "Import Folder")
        #expect(en.captureOneImport == "Import from Capture One")
        #expect(en.toggleSidebar == "Show/Hide Sidebar")
        #expect(en.help == "Gather Help")
        #expect(en[.newWorkspace] == "New Workspace")
        #expect(en[.importFolder] == "Import Folder")
        #expect(en[.captureOneImport] == "Import from Capture One")
        #expect(en[.toggleSidebar] == "Show/Hide Sidebar")
        #expect(en[.help] == "Gather Help")
        #expect(en.newWorkspace != zh.newWorkspace)

        // 入口通知只剩导入目录选择（菜单动作已改 commandCenter，不再有通知名）。
        #expect(GatherAppNotification.importFolderRequest.rawValue == "gather.menu.import-folder-request")

        // 快捷键：键位 + 修饰键（GatherAppCommands 直接把这两项交给 SwiftUI）。
        #expect(GatherAppMenuItem.newWorkspace.shortcut == GatherMenuShortcut(key: "n", command: true))
        #expect(GatherAppMenuItem.importFolder.shortcut == GatherMenuShortcut(key: "o", command: true))
        #expect(GatherAppMenuItem.captureOneImport.shortcut == GatherMenuShortcut(key: "i", command: true, shift: true))
        #expect(GatherAppMenuItem.toggleSidebar.shortcut == GatherMenuShortcut(key: "s", command: true, option: true))
        #expect(GatherAppMenuItem.help.shortcut == nil)
        #expect(GatherAppMenuItem.newWorkspace.shortcut?.modifiers == EventModifiers.command)
        #expect(GatherAppMenuItem.importFolder.shortcut?.modifiers == EventModifiers.command)
        #expect(GatherAppMenuItem.captureOneImport.shortcut?.modifiers == [.command, .shift])
        #expect(GatherAppMenuItem.toggleSidebar.shortcut?.modifiers == [.command, .option])
    }

    @Test("读 l10n 会建立 Observation 依赖（视图/Scene 刷新前提）")
    func readingL10nTracksLanguage() {
        AppLanguageLock.withCopy("zh-CN") {
            let store = makeStore(.zhCN)
            let changed = LockedBox(ObservationFlag())
            withObservationTracking {
                _ = store.l10n
            } onChange: {
                changed.lock.withLock { changed.fired = true }
            }
            #expect(changed.lock.withLock { changed.fired } == false)
            #expect(store.set(.en))
            #expect(changed.lock.withLock { changed.fired })
            #expect(store.language == .en)
        }
    }

    @Test("environment(.languageStore)：会话页读取外壳下发的语言源，换语言即换文案")
    func environmentCarriesLanguageStore() {
        let zhStore = makeStore(.zhCN)
        var environment = EnvironmentValues()
        #expect(environment.languageStore == nil, "未注入时页面按固定兜底渲染，不读进程全局")
        environment.languageStore = zhStore
        #expect(environment.languageStore === zhStore)
        #expect(environment.languageStore?.l10n("工作台") == "工作台")

        // 与页面 l10n 计算属性同构：每次渲染都读 store.l10n，不是缓存字符串。
        // Cut 4 / 4b-2g：换一个 en store（不写进程全局同样能换文案）。
        let enStore = makeStore(.en)
        environment.languageStore = enStore
        #expect(environment.languageStore === enStore)
        #expect(environment.languageStore?.l10n("工作台") == "Workbench")
    }
}
