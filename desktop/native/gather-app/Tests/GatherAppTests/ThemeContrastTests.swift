// ThemeContrastTests.swift
// 主题色对比度回归：只锁“文字安全”token，浅色/深色/高对比分别解析。
import Testing
import SwiftUI
import AppKit
@testable import GatherUI

/// 主题色对比度回归：只锁“文字安全”token，不锁系统 fill 色。
///
/// 解析路径：Color → NSColor → 在指定 NSAppearance 下解析为 sRGB。
/// 这里不复制 hex，避免“测试通过但 token 已改”的假绿灯。
@MainActor
@Suite("theme contrast")
struct ThemeContrastTests {
    private struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }

    private func resolved(_ color: Color, in appearanceName: NSAppearance.Name) -> RGB {
        let appearance = NSAppearance(named: appearanceName)!
        var components: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
            components = (nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent)
        }
        return RGB(r: Double(components.0), g: Double(components.1), b: Double(components.2))
    }

    private func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let l1 = luminance(a)
        let l2 = luminance(b)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func assertTextContrast(
        _ color: Color,
        name: String,
        appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    ) {
        for appearance in appearances {
            let surface = resolved(GatherTheme.surface, in: appearance)
            let value = resolved(color, in: appearance)
            let ratio = contrast(value, surface)
            #expect(
                ratio >= 4.5,
                "\(name) 在 \(appearance.rawValue) 下对比度 \(ratio)，低于 4.5:1"
            )
        }
    }

    @Test("动态色确实随外观解析（防止测试假绿）")
    func dynamicColorsResolve() {
        let light = resolved(GatherTheme.canvas, in: .aqua)
        let dark = resolved(GatherTheme.canvas, in: .darkAqua)
        let ratio = contrast(light, dark)
        #expect(ratio > 1.1, "canvas 在浅/深外观下几乎相同（\(ratio)），动态色解析可能失效")
    }

    @Test("品牌强调色在两种外观下可作为文字")
    func accentIsReadableAsText() {
        assertTextContrast(GatherTheme.accent, name: "accent")
    }

    @Test("主 CTA 填充色与白字保持可读")
    func primaryActionFillIsReadable() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fill = resolved(GatherTheme.accentFill, in: appearance)
            let onFill = resolved(GatherTheme.onAccent, in: appearance)
            let ratio = contrast(fill, onFill)
            #expect(ratio >= 4.5, "accentFill/onAccent 在 \(appearance.rawValue) 下对比度 \(ratio)")
        }
    }

    @Test("语义状态文字变体在浅色/深色下均达到 4.5:1")
    func statusTextTokensAreReadable() {
        assertTextContrast(GatherTheme.successText, name: "successText")
        assertTextContrast(GatherTheme.warningText, name: "warningText")
        assertTextContrast(GatherTheme.errorText, name: "errorText")
        assertTextContrast(GatherTheme.infoText, name: "infoText")
    }

    @Test("增强对比度的强调色仍可作为文字")
    func highContrastAccentIsReadable() {
        assertTextContrast(
            GatherTheme.accent,
            name: "accent",
            appearances: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        )
    }
}
