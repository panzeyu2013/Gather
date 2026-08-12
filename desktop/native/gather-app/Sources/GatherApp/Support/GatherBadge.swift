// 共享徽标组件：对齐旧版 Badge.tsx 的胶囊形态（12px/999px 圆角、状态色），
// 提供任务/状态枚举 → 颜色的统一映射，消除各页"状态色全变 accent"的分裂。
import SwiftUI
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
                .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11, weight: .medium))
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

    // photosLoaded 青（.photosLoaded #e0f7fa / #00695c）
    static let badgePhotosLoadedBg = Color(hex: 0xE0F7FA)
    static let badgePhotosLoadedText = Color(hex: 0x00695C)
    // review 靛蓝（.review #e8eaf6 / #283593）
    static let badgeReviewBg = Color(hex: 0xE8EAF6)
    static let badgeReviewText = Color(hex: 0x283593)
    // running/analyzing 蓝（.running/.analyzing #e3f2fd / #1565c0）
    static let badgeRunningBg = Color(hex: 0xE3F2FD)
    static let badgeRunningText = Color(hex: 0x1565C0)
    // done/completed 绿（.done/.completed #e8f5e9 / #2e7d32）
    static let badgeDoneBg = Color(hex: 0xE8F5E9)
    static let badgeDoneText = Color(hex: 0x2E7D32)
    // failed 红（.failed #ffebee / #c62828）
    static let badgeFailedBg = Color(hex: 0xFFEBEE)
    static let badgeFailedText = Color(hex: 0xC62828)
    // cancelled 橙（.cancelled #fff3e0 / #e65100）
    static let badgeCancelledBg = Color(hex: 0xFFF3E0)
    static let badgeCancelledText = Color(hex: 0xE65100)
    // partial 琥珀（.partial #fff8e1 / #f57f17）
    static let badgePartialBg = Color(hex: 0xFFF8E1)
    static let badgePartialText = Color(hex: 0xF57F17)
    // cleaned 紫（.cleaned #f3e5f5 / #6a1b9a）
    static let badgeCleanedBg = Color(hex: 0xF3E5F5)
    static let badgeCleanedText = Color(hex: 0x6A1B9A)
    // draft 灰（.draft 取旧版 --color-bg-secondary / --color-text-secondary）
    static let badgeDraftBg = Color(hex: 0xEDE6DC)
    static let badgeDraftText = Color(hex: 0x6B655D)
}

// MARK: - 旧版 Badge.tsx STATUS_COLORS 状态工厂（工作区卡片状态徽标；
// 标签对齐旧版 badge.* 键，analyzing/completed 复用 running/done 色板）

public extension GatherBadge {
    static func photosLoaded() -> Self {
        Self("已导入", foreground: .badgePhotosLoadedText, background: .badgePhotosLoadedBg)
    }

    static func review() -> Self {
        Self("待审核", foreground: .badgeReviewText, background: .badgeReviewBg)
    }

    static func running(_ label: String = "运行中") -> Self {
        Self(label, foreground: .badgeRunningText, background: .badgeRunningBg)
    }

    static func done(_ label: String = "完成") -> Self {
        Self(label, foreground: .badgeDoneText, background: .badgeDoneBg)
    }

    static func failed(_ label: String = "失败") -> Self {
        Self(label, foreground: .badgeFailedText, background: .badgeFailedBg)
    }

    static func cancelled() -> Self {
        Self("已取消", foreground: .badgeCancelledText, background: .badgeCancelledBg)
    }

    static func draft() -> Self {
        Self("草稿", foreground: .badgeDraftText, background: .badgeDraftBg)
    }

    static func partial() -> Self {
        Self("部分完成", foreground: .badgePartialText, background: .badgePartialBg)
    }

    static func cleaned() -> Self {
        Self("已清理", foreground: .badgeCleanedText, background: .badgeCleanedBg)
    }
}

// MARK: - 任务状态 → 徽标（对齐旧版 jobs 状态编码）
public extension GatherBadge {
    init(status: AnalysisJobStatus) {
        switch status {
        case .queued:
            self.init("排队中", tone: .info)
        case .running:
            self.init("运行中", tone: .accent)
        case .succeeded:
            self.init("已完成", tone: .success)
        case .failed:
            self.init("失败", tone: .error)
        case .cancelled:
            self.init("已取消", tone: .neutral)
        case .interrupted:
            self.init("已中断", tone: .warning)
        case .cancelling:
            self.init("取消中", tone: .warning)
        }
    }
}
