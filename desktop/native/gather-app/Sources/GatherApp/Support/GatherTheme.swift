// Gather 主题层（原生版）。
//
// 设计原则：
// 1. **品牌色只做 accent**：暖橙只用于 tint / 选中 / 强调，绝不再充当表面色或正文色。
//    与资产目录里的 Color Set 等价，显式提供「增强对比度」变体。
// 2. **表面 / 文字 / 分隔线全部来自 AppKit 语义色**：自动跟随浅色、深色、
//    增强对比度与降低透明度，不再硬编码 hex。
// 3. **不再有 spacing / radius 的自造阶梯**：控件尺寸与圆角交给系统控件；
//    仅在容器层保留一个最小的圆角常量。
import SwiftUI
import AppKit

public enum GatherTheme {
    // MARK: - 品牌 accent（唯一保留的自定义色，且只用于强调）

    /// 品牌暖橙。等价于资产目录 Color Set：浅色/深色/增强对比度四态。
    public static let accent = dynamic(
        light: "#A54D2A",
        dark: "#D98964",
        highContrastLight: "#7E3517",
        highContrastDark: "#F2B08C"
    )

    /// 选中态填充：accent 的低透明度叠色（对应系统选中高亮的强度）。
    public static let selectionFill = accent.opacity(0.16)

    // MARK: - 表面（语义色）

    /// 窗口 / 页面底色。
    public static let windowBackground = Color(nsColor: .windowBackgroundColor)
    /// 分组内容（卡片、表格、列表）底色。
    public static let contentBackground = Color(nsColor: .controlBackgroundColor)
    /// 次级分组底色（嵌套面板）。
    public static let secondaryContentBackground = Color(nsColor: .underPageBackgroundColor)
    /// 分隔线 / 描边。
    public static let separator = Color(nsColor: .separatorColor)

    // MARK: - 文字（语义色）

    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary

    // MARK: - 语义状态色（系统色，自动适配深色与增强对比度）

    public static let info = Color(nsColor: .systemBlue)
    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let error = Color(nsColor: .systemRed)

    // MARK: - 照片查看器（刻意常暗，与 Preview / 照片一致）

    public static let viewerBackground = Color(white: 0.05)
    public static let viewerSurface = Color(white: 0.10)
    public static let viewerChrome = Color(white: 0.13)
    /// 查看器深色面板上的主文字。
    public static let viewerTextPrimary = Color(white: 0.93)

    // MARK: - 阴影（中性，系统级强度）

    public static let shadowSm = Color.black.opacity(0.08)
    public static let shadowMd = Color.black.opacity(0.12)

    // MARK: - 容器圆角

    /// macOS 分组容器的标准圆角。控件圆角由系统控件自行决定。
    public enum Radius {
        public static let group: CGFloat = 10
        public static let panel: CGFloat = 8

        // 旧名兼容：自造圆角阶梯已废弃，映射到分组/面板两级。
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 10
    }

    // MARK: - 动态色构造

    /// 浅色 / 深色 / 增强对比度四态动态色。
    private static func dynamic(
        light: String,
        dark: String,
        highContrastLight: String? = nil,
        highContrastDark: String? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ]) {
            case .accessibilityHighContrastDarkAqua:
                return NSColor(hex: highContrastDark ?? dark)
            case .accessibilityHighContrastAqua:
                return NSColor(hex: highContrastLight ?? light)
            case .darkAqua:
                return NSColor(hex: dark)
            default:
                return NSColor(hex: light)
            }
        })
    }
}

// MARK: - 兼容别名
//
// 旧名保留为「语义指向」，避免 400+ 处调用点一次性重命名带来的回归风险；
// 取值已全部改为系统语义色。新代码请使用上面的语义名。

public extension GatherTheme {
    /// - Note: 语义 = accent。仅用于 tint / 强调，勿用作表面或正文色。
    static var primary: Color { accent }
    /// - Note: 语义 = accent（hover 不再单独调色，交由系统处理）。
    static var primaryHover: Color { accent }
    /// - Note: 语义 = 选中填充。
    static var primarySoft: Color { selectionFill }
    /// - Note: 语义 = 窗口底色。
    static var background: Color { windowBackground }
    /// - Note: 语义 = 分组内容底色。
    static var backgroundSecondary: Color { contentBackground }
    /// - Note: 语义 = 分组内容底色。
    static var surface: Color { contentBackground }
    /// - Note: 语义 = 主文字色。
    static var textPrimary: Color { primaryText }
    /// - Note: 语义 = 分隔线。
    static var border: Color { separator }

    /// 旧版固定标签列宽度。原生实现请改用 Form + LabeledContent。
    static let formLabelWidth: CGFloat = 110
}

public extension Color {
    /// 品牌强调色。
    static var gatherAccent: Color { GatherTheme.accent }
    /// 窗口底色。
    static var gatherWindowBackground: Color { GatherTheme.windowBackground }
    /// 分组内容底色。
    static var gatherContentBackground: Color { GatherTheme.contentBackground }

    // MARK: 兼容别名

    static var gatherPrimary: Color { GatherTheme.accent }
    static var gatherBackground: Color { GatherTheme.windowBackground }
    static var gatherBackgroundSecondary: Color { GatherTheme.contentBackground }
    static var gatherSurface: Color { GatherTheme.contentBackground }
    static var gatherBorder: Color { GatherTheme.separator }
    static var gatherTextPrimary: Color { GatherTheme.primaryText }
}

// MARK: - 原生分组容器

public extension View {
    /// 原生分组容器：语义内容底色 + 系统分隔线描边 + 连续圆角。
    ///
    /// 取代旧版 gatherCard() 的硬编码暖色卡片。与 macOS「内嵌分组」外观一致，
    /// 自动跟随浅色 / 深色 / 增强对比度。
    func gatherCard(cornerRadius: CGFloat = GatherTheme.Radius.group) -> some View {
        modifier(GatherGroupBoxModifier(cornerRadius: cornerRadius))
    }
}

private struct GatherGroupBoxModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(GatherTheme.contentBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(GatherTheme.separator, lineWidth: 1)
            )
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
