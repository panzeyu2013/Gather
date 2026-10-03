// desktop/native/gather-app/Sources/GatherApp/Similarity/SimilarityView.swift
// Phase 3.3 Similarity（相似度分析）：SwiftUI 页面（宿主内直连 GatherCore）。
// TS 源: desktop/src/renderer/pages/Similarity/index.tsx（AnalysisPanel 分析控制 +
//       KeywordWritebackPanel 写回面板 + GroupGrid 分组卡片网格 + stats）
//       + components/WritebackReport/WritebackReport.tsx（三色统计卡 + 失败项）
//       + utils/c1-sync-controls.ts（三按钮状态机门控 + 禁用提示）
//
// 原生化（B1/B3/B4/B5）：
// - 页头（返回 + 26pt 大标题 + 手绘页签 + C1 胶囊）→ 窗口 chrome：
//   .navigationTitle + .sessionPageChrome（工具栏分段页签）+ 工具栏 C1/刷新；
// - 手绘「模式卡」「pill 预设」→ 原生 Picker(.segmented)；
// - 手绘卡片背景/描边 → .gatherCard()（语义底色 + 系统分隔线）；
// - 手绘分组网格（列数公式 + 行高估算 + 内嵌 ScrollView）→ LazyVGrid + 原生
//   DisclosureGroup（自然高度，去掉嵌套滚动与手工高度估算）；
// - 空态/错误态 → ContentUnavailableView；分隔线 → Divider()；
// - 排版：内容语义升到 .callout/.headline，去掉 10pt 承载计数/文件名。
import SwiftUI
import AppKit
import GatherCore

// MARK: - 破坏性动作确认上下文（sim.writeback / sim.retry_failed_writeback / sim.cleanup）

/// 写回确认：影响范围 = 组数 / 照片数 / 关键词 / XMP 项与示例路径。
private struct PendingSimilarityWriteback: Identifiable {
    let groupCount: Int
    let affectedPhotos: Int
    let itemCount: Int
    let keywords: [String]
    let samplePath: String?

    var id: String { "writeback-\(itemCount)-\(affectedPhotos)" }

    var scopeText: String {
        var text = String(
            format: GatherLocalization.l("将 %lld 个相似组、%lld 张照片的关键词「%@」合并写入 XMP（共 %lld 个文件，新建或更新），不修改原图。"),
            groupCount, affectedPhotos, keywords.joined(separator: "、"), itemCount
        )
        if let samplePath, !samplePath.isEmpty {
            text += String(format: GatherLocalization.l("例如：%@。"), samplePath)
        }
        text += GatherLocalization.l("取消不会写入任何文件。")
        return text
    }
}

/// 重试失败项确认：范围 = 失败项数量与路径。
private struct PendingSimilarityRetry: Identifiable {
    let paths: [String]

    var id: String { "retry-\(paths.count)-\(paths.first ?? "")" }

    var scopeText: String {
        let sample = paths.prefix(3).joined(separator: GatherLocalization.l("、"))
        let more = paths.count > 3 ? GatherLocalization.l(" 等") : ""
        return String(
            format: GatherLocalization.l("将重试写入 %lld 个失败项：%@%@。取消不会重写任何文件。"),
            paths.count, sample, more
        )
    }
}

/// 清理确认：范围 = 本次已写入的 XMP 项数。
private struct PendingSimilarityCleanup: Identifiable {
    let writtenCount: Int

    var id: String { "cleanup-\(writtenCount)" }

    var scopeText: String {
        String(
            format: GatherLocalization.l("将恢复或移除本次相似度写回生成的 %lld 个临时 XMP sidecar 文件；只应在 Capture One 已加载元数据并确认同步后执行。取消不会改动任何文件。"),
            writtenCount
        )
    }
}

/// 确认同步：用户在弹窗中声明 Capture One 已完成 Load Metadata。
private struct PendingSimilarityConfirmSync: Identifiable {
    var id: String { "confirm-sync" }

    var scopeText: String {
        GatherLocalization.l("确认后 Gather 认为 Capture One 已读取 XMP 临时变更，之后才可执行清理。若尚未在 Capture One 中执行「加载元数据」，请取消。")
    }
}

struct SimilarityView: View {
    @Bindable var viewModel: SimilarityViewModel
    let router: CommandRouter
    let onBack: () -> Void
    let onOpenGallery: (String) -> Void
    let onOpenTab: (String, SessionTab) -> Void
    let onOpenSettings: () -> Void
    /// 打开成员照片（第三轮审计 E）：(filepath) → 外壳跳到该照片的图库查看器。
    var onOpenPhoto: ((String) -> Void)? = nil
    /// 轮询门控：外壳按目的地条件构建页面，本页不再用可见性隐藏自己。
    var isActive: Bool = true

    /// 展开/「显示全部」状态在 **VM** 上（C-1 审计 5）：
    /// 页面按目的地条件构建，离开即销毁；放在 @State 会让「从其它页签回来保留
    /// 展开态」名不副实（VM 的结果留着，展开态却被重置）。
    private var expandedIds: Set<Int> { viewModel.expandedGroupIds }
    private var showAllIds: Set<Int> { viewModel.showAllMemberGroupIds }
    /// 破坏性动作的待确认上下文：非空即弹确认框；命令只在确认分支发出。
    @State private var pendingWriteback: PendingSimilarityWriteback?
    @State private var pendingRetry: PendingSimilarityRetry?
    @State private var pendingCleanup: PendingSimilarityCleanup?
    @State private var pendingConfirmSync: PendingSimilarityConfirmSync?

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GatherTheme.windowBackground)
            // F09：窗口标题是工作区身份，不能被功能名顶掉（原先这里写死
            // 「相似度分析」，导致整个页面看不到自己在哪个工作区）。
            // 功能名由 sessionPageChrome 的副标题 + 页签行共同承载。
            .sessionPageChrome(
                subtitle: GatherLocalization.l("相似度分析"),
                selection: .similarity,
                onBrowse: { onOpenGallery(viewModel.sessionId) },
                onSimilarity: {},
                onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
            )
            .toolbar { toolbarItems }
            // 外壳以条件构建承载本页，视图身份不随 VM 替换改变：
            // .task 以 sessionId 为 id，换会话（VM 替换）时重新加载。
            .task(id: viewModel.sessionId) {
                await viewModel.load()
            }
            // 兜底：sessionId 变化（外壳 onChange 替换 VM）同样触发加载。
            .onChange(of: viewModel.sessionId) { _, _ in
                Task { await viewModel.load() }
            }
            // 写回协调器 emitSummary 后刷新同步状态视图（TS useEvent('culling:sync-status')）。
            .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.c1SyncStatus)) { notification in
                guard (notification.object as? String) == viewModel.sessionId else { return }
                viewModel.refreshSyncState()
            }
            // 关键词变化 → 清空旧预览/旧写回结果（TS effect [keywordInput, ...]）。
            .onChange(of: viewModel.writebackKeywords) { _, _ in
                viewModel.markWritebackDraftChanged()
            }
            // 破坏性命令统一门控：确认后才带 confirmed: true，取消只写可见文案。
            .gatherDestructiveConfirm(
                pending: $pendingWriteback,
                title: GatherLocalization.l("确认写入 XMP？"),
                confirmLabel: { _ in GatherLocalization.l("写入 XMP") },
                message: { $0.scopeText },
                onConfirm: { _ in Task { await viewModel.executeKeywordWriteback(confirmed: true) } },
                onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("写入 XMP")) }
            )
            .gatherDestructiveConfirm(
                pending: $pendingRetry,
                title: GatherLocalization.l("确认重试失败项？"),
                confirmLabel: { _ in GatherLocalization.l("重试写入") },
                message: { $0.scopeText },
                onConfirm: { _ in Task { await viewModel.retryKeywordWriteback(confirmed: true) } },
                onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("重试失败写入项")) }
            )
            .gatherDestructiveConfirm(
                pending: $pendingCleanup,
                title: GatherLocalization.l("确认清理 XMP 临时变更？"),
                confirmLabel: { _ in GatherLocalization.l("清理") },
                message: { $0.scopeText },
                onConfirm: { _ in Task { await viewModel.cleanupKeywordWriteback(confirmed: true) } },
                onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("清理 XMP 临时变更")) }
            )
            .gatherDestructiveConfirm(
                pending: $pendingConfirmSync,
                title: GatherLocalization.l("确认同步 Capture One？"),
                confirmLabel: { _ in GatherLocalization.l("确认同步") },
                message: { $0.scopeText },
                onConfirm: { _ in Task { await viewModel.confirmSync() } },
                onCancel: { _ in viewModel.reportCancellation(GatherLocalization.l("确认同步 Capture One")) }
            )
    }

    // MARK: - 工具栏（返回 / C1 胶囊 / 刷新）

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // 内容区返回按钮 → 工具栏导航位。
        ToolbarItem(placement: .navigation) {
            Button(action: onBack) {
                Label(GatherLocalization.l("返回"), systemImage: "chevron.backward")
            }
            .help(GatherLocalization.l("返回到上一页"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // C1 状态胶囊（旧版画在页头行里）。
            C1StatusCapsuleHost(
                sessionId: viewModel.sessionId,
                router: router,
                onOpenSettings: onOpenSettings,
                isActive: isActive
            )
            Button {
                Task { await viewModel.load() }
            } label: {
                Label(GatherLocalization.l("刷新"), systemImage: "arrow.clockwise")
            }
            .help(GatherLocalization.l("刷新"))
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: - 页面结构

    /// 先准备预览（无预览自动生成），再弹出带真实影响范围的确认框。
    private func requestWritebackConfirmation() async {
        guard let preview = await viewModel.prepareWritebackConfirmation(), !preview.items.isEmpty else { return }
        pendingWriteback = PendingSimilarityWriteback(
            groupCount: viewModel.selectedGroupIds.count,
            affectedPhotos: preview.affectedPhotos,
            itemCount: preview.items.count,
            keywords: viewModel.parsedWritebackKeywords,
            samplePath: preview.items.first?.xmpPath
        )
    }

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 加载/轮询失败时以重试错误态展示（TS index.tsx:994-999 全页
                    // 错误块），横幅留给操作类（分析/写回）错误，避免双提示。
                    if let error = viewModel.errorMessage, !isLoadError {
                        NativeBanner(
                            text: String(format: GatherLocalization.l("操作失败：%@"), error),
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
                                text: GatherLocalization.l("分组参数已变更，上面的分组来自旧参数；请重新聚类。"),
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
                .padding(20)
                .frame(maxWidth: 1200, alignment: .leading)
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

    private static let groupsTopAnchor = "sim-groups-top"

    private func resetGroupDisclosure() {
        viewModel.expandedGroupIds = []
        viewModel.showAllMemberGroupIds = []
    }

    // MARK: 分析控制（TS AnalysisPanel）

    private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GatherLocalization.l("分析控制"))
                .font(.headline)
            // 旧版两张手绘「模式卡」（primarySoft 底 + 主色描边 + 说明行）
            // → 原生分段控件 + 次要说明行。
            LabeledContent(GatherLocalization.l("分组范围")) {
                groupingModePicker
            }
            Text(groupingModeHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent(GatherLocalization.l("匹配强度")) {
                presetPicker
            }
            Text(GatherLocalization.l("建议从「均衡」开始；需要更精细控制时再展开高级参数。"))
                .font(.callout)
                .foregroundStyle(.secondary)
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
                        .font(.callout)
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
                .gatherPrimaryActionButton()
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

    private var groupingModePicker: some View {
        Picker("", selection: $viewModel.groupingMode) {
            Text(GatherLocalization.l("顺序分组"))
                .tag(SimilarityGroupingMode.sequential)
            Text(GatherLocalization.l("全局分组"))
                .tag(SimilarityGroupingMode.global)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .accessibilityLabel(GatherLocalization.l("分组范围"))
    }

    private var groupingModeHint: String {
        viewModel.groupingMode == .sequential
            ? GatherLocalization.l("只合并导入顺序中连续相似的照片，适合连拍挑片")
            : GatherLocalization.l("在整个工作区查找相似照片，允许跨拍摄顺序聚合")
    }

    /// 匹配强度：旧版手绘 pill 行 → 原生分段控件。
    /// 未命中任何预设（阈值被手动调整）时无选中段，如实反映「自定义」。
    private var presetPicker: some View {
        Picker("", selection: presetSelection) {
            Text(GatherLocalization.l("严格")).tag("strict")
            Text(GatherLocalization.l("均衡")).tag("balanced")
            Text(GatherLocalization.l("宽松")).tag("loose")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .accessibilityLabel(GatherLocalization.l("匹配强度"))
        .accessibilityValue(viewModel.activePreset.map(presetTitle) ?? GatherLocalization.l("自定义"))
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { viewModel.activePreset ?? "" },
            set: { name in
                guard !name.isEmpty else { return }
                viewModel.applyPreset(name)
            }
        )
    }

    private func presetTitle(_ name: String) -> String {
        switch name {
        case "strict": return GatherLocalization.l("严格")
        case "balanced": return GatherLocalization.l("均衡")
        case "loose": return GatherLocalization.l("宽松")
        default: return GatherLocalization.l("自定义")
        }
    }

    // MARK: 写回面板（TS KeywordWritebackPanel + WritebackReport + c1-sync-controls）

    private var writebackPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(GatherLocalization.l("分组关键字写回"))
                    .font(.headline)
                Spacer(minLength: 0)
                // 计数属于内容语义 → .callout（旧版 10pt footnote）。
                Text(String(format: GatherLocalization.l("已选 %lld 组"), viewModel.selectedGroupIds.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(GatherLocalization.l("选择相似分组，关键词会合并写入每张照片旁的 .xmp 文件，不修改原图。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent(GatherLocalization.l("关键词")) {
                TextField(
                    GatherLocalization.l("输入关键词，多个关键词用逗号分隔"),
                    text: $viewModel.writebackKeywords
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 400)
                .accessibilityLabel(GatherLocalization.l("关键词"))
                .onSubmit {
                    Task { await viewModel.previewKeywordWriteback() }
                }
            }
            HStack(spacing: 12) {
                Button(GatherLocalization.l("预览")) {
                    Task { await viewModel.previewKeywordWriteback() }
                }
                .disabled(!viewModel.canPreviewWriteback)
                // 写回：busy 时禁用并显示处理中文案。
                Button(viewModel.isSyncBusy ? GatherLocalization.l("处理中…") : GatherLocalization.l("写入 XMP")) {
                    Task { await requestWritebackConfirmation() }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canPreviewWriteback)
            }
            Text(GatherLocalization.l("写入后在 Capture One 中选择这些照片，执行「图像 → 加载元数据」；确认关键词已进入目录后，再点击「确认同步」和「清理」。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message = viewModel.writebackMessage {
                Text(message)
                    .font(.callout)
            }
            if let preview = viewModel.writebackPreview {
                writebackPreviewList(preview)
            } else if viewModel.result != nil {
                Text(GatherLocalization.l("选择分组并生成预览后才可以写回。"))
                    .font(.callout)
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
            VStack(spacing: 0) {
                ForEach(preview.items.prefix(SimilarityViewModel.previewItemLimit), id: \.xmpPath) { item in
                    writebackPreviewRow(item)
                    Divider()
                }
                if preview.items.count > SimilarityViewModel.previewItemLimit {
                    Text(String(format: GatherLocalization.l("另有 %lld 项未展开"), preview.items.count - SimilarityViewModel.previewItemLimit))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func writebackPreviewRow(_ item: WritebackItem) -> some View {
        let preview = item.preview
        let before = preview?.before.keywords ?? []
        let after = preview?.after.keywords ?? item.keywords
        return VStack(alignment: .leading, spacing: 4) {
            // 文件名是内容语义 → .callout（旧版 10pt footnote）。
            Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .help(item.xmpPath)
                .textSelection(.enabled)
            Text("\(writebackKeywordsText(before)) → \(writebackKeywordsText(after))")
                .font(.callout)
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
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
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
                        pendingRetry = PendingSimilarityRetry(
                            paths: result.failedItems.map { $0.xmpPath.isEmpty ? $0.photoPath : $0.xmpPath }
                        )
                    }
                    .disabled(viewModel.isSyncBusy)
                }
                // 确认同步：仅 c1Read + 已写入 + ack（或 safeToCleanup）可用。
                Button(GatherLocalization.l("确认同步")) {
                    pendingConfirmSync = PendingSimilarityConfirmSync()
                }
                .disabled(viewModel.isSyncBusy || !controls.canConfirmSync)
                .help(controls.confirmHint ?? "")
                // 清理：仅 safeToCleanup 可用。
                Button(GatherLocalization.l("清理"), role: .destructive) {
                    pendingCleanup = PendingSimilarityCleanup(writtenCount: viewModel.syncView?.written ?? 0)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(GatherLocalization.l("加载结果中…"))
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
            Label(GatherLocalization.l("加载结果失败"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(String(format: GatherLocalization.l("错误：%@"), loadErrorMessage))
        } actions: {
            Button(GatherLocalization.l("重试")) {
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

    private var loadErrorMessage: String {
        if case .error(let message) = viewModel.phase { return message }
        return viewModel.errorMessage ?? ""
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
                        .accessibilityLabel(GatherLocalization.l("分析进度"))
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
                    Text(GatherLocalization.l("处理中…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(GatherLocalization.progressPhaseText(viewModel.progressMessage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
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
            Spacer(minLength: 0)
            // 全选分组（对齐 KeywordWritebackPanel 的 selectAll；写回面板已接线）。
            Toggle(isOn: allGroupsSelected) {
                Text(GatherLocalization.l("全选分组"))
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
        }
        .gatherCard()
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
            .font(.callout)
            .monospacedDigit()
    }

    // MARK: 分组网格（TS GroupGrid → LazyVGrid + DisclosureGroup）

    /// TS GroupGrid 的列数公式 / 行高估算 / 内嵌 ScrollView 全部删除：
    /// LazyVGrid(.adaptive) 负责列宽，DisclosureGroup 负责展开，卡片高度自然。
    private func groupGrid(_ result: SimilarityResult) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
            ForEach(result.groups, id: \.id) { group in
                GroupCardView(
                    group: group,
                    selected: viewModel.selectedGroupIds.contains(group.id),
                    expanded: expandedIds.contains(group.id),
                    showAllMembers: showAllIds.contains(group.id),
                    onToggleSelected: { viewModel.toggleGroupSelection(group.id) },
                    onToggleExpanded: { toggleExpanded(group.id) },
                    onToggleShowAll: { toggleShowAll(group.id) },
                    onOpenPhoto: onOpenPhoto
                )
            }
        }
    }

    /// E 报告：此空态与页顶的「开始分析」同屏出现时是两个同文案主按钮。
    /// 页顶那个才是主动作；这里改为解释原因 + 提供「重新聚类」这一补救动作
    ///（放宽阈值后重聚类），不再复制一个主按钮。
    private var emptyGroupsState: some View {
        ContentUnavailableView {
            Label(GatherLocalization.l("当前参数未找到相似分组。"), systemImage: "square.stack.3d.up.slash")
        } description: {
            Text(GatherLocalization.l("可以放宽阈值或改用「宽松」预设后重新聚类。"))
        } actions: {
            Button(viewModel.isReclustering ? GatherLocalization.l("聚类中…") : GatherLocalization.l("重新聚类")) {
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

// MARK: - 分组卡片（TS GroupCard：代表缩略图 + 标签 + 计数 + 展开成员）

/// 原生容器（.gatherCard()）+ 原生 DisclosureGroup；选中态用品牌 accent 描边
/// （强调色语义），不再自绘卡片底色与灰色边框。
private struct GroupCardView: View {
    let group: SimilarityGroup
    let selected: Bool
    let expanded: Bool
    let showAllMembers: Bool
    let onToggleSelected: () -> Void
    let onToggleExpanded: () -> Void
    let onToggleShowAll: () -> Void
    /// 打开成员照片（透传给 MemberCellView）。
    var onOpenPhoto: ((String) -> Void)? = nil

    private static let truncatedMemberLimit = 24
    /// 代表缩略图 64pt。
    private static let representativeThumbSize = 64.0

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: expansionBinding) {
                memberArea
                    .padding(.top, 8)
            } label: {
                cardLabel
            }
            // 选择行单独一行：勾选框不落在 DisclosureGroup 的标签点击区里，
            // 展开/选择互不误触。
            Toggle(isOn: selectionBinding) {
                Text(String(format: GatherLocalization.l("选择分组 %lld 张"), group.count))
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .help(GatherLocalization.l("选择分组"))
        }
        .gatherCard()
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.group, style: .continuous)
                .strokeBorder(ringColor, lineWidth: selected ? 2 : 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var cardLabel: some View {
        HStack(spacing: 10) {
            PhotoThumbnailView(
                path: representative.path,
                size: 256,
                placeholderSize: CGSize(width: Self.representativeThumbSize, height: Self.representativeThumbSize)
            )
            .frame(width: Self.representativeThumbSize, height: Self.representativeThumbSize)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(String(format: GatherLocalization.l("%lld 张照片"), group.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var memberArea: some View {
        // 原生分隔线（旧版是 1pt Rectangle 手绘边框）。
        Divider()
        let visibleMembers = showAllMembers ? group.images : Array(group.images.prefix(Self.truncatedMemberLimit))
        let hasMore = group.images.count > Self.truncatedMemberLimit
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            ForEach(visibleMembers, id: \.path) { image in
                MemberCellView(path: image.path, onOpenPhoto: onOpenPhoto)
            }
        }
        if hasMore {
            HStack {
                Spacer(minLength: 0)
                Button(showAllMembers ? GatherLocalization.l("收起") : String(format: GatherLocalization.l("显示全部（共 %lld 张）"), group.images.count)) {
                    onToggleShowAll()
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded },
            set: { _ in onToggleExpanded() }
        )
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { selected },
            set: { _ in onToggleSelected() }
        )
    }

    private var ringColor: Color {
        if selected { return GatherTheme.accent }
        // 悬停反馈用中性色，不占用品牌色做表面。
        return isHovered ? GatherTheme.separator : Color.clear
    }

    /// TS: rep = images.find(representative) ?? images[0]。
    private var representative: SimilarityImage {
        group.images.first { $0.representative == true } ?? group.images[0]
    }
}

// MARK: - 成员单元格（TS memberItem：92pt 方形缩略图 + 文件名 + hover）

private struct MemberCellView: View {
    let path: String
    /// 打开这张照片（第三轮审计 E）：成员原先只有「在 Finder 中显示」，
    /// 看得见却打不开——用户要自己回图库再找一遍。
    var onOpenPhoto: ((String) -> Void)? = nil

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
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 文件名是内容语义 → .callout（旧版 10pt footnote）。
            Text((path as NSString).lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            // 单击即打开（与「关联照片」网格、全局图库卡片一致）。
            onOpenPhoto?(path)
        }
        .contextMenu {
            if onOpenPhoto != nil {
                Button(GatherLocalization.l("查看照片")) { onOpenPhoto?(path) }
                Divider()
            }
            if let url = finderURLForPath(path) {
                Button(GatherLocalization.l("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .help((path as NSString).lastPathComponent)
        .accessibilityElement(children: .combine)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
