// 共享基础视图组件：统一各页自绘副本，消除实现分裂——
// GatherStatCard（统计卡）、GatherProgressBar（进度条）、
// GatherEmptyState（空态/无结果态）。
import SwiftUI

// MARK: - 统计卡

/// 数值 + 次级标签的统计卡。
/// - .card：24pt bold 数值 + footnote 标签，暖色底 + 边框（写回报告/人脸簇统计）。
/// - .compact：callout 数值 + footnote 标签，弱化底色（设置页队列计数）。
/// - .plain：title2 数值 + footnote 标签，无底色（工作台汇总）。
public struct GatherStatCard: View {
    public enum Style {
        case card
        case compact
        case plain
    }

    public let value: Int
    public let label: String
    public var color: Color = Color.primary
    public var style: Style = .card

    public init(value: Int, label: String, color: Color = Color.primary, style: Style = .card) {
        self.value = value
        self.label = label
        self.color = color
        self.style = style
    }

    public var body: some View {
        VStack(spacing: 2) {
            valueText
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .applyStyle(style)
    }

    @ViewBuilder
    private var valueText: some View {
        let text = Text("\(value)")
            .font(style == .plain ? .title2.weight(.semibold) : (style == .card ? .system(size: 24, weight: .bold) : .callout.monospaced().weight(.medium)))
            .monospacedDigit()
            .foregroundStyle(color)
        if style == .plain {
            text.frame(minWidth: 56, alignment: .center)
        } else {
            text
        }
    }
}

private extension View {
    @ViewBuilder
    func applyStyle(_ style: GatherStatCard.Style) -> some View {
        switch style {
        case .card:
            self
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.backgroundSecondary))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1))
        case .compact:
            self
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(GatherTheme.backgroundSecondary.opacity(0.5)))
        case .plain:
            self
        }
    }
}

// MARK: - 进度条

/// 自绘进度条（对齐旧版 ProgressBar 语义：圆角轨道 + 主色填充）。
/// 可选内嵌文本（label）、边框与固定宽度；默认 8pt 高、4pt 圆角。
public struct GatherProgressBar: View {
    public let fraction: Double
    public var fill: Color = GatherTheme.primary
    public var track: Color = GatherTheme.backgroundSecondary
    public var border: Color? = nil
    public var height: CGFloat = 8
    public var cornerRadius: CGFloat = 4
    public var width: CGFloat? = nil
    public var label: String? = nil
    public var accessibilityText: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        fraction: Double,
        fill: Color = GatherTheme.primary,
        track: Color = GatherTheme.backgroundSecondary,
        border: Color? = nil,
        height: CGFloat = 8,
        cornerRadius: CGFloat = 4,
        width: CGFloat? = nil,
        label: String? = nil,
        accessibilityText: String? = nil
    ) {
        self.fraction = fraction
        self.fill = fill
        self.track = track
        self.border = border
        self.height = height
        self.cornerRadius = cornerRadius
        self.width = width
        self.label = label
        self.accessibilityText = accessibilityText
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(track)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fill)
                    .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
                if let label {
                    Text(label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.gatherTextPrimary)
                        .lineLimit(1)
                        .padding(.leading, 9)
                }
            }
            .overlay(
                Group {
                    if let border {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(border, lineWidth: 1)
                    }
                }
            )
        }
        .frame(width: width, height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: fraction)
        .accessibilityElement(children: label == nil ? .ignore : .contain)
        .accessibilityLabel(accessibilityText ?? label ?? "")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
    }
}

// MARK: - 空态

/// 统一空态/无结果态：图标 + 标题 + 说明 + 可选操作按钮。
/// 替代各页手搓 Image+Text 与 ContentUnavailableView 的两种写法。
public struct GatherEmptyState: View {
    public let icon: String
    public let title: String?
    public let message: String?
    public let actions: AnyView?
    public var iconColor: Color = .secondary
    public var iconSize: CGFloat = 40
    public var spacing: CGFloat = 8

    public init(
        icon: String,
        title: String? = nil,
        message: String? = nil,
        actions: AnyView? = nil,
        iconColor: Color = .secondary,
        iconSize: CGFloat = 40,
        spacing: CGFloat = 8
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions
        self.iconColor = iconColor
        self.iconSize = iconSize
        self.spacing = spacing
    }

    public init(
        icon: String,
        title: String? = nil,
        message: String? = nil,
        iconColor: Color = .secondary,
        iconSize: CGFloat = 40,
        spacing: CGFloat = 8,
        @ViewBuilder actions: () -> some View
    ) {
        self.init(
            icon: icon,
            title: title,
            message: message,
            actions: AnyView(actions()),
            iconColor: iconColor,
            iconSize: iconSize,
            spacing: spacing
        )
    }

    public var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .font(.headline)
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actions {
                actions
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 破坏性动作确认

extension View {
    /// 破坏性动作的二次确认（外壳统一门控）。
    ///
    /// 语义：
    /// - `pending` 非空即弹出 `.confirmationDialog`；`message` 必须写清
    ///   「会发生什么 + 影响范围（数量 / 路径）」；
    /// - 只有确认按钮会调用 `onConfirm` —— 命令层的 `confirmed: true` 只能
    ///   从确认分支到达；
    /// - 「取消」按钮调用 `onCancel` 写入可见文案（不静默 return），取消不发命令。
    func gatherDestructiveConfirm<Item>(
        pending: Binding<Item?>,
        title: String,
        confirmLabel: @escaping (Item) -> String,
        confirmRole: @escaping (Item) -> ButtonRole? = { _ in .destructive },
        message: @escaping (Item) -> String,
        onConfirm: @escaping (Item) -> Void,
        onCancel: @escaping (Item) -> Void
    ) -> some View {
        modifier(GatherDestructiveConfirmModifier(
            pending: pending,
            title: title,
            confirmLabel: confirmLabel,
            confirmRole: confirmRole,
            message: message,
            onConfirm: onConfirm,
            onCancel: onCancel
        ))
    }
}

private struct GatherDestructiveConfirmModifier<Item>: ViewModifier {
    @Binding var pending: Item?
    let title: String
    let confirmLabel: (Item) -> String
    let confirmRole: (Item) -> ButtonRole?
    let message: (Item) -> String
    let onConfirm: (Item) -> Void
    let onCancel: (Item) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { item in
            // 弹窗按钮显式启用：宿主页隐藏时会 .disabled(!isActive)，sheet/弹窗
            // 继承该环境值会把对话框按钮一并禁用（打开后无法确认/取消）。
            Button(confirmLabel(item), role: confirmRole(item)) { onConfirm(item) }
                .disabled(false)
            Button(GatherLocalization.l("取消"), role: .cancel) { onCancel(item) }
                .disabled(false)
        } message: { item in
            Text(message(item))
        }
    }
}
