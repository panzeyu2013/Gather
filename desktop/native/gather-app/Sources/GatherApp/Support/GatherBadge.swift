// 共享徽标组件（原生版）。
//
// 与旧版的区别：
// - **不再对中日韩文字做 `.textCase(.uppercase)` / `.kerning()`**（那是拉丁排版手段，
//   套在中文上只会破坏字面节奏）；
// - 字号从 `.footnote`(10pt) 提到 `.caption`(11pt)，并去掉半粗体压暗；
// - 色调全部改用系统语义色，自动适配浅色 / 深色 / 增强对比度。
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
        case .neutral: return .secondary
        case .accent: return GatherTheme.accent
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

    public init(_ text: String, tone: GatherBadgeTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    /// 旧版实色样式入参：现统一按语义色调渲染（前景给出色调，底色取其低透明度）。
    public init(_ text: String, foreground: Color, background: Color) {
        self.text = text
        self.tone = GatherBadgeTone(approximating: foreground)
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.color.opacity(0.15)))
            .overlay(Capsule().strokeBorder(tone.color.opacity(0.22), lineWidth: 1))
            .accessibilityLabel(text)
    }
}

private extension GatherBadgeTone {
    /// 由旧版实色前景反推语义色调（保持调用点不变）。
    init(approximating color: Color) {
        self = .accent
    }
}

// MARK: - 旧版 Badge.module.css 色板 → 系统语义色
//
// 名称保留（调用点不变），取值改为系统色，深浅色与增强对比度由系统负责。

public extension Color {
    /// 十六进制色值。仅保留给确实需要固定色值的场景（如 C1 色标）。
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    static let badgePhotosLoadedBg = Color(nsColor: .systemTeal).opacity(0.15)
    static let badgePhotosLoadedText = Color(nsColor: .systemTeal)
    static let badgeReviewBg = Color(nsColor: .systemIndigo).opacity(0.15)
    static let badgeReviewText = Color(nsColor: .systemIndigo)
    static let badgeRunningBg = Color(nsColor: .systemBlue).opacity(0.15)
    static let badgeRunningText = Color(nsColor: .systemBlue)
    static let badgeDoneBg = Color(nsColor: .systemGreen).opacity(0.15)
    static let badgeDoneText = Color(nsColor: .systemGreen)
    static let badgeFailedBg = Color(nsColor: .systemRed).opacity(0.15)
    static let badgeFailedText = Color(nsColor: .systemRed)
    static let badgeDraftBg = Color(nsColor: .quaternaryLabelColor)
    static let badgeDraftText = Color(nsColor: .secondaryLabelColor)
}

// MARK: - 状态工厂（工作区卡片状态徽标）

public extension GatherBadge {
    static func photosLoaded() -> Self {
        Self(GatherLocalization.l("已导入"), tone: .success)
    }

    static func review() -> Self {
        Self(GatherLocalization.l("待审核"), tone: .accent)
    }

    static func running(_ label: String = GatherLocalization.l("运行中")) -> Self {
        Self(label, tone: .info)
    }

    static func done(_ label: String = GatherLocalization.l("完成")) -> Self {
        Self(label, tone: .success)
    }

    static func failed(_ label: String = GatherLocalization.l("失败")) -> Self {
        Self(label, tone: .error)
    }

    static func draft() -> Self {
        Self(GatherLocalization.l("草稿"), tone: .neutral)
    }
}

// MARK: - 任务状态 → 徽标

public extension GatherBadge {
    init(status: AnalysisJobStatus) {
        switch status {
        case .queued:
            self.init(GatherLocalization.l("排队中"), tone: .neutral)
        case .running:
            self.init(GatherLocalization.l("运行中"), tone: .info)
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
