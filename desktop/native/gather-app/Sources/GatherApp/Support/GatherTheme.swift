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

    // MARK: - 阴影（旧版暖色半透明阴影族）
    public static let shadowMd = Color(red: 61 / 255, green: 56 / 255, blue: 51 / 255).opacity(0.1)

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
