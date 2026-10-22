// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryToolbar.swift
// Cut 4 / 4c-2c：页面工具栏（返回 / C1 状态胶囊 / 刷新 / 设置），原 GalleryView.swift
// 243-275、325-342 行逐字搬移；工具栏只留模式与瞬时动作，筛选/显示在检查器。
import SwiftUI

extension GalleryView {
    // MARK: - 工具栏（返回 / C1 / 刷新 / 设置：只留模式与瞬时动作）

    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        // 内容区返回按钮 → 工具栏导航位（命中区由系统控件保证 ≥24pt）。
        ToolbarItem(placement: .navigation) {
            Button(action: onBack) {
                Label(l10n("返回"), systemImage: "chevron.backward")
            }
            .help(l10n("返回到上一页"))
        }
        // 按功能分组（HIG Toolbars：「Group toolbar items logically by function
        // and frequency of use… aim for a maximum of three」）。macOS 26 起
        // ToolbarSpacer 会让每组玻璃各自成为独立的胶囊；更早版本它不存在，
        // 于是退化成今天的一整条。
        // 浏览/筛选选项（筛选 / 密度 / 变体）已移入右侧检查器：
        // 工具栏只剩模式与瞬时动作——C1 状态胶囊 + 刷新，以及设置。
        ToolbarItemGroup(placement: .primaryAction) {
            // C1 状态胶囊（旧版画在页头行里）。
            C1StatusCapsuleHost(
                sessionId: viewModel.sessionId,
                culling: culling,
                onOpenSettings: onOpenSettings
            )
            refreshButton
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            settingsButton
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.load() }
        } label: {
            Label(l10n("刷新"), systemImage: "arrow.clockwise")
        }
        .help(l10n("刷新"))
        .keyboardShortcut("r", modifiers: .command)
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings()
        } label: {
            Label(l10n("设置"), systemImage: "gearshape")
        }
        .help(l10n("设置"))
    }
}
