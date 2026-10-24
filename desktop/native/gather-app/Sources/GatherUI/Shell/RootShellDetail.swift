// desktop/native/gather-app/Sources/GatherUI/Shell/RootShellDetail.swift
// 详情区：按 AppRoute 条件构建。会话页只传 (sessionId, page) 给 SessionPageHost，
// 不再逐页构造 9 个导航闭包。
import SwiftUI

extension RootView {
    @ViewBuilder
    var detail: some View {
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

    private var loadingPlaceholder: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
