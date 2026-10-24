// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellOverlay.swift
// Cut 4 / 4c-2k：外壳的导入入口与 Toast 文案，从 RootView.swift 原样搬移。
//
// Phase 4 收口：菜单命令不再经 NotificationCenter 投递；这里只保留两条
// **页面 → 外壳**的入口（导入目录选择请求）与事件 Toast。页面按目的地条件
// 构建，页面不在场时投递通知必然丢失（F02），所以导入请求统一由外壳代收。
import SwiftUI
import Foundation

// MARK: - 导入入口

extension RootView {
    /// 「导入文件夹」：宿主面板 → 可导入文件直接导入；空目录回落到新建表单。
    /// 通知路径与 CommandCenter handler 共用这一个实现。
    @MainActor
    func handleImportFolderRequest(deps: RootShellDependencies? = nil) async {
        let dependencies = deps ?? self.deps
        switch await dependencies.chooseImportFolder() {
        case .cancelled:
            return
        case .files(let files):
            dependencies.importFiles(files)
        case .directory(let directory):
            navigation.selectDashboard()
            newWorkspaceRequest = NewWorkspaceRequest(folderPath: directory.path)
        }
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
