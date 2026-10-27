// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Filters.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出筛选面板（原 180-309 行）与
// LibraryColorOption（原 903-934 行，随唯一使用点移动）。
// 2026-10-24：filterSelect 换成 GatherMenuField（128pt），并把搜索/工作区/
// 清除/刷新全部收进同一个筛选 surface，避免 toolbar 跨到右侧 inspector。
import SwiftUI
import GatherProtocol

extension LibraryView {

    // MARK: 筛选（TS filterPanel：主筛选 + 更多筛选 + 操作）

    /// 主筛选三件套（N09）：字段名与「全部」值分开显示，窄窗口自动换成两行。
    ///
    /// 旧实现用 Picker 的标签承载字段名、又用同文案的菜单项承载「全部」，
    /// 于是同一行出现两次「全部星级」，且选中值被压成「全…」。
    @ViewBuilder
    private var primaryFilterControls: some View {
        filterSelect(
            l10n("星级"),
            allLabel: l10n("全部"),
            selection: $viewModel.filter.rating,
            options: [1, 2, 3, 4, 5].map { (l10n.format("至少 %lld 星", $0), "\($0)") }
        )
        filterSelect(
            l10n("颜色"),
            allLabel: l10n("全部"),
            selection: $viewModel.filter.label,
            options: LibraryColorOption.all.map { (l10n.resolve($0.label), $0.value) }
        )
        filterSelect(
            l10n("在线状态"),
            allLabel: l10n("全部"),
            selection: $viewModel.filter.status,
            options: [(l10n("在线"), "online"), (l10n("离线"), "missing")]
        )
    }

    /// 浏览头：搜索 + 工作区筛选 + 清除/刷新，全部留在中间内容列。
    /// 不能放进窗口 toolbar：右侧 inspector 打开时 toolbar 控件会跨栏。
    private var browseHeaderRow: some View {
        HStack(spacing: 5) {
            GatherSearchField(
                text: $viewModel.filter.search,
                prompt: l10n("搜索文件名"),
                clearLabel: l10n("清除搜索")
            )
            .frame(minWidth: 110, maxWidth: 320)

            Spacer(minLength: 5)

            HStack(spacing: 5) {
                Text(l10n("工作区"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                GatherMenuField(
                    l10n("工作区"),
                    selection: $viewModel.sessionFilter,
                    options: [GatherMenuOption(l10n("全部"), value: "")] +
                        viewModel.sessions.map {
                            GatherMenuOption("\($0.name)（\($0.photoCount)）", value: $0.id)
                        },
                    minWidth: 88,
                    fixedWidth: 112
                )
                .help(l10n("按工作区筛选"))
            }

            Rectangle()
                .fill(GatherTheme.hairline)
                .frame(width: 1, height: 12)
                .padding(.horizontal, 1)
                .accessibilityHidden(true)

            Button {
                viewModel.clearFilters()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n("清除筛选"))
            .accessibilityLabel(l10n("清除筛选"))
            .disabled(viewModel.activeFilterCount == 0)

            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n("刷新"))
            .accessibilityLabel(l10n("刷新"))
            .disabled(viewModel.phase == .loading)
        }
    }

    var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 搜索 / 工作区 / 清除刷新 / 三组筛选共用一个 surface：
            // 它们同属“浏览照片”，并且整块留在中间内容列内。
            VStack(alignment: .leading, spacing: 10) {
                browseHeaderRow

                // 宽窗口一行三列；放不下时整组换成竖排（ViewThatFits 按理想宽度判断），
                // 字段名与当前值在两种排布下都完整可读。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        primaryFilterControls
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        primaryFilterControls
                    }
                }

                // P1 / C：facet 栏。计数随"已提交筛选"变化（与网格一致）。
                // 必须在 ViewThatFits 之外：宽布局分支命中时也要渲染并加载。
                // 智能相册的网格口径是相册 criteria，facet 用 filter criteria；
                // 两者不一致时 facet 是死控件，直接隐藏（切回全部照片再显示）。
                if viewModel.selectedAlbumId == nil, !viewModel.facets.isEmpty {
                    LibraryFacetBar(
                        groups: viewModel.facets,
                        filter: $viewModel.filter,
                        l10n: l10n,
                        onCommit: { viewModel.onFilterChanged() }
                    )
                }
            }
            .task(id: viewModel.criteriaKey) {
                await viewModel.refreshFacets()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                    .fill(GatherTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                    .strokeBorder(GatherTheme.hairline, lineWidth: 1)
            )

            // 手搓「更多筛选」展开按钮 → 系统 DisclosureGroup（chevron / 键盘 / 动画由系统负责）。
            DisclosureGroup(isExpanded: $showAdvancedFilters) {
                advancedFilters
            } label: {
                Text(moreFiltersLabel)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var advancedFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            // P1 / C：规则编辑器（AND/OR、between/in），直接编辑 FilterGroup。
            FilterRuleEditor(
                group: $viewModel.filter.rules,
                l10n: l10n,
                onChange: { viewModel.onFilterChanged() }
            )
            Divider()
            advancedField(l10n("关键词"), text: $viewModel.filter.keyword)
            advancedField(l10n("人物"), text: $viewModel.filter.person)
            advancedField(l10n("目录路径前缀"), text: $viewModel.filter.directory)
            HStack(spacing: 12) {
                filterSelect(
                    l10n("存储卷"),
                    allLabel: l10n("全部"),
                    selection: $viewModel.filter.volume,
                    options: viewModel.assetVolumes.map {
                        ($0.roots.first ?? $0.volumeId, $0.volumeId)
                    }
                )
                filterSelect(
                    l10n("重复状态"),
                    allLabel: l10n("全部"),
                    selection: $viewModel.filter.duplicates,
                    options: [(l10n("有重复候选"), "yes"), (l10n("无重复候选"), "no")]
                )
                filterSelect(
                    l10n("导入时间"),
                    allLabel: l10n("全部"),
                    selection: $viewModel.filter.recentDays,
                    options: [(l10n("最近 24 小时"), "1"), (l10n("最近 7 天"), "7"), (l10n("最近 30 天"), "30")]
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 4)
    }

    /// 表单行：LabeledContent 负责标签列，TextField 用系统字段样式（不再自定宽度/描边）。
    private func advancedField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text)
                .labelsHidden()
                // 自适应宽度（F01）：固定 220 在最小窗口 + 检查器打开时会让
                // 内容区索要比可用宽度更大的最小宽度，触发 AppKit 约束重排。
                .frame(minWidth: 120, maxWidth: 220)
                .onChange(of: text.wrappedValue) { _, _ in viewModel.onFilterChanged() }
        }
    }

    private var moreFiltersLabel: String {
        let count = viewModel.advancedFilterCount
        return count > 0 ? l10n.format("更多筛选（%lld）", count) : l10n("更多筛选")
    }

    /// 一个筛选下拉：左侧字段名（短标签、不随值变化），右侧只显示当前值。
    /// 固定 128pt：三列字段对齐，同时保证最小窗口下仍能一行放下；
    /// 过长的值在字段内省略，完整选项仍在菜单里。
    private func filterSelect(
        _ title: String,
        allLabel: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
            // 字段名由左侧 Text 承载；菜单里只显示当前值（N09 的重复文案不再出现）。
            // 统一用 GatherMenuField，避免每个筛选器都落成一颗系统大灰块。
            GatherMenuField(
                title,
                selection: selection,
                options: [GatherMenuOption(allLabel, value: "")] +
                    options.map { GatherMenuOption($0.0, value: $0.1) },
                // 统一宽度：三个筛选项的字段列对齐，值不再把行撑成一条大灰带。
                fixedWidth: 128
            )
            .help(title)
        }
        .onChange(of: selection.wrappedValue) { _, _ in viewModel.onFilterChanged() }
    }
}

/// TS: COLOR_LABELS（culling.color.* 中文键值）。
private enum LibraryColorOption: CaseIterable {
    case red, orange, yellow, green, blue, pink, purple

    static let all: [LibraryColorOption] = [.red, .orange, .yellow, .green, .blue, .pink, .purple]

    var value: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        case .purple: return "Purple"
        }
    }

    /// Cut 4 / 4b-2d：enum 计算属性读不到 environment，改为只存 key 的
    /// LocalizedText（与 Face Preset 同型），由视图用页面 l10n 在渲染期解析。
    var label: LocalizedText {
        switch self {
        case .red: return LocalizedText("红")
        case .orange: return LocalizedText("橙")
        case .yellow: return LocalizedText("黄")
        case .green: return LocalizedText("绿")
        case .blue: return LocalizedText("蓝")
        case .pink: return LocalizedText("粉")
        case .purple: return LocalizedText("紫")
        }
    }
}
