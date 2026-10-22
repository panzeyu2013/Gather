// desktop/native/gather-app/Tests/GatherAppTests/ShellLanguageWiringTests.swift
// Cut 4 / 4a-3a：LanguageStore 唯一写入口接线后的外壳/菜单文案驱动。
//
// 不渲染 SwiftUI/AppKit（无 UI 快照）：断言的是**驱动文案的值**——
// 1. RootView 用的 RootShellCopy 从 store.l10n 取值，切语言即换文案；
// 2. 菜单文案（GatherAppMenuCopy）从 store.language 取值（旧 commandsLanguageVersion
//    计数器已删）。WP4d 起 GatherAppCommands 在 GatherApp 可执行 target，测试
//    target 无法 import；这里改为断言菜单文案的唯一输入（L10n 键）在两语言下
//    逐字正确，命令本身由 Scene 的 .commands 在编译期引用；
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

    // WP4d：GatherAppCommands 已迁入 GatherApp 可执行 target（Host 不再
    // import SwiftUI）。测试 target 只依赖 GatherUI/GatherHost，无法 import
    // 可执行模块；菜单文案的唯一输入是这 5 个 L10n 键，命令结构由 Scene 的
    // .commands 在编译期引用。语言驱动链路（store.language → L10n）不变。
    @Test("Commands 菜单文案：显式语言值驱动，zh → en 全换")
    func menuCopyFollowsStore() {
        let zh = L10n(language: makeStore(.zhCN).language)
        #expect(zh("新建工作区") == "新建工作区")
        #expect(zh("导入文件夹") == "导入文件夹")
        #expect(zh("从 Capture One 导入") == "从 Capture One 导入")
        #expect(zh("显示/隐藏侧栏") == "显示/隐藏侧栏")
        #expect(zh("Gather 帮助") == "Gather 帮助")

        // Cut 4 / 4b-2g：不切进程全局，直接给 en 语言值。
        let en = L10n(language: makeStore(.en).language)
        #expect(en("新建工作区") == "New Workspace")
        #expect(en("导入文件夹") == "Import Folder")
        #expect(en("从 Capture One 导入") == "Import from Capture One")
        #expect(en("显示/隐藏侧栏") == "Show/Hide Sidebar")
        #expect(en("Gather 帮助") == "Gather Help")
        // 文案确实变了（不是被全局同步「碰巧」换成同一份）
        #expect(en("新建工作区") != zh("新建工作区"))
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
