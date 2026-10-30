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
            // 刷新=就地重取（保选择/保滚动）。整页重载只在首屏失败时由 VM 内部回退。
            // 同时丢掉内存缩略图：用户按刷新往往就是因为外部（C1）改过图。
            onRefresh: {
                Task {
                    PhotoThumbnailCache.invalidateAll()
                    await viewModel.refresh()
                }
            },
            showsSettings: true,
            settingsTitle: l10n("设置"),
            settingsHelp: l10n("设置")
        )
    }
}
