// desktop/native/gather-app/Sources/GatherUI/Interaction/GatherSessionToolbar.swift
// 会话页共享工具栏：C1 状态胶囊 + 可选刷新 + 可选设置。
//
// 7 个会话页此前各自拼 ToolbarItem(Group)；这里只收敛“每页都一样”的三类动作，
// 页面特有动作（导出预览/开始导出、Gallery 搜索等）仍由页面追加。
import SwiftUI
import GatherProtocol

/// ToolbarContent 是值类型；闭包如果直接存在值里，SwiftUI 在 Control/Face 这种
/// 捕获 @State 的页面会拿到失效的 closure context（实测 SIGSEGV）。用一个引用
/// 类型持有动作，ToolbarContent 只持有类引用。
private final class GatherSessionToolbarActions {
    let onOpenSettings: () -> Void
    let onRefresh: (() -> Void)?

    init(onOpenSettings: @escaping () -> Void, onRefresh: (() -> Void)?) {
        self.onOpenSettings = onOpenSettings
        self.onRefresh = onRefresh
    }
}

/// 会话页工具栏的共享部分。
///
/// - refreshTitle == nil 时不渲染刷新（如 Export 只有 C1 胶囊）。
/// - showsSettings 为 true 时在固定 spacer 后追加设置按钮（Gallery 现有行为）。
/// - 刷新快捷键默认不加；Control/Gallery/Similarity/Face 显式传 true 保留 ⌘R。
struct GatherSessionToolbar: ToolbarContent {
    let sessionId: String
    let culling: any CullingAPI
    private let actions: GatherSessionToolbarActions

    var refreshTitle: String?
    var refreshHelp: String?
    var refreshDisabled: Bool = false
    var refreshKeyboardShortcut: Bool = false

    var showsSettings: Bool = false
    var settingsTitle: String = ""
    var settingsHelp: String = ""

    init(
        sessionId: String,
        culling: any CullingAPI,
        onOpenSettings: @escaping () -> Void,
        refreshTitle: String? = nil,
        refreshHelp: String? = nil,
        refreshDisabled: Bool = false,
        refreshKeyboardShortcut: Bool = false,
        onRefresh: (() -> Void)? = nil,
        showsSettings: Bool = false,
        settingsTitle: String = "",
        settingsHelp: String = ""
    ) {
        self.sessionId = sessionId
        self.culling = culling
        self.actions = GatherSessionToolbarActions(
            onOpenSettings: onOpenSettings,
            onRefresh: onRefresh
        )
        self.refreshTitle = refreshTitle
        self.refreshHelp = refreshHelp
        self.refreshDisabled = refreshDisabled
        self.refreshKeyboardShortcut = refreshKeyboardShortcut
        self.showsSettings = showsSettings
        self.settingsTitle = settingsTitle
        self.settingsHelp = settingsHelp
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            C1StatusCapsuleHost(
                sessionId: sessionId,
                culling: culling,
                onOpenSettings: actions.onOpenSettings
            )
            if let refreshTitle, let onRefresh = actions.onRefresh {
                Button {
                    onRefresh()
                } label: {
                    Label(refreshTitle, systemImage: "arrow.clockwise")
                }
                .disabled(refreshDisabled)
                .help(refreshHelp ?? refreshTitle)
                .modifier(OptionalRefreshShortcut(enabled: refreshKeyboardShortcut))
            }
        }

        if showsSettings {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    actions.onOpenSettings()
                } label: {
                    Label(settingsTitle, systemImage: "gearshape")
                }
                .help(settingsHelp.isEmpty ? settingsTitle : settingsHelp)
            }
        }
    }
}

/// 只在该页原本有 ⌘R 时挂快捷键，避免给 Culling/Duplicates 新增行为。
private struct OptionalRefreshShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut("r", modifiers: .command)
        } else {
            content
        }
    }
}
