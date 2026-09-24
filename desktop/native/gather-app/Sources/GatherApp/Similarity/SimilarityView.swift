// desktop/native/gather-app/Sources/GatherApp/Similarity/SimilarityView.swift
// Phase 3.3 Similarity（相似度分析）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析控制 +
//       KeywordWritebackPanel 写回面板 + GroupGrid 分组卡片网格 + stats）
//       + components/WritebackReport/WritebackReport.tsx（三色统计卡 + 失败项）
//       + utils/c1-sync-controls.ts（三按钮状态机门控 + 禁用提示）
// 中文文案硬编码（项目 i18n 于 3.6 收尾，本阶段对齐 TS 默认语言 zh-CN）。
import SwiftUI
import AppKit
import GatherCore

struct SimilarityView: View {
    @Bindable var viewModel: SimilarityViewModel
    let commands: CommandSurface
    let onBack: () -> Void
    let onOpenGallery: (String) -> Void
    let onOpenTab: (String, SessionTab) -> Void
    let onOpenSettings: () -> Void
    /// 可见性门控（opacity 常驻架构）：隐藏时停止 C1 胶囊 12s 轮询。
    var isActive: Bool = true

    /// TS: GroupGrid 窗口化常量（GROUP_*）。
    private static let groupMinColWidth = 280.0
    private static let groupCardGap = 16.0
    private static let groupHeaderHeight = 90.0
    private static let truncatedMemberLimit = 24
    /// 成员格最小宽：92（旧版 minmax(100px,1fr) → 原生 92px 对齐，与网格实际一致）。
    private static let memberCellMinWidth = 92.0
    private static let memberCellGap = 8.0
    private static let memberAreaPadding = 16.0
    private static let memberToggleHeight = 54.0
    /// 展开成员单元格总高（估算用）：92 缩略图 + caption 文件名 + 间距 + hover 内边距。
    private static let memberCellHeight = 114.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 展开/「显示全部」状态（TS GroupGrid 持有：保持高度估算精确、
    /// 状态在卡片滚出后不丢失）。
    @State private var expandedIds: Set<Int> = []
    @State private var showAllIds: Set<Int> = []
    /// 清理/确认同步的确认弹窗（对齐 Culling/FaceKw 门控）。
    @State private var confirmSyncRequested = false
    @State private var confirmCleanupRequested = false

    var body: some View {
        // 外层 GeometryReader 取窗口高度：分组网格高度自适应（旧版 70vh），
        // 大窗口不再浪费、小窗口保留最小高度。
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                header
                // 加载/轮询失败时以重试错误态展示（TS index.tsx:994-999 全页
                // 错误块），横幅留给操作类（分析/写回）错误，避免双提示。
                if let error = viewModel.errorMessage, !isLoadError {
                    NativeBanner(text: String(format: GatherLocalization.l("操作失败：%@"), error), color: GatherTheme.error)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                            statsBar(result)
                            if result.groups.isEmpty {
                                // TS GroupGrid: groups.length === 0 空态。
                                VStack(spacing: 10) {
                                    Text(GatherLocalization.l("当前参数未找到相似分组。"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 28)
                                    Button(GatherLocalization.l("开始分析")) {
                                        viewModel.startAnalyze()
                                    }
                                    .buttonStyle(.bordered)
                                    .padding(.bottom, 28)
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                groupGrid(result, availableHeight: geometry.size.height)
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gatherBackground)
        }
        // RootView 以 opacity 常驻本视图且视图身份不随 VM 替换改变：
        // .task 只执行一次 → 以 sessionId 为 id，换会话（VM 替换）时重新加载。
        .task(id: viewModel.sessionId) {
            await viewModel.load()
        }
        // 兜底：sessionId 变化（RootView onChange 替换 VM）同样触发加载。
        .onChange(of: viewModel.sessionId) { _, _ in
            Task { await viewModel.load() }
        }
        // 写回协调器 emitSummary 后刷新同步状态视图（TS useEvent('culling:sync-status')）。
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
            guard (notification.object as? String) == viewModel.sessionId else { return }
            Task { await viewModel.refreshSyncState() }
        }
        // 关键词变化 → 清空旧预览/旧写回结果（TS effect [keywordInput, ...]）。
        .onChange(of: viewModel.writebackKeywords) { _, _ in
            viewModel.markWritebackDraftChanged()
        }
        .confirmationDialog(GatherLocalization.l("确认同步 Capture One？"), isPresented: $confirmSyncRequested, titleVisibility: .visible) {
            Button(GatherLocalization.l("确认同步")) { Task { await viewModel.confirmSync() } }
            Button(GatherLocalization.l("取消"), role: .cancel) {}
        } message: {
            Text(GatherLocalization.l("仅在 Capture One 已加载元数据并确认关键词进入目录后确认；确认后才可安全清理临时 XMP 变更。"))
        }
        .confirmationDialog(GatherLocalization.l("确认清理 XMP 临时变更？"), isPresented: $confirmCleanupRequested, titleVisibility: .visible) {
            Button(GatherLocalization.l("清理"), role: .destructive) { Task { await viewModel.cleanupKeywordWriteback() } }
            Button(GatherLocalization.l("取消"), role: .cancel) {}
        } message: {
            Text(GatherLocalization.l("清理会恢复或移除 sidecar 文件中的临时变更；请先确认同步完成。"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onBack) {
                    Label(GatherLocalization.l("返回图库"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.gatherPrimary)
                Text(GatherLocalization.l("相似度分析"))
                    .font(.largeTitle.weight(.bold))
                Spacer()
                C1StatusCapsuleHost(
                    sessionId: viewModel.sessionId,
                    culling: commands.culling,
                    onOpenSettings: onOpenSettings,
                    isActive: isActive
                )
            }
            SessionTabBar(
                selection: .similarity,
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: {},
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: 分析控制（TS AnalysisPanel）

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("分析控制"))
                .font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                Text(GatherLocalization.l("分组范围"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: GatherTheme.formLabelWidth, alignment: .leading)
                    .padding(.top, 4)
                modeButton(
                    title: GatherLocalization.l("顺序分组"),
                    hint: GatherLocalization.l("只合并导入顺序中连续相似的照片，适合连拍挑片"),
                    isActive: viewModel.groupingMode == .sequential
                ) {
                    viewModel.groupingMode = .sequential
                }
                modeButton(
                    title: GatherLocalization.l("全局分组"),
                    hint: GatherLocalization.l("在整个工作区查找相似照片，允许跨拍摄顺序聚合"),
                    isActive: viewModel.groupingMode == .global
                ) {
                    viewModel.groupingMode = .global
                }
            }
            HStack(spacing: 12) {
                Text(GatherLocalization.l("匹配强度"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                presetButton(GatherLocalization.l("严格"), isActive: viewModel.activePreset == "strict") { viewModel.applyPreset("strict") }
                presetButton(GatherLocalization.l("均衡"), isActive: viewModel.activePreset == "balanced") { viewModel.applyPreset("balanced") }
                presetButton(GatherLocalization.l("宽松"), isActive: viewModel.activePreset == "loose") { viewModel.applyPreset("loose") }
                Text(GatherLocalization.l("建议从「均衡」开始；需要更精细控制时再展开高级参数。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(GatherLocalization.l("高级参数")) {
                VStack(alignment: .leading, spacing: 10) {
                    // TS: threshold range 0–30 step 1（对齐 SliderInput.tsx 联动：
                    // 滑块拖动实时更新 + 数字框键入精确值 blur/回车钳制到范围）。
                    // 键入变更同样触发阈值档切换防抖（thresholdDraftChanged）。
                    SliderInputIntView(
                        title: GatherLocalization.l("相似度阈值"),
                        value: Binding(
                            get: { viewModel.threshold },
                            set: { newValue in
                                if newValue != viewModel.threshold {
                                    viewModel.threshold = newValue
                                    viewModel.thresholdDraftChanged()
                                }
                            }
                        ),
                        range: 0...30
                    )
                    Text(GatherLocalization.l("0（严格）— 30（宽松）"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SliderInputIntView(
                        title: GatherLocalization.l("最小组大小"),
                        value: $viewModel.minGroupSize,
                        range: 2...10
                    )
                }
                .padding(.top, 6)
            }
            HStack(spacing: 12) {
                // 开始分析：busy 时禁用并显示处理中文案。
                Button(viewModel.isAnalyzing ? GatherLocalization.l("处理中…") : GatherLocalization.l("开始分析")) {
                    viewModel.startAnalyze()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isAnalyzing)
                if viewModel.result != nil {
                    Button(viewModel.isReclustering ? GatherLocalization.l("聚类中…") : GatherLocalization.l("重新聚类")) {
                        Task { await viewModel.recluster() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isReclustering || viewModel.isAnalyzing)
                }
            }
        }
        .gatherCard()
    }

    // MARK: 写回面板（TS KeywordWritebackPanel + WritebackReport + c1-sync-controls）

    private var writebackPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(GatherLocalization.l("分组关键字写回"))
                    .font(.title3.bold())
                Spacer()
                Text(String(format: GatherLocalization.l("已选 %lld 组"), viewModel.selectedGroupIds.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(GatherLocalization.l("选择相似分组，关键词会合并写入每张照片旁的 .xmp 文件，不修改原图。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                TextField(GatherLocalization.l("输入关键词，多个关键词用逗号分隔"), text: $viewModel.writebackKeywords)
                    .textFieldStyle(.roundedBorder)
                Button(GatherLocalization.l("预览")) {
                    Task { await viewModel.previewKeywordWriteback() }
                }
                .disabled(!viewModel.canPreviewWriteback)
                // 写回：busy 时禁用并显示处理中文案。
                Button(viewModel.isSyncBusy ? GatherLocalization.l("处理中…") : GatherLocalization.l("写入 XMP")) {
                    Task { await viewModel.executeKeywordWriteback() }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canPreviewWriteback)
            }
            Text(GatherLocalization.l("写入后在 Capture One 中选择这些照片，执行「图像 → 加载元数据」；确认关键词已进入目录后，再点击「确认同步」和「清理」。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let message = viewModel.writebackMessage {
                Text(message)
                    .font(.callout)
            }
            if let preview = viewModel.writebackPreview {
                writebackPreviewList(preview)
            } else if viewModel.result != nil {
                Text(GatherLocalization.l("选择分组并生成预览后才可以写回。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let result = viewModel.writebackResult {
                writebackReport(result)
            }
        }
        .gatherCard()
    }

    /// 写回预览明细（TS writebackPreview：before→after 关键词、新建/更新、
    /// 共享数、外部冲突、来源；超过 50 条计数提示）。
    private func writebackPreviewList(_ preview: WritebackPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(GatherLocalization.l("XMP 写回预览"))
                .font(.subheadline.weight(.semibold))
            Text(String(format: GatherLocalization.l("预览完成：%lld 张照片将合并这些关键词。"), preview.affectedPhotos))
                .font(.callout)
            VStack(spacing: 6) {
                ForEach(preview.items.prefix(SimilarityViewModel.previewItemLimit), id: \.xmpPath) { item in
                    writebackPreviewRow(item)
                    Divider().opacity(0.4)
                }
                if preview.items.count > SimilarityViewModel.previewItemLimit {
                    Text(String(format: GatherLocalization.l("另有 %lld 项未展开"), preview.items.count - SimilarityViewModel.previewItemLimit))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func writebackPreviewRow(_ item: WritebackItem) -> some View {
        let preview = item.preview
        let before = preview?.before.keywords ?? []
        let after = preview?.after.keywords ?? item.keywords
        return VStack(alignment: .leading, spacing: 4) {
            Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .help(item.xmpPath)
                .textSelection(.enabled)
            Text("\(writebackKeywordsText(before)) → \(writebackKeywordsText(after))")
                .font(.footnote)
                .lineLimit(1)
                .textSelection(.enabled)
            HStack(spacing: 0) {
                Text(preview?.willCreate == true ? GatherLocalization.l("新建 XMP") : GatherLocalization.l("更新 XMP"))
                if (preview?.sharedPhotoCount ?? 1) > 1 {
                    Text(String(format: GatherLocalization.l(" · %lld 张共享"), preview?.sharedPhotoCount ?? 1))
                }
                if preview?.externalChanged == true {
                    Text(GatherLocalization.l(" · 检测到外部冲突"))
                }
                Text(GatherLocalization.l(" · 来源：相似组"))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func writebackKeywordsText(_ keywords: [String]) -> String {
        keywords.isEmpty ? GatherLocalization.l("无关键词") : keywords.joined(separator: "、")
    }

    /// 写回结果（TS WritebackReport：三色统计卡 + 失败项列表 + 门控操作行）。
    private func writebackReport(_ result: WritebackResult) -> some View {
        let controls = viewModel.syncControls
        return VStack(alignment: .leading, spacing: 10) {
            // 同步状态文案（TS syncStatusCopy）。
            Text(String(format: GatherLocalization.l("同步状态：%@"), controls.statusText))
                .font(.callout)
            WritebackReportCard(
                written: result.written,
                failed: result.failed,
                skipped: result.skipped,
                failedItems: result.failedItems.map { item in
                    WritebackFailureItem(
                        id: item.xmpPath,
                        path: item.photoPath.isEmpty ? item.xmpPath : item.photoPath,
                        message: item.errorMessage
                    )
                }
            )
            HStack(spacing: 12) {
                if !result.failedItems.isEmpty {
                    Button(GatherLocalization.l("重试失败项")) {
                        Task { await viewModel.retryKeywordWriteback() }
                    }
                    .disabled(viewModel.isSyncBusy)
                }
                // 确认同步：仅 c1Read + 已写入 + ack（或 safeToCleanup）可用。
                Button(GatherLocalization.l("确认同步")) {
                    confirmSyncRequested = true
                }
                .disabled(viewModel.isSyncBusy || !controls.canConfirmSync)
                .help(controls.confirmHint ?? "")
                // 清理：仅 safeToCleanup 可用。
                Button(GatherLocalization.l("清理"), role: .destructive) {
                    confirmCleanupRequested = true
                }
                .disabled(viewModel.isSyncBusy || !controls.canCleanup)
                .help(controls.cleanupHint ?? "")
            }
            // 两步流第一步：加载元数据（TS reloadRow + loadHint）。
            HStack(spacing: 12) {
                Button(GatherLocalization.l("在 Capture One 中加载元数据")) {
                    Task { await viewModel.loadMetadataInCaptureOne() }
                }
                .disabled(viewModel.isSyncBusy || !controls.canLoadMetadata)
                .help(controls.loadHint ?? "")
                Text(controls.canLoadMetadata
                    ? GatherLocalization.l("先在 Capture One 中 Load Metadata，再返回 Gather 确认同步")
                    : (controls.loadHint ?? ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(GatherLocalization.l("加载结果中…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 加载/轮询失败错误态（TS index.tsx:994-999）：message + 重试按钮
    /// （重跑 load()：重新查询结果并做挂载恢复）。
    private var errorState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: GatherLocalization.l("错误：%@"), loadErrorMessage))
                .font(.callout)
                .foregroundStyle(GatherTheme.error)
            Button(GatherLocalization.l("重试")) {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).fill(GatherTheme.error.opacity(0.12)))
    }

    /// TS: error（useQuery 全页错误）→ phase == .error。
    private var isLoadError: Bool {
        if case .error = viewModel.phase { return true }
        return false
    }

    private var loadErrorMessage: String {
        if case .error(let message) = viewModel.phase { return message }
        return viewModel.errorMessage ?? ""
    }

    private func modeButton(title: String, hint: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? GatherTheme.primarySoft : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? GatherTheme.primary : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func presetButton(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? GatherTheme.primarySoft : GatherTheme.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? GatherTheme.primary : GatherTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: 进度（TS AnalysisProgress + cancel 按钮）

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.progressTotal > 0 {
                // TS ProgressBar：百分比文本（对齐旧版进度显示，P0）。
                HStack(spacing: 8) {
                    GatherProgressBar(
                        fraction: progressRatio,
                        track: Color.gatherBorder.opacity(0.3),
                        accessibilityText: GatherLocalization.l("分析进度")
                    )
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
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    Text(GatherLocalization.l("处理中…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(GatherLocalization.progressPhaseText(viewModel.progressMessage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                // 取消分析：busy 时禁用并显示处理中文案。
                Button(viewModel.isCanceling ? GatherLocalization.l("处理中…") : GatherLocalization.l("取消分析")) {
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
            statItem(String(format: GatherLocalization.l("%lld 个分组"), result.stats.totalGroups))
            statItem(String(format: GatherLocalization.l("%lld 未分组"), result.stats.totalUngrouped))
            statItem(String(format: GatherLocalization.l("阈值 %lld"), Int(result.stats.threshold)))
            statItem(result.stats.groupingMode == .sequential ? GatherLocalization.l("顺序分组") : GatherLocalization.l("全局分组"))
            Spacer()
            // 全选分组（对齐 KeywordWritebackPanel 的 selectAll；写回面板已接线）。
            Toggle(isOn: Binding(
                get: {
                    !result.groups.isEmpty && viewModel.selectedGroupIds.count == result.groups.count
                },
                set: { viewModel.setAllGroupsSelected($0) }
            )) {
                Text(GatherLocalization.l("全选分组"))
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gatherSurface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gatherBorder.opacity(0.6), lineWidth: 1))
    }

    private func statItem(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .monospacedDigit()
    }

    // MARK: 分组卡片网格（TS GroupGrid：列数公式 + 行高估算 + 展开状态）

    private func groupGrid(_ result: SimilarityResult, availableHeight: Double) -> some View {
        GeometryReader { geometry in
            let cols = max(1, Int((geometry.size.width + Self.groupCardGap) / (Self.groupMinColWidth + Self.groupCardGap)))
            let cardWidth = (geometry.size.width - Double(cols - 1) * Self.groupCardGap) / Double(cols)
            let rows = buildGroupRows(result: result, cols: cols, cardWidth: cardWidth)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.groupCardGap) {
                        // 滚动复位锚点：新结果采纳（recluster / 阈值档切换）时
                        // 回到顶部。
                        Color.clear
                            .frame(width: 0, height: 0)
                            .id("sim-groups-top")
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
                    // 首帧挂载：清空展开/全部显示状态（TS useEffect([result])
                    // 挂载即执行一次）。
                    expandedIds = []
                    showAllIds = []
                    proxy.scrollTo("sim-groups-top", anchor: .top)
                }
                .onChange(of: viewModel.result) { _, _ in
                    // TS GroupGrid useEffect([result])：结果替换（recluster 完成 /
                    // 阈值档采纳）时重置展开/滚动状态，旧展开不跨结果泄漏。
                    expandedIds = []
                    showAllIds = []
                    proxy.scrollTo("sim-groups-top", anchor: .top)
                }
            }
        }
        // 高度自适应：旧版 maxHeight 70vh（大窗口不再浪费，小窗口保留最小 520）。
        .frame(height: max(520, availableHeight * 0.7))
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
        var perRow = 1
        while (memberWidth - Double(perRow - 1) * Self.memberCellGap) / Double(perRow) >= Self.memberCellMinWidth {
            perRow += 1
        }
        perRow = max(1, perRow - 1)
        let visibleCount = showAllMembers
            ? group.images.count
            : min(Self.truncatedMemberLimit, group.images.count)
        let rows = max(1, Int(ceil(Double(visibleCount) / Double(perRow))))
        // 成员格固定 92pt 方形（含文件名 caption 行），行高为常量。
        let cellHeight = Self.memberCellHeight
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
    /// 代表缩略图 64pt（旧版 64px，圆角 6 与 Persons 详情缩略图一致）。
    private static let representativeThumbSize = 64.0

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in onToggleSelected() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(group.label + "，" + String(format: GatherLocalization.l("选择分组 %lld 张"), group.count))
                Button(action: onToggleExpanded) {
                    HStack(spacing: 8) {
                        PhotoThumbnailView(
                            path: representative.path,
                            size: 256,
                            placeholderSize: CGSize(width: Self.representativeThumbSize, height: Self.representativeThumbSize)
                        )
                        .frame(width: Self.representativeThumbSize, height: Self.representativeThumbSize)
                        .clipped()
                        .cornerRadius(6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(String(format: GatherLocalization.l("%lld 张照片"), group.count))
                                .font(.footnote)
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
            // TS groupExpand:hover —— 主题色微变背景。
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? GatherTheme.primarySoft.opacity(0.3) : Color.clear)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)

            if expanded {
                // TS groupMembers border-top 分隔。
                Rectangle()
                    .fill(Color.gatherBorder.opacity(0.6))
                    .frame(height: 1)
                let visibleMembers = showAllMembers ? group.images : Array(group.images.prefix(Self.truncatedMemberLimit))
                let hasMore = group.images.count > Self.truncatedMemberLimit
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(visibleMembers, id: \.path) { image in
                        MemberCellView(path: image.path)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                if hasMore {
                    HStack {
                        Spacer(minLength: 0)
                        Button(showAllMembers ? GatherLocalization.l("收起") : String(format: GatherLocalization.l("显示全部（共 %lld 张）"), group.images.count)) {
                            onToggleShowAll()
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gatherSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    selected ? GatherTheme.primary : (isHovered ? GatherTheme.primary.opacity(0.5) : Color.clear),
                    lineWidth: selected ? 1.5 : 1
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// TS: rep = images.find(representative) ?? images[0]。
    private var representative: SimilarityImage {
        group.images.first { $0.representative == true } ?? group.images[0]
    }
}

// MARK: - 成员单元格（TS memberItem：92px 方形缩略图圆角 6 + 文件名 + hover）

private struct MemberCellView: View {
    let path: String

    private static let thumbSize = 92.0

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            PhotoThumbnailView(
                path: path,
                size: 256,
                placeholderSize: CGSize(width: Self.thumbSize, height: Self.thumbSize)
            )
            .frame(width: Self.thumbSize, height: Self.thumbSize)
            .clipped()
            .cornerRadius(6)
            Text((path as NSString).lastPathComponent)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(2)
        // TS memberItem:hover —— 主题色微变背景。
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? GatherTheme.primarySoft.opacity(0.45) : Color.clear)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            if let url = Self.finderURL(for: path) {
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// 右键「在 Finder 中显示」的 URL：路径为空时返回 nil（跳过该项）。
    private static func finderURL(for path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }
}
