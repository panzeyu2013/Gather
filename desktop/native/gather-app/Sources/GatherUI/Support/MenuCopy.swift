// desktop/native/gather-app/Sources/GatherUI/Support/MenuCopy.swift
// P1-2：菜单文案 / L10n 键 / 通知名 / 快捷键数据的唯一来源。
//
// WP4d 把 GatherAppMenuCopy 与 GatherAppCommands 一起放进了 GatherApp 可执行
// target；GatherAppTests 只依赖 GatherUI/GatherHost，无法 import 可执行模块，
// 菜单测试于是退化成“对 5 个 L10n 字面量的自证”
// （docs/reviews/final-acceptance-tests.md P1-2）。这里把**纯数据**下沉到
// GatherUI：可执行 target 只保留 SwiftUI Commands 装配，测试 target 直接
// import GatherUI 断言 5 个菜单项的键 → 文案/通知/快捷键映射，避免 key 与
// 命令错接（例如 newWorkspace 错接 importFolder 的 key 或 ⌘O 错配通知）。
//
// 只搬数据，不改文案/快捷键/通知名：5 个 key、4 个通知、4 组快捷键与
// 搬移前 GatherAppCommands.swift 逐字一致。
import Foundation
import SwiftUI

// MARK: - 菜单项描述符

/// 菜单项。`allCases` 的顺序即同一 CommandGroup 内的展示顺序。
package enum GatherAppMenuItem: String, CaseIterable, Sendable {
    case newWorkspace
    case importFolder
    case captureOneImport
    case toggleSidebar
    case help

    /// L10n 键（值见 GatherUI/Resources/{en,zh-Hans}.lproj/Localizable.strings）。
    package var titleKey: String {
        switch self {
        case .newWorkspace: "新建工作区"
        case .importFolder: "导入文件夹"
        case .captureOneImport: "从 Capture One 导入"
        case .toggleSidebar: "显示/隐藏侧栏"
        case .help: "Gather 帮助"
        }
    }

    /// 菜单动作投递的通知名；帮助项直接打开 URL，不投递通知。
    package var notificationName: Notification.Name? {
        switch self {
        case .newWorkspace: GatherAppNotification.menuNewWorkspace
        case .importFolder: GatherAppNotification.importFolderRequest
        case .captureOneImport: GatherAppNotification.captureOneImportRequest
        case .toggleSidebar: GatherAppNotification.menuToggleSidebar
        case .help: nil
        }
    }

    /// 菜单快捷键；帮助项没有快捷键。
    package var shortcut: GatherMenuShortcut? {
        switch self {
        case .newWorkspace: GatherMenuShortcut(key: "n", command: true)
        case .importFolder: GatherMenuShortcut(key: "o", command: true)
        case .captureOneImport: GatherMenuShortcut(key: "i", command: true, shift: true)
        case .toggleSidebar: GatherMenuShortcut(key: "s", command: true, option: true)
        case .help: nil
        }
    }
}

// MARK: - 快捷键数据

/// 快捷键的纯数据表示：测试可以逐位断言，SwiftUI 修饰键由 `modifiers` 映射。
package struct GatherMenuShortcut: Equatable, Sendable {
    package let key: Character
    package let command: Bool
    package let shift: Bool
    package let option: Bool
    package let control: Bool

    package init(
        key: Character,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// SwiftUI `.keyboardShortcut(_:modifiers:)` 使用的 KeyEquivalent。
    package var keyEquivalent: KeyEquivalent { KeyEquivalent(key) }

    /// SwiftUI 修饰键映射（仅装配层使用，测试可断言此值）。
    package var modifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }
}

// MARK: - 当前语言下的菜单文案

/// 5 个菜单文案（属性名与菜单项一一对应；build 时按传入的 L10n 解析）。
package struct GatherAppMenuCopy: Equatable {
    package let newWorkspace: String
    package let importFolder: String
    package let captureOneImport: String
    package let toggleSidebar: String
    package let help: String

    package init(_ l10n: L10n) {
        self.newWorkspace = l10n(GatherAppMenuItem.newWorkspace.titleKey)
        self.importFolder = l10n(GatherAppMenuItem.importFolder.titleKey)
        self.captureOneImport = l10n(GatherAppMenuItem.captureOneImport.titleKey)
        self.toggleSidebar = l10n(GatherAppMenuItem.toggleSidebar.titleKey)
        self.help = l10n(GatherAppMenuItem.help.titleKey)
    }

    /// 按菜单项取文案（Commands 装配统一走这里，避免属性名散落在 body 里）。
    package subscript(item: GatherAppMenuItem) -> String {
        switch item {
        case .newWorkspace: newWorkspace
        case .importFolder: importFolder
        case .captureOneImport: captureOneImport
        case .toggleSidebar: toggleSidebar
        case .help: help
        }
    }
}
