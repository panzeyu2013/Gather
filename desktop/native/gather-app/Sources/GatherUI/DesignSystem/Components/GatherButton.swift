// desktop/native/gather-app/Sources/GatherUI/DesignSystem/Components/GatherButton.swift
// 按钮语义层：页面只声明“这是什么级别的动作”，不直接挑 bordered / prominent / glass。
//
// 设计依据：
// - Apple HIG Buttons：一个视图最多 1–2 个 prominent；用样式而不是尺寸区分主次。
// - Apple HIG Materials：Liquid Glass 是功能层材质，内容层（表单/卡片/页面）不用玻璃。
// - Material 3 / Carbon：主操作实心、次操作描边/弱填充、低优先级纯文字、危险操作红色。
//
// 例外：
// - 图标按钮（工具栏/检查器/卡片命中区）不是 CTA，继续用系统 .borderless/.plain；
//   需要统一时用 gatherIconButton(size:)。
// - 窗口 toolbar / 浮层等**功能层**按钮不走内容层 tint：用 GatherGlass 的
//   gatherFunctionalPrimaryButton / gatherFunctionalSecondaryButton。
// - 恒暗媒体查看器（Lightbox）的 chrome 用 gatherViewerButton：plain + viewer 文字色。
// - alert / confirmationDialog 里的按钮交给系统 role，不套内容层样式。
import SwiftUI

/// 内容层动作按钮的角色。
package enum GatherButtonRole: Sendable {
    /// 当前视图唯一的主操作：品牌色实心。
    case primary
    /// 与主操作成对的次操作（取消、返回、替代路径）：系统描边，不着品牌色。
    ///
    /// 刻意不 tint：macOS 的 bordered 只把 tint 染到标签上，bezel 仍是系统灰；
    /// 给「取消 / 关闭」这类按钮上品牌橙会与主 CTA 抢注意力，也让 secondary
    /// 与 tertiary 只剩描边之差。品牌色留给 primary / tertiary。
    case secondary
    /// 行内/低优先级动作（选择…、重试、清除筛选）：纯文字。
    case tertiary
    /// 错误上下文里的行内动作（错误行“重试”）：纯文字，但用错误色。
    case tertiaryDanger
    /// 页面级危险动作（删除选中、移除）：系统描边 + 红色标签，不抢主操作。
    ///
    /// 说明：macOS 的 bordered 不会把 tint 染到 bezel（描边仍是系统色），
    /// 所以这里是「红字」而不是「红描边」；真正需要红色实心时用
    /// destructiveProminent（errorFill 填充）。
    case destructive
    /// 确认面板里不可逆的主操作：红色实心。只在确认场景使用。
    case destructiveProminent
}

/// 内容层按钮尺寸。
package enum GatherButtonSize: Sendable {
    /// 行内动作 / 紧凑工具条。
    case small
    /// 表单、footer、普通页面动作。
    case regular
    /// hero / 首屏 CTA。
    case large

    fileprivate var controlSize: ControlSize {
        switch self {
        case .small: .small
        case .regular: .regular
        case .large: .large
        }
    }
}

package extension View {
    /// 内容层动作按钮。行为、命中区、focus ring、disabled 态仍由系统 Button 负责。
    func gatherButton(_ role: GatherButtonRole, size: GatherButtonSize = .regular) -> some View {
        modifier(GatherButtonModifier(role: role, size: size))
    }


    /// 图标按钮：保留系统无边框语法，不参与 CTA 层级。
    /// 默认 .regular——工具栏/行尾图标原本就是常规尺寸，收成 .small 只会让
    /// 图标变小而命中区不变（24pt 底线由 frame 保底）。
    func gatherIconButton(size: GatherButtonSize = .regular) -> some View {
        self.buttonStyle(.borderless)
            .controlSize(size.controlSize)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
    }

    /// 恒暗媒体查看器（Lightbox）的 chrome 按钮：无 bezel，使用 viewer 文字色。
    /// 不要用 primary/secondary：它们按浅色内容层 tint，压黑底会失去对比。
    func gatherViewerButton(size: GatherButtonSize = .regular) -> some View {
        modifier(GatherViewerButtonModifier(size: size))
    }
}

/// 恒暗查看器按钮：plain + viewer 文字色，并显式处理 disabled 视觉（plain 不会自动变灰）。
private struct GatherViewerButtonModifier: ViewModifier {
    let size: GatherButtonSize
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(GatherTheme.viewerTextPrimary)
            .controlSize(size.controlSize)
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : GatherMetrics.Opacity.disabled)
    }
}

private struct GatherButtonModifier: ViewModifier {
    let role: GatherButtonRole
    let size: GatherButtonSize

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content
                .buttonStyle(.borderedProminent)
                .tint(GatherTheme.accentFill)
                .controlSize(size.controlSize)

        case .secondary:
            content
                .buttonStyle(.bordered)
                .controlSize(size.controlSize)

        case .tertiary:
            content
                .buttonStyle(.borderless)
                .tint(GatherTheme.accent)
                .controlSize(size.controlSize)

        case .tertiaryDanger:
            content
                .buttonStyle(.borderless)
                .tint(GatherTheme.errorText)
                .controlSize(size.controlSize)

        case .destructive:
            content
                .buttonStyle(.bordered)
                .tint(GatherTheme.errorText)
                .controlSize(size.controlSize)

        case .destructiveProminent:
            content
                .buttonStyle(.borderedProminent)
                .tint(GatherTheme.errorFill)
                .controlSize(size.controlSize)
        }
    }
}
