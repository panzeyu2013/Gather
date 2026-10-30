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
            onRefresh: {
                Task {
                    // 与图库/挑片同一口径：主动刷新 = 允许重取被外部修改过的缩略图。
                    PhotoThumbnailCache.invalidateAll()
                    await viewModel.load()
                }
            }
        )
    }
}
