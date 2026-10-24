// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityView+Toolbar.swift
// Cut 4 / 4c-2h：C1 胶囊宿主、刷新与 ⌘R 快捷键。
import SwiftUI
import GatherProtocol

extension SimilarityView {
    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        GatherSessionToolbar(
            sessionId: viewModel.sessionId,
            culling: culling,
            onOpenSettings: { openSettings() },
            refreshTitle: l10n("刷新"),
            refreshHelp: l10n("刷新"),
            refreshKeyboardShortcut: true,
            onRefresh: { Task { await viewModel.load() } }
        )
    }
}
