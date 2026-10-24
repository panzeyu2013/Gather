import SwiftUI

/// 文本角色：页面只选角色，不直接选字号 / 字重。
///
/// 这些角色刻意映射到 macOS 系统文本样式，保留 Dynamic Type；
/// 需要固定字号时用 `GatherFont` 的底层常量，但页面代码不应直接调用。
public enum GatherTextRole: Sendable {
    case hero
    case pageTitle
    case sectionTitle
    case body
    case bodyStrong
    case secondary
    case secondaryStrong
    case label
    case mono
    case stat

    var font: Font {
        switch self {
        case .hero: return GatherFont.hero
        case .pageTitle: return GatherFont.pageTitle
        case .sectionTitle: return GatherFont.sectionTitle
        case .body: return GatherFont.body
        case .bodyStrong: return GatherFont.bodyStrong
        case .secondary: return GatherFont.secondary
        case .secondaryStrong: return GatherFont.secondaryStrong
        case .label: return GatherFont.label
        case .mono: return GatherFont.mono
        case .stat: return GatherFont.stat
        }
    }

    var defaultColor: Color {
        switch self {
        case .secondary, .secondaryStrong:
            return .secondary
        default:
            return .primary
        }
    }
}

public extension View {
    /// 文本角色修饰符。用于 `Text` / `Label`；不要把它套在含按钮的整块容器上。
    func gatherText(_ role: GatherTextRole, color: Color? = nil) -> some View {
        self
            .font(role.font)
            .foregroundStyle(color ?? role.defaultColor)
    }
}
