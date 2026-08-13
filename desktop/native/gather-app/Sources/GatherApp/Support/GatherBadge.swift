// 共享徽标组件：对齐旧版 Badge.tsx 的胶囊形态（12px/999px 圆角、状态色），
// 提供任务/状态枚举 → 颜色的统一映射，消除各页"状态色全变 accent"的分裂。
import SwiftUI
import AppKit
import GatherCore

public enum GatherBadgeTone {
    case neutral
    case accent
    case success
    case warning
    case error
    case info

    var color: Color {
        switch self {
        case .neutral: return Color.secondary
        case .accent: return GatherTheme.primary
        case .success: return GatherTheme.success
        case .warning: return GatherTheme.warning
        case .error: return GatherTheme.error
        case .info: return GatherTheme.info
        }
    }
}

public struct GatherBadge: View {
    let text: String
    let tone: GatherBadgeTone
    /// 旧版实色样式（Badge.module.css：solid pastel 底 + 深色文字）：非 nil 时
    /// 渲染为 11px/600/uppercase/letter-spacing 0.5px/radius 10 实色徽标。
    let pastel: (foreground: Color, background: Color)?

    public init(_ text: String, tone: GatherBadgeTone = .neutral) {
        self.text = text
        self.tone = tone
        self.pastel = nil
    }

    /// 旧版 Badge.tsx STATUS_COLORS 实色样式：pastel 底 + 深色文字。
    public init(_ text: String, foreground: Color, background: Color) {
        self.text = text
        self.tone = .neutral
        self.pastel = (foreground, background)
    }

    public var body: some View {
        if let pastel {
            Text(text)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(pastel.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(pastel.background)
                )
                .accessibilityLabel(text)
        } else {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tone.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(tone.color.opacity(0.14))
                )
                .overlay(
                    Capsule().strokeBorder(tone.color.opacity(0.25), lineWidth: 1)
                )
                .accessibilityLabel(text)
        }
    }
}

// MARK: - 旧版 Badge.module.css 状态色板（pastel 底 + 深色文字，逐字对齐 CSS 色值）

public extension Color {
    /// 十六进制色值（旧版 CSS 色板直引）。
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    private static func badgeDynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hexValue: isDark ? dark : light)
        })
    }

    // photosLoaded 青（浅色取旧版 #e0f7fa / #00695c；深色为深底浅字）
    static let badgePhotosLoadedBg = Color.badgeDynamic(light: 0xE0F7FA, dark: 0x14332F)
    static let badgePhotosLoadedText = Color.badgeDynamic(light: 0x00695C, dark: 0x8FE0D8)
    // review 靛蓝（浅色 #e8eaf6 / #283593；深色深底浅字）
    static let badgeReviewBg = Color.badgeDynamic(light: 0xE8EAF6, dark: 0x2A2D4A)
    static let badgeReviewText = Color.badgeDynamic(light: 0x283593, dark: 0xB4BBF2)
    // running/analyzing 蓝（浅色 #e3f2fd / #1565c0；深色深底浅字）
    static let badgeRunningBg = Color.badgeDynamic(light: 0xE3F2FD, dark: 0x1B2D42)
    static let badgeRunningText = Color.badgeDynamic(light: 0x1565C0, dark: 0x9CC8EE)
    // done/completed 绿（浅色 #e8f5e9 / #2e7d32；深色深底浅字）
    static let badgeDoneBg = Color.badgeDynamic(light: 0xE8F5E9, dark: 0x1F3423)
    static let badgeDoneText = Color.badgeDynamic(light: 0x2E7D32, dark: 0x9AD9A0)
    // failed 红（浅色 #ffebee / #c62828；深色深底浅字）
    static let badgeFailedBg = Color.badgeDynamic(light: 0xFFEBEE, dark: 0x40242A)
    static let badgeFailedText = Color.badgeDynamic(light: 0xC62828, dark: 0xF2A6A6)
    // cancelled 橙（浅色 #fff3e0 / #e65100；深色深底浅字）
    static let badgeCancelledBg = Color.badgeDynamic(light: 0xFFF3E0, dark: 0x3D2A18)
    static let badgeCancelledText = Color.badgeDynamic(light: 0xE65100, dark: 0xF0BC8A)
    // partial 琥珀（浅色 #fff8e1 / #f57f17；深色深底浅字）
    static let badgePartialBg = Color.badgeDynamic(light: 0xFFF8E1, dark: 0x3B3215)
    static let badgePartialText = Color.badgeDynamic(light: 0xF57F17, dark: 0xF0D488)
    // cleaned 紫（浅色 #f3e5f5 / #6a1b9a；深色深底浅字）
    static let badgeCleanedBg = Color.badgeDynamic(light: 0xF3E5F5, dark: 0x33203B)
    static let badgeCleanedText = Color.badgeDynamic(light: 0x6A1B9A, dark: 0xD4A8EA)
    // draft 灰（.draft 取旧版 --color-bg-secondary / --color-text-secondary）
    static let badgeDraftBg = GatherTheme.backgroundSecondary
    static let badgeDraftText = GatherTheme.textPrimary
}

private extension NSColor {
    convenience init(hexValue: UInt32) {
        let red = Double((hexValue >> 16) & 0xFF) / 255
        let green = Double((hexValue >> 8) & 0xFF) / 255
        let blue = Double(hexValue & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

// MARK: - 旧版 Badge.tsx STATUS_COLORS 状态工厂（工作区卡片状态徽标；
// 标签对齐旧版 badge.* 键，analyzing/completed 复用 running/done 色板）

public extension GatherBadge {
    static func photosLoaded() -> Self {
        Self(GatherLocalization.l("已导入"), foreground: .badgePhotosLoadedText, background: .badgePhotosLoadedBg)
    }

    static func review() -> Self {
        Self(GatherLocalization.l("待审核"), foreground: .badgeReviewText, background: .badgeReviewBg)
    }

    static func running(_ label: String = GatherLocalization.l("运行中")) -> Self {
        Self(label, foreground: .badgeRunningText, background: .badgeRunningBg)
    }

    static func done(_ label: String = GatherLocalization.l("完成")) -> Self {
        Self(label, foreground: .badgeDoneText, background: .badgeDoneBg)
    }

    static func failed(_ label: String = GatherLocalization.l("失败")) -> Self {
        Self(label, foreground: .badgeFailedText, background: .badgeFailedBg)
    }

    static func cancelled() -> Self {
        Self(GatherLocalization.l("已取消"), foreground: .badgeCancelledText, background: .badgeCancelledBg)
    }

    static func draft() -> Self {
        Self(GatherLocalization.l("草稿"), foreground: .badgeDraftText, background: .badgeDraftBg)
    }

    static func partial() -> Self {
        Self(GatherLocalization.l("部分完成"), foreground: .badgePartialText, background: .badgePartialBg)
    }

    static func cleaned() -> Self {
        Self(GatherLocalization.l("已清理"), foreground: .badgeCleanedText, background: .badgeCleanedBg)
    }
}

// MARK: - 任务状态 → 徽标（对齐旧版 jobs 状态编码）
public extension GatherBadge {
    init(status: AnalysisJobStatus) {
        switch status {
        case .queued:
            self.init(GatherLocalization.l("排队中"), tone: .info)
        case .running:
            self.init(GatherLocalization.l("运行中"), tone: .accent)
        case .succeeded:
            self.init(GatherLocalization.l("已完成"), tone: .success)
        case .failed:
            self.init(GatherLocalization.l("失败"), tone: .error)
        case .cancelled:
            self.init(GatherLocalization.l("已取消"), tone: .neutral)
        case .interrupted:
            self.init(GatherLocalization.l("已中断"), tone: .warning)
        case .cancelling:
            self.init(GatherLocalization.l("取消中"), tone: .warning)
        }
    }
}
