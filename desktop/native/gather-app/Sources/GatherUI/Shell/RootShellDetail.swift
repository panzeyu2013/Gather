// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellDetail.swift
// 详情区：按 AppRoute 条件构建。会话页只传 (sessionId, page) 给 SessionPageHost，
// 不再逐页构造 9 个导航闭包。
import SwiftUI

extension RootView {
    @ViewBuilder
    var detail: some View {
        Group {
            switch navigation.route {
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
                    onOpenPhoto: { sessionId, photoId in
                        openGallery(sessionId, photoId: photoId)
                    },
                    onCreateWorkspace: { directoryPath in
                        handleCreateWorkspaceRequest(at: directoryPath)
                    },
                    onIngestFolder: { sessionId, sessionSourcePath, folderPath in
                        handleIngestFolderRequest(
                            sessionId: sessionId,
                            sessionSourcePath: sessionSourcePath,
                            folderPath: folderPath)
                    }
                )
            case .persons:
                PersonsView(
                    viewModel: personsViewModel,
                    onReview: { sessionId in navigation.openSessionPage(sessionId, .faceKw) },
                    onReviewFaceRole: { role, sessionId in
                        navigation.openFaceRole(role, in: sessionId)
                    },
                    onOpenPhoto: { sessionId, photoId in
                        openGallery(sessionId, photoId: photoId)
                    },
                    currentSessionId: currentSidebarSessionId
                )
            case .session(let sessionId, let page):
                if let workspace = sessionStore.workspaces[sessionId] {
                    SessionPageHost(
                        sessionId: sessionId,
                        page: page,
                        culling: deps.culling
                    )
                    .environment(\.sessionWorkspace, workspace)
                } else {
                    loadingPlaceholder
                }
            }
        }
        // 页签/目的地切换的交叉淡入：两个页面共用同一个 detail 容器，
        // 加一层 0.18s 的透明度过渡，避免「瞬移」。不改变任何身份/生命周期。
        .animation(reduceMotion ? nil : .easeInOut(duration: GatherMetrics.Motion.standard), value: navigation.route)
    }

    private var loadingPlaceholder: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
