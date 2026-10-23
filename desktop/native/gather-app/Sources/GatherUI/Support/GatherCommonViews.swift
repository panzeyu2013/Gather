// 共享基础视图组件（原生版）。
//
// 与旧版的区别：
// - 数值不再用 `.system(size: 24, weight: .bold)`，改用系统文本样式，随文字大小设置缩放；
// - 进度条改为原生 `ProgressView(value:)` + `.progressViewStyle(.linear)`；
// - 空态改用系统文本样式与 `.imageScale`，尺寸不再硬编码；
// - 一律使用语义色，跟随浅色 / 深色 / 增强对比度。
import SwiftUI

// MARK: - 统计数字

/// 数值 + 次级标签的统计单元。原生实现：数值走系统文本样式，标签走 `.caption`。
public struct GatherStatCard: View {
    public enum Style {
        /// 报告 / 统计区：较大的数值。
        case card
        /// 队列计数等紧凑场景。
        case compact
        /// 汇总条：内联数值。
        case plain
    }

    public let value: Int
    public let label: String
    public var color: Color = .primary
    public var style: Style = .card

    public init(value: Int, label: String, color: Color = .primary, style: Style = .card) {
        self.value = value
        self.label = label
        self.color = color
        self.style = style
    }

    public var body: some View {
        VStack(spacing: style == .plain ? 2 : 4) {
            // 状态色只出现在圆点上，数字始终用系统前景色。
            // （systemGreen/systemRed 当正文色在浅色下只有 ~2:1 —— 这是
            // macOS 设计语言里"颜色用于填充、不用于文字"的原因。）
            HStack(spacing: 6) {
                if style != .plain {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(value, format: .number)
                    .font(valueFont)
                    .monospacedDigit()
                    .foregroundStyle(style == .plain ? color : Color.primary)
            }
            Text(label)
                .font(GatherFont.labelRegular)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .applyStyle(style)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
    }

    private var valueFont: Font {
        switch style {
        case .card: return .title2.weight(.semibold)
        case .compact: return .callout.weight(.medium)
        case .plain: return .title3.weight(.semibold)
        }
    }
}

private extension View {
    @ViewBuilder
    func applyStyle(_ style: GatherStatCard.Style) -> some View {
        switch style {
        case .card:
            self
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                        .fill(GatherTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                        .strokeBorder(GatherTheme.hairline, lineWidth: 1)
                )

        case .compact, .plain:
            self
        }
    }
}

// MARK: - 进度条

/// 原生进度指示器。
///
/// `fill` 映射为 tint；`label` 映射为 `ProgressView` 的原生标签（显示在条上方）。
public struct GatherProgressBar: View {
    public let fraction: Double
    public var fill: Color = GatherTheme.accent
    public var label: String? = nil
    public var accessibilityText: String? = nil

    public init(
        fraction: Double,
        fill: Color = GatherTheme.accent,
        label: String? = nil,
        accessibilityText: String? = nil
    ) {
        self.fraction = fraction
        self.fill = fill
        self.label = label
        self.accessibilityText = accessibilityText
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    public var body: some View {
        ProgressView(value: clamped) {
            if let label {
                Text(label)
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .progressViewStyle(.linear)
        .tint(fill)
        .labelsHidden(if: label == nil)
        .accessibilityLabel(accessibilityText ?? label ?? "")
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(if condition: Bool) -> some View {
        if condition { self.labelsHidden() } else { self }
    }
}

// MARK: - 空态

/// 统一空态 / 无结果态：SF Symbol + 标题 + 说明 + 可选操作。
/// 视觉对齐系统 `ContentUnavailableView`（次要色符号、`headline` 标题、`callout` 说明）。
public struct GatherEmptyState: View {
    public let icon: String
    public let title: String?
    public let message: String?
    public let actions: AnyView?
    public var iconColor: Color = .secondary
    public var iconSize: CGFloat = 44
    public var spacing: CGFloat = 10

    public init(
        icon: String,
        title: String? = nil,
        message: String? = nil,
        actions: AnyView? = nil,
        iconColor: Color = .secondary,
        iconSize: CGFloat = 44,
        spacing: CGFloat = 10
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
        iconSize: CGFloat = 44,
        spacing: CGFloat = 10,
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
                .font(.system(size: iconSize, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .font(GatherFont.cardTitle)
            }
            if let message {
                Text(message)
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actions {
                actions
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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
    ///
    /// - Important: `confirmRole` 默认为 `nil`（普通按钮）。**只有真正不可撤销的
    ///   动作**才应传 `.destructive`；给可逆动作套红色按钮会稀释该信号。
    func gatherDestructiveConfirm<Item>(
        pending: Binding<Item?>,
        title: String,
        confirmLabel: @escaping (Item) -> String,
        confirmRole: @escaping (Item) -> ButtonRole? = { _ in nil },
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
    /// Cut 4 / 4b-2l：「取消」在渲染期按当前界面语言解析（无 store 时默认中文）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

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
            Button(l10n("取消"), role: .cancel) { onCancel(item) }
                .disabled(false)
        } message: { item in
            Text(message(item))
        }
    }
}
