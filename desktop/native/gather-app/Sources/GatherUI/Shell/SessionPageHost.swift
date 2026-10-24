// desktop/native/gather-app/Sources/GatherUI/Shell/SessionPageHost.swift
// 会话页宿主：按 SessionPage 分发 7 个页面，不再持有/构造 VM，也不再接收导航闭包。
//
// 页面的路由/设置/照片入口从 environment 取（RootView 注入 navigator +
// openSettings）；宿主只负责 workspace 与 session/page 身份。
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

// MARK: - 宿主

/// 会话页宿主：**不持有/构造 VM**。
///
/// 7 个 VM 由 `SessionWorkspace` 提供；页面 init 只接 workspace + culling。
/// 页面 identity 由 `(sessionId, page)` 决定，切换会话/页签强制重建页面状态。
package struct SessionPageHost: View {
    package let sessionId: String
    package let page: SessionPage
    package let culling: any CullingAPI

    @Environment(\.sessionWorkspace) private var workspace
    @Environment(\.languageStore) private var languageStore

    package init(sessionId: String, page: SessionPage, culling: any CullingAPI) {
        self.sessionId = sessionId
        self.page = page
        self.culling = culling
    }

    package var body: some View {
        Group {
            if let workspace {
                pageView(workspace)
                    .environment(\.languageStore, languageStore)
                    .id("session-page-\(sessionId)-\(page.rawValue)")
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func pageView(_ workspace: SessionWorkspace) -> some View {
        switch page {
        case .control:
            SessionControlView(workspace: workspace, culling: culling)
        case .faceKw:
            FaceKeywordingView(workspace: workspace, culling: culling)
        case .duplicates:
            DuplicatesView(workspace: workspace, culling: culling)
        case .culling:
            CullingView(workspace: workspace, culling: culling)
        case .export:
            ExportView(workspace: workspace, culling: culling)
        case .gallery:
            GalleryView(workspace: workspace, culling: culling)
        case .similarity:
            SimilarityView(workspace: workspace, culling: culling)
        }
    }
}
