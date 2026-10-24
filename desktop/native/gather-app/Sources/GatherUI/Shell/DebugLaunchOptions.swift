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

    /// `--ui-activate`：截图前把窗口置前（终端直接启动时可能被其它窗口盖住）。
    static var activateWindow: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-activate")
    }

    /// `--ui-language en`：截图/验收用的界面语言覆盖（只在 scene 发布后设置，
    /// 不改持久化设置；上一版在启动前设置会停在 loading）。
    static var languageCode: String? {
        value(for: "--ui-language")
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
