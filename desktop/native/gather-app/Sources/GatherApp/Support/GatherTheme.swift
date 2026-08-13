// Gather 主题令牌：整体偏向旧版暖橙品牌（primary #a54d2a / 背景 #f5f0eb），
// 控件外观保持系统原生。通过 .tint(GatherTheme.primary) 挂到根视图后，
// 现有 Color.accentColor 引用与系统控件自动跟随暖橙主色。
import SwiftUI
import AppKit

public enum GatherTheme {
    // MARK: - 品牌主色（旧版 global.css --color-primary 系）
    public static let primary = dynamic(light: "#A54D2A", dark: "#D98964")
    public static let primaryHover = dynamic(light: "#9E4525", dark: "#E09A77")
    public static let primarySoft = dynamic(light: "#F3DFD4", dark: "#4A3228")

    // MARK: - 背景 / 表面
    public static let background = dynamic(light: "#F5F0EB", dark: "#221E1A")
    public static let backgroundSecondary = dynamic(light: "#EDE6DC", dark: "#2A2621")
    public static let surface = dynamic(light: "#FAF7F2", dark: "#2E2A24")

    // MARK: - 文字
    public static let textPrimary = dynamic(light: "#3D3833", dark: "#F0EAE2")

    // MARK: - 边框
    public static let border = dynamic(light: "#E0D8CE", dark: "#3A352F")

    // MARK: - 语义色（旧版语义色值，深色模式取亮化版本）
    public static let info = dynamic(light: "#2D6BA1", dark: "#6BA8D8")
    public static let success = dynamic(light: "#31723D", dark: "#6FBF7F")
    public static let error = dynamic(light: "#B3403F", dark: "#E0706F")
    public static let warning = dynamic(light: "#D4944F", dark: "#E5B27B")

    // MARK: - 语义色柔和填充（浅色按 14% / 深色按 16% 叠在表面色上）
    public static let successSoft = dynamic(light: "#DEE4D9", dark: "#384233")
    public static let errorSoft = dynamic(light: "#F0DDD9", dark: "#4A3530")
    public static let warningSoft = dynamic(light: "#F5E9DB", dark: "#4B4032")

    // MARK: - 查看器深色面板（始终深色，不随外观模式切换）
    public static let viewerBackground = Color(hex: 0x080808)
    public static let viewerSurface = Color(hex: 0x191919)
    public static let viewerChrome = Color(hex: 0x202020)
    /// 查看器/胶片条深色面板上的主文字（旧版 0xeee9e5）。
    public static let viewerTextPrimary = Color(hex: 0xEEE9E5)

    // MARK: - 阴影（旧版暖色半透明阴影族）
    public static let shadowSm = Color(red: 61 / 255, green: 56 / 255, blue: 51 / 255).opacity(0.12)
    public static let shadowMd = Color(red: 61 / 255, green: 56 / 255, blue: 51 / 255).opacity(0.1)

    // MARK: - 圆角阶梯
    public enum Radius {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 10
    }

    // MARK: - 间距阶梯
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
    }

    // MARK: - 表单标签列统一宽度
    public static let formLabelWidth: CGFloat = 110

    // MARK: - 动态色
    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

public extension Color {
    /// 主题主色（等价旧版 primary #a54d2a）。
    static var gatherPrimary: Color { GatherTheme.primary }
    /// 主题页面背景（等价旧版 #f5f0eb）。
    static var gatherBackground: Color { GatherTheme.background }
    /// 主题次级背景（等价旧版 #ede6dc）。
    static var gatherBackgroundSecondary: Color { GatherTheme.backgroundSecondary }
    /// 主题卡片表面（等价旧版 #faf7f2）。
    static var gatherSurface: Color { GatherTheme.surface }
    static var gatherBorder: Color { GatherTheme.border }
    static var gatherTextPrimary: Color { GatherTheme.textPrimary }
}

public extension View {
    /// 统一卡片样式：暖色表面 + 圆角 10（旧版 surface + radius 10）。
    func gatherCard(cornerRadius: CGFloat = 10) -> some View {
        padding(18)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gatherSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1)
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
