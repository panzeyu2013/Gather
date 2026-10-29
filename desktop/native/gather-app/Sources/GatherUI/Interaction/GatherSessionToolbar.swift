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
            // 状态 + 页面刷新是一个“同步簇”，但必须是两个可辨识的动作：
            // 状态点进去是同步设置，刷新只重载当前页。macOS 26 会把相邻的
            // toolbar item 合并成一枚玻璃胶囊；旧实现的「已同步」和刷新图标
            // 都被 tint 成品牌色，看起来像一个奇怪的大按钮。这里显式收进
            // 一个 HStack，用 1pt 分隔线分开两种语义，并压小刷新图标。
            HStack(spacing: 0) {
                C1StatusCapsuleHost(
                    sessionId: sessionId,
                    culling: culling,
                    onOpenSettings: actions.onOpenSettings
                )
                if let refreshTitle, let onRefresh = actions.onRefresh {
                    Rectangle()
                        .fill(GatherTheme.hairline)
                        .frame(width: 1, height: 12)
                        .padding(.horizontal, 5)
                        .accessibilityHidden(true)
                    GatherToolbarRefreshButton(
                        title: refreshTitle,
                        help: refreshHelp ?? refreshTitle
                    ) {
                        onRefresh()
                    }
                    .disabled(refreshDisabled)
                    .modifier(OptionalRefreshShortcut(enabled: refreshKeyboardShortcut))
                }
            }
            // 10pt 内容内边距：Liquid Glass 胶囊里的文字/图标不能贴住圆角。
            .padding(.horizontal, 10)
            // 关键：没有搜索字段的页面（控制中心/挑片/导出）工具栏会剩下整段
            // 弹性空间；没有 fixedSize 时状态按钮被拉满，玻璃胶囊一路顶到窗口
            // 边缘（右侧被裁掉）。锁成内容宽度，胶囊才是“一颗”，不是一条横条。
            .fixedSize(horizontal: true, vertical: false)
        }

        if showsSettings {
            ToolbarSpacer(.fixed, placement: .primaryAction)
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

/// 工具栏刷新：plain 按钮避免 macOS 26 把 borderless 图标染成品牌棕。
/// 自己画 22pt 命中区和悬停底，尺寸与状态胶囊里的刷新位对齐。
private struct GatherToolbarRefreshButton: View {
    let title: String
    let help: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovered ? GatherTheme.selectionFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                hovered = hovering
            }
        }
        .help(help)
        .accessibilityLabel(title)
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
