// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Toolbar.swift
// Cut 4 / 4c-2e：窗口 chrome 工具栏（C1 状态胶囊 / 刷新），原 553-582 行。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 工具栏（窗口 chrome：状态胶囊 / 刷新）

    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            C1StatusCapsuleHost(
                sessionId: viewModel.sessionId,
                culling: culling,
                onOpenSettings: onOpenSettings
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.load() }
            } label: {
                Label(l10n("刷新"), systemImage: "arrow.clockwise")
            }
            .help(l10n("刷新工作区状态"))
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
