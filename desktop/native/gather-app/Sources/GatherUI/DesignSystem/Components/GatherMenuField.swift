import SwiftUI

/// 一个菜单选项：显示文案 + 稳定值。
///
/// 组件不依赖业务枚举；调用点在渲染期把本地化文案解析好再传进来。
public struct GatherMenuOption<Value: Hashable>: Identifiable {
    public let label: String
    public let value: Value

    public var id: Value { value }

    public init(_ label: String, value: Value) {
        self.label = label
        self.value = value
    }
}

/// 紧凑菜单字段：检查器 / 筛选条里的「当前值 + chevron」。
///
/// 不再直接用系统 `.pickerStyle(.menu)` 的大灰块（在检查器里像一块空表单），
/// 而是用统一的 26pt 字段：中性表面 + hairline + 悬停强调；菜单项仍由系统
/// `Picker` 提供选中勾、键盘与 VoiceOver 语义。
///
/// 两种形态：
/// - `.field`：填充表面，适合检查器 / 筛选条；
/// - `.toolbar`：无底色、悬停才出现浅底，适合系统工具栏玻璃内。
public struct GatherMenuField<Value: Hashable>: View {
    public enum Style: Sendable {
        case field
        case toolbar
    }

    private let title: String
    @Binding private var selection: Value
    private let options: [GatherMenuOption<Value>]
    private let systemImage: String?
    private let style: Style
    private let minWidth: CGFloat
    private let maxWidth: CGFloat?
    private let fixedWidth: CGFloat?
    private let expands: Bool

    @State private var isHovered = false

    public init(
        _ title: String,
        selection: Binding<Value>,
        options: [GatherMenuOption<Value>],
        systemImage: String? = nil,
        style: Style = .field,
        minWidth: CGFloat = 0,
        maxWidth: CGFloat? = nil,
        fixedWidth: CGFloat? = nil,
        expands: Bool = false
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.systemImage = systemImage
        self.style = style
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.fixedWidth = fixedWidth
        self.expands = expands
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    public var body: some View {
        // 关键：可见的字段完全由我们绘制；Menu 只作为透明命中层叠在上面。
        //
        // 直接给 Menu 的 label 套背景在 macOS 26 会被 borderlessButton 菜单样式
        // 接管：底被抹掉、chevron 被换成系统的前导指示符、图标还会继承品牌 tint。
        // 透明 overlay 保留原生 Menu 的勾选 / 键盘 / VoiceOver，同时不干扰外观。
        label
            .accessibilityHidden(true)
            .overlay {
                Menu {
                    // .inline：直接在当前菜单里列出选项并打勾；默认的菜单
                    // 样式会把 Picker 变成一个「筛选 ›」二级子菜单，多一次悬停。
                    // 空 label：菜单顶部不再重复一行「筛选」标题。
                    Picker(selection: $selection) {
                        ForEach(options) { option in
                            Text(option.label).tag(option.value)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel(title)
                .accessibilityValue(currentLabel)
            }
            // 不再 horizontal fixedSize：它会让长值顶破 maxWidth，无法省略。
            // frame(maxWidth:) 负责收敛；expands 时由父级给满宽。
            .fixedSize(horizontal: !expands && fixedWidth == nil, vertical: true)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var label: some View {
        HStack(spacing: GatherMetrics.Space.controlGap) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(currentLabel)
                .font(GatherFont.labelRegular)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if expands || fixedWidth != nil {
                // 固定宽的工具栏字段：值贴左、chevron 贴右，避免文字悬在中间。
                Spacer(minLength: 8)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, style == .toolbar
            ? GatherChromeMetrics.fieldToolbarHorizontalPadding
            : GatherChromeMetrics.fieldHorizontalPadding)
        // 紧凑形态按内容取宽（避免三个筛选项被拉成三大条），只有 expands
        // 或 fixedWidth 才占满 / 固定宽度。
        .frame(minWidth: minWidth, maxWidth: expands ? .infinity : (fixedWidth ?? maxWidth))
        .frame(width: fixedWidth, height: style == .toolbar ? 22 : 26)
        .background(background)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .field:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? GatherTheme.selectionFill : GatherTheme.surfaceMuted)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(GatherTheme.hairline, lineWidth: 0.5)
                )
        case .toolbar:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? GatherTheme.selectionFill : Color.clear)
        }
    }
}

/// 检查器行：左标签 + 右紧凑菜单。用于「网格尺寸」这类需要字段名的设置。
public struct GatherMenuRow<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [GatherMenuOption<Value>]
    private let minWidth: CGFloat
    private let fixedWidth: CGFloat?

    public init(
        _ title: String,
        selection: Binding<Value>,
        options: [GatherMenuOption<Value>],
        minWidth: CGFloat = 72,
        fixedWidth: CGFloat? = nil
    ) {
        self.title = title
        self._selection = selection
        self.options = options
        self.minWidth = minWidth
        self.fixedWidth = fixedWidth
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(GatherFont.labelRegular)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            GatherMenuField(
                title,
                selection: $selection,
                options: options,
                minWidth: minWidth,
                maxWidth: 150,
                fixedWidth: fixedWidth
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
