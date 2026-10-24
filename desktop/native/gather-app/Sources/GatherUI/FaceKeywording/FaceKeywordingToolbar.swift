// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingToolbar.swift
// Cut 4 / 4c-2b：窗口工具栏（C1 胶囊 / 刷新）。
import SwiftUI
import GatherProtocol

extension FaceKeywordingView {
    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        GatherSessionToolbar(
            sessionId: viewModel.sessionId,
            culling: culling,
            onOpenSettings: { openSettings() },
            refreshTitle: l10n("刷新"),
            refreshHelp: l10n("刷新人脸簇"),
            refreshKeyboardShortcut: true,
            onRefresh: { Task { await viewModel.reload() } }
        )
    }
}
