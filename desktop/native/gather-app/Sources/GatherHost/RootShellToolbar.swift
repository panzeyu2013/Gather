// desktop/native/gather-app/Sources/GatherHost/RootShellToolbar.swift
// Cut 4 / 4c-2k：外壳的工具栏 / 窗口标题 / 尺寸预算 / 文案，从 RootView.swift 原样搬移。
//
// 布局预算常量仍单点定义（D-2 审计 5）；窗口标题继续读 SessionWorkspace 的
// 异步标题缓存（4a-2c），不在导航时同步查库。
import SwiftUI
import Foundation
import GatherUI

// MARK: - 外壳尺寸

/// 主窗口外壳的尺寸约束（D-2 审计 5）：内容区可用最小宽度 = 窗口最小宽度 − 侧栏最小宽度。
/// 布局预算测试此前把 680 写死在测试里，两处常量漂移时测试不会失败——改由这里单点定义。
enum RootShellMetrics {
    static let windowMinWidth: CGFloat = 860
    static let sidebarMinWidth: CGFloat = 180
    /// 内容区（会话页 + 页签行）必须放得下的最小宽度。
    static var contentMinWidthBudget: CGFloat { windowMinWidth - sidebarMinWidth }
}

// MARK: - 外壳文案（4a-3a）

/// 外壳自有的 4 条文案：按**当前语言值**解析，由 `LanguageStore.l10n` 驱动。
///
/// 视图在渲染期读一次 `languageStore.l10n`，语言切换时 Observation 让外壳重
/// 渲染即可——不再是「`.id(languageVersion)` 整树重建」（那会连带丢掉页面里的
/// 选择/草稿状态）。Cut 4 / 4b-3：外壳的 toast/侧栏标题也不再读进程全局，
/// Sources 内已无 `GatherLocalization` 的裸 `l()` 调用点。
struct RootShellCopy {
    let workbench: String
    let currentSession: String
    let globalLibrary: String
    let importFolder: String

    init(_ l10n: L10n) {
        self.workbench = l10n("工作台")
        self.currentSession = l10n("当前会话")
        self.globalLibrary = l10n("全局图库")
        self.importFolder = l10n("导入文件夹")
    }
}

// MARK: - RootView chrome

extension RootView {
    /// 外壳文案：读 languageStore.l10n 建立 Observation 依赖（4a-3a）。
    var copy: RootShellCopy { RootShellCopy(languageStore.l10n) }

    /// 渲染期文案器（侧栏标题等不属于 shell-copy 的零散文案）。
    var l10n: L10n { languageStore.l10n }

    /// 窗口标题读 workspace 的异步标题缓存（4a-2c）：不再每次导航同步查库。
    var windowTitle: String {
        guard let sessionId = navigation.currentSessionId,
              let name = sessionStore.workspaces[sessionId]?.sessionName,
              !name.isEmpty else { return "Gather" }
        return name
    }

    /// 侧栏工具栏（原 RootView.sidebar 的 .toolbar 内容，位置不变）。
    @ToolbarContentBuilder
    var rootSidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                // F02：不再直接 post menuImportFolder——该通知的载荷语义是
                // 「已经选好的目录」，object: nil 会被接收方（要求 URL）静默丢弃，
                // 表现就是按钮点了没反应。统一走 importFolderRequest：
                // AppDelegate 打开目录选择器，落点由面板回调决定
                //（目录里可导入 → 直接建库；没有可导入文件 → menuImportFolder
                // 带目录 URL 回落到新建表单）。
                NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            } label: {
                Label(copy.importFolder, systemImage: "square.and.arrow.down")
            }
            .help(copy.importFolder)
        }
    }
}
