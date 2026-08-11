// desktop/native/gather-app/Sources/GatherApp/Similarity/SimilarityView.swift
// Phase 3.3 Similarity（相似度分析）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析控制 +
//       GroupGrid 分组卡片网格 + stats）
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

struct SimilarityView: View {
    @Bindable var viewModel: SimilarityViewModel
    let onBack: () -> Void

    /// TS: GroupGrid 窗口化常量（GROUP_*）。
    private static let groupMinColWidth = 280.0
    private static let groupCardGap = 16.0
    private static let groupHeaderHeight = 90.0
    private static let truncatedMemberLimit = 24
    private static let memberCellMinWidth = 100.0
    private static let memberCellGap = 8.0
    private static let memberAreaPadding = 16.0
    private static let memberToggleHeight = 54.0

    /// 展开/「显示全部」状态（TS GroupGrid 持有：保持高度估算精确、
    /// 状态在卡片滚出后不丢失）。
    @State private var expandedIds: Set<Int> = []
    @State private var showAllIds: Set<Int> = []
    @State private var confirmWriteback = false
    @State private var confirmCleanup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = viewModel.errorMessage {
                Text("错误: \(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    analysisPanel
                    if viewModel.result != nil {
                        writebackPanel
                    }
                    if viewModel.isAnalyzing {
                        progressSection
                    }
                    if let result = viewModel.result {
                        statsBar(result)
                        groupGrid(result)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
        .confirmationDialog("确认写回相似度关键字？", isPresented: $confirmWriteback, titleVisibility: .visible) {
            Button("确认写回") { Task { await viewModel.executeKeywordWriteback() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("写回前请检查预览；写入后需要重新加载 Capture One，再确认同步。")
        }
        .confirmationDialog("确认清理相似度写回备份？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("清理", role: .destructive) { Task { await viewModel.cleanupKeywordWriteback() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只应在 Capture One 已重新加载并确认同步后执行。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button(action: onBack) {
                Label("返回图库", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Text("相似度分析")
                .font(.system(size: 24, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: 分析控制（TS AnalysisPanel）

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分析控制")
                .font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                Text("分组范围")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                    .padding(.top, 4)
                modeButton(
                    title: "顺序分组",
                    hint: "只合并导入顺序中连续相似的照片，适合连拍挑片",
                    isActive: viewModel.groupingMode == .sequential
                ) {
                    viewModel.groupingMode = .sequential
                }
                modeButton(
                    title: "全局分组",
                    hint: "在整个工作区查找相似照片，允许跨拍摄顺序聚合",
                    isActive: viewModel.groupingMode == .global
                ) {
                    viewModel.groupingMode = .global
                }
            }
            HStack(spacing: 12) {
                Text("匹配强度")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                presetButton("严格", isActive: viewModel.activePreset == "strict") { viewModel.applyPreset("strict") }
                presetButton("均衡", isActive: viewModel.activePreset == "balanced") { viewModel.applyPreset("balanced") }
                presetButton("宽松", isActive: viewModel.activePreset == "loose") { viewModel.applyPreset("loose") }
                Text("建议从“均衡”开始；需要更精细控制时再展开高级参数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("高级参数") {
                VStack(alignment: .leading, spacing: 10) {
                    // TS: threshold slider（min 0 / max 30，Number 步进 1）。
                    HStack(spacing: 12) {
                        Text("相似度阈值：")
                            .font(.callout)
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(viewModel.threshold) },
                            set: { newValue in
                                let rounded = Int(newValue.rounded())
                                if rounded != viewModel.threshold {
                                    viewModel.threshold = rounded
                                    viewModel.thresholdDraftChanged()
                                }
                            }
                        ), in: 0...30, step: 1)
                        Text("\(viewModel.threshold)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 30)
                        Text("0 (严格) — 30 (宽松)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Text("最小组大小: ")
                            .font(.callout)
                            .frame(width: 100, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(viewModel.minGroupSize) },
                            set: { newValue in
                                viewModel.minGroupSize = Int(newValue.rounded())
                            }
                        ), in: 2...10, step: 1)
                        Text("\(viewModel.minGroupSize)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }
                .padding(.top, 6)
            }
            HStack(spacing: 12) {
                Button(viewModel.isAnalyzing ? "分析中..." : "开始分析") {
                    viewModel.startAnalyze()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isAnalyzing)
                if viewModel.result != nil {
                    Button(viewModel.isReclustering ? "聚类中..." : "重新聚类") {
                        Task { await viewModel.recluster() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isReclustering || viewModel.isAnalyzing)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var writebackPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分组关键字写回")
                    .font(.title3.bold())
                Spacer()
                Button("生成预览", systemImage: "eye") {
                    viewModel.previewKeywordWriteback()
                }
                Button("确认写回", systemImage: "square.and.arrow.down") {
                    confirmWriteback = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.writebackPreview?.items.isEmpty != false || viewModel.isWritingBack)
            }
            HStack {
                TextField("关键字，用逗号分隔（作用于已选分组）", text: $viewModel.writebackKeywords)
                    .textFieldStyle(.roundedBorder)
                Text("已选 \(viewModel.selectedGroupIds.count) 组")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let preview = viewModel.writebackPreview {
                Text("预览：影响 \(preview.affectedPhotos) 张照片，共 \(preview.totalCount) 个写回项")
                    .font(.callout)
                ForEach(preview.items.prefix(6), id: \.photoId) { item in
                    Text("\(URL(fileURLWithPath: item.photoPath).lastPathComponent)：\(item.keywords.joined(separator: ", "))")
                        .font(.caption)
                        .lineLimit(1)
                }
            } else {
                Text("选择分组并生成预览后才可以写回。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = viewModel.writebackResult {
                Text("结果：总计 \(result.totalAffected) · 成功 \(result.written) · 失败 \(result.failed) · 跳过 \(result.skipped)")
                HStack {
                    Button("重试失败项") { Task { await viewModel.retryKeywordWriteback() } }
                        .disabled(result.failedItems.isEmpty)
                    Button("Capture One 重新加载并确认") {
                        Task { await viewModel.reloadCaptureOneAndConfirm() }
                    }
                    Button("清理备份", role: .destructive) { confirmCleanup = true }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func modeButton(title: String, hint: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func presetButton(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 进度（TS AnalysisProgress + cancel 按钮）

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.progressTotal > 0 {
                ProgressView(
                    value: Double(viewModel.progressCurrent),
                    total: Double(viewModel.progressTotal)
                )
            } else {
                ProgressView()
            }
            HStack {
                Text(viewModel.progressPhaseLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消分析") {
                    Task { await viewModel.cancelAnalysis() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 统计条（TS stats）

    private func statsBar(_ result: SimilarityResult) -> some View {
        HStack(spacing: 20) {
            statItem("\(result.stats.totalGroups) 个分组")
            statItem("\(result.stats.totalUngrouped) 未分组")
            statItem("阈值 \(Int(result.stats.threshold))")
            statItem(result.stats.groupingMode == .sequential ? "顺序分组" : "全局分组")
            Spacer()
            // 全选分组（对齐 KeywordWritebackPanel 的 selectAll；写回面板已接线）。
            Toggle(isOn: Binding(
                get: {
                    !result.groups.isEmpty && viewModel.selectedGroupIds.count == result.groups.count
                },
                set: { viewModel.setAllGroupsSelected($0) }
            )) {
                Text("全选分组")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func statItem(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
    }

    // MARK: 分组卡片网格（TS GroupGrid：列数公式 + 行高估算 + 展开状态）

    private func groupGrid(_ result: SimilarityResult) -> some View {
        GeometryReader { geometry in
            let cols = max(1, Int((geometry.size.width + Self.groupCardGap) / (Self.groupMinColWidth + Self.groupCardGap)))
            let cardWidth = (geometry.size.width - Double(cols - 1) * Self.groupCardGap) / Double(cols)
            let rows = buildGroupRows(result: result, cols: cols, cardWidth: cardWidth)

            ScrollView {
                LazyVStack(spacing: Self.groupCardGap) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: Self.groupCardGap) {
                            ForEach(row.cards, id: \.group.id) { card in
                                GroupCardView(
                                    group: card.group,
                                    cardWidth: cardWidth,
                                    selected: viewModel.selectedGroupIds.contains(card.group.id),
                                    expanded: expandedIds.contains(card.group.id),
                                    showAllMembers: showAllIds.contains(card.group.id),
                                    onToggleSelected: { viewModel.toggleGroupSelection(card.group.id) },
                                    onToggleExpanded: { toggleExpanded(card.group.id) },
                                    onToggleShowAll: { toggleShowAll(card.group.id) }
                                )
                            }
                        }
                        .frame(height: row.height, alignment: .top)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear {
                // TS GroupGrid：结果替换时重置展开/滚动状态。
                expandedIds = []
                showAllIds = []
            }
        }
        .frame(height: 520)
    }

    private func toggleExpanded(_ groupId: Int) {
        if expandedIds.contains(groupId) {
            expandedIds.remove(groupId)
        } else {
            expandedIds.insert(groupId)
        }
    }

    private func toggleShowAll(_ groupId: Int) {
        if showAllIds.contains(groupId) {
            showAllIds.remove(groupId)
        } else {
            showAllIds.insert(groupId)
        }
    }

    /// TS: estimateGroupCardHeight 移植（窗口化行高估算：折叠恒高，展开按
    /// 成员网格行数累加）。
    func estimateGroupCardHeight(
        group: SimilarityGroup,
        expanded: Bool,
        showAllMembers: Bool,
        cardWidth: Double
    ) -> Double {
        if !expanded { return Self.groupHeaderHeight }
        let memberWidth = max(0, cardWidth - 2 - Self.memberAreaPadding)
        let perRow = max(1, Int((memberWidth + Self.memberCellGap) / (Self.memberCellMinWidth + Self.memberCellGap)))
        let visibleCount = showAllMembers
            ? group.images.count
            : min(Self.truncatedMemberLimit, group.images.count)
        let rows = max(1, Int(ceil(Double(visibleCount) / Double(perRow))))
        let cellHeight = max(0, (memberWidth - Double(perRow - 1) * Self.memberCellGap) / Double(perRow))
        let memberArea = Self.memberAreaPadding + Double(rows) * cellHeight + Double(rows - 1) * Self.memberCellGap
        let toggle = group.images.count > Self.truncatedMemberLimit ? Self.memberToggleHeight : 0
        return Self.groupHeaderHeight + memberArea + toggle
    }

    /// TS: GroupGrid 行模型（top/height/cards）。
    private struct GroupGridRow {
        let height: Double
        let cards: [(group: SimilarityGroup, id: Int)]
    }

    private func buildGroupRows(result: SimilarityResult, cols: Int, cardWidth: Double) -> [GroupGridRow] {
        var rows: [GroupGridRow] = []
        let groups = result.groups
        for start in stride(from: 0, to: groups.count, by: cols) {
            let slice = groups[start..<min(start + cols, groups.count)]
            var rowHeight = 0.0
            var cards: [(group: SimilarityGroup, id: Int)] = []
            for (offset, group) in slice.enumerated() {
                cards.append((group, start + offset))
                rowHeight = max(rowHeight, estimateGroupCardHeight(
                    group: group,
                    expanded: expandedIds.contains(group.id),
                    showAllMembers: showAllIds.contains(group.id),
                    cardWidth: cardWidth
                ))
            }
            rows.append(GroupGridRow(height: rowHeight, cards: cards))
        }
        return rows
    }
}

// MARK: - 分组卡片（TS GroupCard：代表缩略图 + 标签 + 计数 + 展开成员）

private struct GroupCardView: View {
    let group: SimilarityGroup
    let cardWidth: Double
    let selected: Bool
    let expanded: Bool
    let showAllMembers: Bool
    let onToggleSelected: () -> Void
    let onToggleExpanded: () -> Void
    let onToggleShowAll: () -> Void

    private static let truncatedMemberLimit = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in onToggleSelected() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Button(action: onToggleExpanded) {
                    HStack(spacing: 8) {
                        PhotoThumbnailView(
                            path: representative.path,
                            size: 256,
                            placeholderSize: CGSize(width: 56, height: 56)
                        )
                        .frame(width: 56, height: 56)
                        .clipped()
                        .cornerRadius(4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(group.count) 张照片")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(expanded ? "▾" : "▸")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(10)

            if expanded {
                let visibleMembers = showAllMembers ? group.images : Array(group.images.prefix(Self.truncatedMemberLimit))
                let hasMore = group.images.count > Self.truncatedMemberLimit
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(visibleMembers, id: \.path) { image in
                        VStack(spacing: 2) {
                            PhotoThumbnailView(path: image.path, size: 256)
                                .frame(height: 92)
                                .clipped()
                                .cornerRadius(4)
                            Text((image.path as NSString).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                if hasMore {
                    Button(showAllMembers ? "收起" : "显示全部 (共 \(group.images.count) 张)") {
                        onToggleShowAll()
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    /// TS: rep = images.find(representative) ?? images[0]。
    private var representative: SimilarityImage {
        group.images.first { $0.representative == true } ?? group.images[0]
    }
}

/// TS: translatePhase（progress.<phase> 键值中文映射；未知回退通用文案）。
extension SimilarityViewModel {
    var progressPhaseLabel: String {
        let phase = progressMessage
        switch phase {
        case "similarity.hash": return "正在计算感知哈希…"
        case "similarity.hash-done": return "哈希计算完成"
        case "similarity.cluster": return "正在聚类相似照片…"
        case "similarity.cluster-done": return "聚类完成"
        case "similarity.thresholds": return "正在预计算邻居阈值…"
        case "similarity.analyzing": return "正在计算哈希并聚类..."
        case "": return "正在处理…"
        default: return "正在处理…"
        }
    }
}
