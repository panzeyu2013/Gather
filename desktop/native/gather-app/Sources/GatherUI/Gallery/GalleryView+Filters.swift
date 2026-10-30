// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryView+Filters.swift
// P1 下一波 §3.7.2：Gallery 的筛选面 UI（facet 栏 / 规则入口 / 保存查询菜单）。
//
// 组合方式（与 plan 一致）：4 档 AND 规则 AND 搜索串多字段 OR 组 → 一个 FilterGroup，
// 由 GalleryViewModel.activeCriteria 合成；本文件只负责把用户动作转成 VM 调用，
// 不自己拼条件（避免 UI 与服务端两套语义）。
import SwiftUI
import GatherProtocol

extension GalleryView {

    // MARK: - facet 栏（检查器"筛选"分区）

    /// facet 面板：维度与网格同口径（服务端 counts）。未接线 PhotoAPI 时整块隐藏，
    /// 不留一个永远空的假面板。
    @ViewBuilder
    var facetBarSection: some View {
        if viewModel.photoAPI != nil, !viewModel.facetGroups.isEmpty {
            FacetBar(
                groups: viewModel.facetGroups,
                selected: viewModel.facetSelection,
                l10n: l10n,
                keywordNode: viewModel.keywordFacetNode,
                onSelect: { dimension, value in
                    viewModel.selectFacet(dimension: dimension, value: value)
                }
            )
            if viewModel.activeCriteria != nil {
                Button(l10n("清除全部筛选")) {
                    viewModel.clearFacetSelection()
                    viewModel.search = ""
                    viewModel.filter = .all
                    viewModel.applyRules(FilterGroup(logic: .and, conditions: []))
                    viewModel.appliedSearchName = nil
                }
                .buttonStyle(.borderless)
                .help(l10n("清除 facet、规则、搜索与四档筛选"))
            }
        }
    }

    /// 规则编辑器入口（与 facet 同层："筛选"分区里的一条按钮）。
    var ruleEditorEntry: some View {
        Button {
            showRuleEditor = true
        } label: {
            Label(l10n("高级筛选规则…"), systemImage: "line.3.horizontal.decrease")
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.photoAPI == nil)
        .help(l10n("用 AND/OR 组合字段条件（与 facet、搜索同时生效）"))
    }

    // MARK: - 保存查询菜单（搜索框右侧）

    /// "保存当前筛选…" + 已保存列表（全局/本会话）＋删除子菜单。
    /// 未接线 PhotoAPI 时整个菜单隐藏（不做点了没反应的入口）。
    @ViewBuilder
    var savedSearchMenu: some View {
        if viewModel.photoAPI != nil {
            Menu {
                Button(l10n("保存当前筛选…")) {
                    savedSearchName = viewModel.appliedSearchName ?? ""
                    showSaveSearchPrompt = true
                }
                .disabled(viewModel.activeCriteria == nil)
                if !viewModel.savedSearches.isEmpty {
                    Divider()
                    ForEach(viewModel.savedSearches, id: \.id) { search in
                        Button(savedSearchTitle(search)) {
                            viewModel.applySavedSearch(search)
                        }
                    }
                    Divider()
                    Menu(l10n("删除保存的查询")) {
                        ForEach(viewModel.savedSearches, id: \.id) { search in
                            Button(savedSearchTitle(search)) {
                                Task { await viewModel.deleteSavedSearch(search.id) }
                            }
                        }
                    }
                }
            } label: {
                Label(
                    viewModel.appliedSearchName ?? l10n("保存的查询"),
                    systemImage: "bookmark")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n("保存/恢复当前筛选（facet + 规则 + 搜索 + 四档）"))
        }
    }

    private func savedSearchTitle(_ search: SavedSearchData) -> String {
        search.sessionId == nil
            ? l10n.format("%@（全局）", search.name)
            : search.name
    }

    // MARK: - 保存查询命名 sheet

    var saveSearchPromptSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("保存当前筛选"))
                .font(GatherFont.sectionTitle)
            TextField(l10n("名称"), text: $savedSearchName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitSaveSearch() }
            Text(l10n("同名会覆盖同作用域里已有的查询。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer(minLength: 0)
                Button(l10n("取消")) { showSaveSearchPrompt = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(l10n("保存")) { commitSaveSearch() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(
                        savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 320)
    }

    private func commitSaveSearch() {
        let name = savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showSaveSearchPrompt = false
        Task { await viewModel.saveCurrentSearch(name: name) }
    }
}

/// 规则编辑 sheet：本地草稿 + 显式"应用"（编辑过程中不重取数据）。
struct GalleryRuleEditorSheet: View {
    let l10n: L10n
    let initial: FilterGroup
    let onApply: (FilterGroup) -> Void
    @State private var draft: FilterGroup
    @Environment(\.dismiss) private var dismiss

    init(l10n: L10n, initial: FilterGroup, onApply: @escaping (FilterGroup) -> Void) {
        self.l10n = l10n
        self.initial = initial
        self.onApply = onApply
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("高级筛选规则"))
                .font(GatherFont.sectionTitle)
            ScrollView {
                FilterRuleEditor(group: $draft, l10n: l10n, onChange: {})
                    .padding(.vertical, 4)
            }
            .frame(minHeight: 160, maxHeight: 320)
            HStack {
                Button(l10n("清空")) {
                    draft = FilterGroup(logic: .and, conditions: [])
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
                Button(l10n("取消")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(l10n("应用")) {
                    onApply(draft)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 420)
    }
}
