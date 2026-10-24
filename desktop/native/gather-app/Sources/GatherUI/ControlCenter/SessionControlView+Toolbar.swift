// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Toolbar.swift
// Cut 4 / 4c-2e：窗口 chrome 工具栏（C1 状态胶囊 / 刷新）。
import SwiftUI
import GatherProtocol

extension SessionControlView {
    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        GatherSessionToolbar(
            sessionId: viewModel.sessionId,
            culling: culling,
            onOpenSettings: { openSettings() },
            refreshTitle: l10n("刷新"),
            refreshHelp: l10n("刷新工作区状态"),
            refreshKeyboardShortcut: true,
            onRefresh: { Task { await viewModel.load() } }
        )
    }
}
