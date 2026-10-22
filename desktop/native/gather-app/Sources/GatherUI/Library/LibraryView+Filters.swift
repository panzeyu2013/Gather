// desktop/native/gather-app/Sources/GatherUI/Library/LibraryView+Filters.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出筛选面板（原 180-309 行）与
// LibraryColorOption（原 903-934 行，随唯一使用点移动）。纯搬移：主筛选三件套、
// 更多筛选、LabeledContent 行、filterSelect 与 onFilterChanged 接线逐字未动。
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

    var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
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
    /// 自适应宽度（F01）：固定 150 × 3 个下拉在最小窗口宽度下会超出可用宽度，
    /// 非滚动容器里的超宽固定子视图会把布局推入约束更新循环。
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
            Picker(title, selection: selection) {
                Text(allLabel).tag("")
                ForEach(options, id: \.1) { label, value in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.menu)
            // 字段名由左侧 Text 承载，Picker 不再重复渲染标签（N09 的重复文案）。
            .labelsHidden()
            .frame(minWidth: 88, maxWidth: 150)
            .accessibilityLabel(title)
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
