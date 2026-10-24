// 共享徽标组件（原生版）。
//
// 与旧版的区别：
// - **不再对中日韩文字做 `.textCase(.uppercase)` / `.kerning()`**（那是拉丁排版手段，
//   套在中文上只会破坏字面节奏）；
// - 字号从 `.footnote`(10pt) 提到 `.caption`(11pt)，并去掉半粗体压暗；
// - 色调全部改用系统语义色，自动适配浅色 / 深色 / 增强对比度。
import SwiftUI
import AppKit
import GatherProtocol

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

    public var body: some View {
        HStack(spacing: 5) {
            // 语义色只做圆点；文字保持系统主色，保证 4.5:1 对比度。
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(GatherFont.label)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // 实心 surface：徽标既可能落在白卡上，也可能压在照片上；
        // 半透明语义底色在照片上不可控，改用中性胶囊 + 语义圆点。
        .background(Capsule().fill(GatherTheme.surface))
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.24), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - 固定色值

public extension Color {
    /// 十六进制色值。仅保留给确实需要固定色值的场景（如 C1 色标）。
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - 状态工厂（工作区卡片状态徽标）

// Cut 4 / 4b-2l：本文件是**非 View 的纯构造入口**（静态工厂 + init(status:)），
// 没有 Environment 可读，因此语言必须由调用方在渲染期显式传入（with l10n）。
// 旧实现在工厂里调进程级 l()，切语言后已构造的徽标不刷新（D-129）。
public extension GatherBadge {
    static func photosLoaded(with l10n: L10n) -> Self {
        Self(l10n("已导入"), tone: .success)
    }

    static func review(with l10n: L10n) -> Self {
        Self(l10n("待审核"), tone: .accent)
    }

    /// 运行中/完成/失败的状态词由调用方给出（唯一调用点在渲染期用 l10n 生成），
    /// 工厂不再自带默认中文标签——默认值会让「未迁移调用点」悄悄回退全局语言。
    static func running(_ label: String) -> Self {
        Self(label, tone: .info)
    }

    static func done(_ label: String) -> Self {
        Self(label, tone: .success)
    }

    static func failed(_ label: String) -> Self {
        Self(label, tone: .error)
    }

    static func draft(with l10n: L10n) -> Self {
        Self(l10n("草稿"), tone: .neutral)
    }
}

// MARK: - 任务状态 → 徽标

public extension GatherBadge {
    /// 任务状态 → 徽标；文案在渲染期按传入的 L10n 解析（与旧 switch 表同源）。
    init(status: AnalysisJobStatus, l10n: L10n) {
        switch status {
        case .queued:
            self.init(l10n("排队中"), tone: .neutral)
        case .running:
            self.init(l10n("运行中"), tone: .info)
        case .succeeded:
            self.init(l10n("已完成"), tone: .success)
        case .failed:
            self.init(l10n("失败"), tone: .error)
        case .cancelled:
            self.init(l10n("已取消"), tone: .neutral)
        case .interrupted:
            self.init(l10n("已中断"), tone: .warning)
        case .cancelling:
            self.init(l10n("取消中"), tone: .warning)
        }
    }
}
