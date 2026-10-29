// Gather 主题层（原生版）。
//
// 设计原则：
// 1. 品牌色统一做“行动”：暖橙用于主 CTA、选中态、强调图标与评分；
//    浅色 / 深色 / 增强对比度四态显式提供，避免系统蓝与品牌橙同屏竞争。
// 2. 表面分三层：canvas（窗口/页面）→ surface（卡片/工具条）→ surfaceMuted（嵌套面板）。
//    不再让卡片与页面同色；卡片用 1px hairline + 一层极轻阴影建立边界。
// 3. 文字与状态分离：语义状态色只做 fill / 图标 / 圆点；
//    需要彩色正文时使用 *Text 变体（已按 4.5:1 校核）。
// 4. 尺寸角色化：控件尺寸与圆角优先系统；卡片 / 缩略图 / 浮层使用固定三级圆角。
import SwiftUI
import AppKit
import Foundation

public enum GatherTheme {
    // MARK: - 品牌（行动 / 选中 / 强调）

    /// 品牌暖橙：文字、图标、选中描边、评分星标。
    public static let accent = dynamic(
        light: "#A54D2A",
        dark: "#D98964",
        highContrastLight: "#7E3517",
        highContrastDark: "#F2B08C"
    )

    /// 主 CTA 填充色：与白色文字组合的对比度 >= 5.68:1（深色模式同样成立）。
    public static let accentFill = dynamic(
        light: "#A54D2A",
        dark: "#A54D2A",
        highContrastLight: "#7E3517",
        highContrastDark: "#8A3E1F"
    )

    /// 填充品牌色上的文字色。
    public static let onAccent = Color.white

    /// 选中态：自定义表面统一使用品牌选中色。
    public static let selection = GatherTheme.accent

    /// 选中态低透明度填充。
    public static let selectionFill = GatherTheme.selection.opacity(0.14)

    /// 分段 / 页签控件的选中片：浅色是白片，深色比 surface 再亮一档。
    ///
    /// 深色模式下 surface(#2A2A2C) 与 surfaceMuted(#202022) 只差 10 个灰阶，
    /// 用 surface 直接做选中片会看不出边界；controlSelection 在深色提到
    /// #3A3A3C，浅色保持纯白。
    public static let controlSelection = dynamic(
        light: "#FFFFFF",
        dark: "#3A3A3C",
        highContrastLight: "#FFFFFF",
        highContrastDark: "#4A4A4C"
    )

    // MARK: - 表面（三层）

    /// 窗口 / 页面底色。
    public static let canvas = dynamic(
        light: "#F6F5F2",
        dark: "#1B1B1D",
        highContrastLight: "#F0F0F0",
        highContrastDark: "#000000"
    )

    /// 卡片 / 工具条 / 检查器分区表面。
    public static let surface = dynamic(
        light: "#FFFFFF",
        dark: "#2A2A2C",
        highContrastLight: "#FFFFFF",
        highContrastDark: "#1C1C1E"
    )

    /// 嵌套面板 / 次级表面。
    public static let surfaceMuted = dynamic(
        light: "#EFEDE8",
        dark: "#202022",
        highContrastLight: "#E8E8E8",
        highContrastDark: "#141416"
    )

    /// 卡片描边：比系统 separator 更清晰，浅色 14% / 深色 12%。
    public static let hairline = dynamic(
        light: "#00000024",
        dark: "#FFFFFF1F",
        highContrastLight: "#00000059",
        highContrastDark: "#FFFFFF4D"
    )

    /// 分组内容 / 卡片底色（兼容旧名，语义已指向 surface）。
    public static let contentBackground = GatherTheme.surface
    /// 次级分组底色（兼容旧名，语义已指向 surfaceMuted）。
    public static let secondaryContentBackground = GatherTheme.surfaceMuted
    /// 系统分隔线（用于列表 / 原生 Divider，不用于卡片边界）。
    public static let separator = Color(nsColor: .separatorColor)

    // MARK: - 文字

    public static let primaryText = Color.primary
    public static let secondaryText = Color.secondary

    // MARK: - 语义状态（fill / icon / dot）

    public static let info = Color(nsColor: .systemBlue)
    public static let success = Color(nsColor: .systemGreen)
    public static let warning = Color(nsColor: .systemOrange)
    public static let error = Color(nsColor: .systemRed)

    // 文字安全变体：只在必须使用彩色正文时使用（均已按 4.5:1 校核）。
    public static let infoText = dynamic(light: "#0060C9", dark: "#6FB3FF")
    public static let successText = dynamic(light: "#1E7B36", dark: "#6EE7A0")
    public static let warningText = dynamic(light: "#8A5A1F", dark: "#E5B27B")
    public static let errorText = dynamic(light: "#B3261E", dark: "#FF9C96")

    // MARK: - 照片查看器（刻意常暗，与 Preview / 照片一致）

    public static let viewerBackground = Color(white: 0.05)
    public static let viewerSurface = Color(white: 0.10)
    public static let viewerChrome = Color(white: 0.13)
    public static let viewerTextPrimary = Color(white: 0.93)
    public static let viewerTextSecondary = GatherTheme.viewerTextPrimary.opacity(0.72)

    // MARK: - 阴影

    /// 卡片：极轻，仅在浅色模式下可见。
    public static let shadowCard = Color.black.opacity(0.06)
    /// 首屏 hero / 大卡片。
    public static let shadowHero = Color.black.opacity(0.10)
    /// 浮层：toast / 冲突面板 / 浮动工具条。
    public static let shadowFloating = Color.black.opacity(0.16)

    // MARK: - 圆角

    public enum Radius {
        /// 缩略图 / 小控件。
        public static let thumbnail: CGFloat = 6
        /// 卡片 / 分组容器 / 大缩略图。
        public static let card: CGFloat = 12
        /// 功能块 / 首屏 tile。
        public static let tile: CGFloat = 16
        /// 首屏 hero / 大型浮层。
        public static let hero: CGFloat = 24
        /// 浮层 / toast / sheet。
        public static let floating: CGFloat = 12

        /// 嵌套面板（检查器内的分组容器）。
        public static let panel: CGFloat = 8
    }

    // MARK: - 动态色构造

    /// 浅色 / 深色 / 增强对比度四态动态色。
    /// 支持 6 位 RRGGBB 与 8 位 RRGGBBAA。
    static func dynamic(
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

// MARK: - 原生分组容器

public extension View {
    /// 原生分组容器：surface 底色 + hairline 描边 + 连续圆角 + 极轻卡片阴影。
    ///
    /// - Parameters:
    ///   - cornerRadius: 容器圆角，默认 10。
    ///   - padding: 内容内边距，默认 16。调用点不要再追加 padding(18)。
    ///   - elevated: 是否画卡片阴影；嵌套面板可传 false。
    func gatherCard(
        cornerRadius: CGFloat = GatherTheme.Radius.card,
        padding: CGFloat = 16,
        elevated: Bool = true
    ) -> some View {
        modifier(GatherGroupBoxModifier(
            cornerRadius: cornerRadius,
            padding: padding,
            elevated: elevated
        ))
    }
}

private struct GatherGroupBoxModifier: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(GatherTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(GatherTheme.hairline, lineWidth: 1)
            )
            .shadow(
                color: elevated ? GatherTheme.shadowCard : .clear,
                radius: 3,
                x: 0,
                y: 1
            )
    }
}

private extension NSColor {
    /// 十六进制色值：支持 6 位 RRGGBB 与 8 位 RRGGBBAA。
    convenience init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        if cleaned.count == 8 {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
