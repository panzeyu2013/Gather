// desktop/native/gather-app/Sources/GatherHost/RootShellOverlay.swift
// Cut 4 / 4c-2k：外壳的通知入口与 Toast 文案，从 RootView.swift 原样搬移。
//
// 菜单/导入/捕获通知仍由外壳统一接收后转成导航 + 意图（F02：页面按目的地
// 条件构建，页面不在场时投递通知必然丢失）；Toast 仍在**事件发生时**按当前
// 语言解析（唯一语言源是 LanguageStore），不缓存文案。
import SwiftUI
import Foundation
import GatherUI

// MARK: - 通知入口

extension RootView {
    /// ⌘⌥S：交给系统，语义由 NavigationSplitView 的列可见性承载。
    func handleMenuToggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    /// ⌘N：请求先落到外壳再切工作台。DashboardView 是按目的地条件构建的，
    /// 页面不在场时把通知直接投递给它必然丢失（与 F02 同类竞态）。
    func handleMenuNewWorkspace() {
        navigation.selectDashboard()
        newWorkspaceRequest = NewWorkspaceRequest()
    }

    /// 菜单「导入文件夹」：载荷是已选好的目录；object: nil 时退回统一入口。
    func handleMenuImportFolder(_ notification: Notification) {
        navigation.selectDashboard()
        guard let directory = notification.object as? URL else {
            // 兼容旧语义（object: nil = 用户要导入但尚未选目录）：
            // 退回统一入口打开目录选择器，绝不静默无响应。
            NotificationCenter.default.post(name: GatherAppNotification.importFolderRequest, object: nil)
            return
        }
        newWorkspaceRequest = NewWorkspaceRequest(folderPath: directory.path)
    }

    /// ⌘, 与各页面的「打开设置」入口统一打开原生设置窗口。
    func handleMenuOpenSettings() {
        openSettings()
    }

    /// 导入完成：失败计数转 Toast，成功/失败都深链到图库（对齐旧版 App.tsx:34-64）。
    func handleImportCompleted(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionId = userInfo[GatherAppImportUserInfoKey.sessionId] as? String,
              !sessionId.isEmpty else { return }
        let failedCount = (userInfo[GatherAppImportUserInfoKey.failedCount] as? Int) ?? 0
        if failedCount > 0 {
            // 对齐旧版 importFailureMessage（session-paths.ts:26-45）：
            // 「N 张照片已导入；来源读取失败：示例文件、… 等 N 个」。
            //
            // Cut 4 / 4b-3：toast 在**事件发生时**按当前语言解析（唯一语言源
            // 是 store）；不缓存文案，切语言后的下一次导入即新语言。
            let l10n = languageStore.l10n
            let addedCount = (userInfo[GatherAppImportUserInfoKey.addedCount] as? Int) ?? 0
            let sourceLabel = (userInfo[GatherAppImportUserInfoKey.sourceLabel] as? String)
                ?? l10n("文件")
            let examples = (userInfo[GatherAppImportUserInfoKey.examples] as? String) ?? ""
            let remaining = failedCount > 3
                ? l10n.format(" 等 %d 个", failedCount)
                : ""
            GatherToastCenter.shared.show(
                type: .warning,
                message: l10n.format("%lld 张照片已导入；%@读取失败：%@%@", addedCount, sourceLabel, examples, remaining)
            )
        }
        // 深链/导入完成语义对齐旧版 App.tsx:34-64：落点浏览页（图库）。
        openGallery(sessionId)
    }

    /// Capture One 错误：按当前语言解析错误码文案后 Toast。
    func handleCaptureOneError(_ notification: Notification) {
        guard let code = notification.object as? String else { return }
        // Cut 4 / 4b-1：toast 在事件发生时按当前语言解析（唯一语言源是 store）。
        GatherToastCenter.shared.show(type: .error, message: languageStore.l10n.errorText(code))
    }
}
