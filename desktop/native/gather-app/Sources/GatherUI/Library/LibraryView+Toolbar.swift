// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Toolbar.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出工具栏（原 138-178 行）。纯搬移：
// 工作区 Picker、清除筛选、刷新与禁用条件逐字未动。
import SwiftUI
import GatherProtocol

extension LibraryView {

    // MARK: 工具栏（工作区筛选 / 清除筛选 / 刷新）

    @ToolbarContentBuilder
    var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // N09 同类（E 报告）：Picker 的标签与「全部」选项同文案会在同一行
            // 出现两次「全部工作区」；改为固定短标签 + 精简的选项文案。
            HStack(spacing: 6) {
                Text(l10n("工作区"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker(l10n("工作区"), selection: $viewModel.sessionFilter) {
                    Text(l10n("全部")).tag("")
                    ForEach(viewModel.sessions, id: \.id) { session in
                        Text("\(session.name)（\(session.photoCount)）").tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(l10n("工作区"))
            }
            .help(l10n("按工作区筛选"))

            Button {
                viewModel.clearFilters()
            } label: {
                Label(l10n("清除筛选"), systemImage: "line.3.horizontal.decrease.circle")
            }
            .help(l10n("清除筛选"))
            .disabled(viewModel.activeFilterCount == 0)

            Button {
                Task { await viewModel.load() }
            } label: {
                Label(l10n("刷新"), systemImage: "arrow.clockwise")
            }
            .help(l10n("刷新"))
            .disabled(viewModel.phase == .loading)
        }
    }
}
