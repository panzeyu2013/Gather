// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryToolbar.swift
// Cut 4 / 4c-2c：页面工具栏（C1 状态胶囊 / 刷新 / 设置）。
// 共享部分收在 GatherSessionToolbar；筛选/显示仍在检查器。
import SwiftUI

extension GalleryView {
    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        GatherSessionToolbar(
            sessionId: viewModel.sessionId,
            culling: culling,
            onOpenSettings: { openSettings() },
            refreshTitle: l10n("刷新"),
            refreshHelp: l10n("刷新"),
            refreshKeyboardShortcut: true,
            onRefresh: { Task { await viewModel.load() } },
            showsSettings: true,
            settingsTitle: l10n("设置"),
            settingsHelp: l10n("设置")
        )
    }
}
