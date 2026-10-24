import Foundation
import Observation

/// 应用级命令（菜单/按钮/快捷键共用）。
package enum AppCommand: String, CaseIterable, Sendable {
    case newWorkspace
    case importFolder
    case captureOneImport
    case toggleSidebar
    case openSettings

}

/// 命令中心：菜单与 RootView 之间唯一的动作通道。
///
/// 不再用 NotificationCenter 传菜单命令；RootView 在 onAppear 安装 handler，
/// 菜单只调用 `perform`。没有 handler 时 `canPerform` 为 false；菜单暂时回退
/// 旧通知（禁用态尚未实现，见 docs/reviews/appearance-m2-m4-review.md）。
@MainActor
@Observable
package final class AppCommandCenter {
    @ObservationIgnored package var onNewWorkspace: (() -> Void)?
    @ObservationIgnored package var onImportFolder: (() -> Void)?
    @ObservationIgnored package var onCaptureOneImport: (() -> Void)?
    @ObservationIgnored package var onToggleSidebar: (() -> Void)?
    @ObservationIgnored package var onOpenSettings: (() -> Void)?

    package init() {}

    /// 窗口离场时清掉 handler，避免菜单命令落到已销毁窗口的 @State binding。
    /// 单窗口模型下由 RootView.onDisappear 调用；重开后 onAppear 会重新安装。
    package func clearHandlers() {
        onNewWorkspace = nil
        onImportFolder = nil
        onCaptureOneImport = nil
        onToggleSidebar = nil
        onOpenSettings = nil
    }

    package func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .newWorkspace: return onNewWorkspace != nil
        case .importFolder: return onImportFolder != nil
        case .captureOneImport: return onCaptureOneImport != nil
        case .toggleSidebar: return onToggleSidebar != nil
        case .openSettings: return onOpenSettings != nil
        }
    }

    package func perform(_ command: AppCommand) {
        switch command {
        case .newWorkspace: onNewWorkspace?()
        case .importFolder: onImportFolder?()
        case .captureOneImport: onCaptureOneImport?()
        case .toggleSidebar: onToggleSidebar?()
        case .openSettings: onOpenSettings?()
        }
    }
}
