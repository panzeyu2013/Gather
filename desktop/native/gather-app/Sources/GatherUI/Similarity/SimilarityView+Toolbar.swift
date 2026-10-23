// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityView+Toolbar.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出工具栏（原 214-240 行）。
// 纯搬移：返回位、C1 胶囊宿主、刷新与 ⌘R 快捷键逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

extension SimilarityView {

    // MARK: - 工具栏（C1 胶囊 / 刷新）

    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        // 内容区返回按钮 → 工具栏导航位。
        ToolbarItemGroup(placement: .primaryAction) {
            // C1 状态胶囊（旧版画在页头行里）。
            C1StatusCapsuleHost(
                sessionId: viewModel.sessionId,
                culling: culling,
                onOpenSettings: onOpenSettings
            )
            Button {
                Task { await viewModel.load() }
            } label: {
                Label(l10n("刷新"), systemImage: "arrow.clockwise")
            }
            .help(l10n("刷新"))
            .keyboardShortcut("r", modifiers: .command)
        }
    }

}
