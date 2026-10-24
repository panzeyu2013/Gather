// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityView+Content.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出页面结构（原 256-330、631-817 行）：
// 滚动容器 / 结果滚动复位 / 加载与错误态 / 进度 / 统计条 / 分组网格 / 空态。
// 纯搬移：onChange(of: viewModel.result) 的滚动复位与展开态重置仍在同一节点、
// 同一顺序；loadingRow / errorState / progressSection / statsBar / groupGrid
// 的层级、文案与禁用条件逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

extension SimilarityView {

    var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 加载/轮询失败时以重试错误态展示（TS index.tsx:994-999 全页
                    // 错误块），横幅留给操作类（分析/写回）错误，避免双提示。
                    if let error = viewModel.errorMessage, !isLoadError {
                        NativeBanner(
                            text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                            color: GatherTheme.error
                        )
                    }
                    analysisPanel
                    if isLoadError {
                        errorState
                    }
                    if viewModel.isLoading {
                        loadingRow
                    }
                    if viewModel.result != nil {
                        writebackPanel
                    }
                    if viewModel.isAnalyzing {
                        progressSection
                    }
                    if let result = viewModel.result {
                        // 滚动复位锚点：新结果采纳（recluster / 阈值档切换）时回到顶部。
                        Color.clear
                            .frame(height: 0)
                            .id(Self.groupsTopAnchor)
                        // B-2（审计 5）：最小组合 / 分组范围改了之后，屏幕上的分组仍是
                        // 旧参数算出来的（「派生结果缺输入指纹」同型第二处）。这里显式标过期。
                        if viewModel.isResultStale {
                            NativeBanner(
                                text: l10n("分组参数已变更，上面的分组来自旧参数；请重新聚类。"),
                                systemImage: "exclamationmark.triangle.fill",
                                color: GatherTheme.warning
                            )
                        }
                        statsBar(result)
                        if result.groups.isEmpty {
                            emptyGroupsState
                        } else {
                            groupGrid(result)
                        }
                    }
                }
                .padding(GatherMetrics.Layout.pageGutter)
                .frame(maxWidth: GatherMetrics.Layout.maxReadingWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                // D 报告：这里原先**无条件**清空展开/全部显示并滚回顶部，而结果本身
                // 由外壳持有的 VM 跨页签保留 → 从图库/其它页签回到本页时，用户刚刚
                // 展开的分组与滚动位置全部丢失。真正的失效条件是「结果被替换」，
                // 已由下面的 onChange(of: viewModel.result) 覆盖，这里不再重置。
                // 仅在结果尚未加载过（首次进入）时把滚动定位到分组顶部。
                if viewModel.result == nil {
                    proxy.scrollTo(Self.groupsTopAnchor, anchor: .top)
                }
            }
            .onChange(of: viewModel.result) { _, _ in
                // TS GroupGrid useEffect([result])：结果替换（recluster 完成 /
                // 阈值档采纳）时重置展开/滚动状态，旧展开不跨结果泄漏。
                resetGroupDisclosure()
                proxy.scrollTo(Self.groupsTopAnchor, anchor: .top)
            }
        }
    }

    private func resetGroupDisclosure() {
        viewModel.expandedGroupIds = []
        viewModel.showAllMemberGroupIds = []
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(l10n("加载结果中…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gatherCard()
    }

    /// 加载/轮询失败错误态（TS index.tsx:994-999）：系统空态视图 + 重试出口
    /// （重跑 load()：重新查询结果并做挂载恢复）。
    private var errorState: some View {
        ContentUnavailableView {
            Label(l10n("加载结果失败"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(l10n.format("错误：%@", loadErrorMessage))
        } actions: {
            Button(l10n("重试")) {
                Task { await viewModel.load() }
            }
            .gatherPrimaryActionButton()
        }
    }

    /// TS: error（useQuery 全页错误）→ phase == .error。
    private var isLoadError: Bool {
        if case .error = viewModel.phase { return true }
        return false
    }

    /// 全页错误文案（渲染期本地化）。
    ///
    /// Cut 4 / 4c-3：页级错误唯一来源是 `phase.error`（4a-3b-2a 起直接携带
    /// `CommandError`，码/参数原样保留）；`isLoadError` 已保证命中该分支，
    /// 不再从 `errorMessage` 复制一份兜底。
    private var loadErrorMessage: String {
        guard case .error(let error) = viewModel.phase else { return "" }
        return CommandErrorText.resolve(error, with: l10n)
    }

    // MARK: 进度（TS AnalysisProgress + cancel 按钮）

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.progressTotal > 0 {
                // TS ProgressBar → 原生线性进度条 + 百分比文本。
                HStack(spacing: 8) {
                    ProgressView(value: progressRatio)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(l10n("分析进度"))
                        .accessibilityValue("\(progressPercent)%")
                    Text("\(progressPercent)%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } else {
                // TS ProgressBar：indeterminate（total == 0）时显示处理中文案
                // （progressBar.inProgress，对齐旧版 处理中…）。
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(l10n("处理中…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(l10n.progressPhaseText(viewModel.progressMessage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 取消分析：busy 时禁用并显示处理中文案。
                Button(viewModel.isCanceling ? l10n("处理中…") : l10n("取消分析")) {
                    Task { await viewModel.cancelAnalysis() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCanceling)
            }
        }
        .gatherCard()
    }

    /// TS ProgressBar：百分比 = current/total × 100，钳制 0–100。
    private var progressPercent: Int {
        guard viewModel.progressTotal > 0 else { return 0 }
        let percent = Double(viewModel.progressCurrent) / Double(viewModel.progressTotal) * 100
        return min(100, max(0, Int(percent.rounded())))
    }

    private var progressRatio: Double {
        guard viewModel.progressTotal > 0 else { return 0 }
        return Double(viewModel.progressCurrent) / Double(viewModel.progressTotal)
    }

    // MARK: 统计条（TS stats）

    private func statsBar(_ result: SimilarityResult) -> some View {
        HStack(spacing: 20) {
            statItem(l10n.format("%lld 个分组", result.stats.totalGroups))
            statItem(l10n.format("%lld 未分组", result.stats.totalUngrouped))
            statItem(l10n.format("阈值 %lld", Int(result.stats.threshold)))
            statItem(result.stats.groupingMode == .sequential ? l10n("顺序分组") : l10n("全局分组"))
            Spacer(minLength: 0)
            // 全选分组（对齐 KeywordWritebackPanel 的 selectAll；写回面板已接线）。
            Toggle(isOn: allGroupsSelected) {
                Text(l10n("全选分组"))
                    .font(GatherFont.secondary)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.vertical, GatherMetrics.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var allGroupsSelected: Binding<Bool> {
        Binding(
            get: {
                guard let result = viewModel.result, !result.groups.isEmpty else { return false }
                return viewModel.selectedGroupIds.count == result.groups.count
            },
            set: { viewModel.setAllGroupsSelected($0) }
        )
    }

    private func statItem(_ text: String) -> some View {
        Text(text)
            .font(GatherFont.body)
            .monospacedDigit()
    }

    // MARK: 分组网格（TS GroupGrid → LazyVGrid + DisclosureGroup）

    /// TS GroupGrid 的列数公式 / 行高估算 / 内嵌 ScrollView 全部删除：
    /// LazyVGrid(.adaptive) 负责列宽，DisclosureGroup 负责展开，卡片高度自然。
    private func groupGrid(_ result: SimilarityResult) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
            ForEach(result.groups, id: \.id) { group in
                SimilarityGroupCardView(
                    group: group,
                    selected: viewModel.selectedGroupIds.contains(group.id),
                    expanded: expandedIds.contains(group.id),
                    showAllMembers: showAllIds.contains(group.id),
                    onToggleSelected: { viewModel.toggleGroupSelection(group.id) },
                    onToggleExpanded: { toggleExpanded(group.id) },
                    onToggleShowAll: { toggleShowAll(group.id) },
                    onOpenPhoto: openPhotoAction
                )
            }
        }
    }

    /// E 报告：此空态与页顶的「开始分析」同屏出现时是两个同文案主按钮。
    /// 页顶那个才是主动作；这里改为解释原因 + 提供「重新聚类」这一补救动作
    ///（放宽阈值后重聚类），不再复制一个主按钮。
    private var emptyGroupsState: some View {
        ContentUnavailableView {
            Label(l10n("当前参数未找到相似分组。"), systemImage: "square.stack.3d.up.slash")
        } description: {
            Text(l10n("可以放宽阈值或改用「宽松」预设后重新聚类。"))
        } actions: {
            Button(viewModel.isReclustering ? l10n("聚类中…") : l10n("重新聚类")) {
                Task { await viewModel.recluster() }
            }
            .disabled(viewModel.isReclustering || viewModel.isAnalyzing)
        }
    }

    private func toggleExpanded(_ groupId: Int) {
        if viewModel.expandedGroupIds.contains(groupId) {
            viewModel.expandedGroupIds.remove(groupId)
        } else {
            viewModel.expandedGroupIds.insert(groupId)
        }
    }

    private func toggleShowAll(_ groupId: Int) {
        if viewModel.showAllMemberGroupIds.contains(groupId) {
            viewModel.showAllMemberGroupIds.remove(groupId)
        } else {
            viewModel.showAllMemberGroupIds.insert(groupId)
        }
    }

}
