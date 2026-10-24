#if DEBUG
import Foundation

/// 仅 DEBUG 的视觉 QA 入口：`--ui-page library|persons|settings|control|gallery|...`，
/// 配合 `--ui-session <id>` 可直接打开一个已有工作区的某个页面。
///
/// 生产构建不包含这段逻辑；它只用于在没有辅助功能权限的机器上,
/// 直接启动到某个全局页并截图。会话页仍走正常导航。
package enum DebugLaunchOptions {
    static var page: String? {
        value(for: "--ui-page")
    }

    /// `--ui-appearance dark|light|high-contrast|high-contrast-dark`：强制窗口外观。
    static var appearance: String? {
        value(for: "--ui-appearance")
    }

    /// `--ui-session <id>`：直接打开一个已有工作区（配合 --ui-page 选页面）。
    static var sessionId: String? {
        value(for: "--ui-session")
    }

    /// `--ui-window-width 860 --ui-window-height 560`：最小窗口截图。
    package static var windowWidth: CGFloat? {
        dimension(for: "--ui-window-width")
    }

    package static var windowHeight: CGFloat? {
        dimension(for: "--ui-window-height")
    }

    private static func dimension(for flag: String) -> CGFloat? {
        guard let raw = value(for: flag), let value = Double(raw),
              value >= 400, value <= 2400 else { return nil }
        return CGFloat(value)
    }

    private static func value(for flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
#endif
