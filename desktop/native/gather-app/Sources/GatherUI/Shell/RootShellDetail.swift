// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellDetail.swift
// Cut 4 / 4c-2k：详情区（按目的地条件构建）与 SessionTab 装配，从 RootView.swift 原样搬移。
//
// 四个 pending 容器 / 入口意图仍由 workspace 承载；SessionTabHost 的 workspace
// 仍从 environment 注入，页签身份 .id("session-tab-…") 与页面 init 参数逐字保留。
import SwiftUI

// MARK: - 详情区（按目的地条件构建）

extension RootView {
    @ViewBuilder
    var detail: some View {
        switch navigation.destination {
        case .dashboard:
            DashboardView(
                viewModel: viewModel,
                newWorkspaceRequest: $newWorkspaceRequest,
                onOpenSession: { navigation.openSession($0) },
                onOpenSettings: { openSettings() }
            )
        case .library:
            LibraryView(
                viewModel: libraryViewModel,
                onOpenSession: { sessionId in navigation.openSession(sessionId) },
                // N07：点击卡片打开那张照片（而不是丢掉目标只打开工作区）。
                onOpenPhoto: { sessionId, photoId in
                    openGallery(sessionId, photoId: photoId)
                }
            )
        case .page(.persons):
            PersonsView(
                viewModel: personsViewModel,
                onReview: { sessionId in navigation.openSessionTab(sessionId, .faceKw) },
                onReviewFaceRole: { role, sessionId in
                    // 4a-2c：深链角色意图进 workspace（页面 .task take 取出即清）。
                    sessionStore.workspace(for: sessionId).enqueue(.faceRole(role))
                    navigation.openSessionTab(sessionId, .faceKw)
                },
                // E：人物关联照片可直接打开（走到那张照片的查看器）。
                onOpenPhoto: { sessionId, photoId in
                    openGallery(sessionId, photoId: photoId)
                },
                // D12：复核按钮优先落在当前工作区（人物可能横跨多个工作区）。
                currentSessionId: currentSidebarSessionId
            )
        case .gallery(let sessionId):
            // 4a-2a-2：gallery 单槽已删除；VM 来自 sessionStore 的会话工作区。
            // 首帧 workspace 可能尚未登记（由 .task/.onAppear 建立），先占位。
            if let workspace = sessionStore.workspaces[sessionId] {
                GalleryView(
                    workspace: workspace,
                    culling: deps.culling,
                    // 图库返回同样回到真实来源（默认工作台）。
                    onBack: { navigation.backFromGallery() },
                    onOpenSimilarity: { navigation.openSimilarity($0) },
                    onOpenTab: { navigation.openSessionTab($0, $1) },
                    onOpenSettings: { openSettings() }
                )
            } else {
                loadingPlaceholder
            }
        case .similarity(let sessionId):
            // 4a-2a-2：similarity 单槽已删除；轮询启停由 SimilarityView 的
            // setVisible/onDisappear 负责（VM 来自 workspace）。
            if let workspace = sessionStore.workspaces[sessionId] {
                SimilarityView(
                    workspace: workspace,
                    culling: deps.culling,
                    // G-3（审计 5）：返回真实来源页（此前写死去图库）。
                    onBack: { navigation.backFromSimilarity(sessionId: sessionId) },
                    onOpenGallery: { openGallery($0) },
                    onOpenTab: { navigation.openSessionTab($0, $1) },
                    onOpenSettings: { openSettings() },
                    // E：成员行「查看照片」→ 该照片的图库查看器（按路径匹配）。
                    onOpenPhoto: { path in
                        openGallery(sessionId, photoPath: path)
                    }
                )
            } else {
                loadingPlaceholder
            }
        case .sessionTab(let sessionId, let tab):
            SessionTabHost(
                tab: tab,
                culling: deps.culling,
                router: SessionTabRouter(
                    // E-P0：返回真实的来源页（工作台 / 全局图库 / 人脸库 / 图库），
                    // 而不是一律回图库。
                    onBack: { navigation.backFromSession(sessionId: sessionId) },
                    onOpenSimilarity: { navigation.openSimilarity($0) },
                    onOpenTab: { navigation.openSessionTab($0, $1) },
                    onOpenGallery: { openGallery($0) },
                    onOpenSettings: { openSettings() },
                    onOpenExportTab: { id, intent in
                        openExport(sessionId: id, intent: intent)
                    },
                    onReviewXmpConflicts: { openCullingConflicts(sessionId: $0) },
                    onReviewOfflinePhotos: { openGalleryOffline(sessionId: $0) },
                    onReviewStaleAnalysis: { openFaceAnalyze(sessionId: $0) }
                ),
                // E：成员行「查看照片」→ 该照片的图库查看器（按 photoId 匹配）。
                onOpenPhoto: { photoId in
                    openGallery(sessionId, photoId: photoId)
                }
            )
            // workspace 从 environment 读取（4a-2a-2：宿主不再构造/缓存 VM）。
            .environment(\.sessionWorkspace, sessionStore.workspaces[sessionId])
            // 会话切换守卫：页面 @State VM 以 init 时的 workspace 初始化，
            // 直接 control(A)→control(B) 跳转也必须强制重建。
            // 4a-3a：这是**会话/页签身份** id，与语言无关（语言重建已删除，
            // 切换语言不会再重置页面选择/草稿）；保留它是 B2 的语义要求。
            .id("session-tab-\(sessionId)-\(tab)")
        }
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
