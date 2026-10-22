// desktop/native/gather-app/Sources/GatherHost/RootShellWorkspace.swift
// Cut 4 / 4c-2k：入口动作 + 意图失效 + 工作区生命周期，从 RootView.swift 原样搬移。
//
// 顺序契约（4c-2k 验收）：
// - .onChange(of: navigation.destination) 内先 pruneWorkspaceIntents，再停离开页的
//   轮询/可见性，再按新目的地启停工作台刷新，最后 switchWorkspace；
// - 会话页 activate(id) 只标记会话区域可见（R4 P1-2：不再对 7 个 VM 扇出 true），
//   页面自身 onAppear 经 workspace.setPageVisible 启动它对应的那一个 VM；
//   非会话页 activate(nil) 只 suspend；同一会话内的页签切换不重复 activate。
import SwiftUI
import GatherProtocol
import GatherUI

// MARK: - 入口动作（意图先进 workspace，再切目的地）

extension RootView {
    /// 打开图库（可选直达某张照片）：意图写进 workspace，由 GalleryView 在
    /// .task 里 take 后消费；普通进入会清掉上一次未消费的照片意图。
    func openGallery(_ sessionId: String, photoId: String? = nil, photoPath: String? = nil) {
        let workspace = sessionStore.workspace(for: sessionId)
        _ = workspace.take(.galleryPhoto)
        if photoId != nil || photoPath != nil {
            workspace.enqueue(.galleryPhoto(id: photoId, path: photoPath))
        }
        navigation.openGallery(sessionId)
    }

    /// 控制中心「N 张照片离线 → 查看」（D10）：进入图库并只看离线照片。
    func openGalleryOffline(sessionId: String) {
        sessionStore.workspace(for: sessionId).enqueue(.galleryFilter(.offline))
        openGallery(sessionId)
    }

    /// 控制中心「分析已过期 → 重新分析」（D10）：进入人脸页并直达分析步骤。
    func openFaceAnalyze(sessionId: String) {
        sessionStore.workspace(for: sessionId).enqueue(.faceAnalyze)
        navigation.openSessionTab(sessionId, .faceKw)
    }

    /// 控制中心「逐条裁决」（D10）：记录「只看 XMP 冲突」意图后切到挑片页。
    func openCullingConflicts(sessionId: String) {
        sessionStore.workspace(for: sessionId).enqueue(.cullingConflicts)
        navigation.openSessionTab(sessionId, .culling)
    }

    /// 控制中心「去导出」：记录入口意图（挑片成果 → 默认保留片）后切到导出页（N05）。
    func openExport(sessionId: String, intent: ExportRangeIntent) {
        sessionStore.workspace(for: sessionId).enqueue(.exportRange(intent))
        navigation.openSessionTab(sessionId, .export)
    }

    // MARK: - 意图失效（A9）

    /// 未消费的入口意图离开目标页即失效：按**新目的地**决定保留哪几种 Kind，
    /// 其余在全部 workspace 上 take 掉（取出即清；旧实现清的是 4 个 pending 容器）。
    func pruneWorkspaceIntents(
        previous: RootNavigation.Destination,
        destination: RootNavigation.Destination
    ) {
        let keepsGallery = Self.isGalleryDestination(destination)
        var keepsCullingConflicts = false
        if case .sessionTab(_, .culling) = destination { keepsCullingConflicts = true }
        var keepsFaceAnalyze = false
        if case .sessionTab(_, .faceKw) = destination { keepsFaceAnalyze = true }
        var keepsExportRange = false
        if case .sessionTab(_, .export) = destination { keepsExportRange = true }
        var faceRoleSessionId: String?
        if case .sessionTab(let id, .faceKw) = destination { faceRoleSessionId = id }

        for (sessionId, workspace) in sessionStore.workspaces {
            if !keepsGallery {
                _ = workspace.take(.galleryFilter)
                _ = workspace.take(.galleryPhoto)
            }
            if !keepsCullingConflicts { _ = workspace.take(.cullingConflicts) }
            if !keepsFaceAnalyze { _ = workspace.take(.faceAnalyze) }
            if !keepsExportRange { _ = workspace.take(.exportRange) }
            // 角色意图只对目标会话的人脸页有效（同一页内保留给 .task take）。
            if faceRoleSessionId != sessionId { _ = workspace.take(.faceRole) }
        }

        // 图库会话切换（gallery s1 → gallery s2）：s1 未消费的照片/筛选意图作废，
        // 避免下次回到 s1 时静默弹出旧照片。
        if case .gallery(let previousSessionId) = previous {
            if !Self.galleryStays(previousSessionId, destination) {
                _ = sessionStore.workspaces[previousSessionId]?.take(.galleryPhoto)
                _ = sessionStore.workspaces[previousSessionId]?.take(.galleryFilter)
            }
        }
    }

    private static func isGalleryDestination(_ destination: RootNavigation.Destination) -> Bool {
        if case .gallery = destination { return true }
        return false
    }

    private static func galleryStays(
        _ sessionId: String,
        _ destination: RootNavigation.Destination
    ) -> Bool {
        if case .gallery(let current) = destination { return current == sessionId }
        return false
    }

    // MARK: - 工作区生命周期（SessionStore / SessionWorkspace）

    /// 目的地 → 会话 id（nil = 工作台/图库库/人物库/设置等非会话页）。
    /// 与 .task(id:)/.onChange 共用，4a-2c 迁 intents/标题时仍可复用。
    static func workspaceSessionId(for destination: RootNavigation.Destination) -> String? {
        switch destination {
        case .gallery(let id), .similarity(let id), .sessionTab(let id, _):
            return id
        default:
            return nil
        }
    }

    /// 按目的地切换活动工作区：会话页 activate(id)（内部 suspend 旧 workspace
    /// 并 workspace.setVisible(true)，R4 P1-2 起只标记会话区域可见、不启动 VM），
    /// 非会话页 activate(nil) 只 suspend 不淘汰。同一会话内的页签切换不重复
    /// activate——由各页面自己的可见性钩子经 workspace.setPageVisible 交接，
    /// 切页签只启停当前页对应的 VM（不会把 7 个 VM 重新置真）。
    func switchWorkspace(for destination: RootNavigation.Destination) {
        guard let sessionId = Self.workspaceSessionId(for: destination) else {
            sessionStore.activate(nil)
            return
        }
        guard sessionStore.activeSessionId != sessionId else { return }
        let workspace = sessionStore.activate(sessionId)
        // 4a-2c：标题走异步缓存（workspace 内查一次 SessionAPI.get）。
        workspace?.loadSessionNameIfNeeded(using: deps.session)
    }

    /// .onChange(of: navigation.destination) 的全部副作用（顺序逐字保留）。
    func handleDestinationChange(
        previous: RootNavigation.Destination,
        destination: RootNavigation.Destination
    ) {
        // A9（审计 4）：未消费的入口意图离开即失效（只有对应目标页才有意义）。
        pruneWorkspaceIntents(previous: previous, destination: destination)
        // B2（9-30 审查）：离开图库/相似度必须**显式**停轮询。页面是条件构建
        // （销毁），而 VM 由 workspace 持有——同会话页签切换不会 activate，
        // 不能只依赖页面的 onDisappear 分支。R4 P1-2 后页面的 onDisappear 也会
        // 经 workspace.setPageVisible 停一次；这里是目的地级的幂等兜底。
        if case .gallery(let previousSessionId) = previous, !Self.isGalleryDestination(destination) {
            sessionStore.workspaces[previousSessionId]?.gallery.setVisible(false)
        }
        if case .similarity(let previousSessionId) = previous {
            sessionStore.workspaces[previousSessionId]?.similarity.setVisible(false)
        }
        // 轮询门控：离开工作台显式停止自动刷新，回到时恢复。
        if case .dashboard = previous {
            viewModel.isVisible = false
            viewModel.stopAutoRefresh()
        }
        if case .dashboard = destination {
            viewModel.isVisible = true
            viewModel.startAutoRefresh()
        }
        // 4a-2c：活动工作区跟随目的地——会话页 activate(id)（只标记会话可见；
        // R4 P1-2：VM 启停由当前挂载页的 onAppear 负责），其它页面 activate(nil)
        // 只 suspend。
        switchWorkspace(for: destination)
    }
}
