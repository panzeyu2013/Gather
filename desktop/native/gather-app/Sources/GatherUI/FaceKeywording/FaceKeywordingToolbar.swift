// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingToolbar.swift
// Cut 4 / 4c-2b：窗口工具栏（原 1192-1224 行，逐字搬移）。
import SwiftUI
import GatherProtocol

extension FaceKeywordingView {
    // MARK: - 工具栏（窗口 chrome）

    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        // onOpenSettings 为 nil 时不渲染状态胶囊（旧版胶囊仍可悬停/按下但无去处）。
        if onOpenSettings != nil {
            ToolbarItem(placement: .primaryAction) {
                C1StatusCapsuleHost(
                    sessionId: viewModel.sessionId,
                    culling: culling,
                    onOpenSettings: onOpenSettings ?? {}
                )
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.reload() }
            } label: {
                Label(l10n("刷新"), systemImage: "arrow.clockwise")
            }
            .help(l10n("刷新人脸簇"))
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
