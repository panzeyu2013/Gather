// desktop/native/gather-app/Sources/GatherUI/Shell/SessionTabHost.swift
// Cut 4 / 4a-2c：会话页宿主从 GatherHost/RootView.swift 迁入 GatherUI（§4.6/D-017）。
//
// 职责：
// - SessionWorkspaceEnvironmentKey：RootView 按目的地注入 workspace，宿主读取；
// - SessionTabRouter：会话页内的导航/回调集合（替代原先 RootView 里的一串局部闭包）；
// - SessionTabHost：按页签把 workspace 里的 VM 分发给 7 个页面。
//
// 4a-2c：宿主不再接收入口意图（4 个 pending 容器已迁 WorkspaceIntent），
// 页面在 .task 里从 workspace.take 后自行消费；宿主也不构造/缓存任何 VM。
import SwiftUI
import GatherProtocol

// MARK: - Environment

/// 当前会话页对应的 workspace（RootView 注入；宿主读取后分发给页面）。
public struct SessionWorkspaceEnvironmentKey: EnvironmentKey {
    public static var defaultValue: SessionWorkspace? { nil }
}

public extension EnvironmentValues {
    var sessionWorkspace: SessionWorkspace? {
        get { self[SessionWorkspaceEnvironmentKey.self] }
        set { self[SessionWorkspaceEnvironmentKey.self] = newValue }
    }
}

// MARK: - 路由

/// 会话页内的导航/回调集合（替代原先 `sessionTabView` 里的一串局部闭包）。
package struct SessionTabRouter {
    package let onBack: () -> Void
    package let onOpenSimilarity: (String) -> Void
    package let onOpenTab: (String, SessionTab) -> Void
    package let onOpenGallery: (String) -> Void
    package let onOpenSettings: () -> Void
    package let onOpenExportTab: (String, ExportRangeIntent) -> Void
    package let onReviewXmpConflicts: (String) -> Void
    package let onReviewOfflinePhotos: (String) -> Void
    package let onReviewStaleAnalysis: (String) -> Void

    package init(
        onBack: @escaping () -> Void,
        onOpenSimilarity: @escaping (String) -> Void,
        onOpenTab: @escaping (String, SessionTab) -> Void,
        onOpenGallery: @escaping (String) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenExportTab: @escaping (String, ExportRangeIntent) -> Void,
        onReviewXmpConflicts: @escaping (String) -> Void,
        onReviewOfflinePhotos: @escaping (String) -> Void,
        onReviewStaleAnalysis: @escaping (String) -> Void
    ) {
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
        self.onOpenExportTab = onOpenExportTab
        self.onReviewXmpConflicts = onReviewXmpConflicts
        self.onReviewOfflinePhotos = onReviewOfflinePhotos
        self.onReviewStaleAnalysis = onReviewStaleAnalysis
    }
}

// MARK: - 宿主

/// 会话页宿主：**不持有/构造 VM**。
///
/// workspace 从 environment 读取（RootView 按目的地注入），7 个 VM 由
/// `SessionWorkspace` 提供；页面 init 只接 `workspace`。workspace 尚未登记时
/// 先显示加载占位，由 RootView 的 `.task(id: navigation.destination)` 建好后重绘。
package struct SessionTabHost: View {
    package let tab: SessionTab
    package let culling: any CullingAPI
    package let router: SessionTabRouter
    package let onOpenPhoto: (String) -> Void

    @Environment(\.sessionWorkspace) private var workspace
    /// 4a-3b-2b：会话页语言源（RootView 注入；这里再显式下发给 5 个页面，
    /// 宿主脱离 RootView 单独使用时仍走同一协议，而不是各页各读进程全局）。
    @Environment(\.languageStore) private var languageStore

    package init(
        tab: SessionTab,
        culling: any CullingAPI,
        router: SessionTabRouter,
        onOpenPhoto: @escaping (String) -> Void
    ) {
        self.tab = tab
        self.culling = culling
        self.router = router
        self.onOpenPhoto = onOpenPhoto
    }

    package var body: some View {
        Group {
        if let workspace {
            switch tab {
            case .control:
                SessionControlView(
                    workspace: workspace,
                    // C1 状态胶囊的 syncStatus 入口（B8.2e）。
                    culling: culling,
                    onBack: router.onBack,
                    onOpenSimilarity: router.onOpenSimilarity,
                    onOpenTab: router.onOpenTab,
                    onOpenGallery: router.onOpenGallery,
                    onOpenSettings: router.onOpenSettings,
                    onOpenExportTab: router.onOpenExportTab,
                    // D10：冲突待办带上「只看冲突」意图（由挑片页 take 后消费）。
                    onReviewXmpConflicts: router.onReviewXmpConflicts,
                    // D10：离线照片 → 图库只看离线；分析过期 → 人脸页直达分析步骤。
                    onReviewOfflinePhotos: router.onReviewOfflinePhotos,
                    onReviewStaleAnalysis: router.onReviewStaleAnalysis
                )
            case .faceKw:
                FaceKeywordingView(
                    workspace: workspace,
                    culling: culling,
                    onBack: router.onBack,
                    onOpenSimilarity: router.onOpenSimilarity,
                    onOpenTab: router.onOpenTab,
                    onOpenGallery: router.onOpenGallery,
                    onOpenSettings: router.onOpenSettings
                )
            case .duplicates:
                DuplicatesView(
                    workspace: workspace,
                    culling: culling,
                    onBack: router.onBack,
                    onOpenSimilarity: router.onOpenSimilarity,
                    onOpenTab: router.onOpenTab,
                    onOpenGallery: router.onOpenGallery,
                    onOpenSettings: router.onOpenSettings,
                    // E：成员行「查看照片」→ 该照片的图库查看器（按 photoId 匹配）。
                    onOpenPhoto: onOpenPhoto
                )
            case .culling:
                CullingView(
                    workspace: workspace,
                    culling: culling,
                    onBack: router.onBack,
                    onOpenSimilarity: router.onOpenSimilarity,
                    onOpenTab: router.onOpenTab,
                    onOpenGallery: router.onOpenGallery,
                    onOpenSettings: router.onOpenSettings
                )
            case .export:
                ExportView(
                    workspace: workspace,
                    culling: culling,
                    onBack: router.onBack,
                    onOpenSimilarity: router.onOpenSimilarity,
                    onOpenTab: router.onOpenTab,
                    onOpenGallery: router.onOpenGallery,
                    onOpenSettings: router.onOpenSettings
                )
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        }
        // 4a-3b-2b：把 RootView 下发的语言源显式传给 5 个会话页。
        .environment(\.languageStore, languageStore)
    }
}
