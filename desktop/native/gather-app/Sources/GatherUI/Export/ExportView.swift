// desktop/native/gather-app/Sources/GatherUI/Export/ExportView.swift
// Cut 4 / 4c-2f：导出页壳（原 671-1190 行）。只保留 5 个状态、装配 init、Form
// 五段顺序与接线顺序（逐字未动）；@FocusState 以 Binding 下传；五段见 +*.swift。
import SwiftUI
import GatherProtocol

public struct ExportView: View {
    /// 由外壳注入（N04：跨页签保留导出草稿），或本页自建（独立预览/测试）。
    /// 计划重算去抖任务（D-9）。
    @State private var planDebounceTask: Task<Void, Never>?

    @State private var viewModel: ExportViewModel
    /// 所属会话工作区（Cut 4 / 4a-2c）：入口意图 .exportRange 在 .task 里 take。
    private let workspace: SessionWorkspace
    /// 非空即弹确认；confirmed 载荷只在确认分支写出（UI 不得自证确认）。
    @State private var pendingExport: ExportConfirmation?
    @FocusState private var maxDimensionFocused: Bool
    @FocusState private var watermarkFontSizeFocused: Bool
    /// B8.2e：仅 C1 状态胶囊宿主需要；导出/会话域本身已全部走类型化 API。
    private let culling: any CullingAPI
    private let onBack: () -> Void
    private let onOpenSimilarity: (String) -> Void
    private let onOpenTab: (String, SessionTab) -> Void
    private let onOpenGallery: (String) -> Void
    private let onOpenSettings: () -> Void

    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（workspace.export）。
    /// 同一工作区的导出草稿（目录/格式/命名/范围/预览）在切换页签后原样恢复，
    /// 外壳不再缓存/替换 ViewModel。
    ///
    /// Cut 4 / 4a-2c：删除 rangeIntent / 兼容 init / 独立 init；入口意图由页面
    /// 在 .task 里从 workspace.take(.exportRange) 消费。
    package init(
        workspace: SessionWorkspace,
        culling: any CullingAPI,
        onBack: @escaping () -> Void = {},
        onOpenSimilarity: @escaping (String) -> Void = { _ in },
        onOpenTab: @escaping (String, SessionTab) -> Void = { _, _ in },
        onOpenGallery: @escaping (String) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.workspace = workspace
        _viewModel = State(initialValue: workspace.export)
        self.culling = culling
        self.onBack = onBack
        self.onOpenSimilarity = onOpenSimilarity
        self.onOpenTab = onOpenTab
        self.onOpenGallery = onOpenGallery
        self.onOpenSettings = onOpenSettings
    }

    // Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView / SessionTabHost）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 行内字段错误已就近定位（fieldError），横幅仅展示行内不可见的一般错误，
            // 避免同源重复提示。
            if let error = viewModel.errorMessage, viewModel.fieldError == nil {
                NativeBanner(
                    text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                    color: GatherTheme.error
                )
                    .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                    .padding(.top, 12)
            }
            if let notice = viewModel.notice {
                NativeBanner(text: l10n.resolve(notice), color: GatherTheme.success)
                    .padding(.horizontal, GatherMetrics.Layout.pageGutter)
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n("导出设置"))
                    .font(GatherFont.pageTitle)
                Text(l10n("先选择范围，再设置格式、命名与导出目录。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, GatherMetrics.Layout.pageGutter)
            .padding(.top, 16)
            .padding(.bottom, 4)
            // 导出选项/预览/结果全部走系统分组表单（行标签由系统对齐）。
            Form {
                ExportProgressSection(viewModel: viewModel)
                // 范围先于输出细节（F04）：先回答「导出哪些照片」，再问格式/命名。
                ExportRangeSection(viewModel: viewModel)
                ExportOptionsSection(
                    viewModel: viewModel,
                    maxDimensionFocused: $maxDimensionFocused,
                    watermarkFontSizeFocused: $watermarkFontSizeFocused
                )
                ExportPreviewSection(viewModel: viewModel)
                ExportResultSection(viewModel: viewModel)
            }
            .formStyle(.grouped)
        }
        .background(GatherTheme.windowBackground)
        .task {
            await viewModel.loadSessionName()
            // N05 / 4a-2c：入口意图取出即清（挑片成果 → 默认保留片）。
            if case let .exportRange(intent)? = workspace.take(.exportRange) {
                viewModel.applyRangeIntent(intent)
            }
            await viewModel.refreshPlan()
        }
        // F04 + N03：任何影响导出计划的参数变化都重算计划
        //（范围 / 变体 / 格式 / 目录 / 命名 / 水印 / 复制 XMP），
        // 保证摘要、清单、确认弹窗与实际输出始终同源。
        // D-9/C-P0-2（性能审计）：planSignature 含命名模式与水印文字，旧实现
        // 每键入一个字符就全量 export.preview（1 万张 ≈5 万次 syscall/字符）。
        // 这里 300ms 去抖：停止输入后才重算；预览/确认按钮仍会即时刷新。
        // R4 P1-2：页面级可见性只由本页 onAppear/onDisappear 驱动（切页签即交接）；
        // 导出页没有轮询，钩子与其他 6 页同形，避免未挂载页被会话级置真。
        .onAppear {
            workspace.setPageVisible(.export, true)
        }
        // P1：离开页面即取消挂起的计划重算（否则切页后仍会发一次全量 preview）。
        .onDisappear {
            planDebounceTask?.cancel()
            workspace.setPageVisible(.export, false)
        }
        .onChange(of: viewModel.planSignature) { _, _ in
            planDebounceTask?.cancel()
            viewModel.markPlanRefreshScheduled()
            planDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await viewModel.refreshPlan()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        .gatherDestructiveConfirm(
            pending: $pendingExport,
            title: l10n("开始导出？"),
            confirmLabel: { _ in l10n("开始导出") },
            message: { request in
                // D09：承诺的文件数必须是**物理文件数**（照片 + XMP 边车），
                // 旧实现只报照片数，勾选「复制 XMP」时承诺与实际不符。
                l10n.format(
                    "范围「%@」：将向「%@」写入 %lld 个文件；重名文件会自动改名，不会覆盖已有文件。",
                    request.scopeLabel.resolve(with: l10n),
                    request.destination,
                    request.fileCount
                )
            },
            onConfirm: { confirmation in
                // confirmed: true 只能从这个确认分支到达；执行的参数就是用户确认的
                // 那份快照（D03），不再重读界面状态。
                Task { await viewModel.executeExport(confirmed: true, request: confirmation.request) }
            },
            onCancel: { _ in viewModel.reportExportCancelled() }
        )
        .sessionPageChrome(
            subtitle: l10n("按统一格式、命名规则导出照片及元数据"),
            onBack: onBack,
            selection: .tab(.export),
            onBrowse: { onOpenGallery(viewModel.sessionId) },
            onSimilarity: { onOpenSimilarity(viewModel.sessionId) },
            onSelectTab: { onOpenTab(viewModel.sessionId, $0) }
        )
        .toolbar {
            // 页面级动作（预览 / 开始导出 / 取消导出）上移到工具栏，
            // 取代旧版自绘 sticky actionBar 卡片。
            ToolbarItemGroup(placement: .primaryAction) {
                C1StatusCapsuleHost(sessionId: viewModel.sessionId, culling: culling, onOpenSettings: onOpenSettings)
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(viewModel.isPreviewing ? l10n("正在计算…") : l10n("预览"), systemImage: "eye") {
                    // P1（第二轮验证）：预览会自己在 VM 里发起 preview，若留着
                    // 待触发的去抖任务，它 300ms 后还会 refreshPlan（入口先清空 preview）
                    // → 用户看到清单「自己消失一个往返」。
                    planDebounceTask?.cancel()
                    Task { await viewModel.previewExport() }
                }
                .disabled(viewModel.isWorking || viewModel.destinationIsEmpty)
                .help(l10n("预览本次导出的文件清单与空间占用"))
                // 对齐旧版 export.tsx:192：仅导出进行中禁用，预览不互斥（旧版可并发）。
                Button(viewModel.isExporting ? l10n("正在导出…") : l10n("开始导出"), systemImage: "square.and.arrow.up.fill") {
                    // 参数校验通过、且当前范围能算出导出计划，才弹确认；
                    // 确认载荷只在 onConfirm 分支下发（F04：文件数与范围同源）。
                    Task { pendingExport = await viewModel.exportConfirmation() }
                }
                // 唯一的 primary action，固定放尾侧（HIG Toolbars）。
                .gatherPrimaryActionButton()
                .disabled(viewModel.isExporting || viewModel.destinationIsEmpty)
                // 对齐旧版 export.tsx:195：取消仅在导出进行中可用（预览期间禁用）。
                // F06：改为只在导出进行中出现——禁用态常驻只会白白占掉工具栏预算。
                if viewModel.isExporting {
                    Button(l10n("取消导出"), systemImage: "stop.circle") {
                        Task { await viewModel.cancelExport() }
                    }
                    .help(l10n("取消正在进行的导出"))
                }
            }
        }
    }
}
#if DEBUG
#Preview("Export · 导出计划") {
    PreviewFactory.exportPage()
}
#endif
