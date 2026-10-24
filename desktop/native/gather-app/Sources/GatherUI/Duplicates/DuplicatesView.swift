// Phase 3.6：重复检测与处置 SwiftUI 页面。
// TS 源：desktop/src/renderer/pages/SessionDetail/Duplicates.tsx。
// 对齐项：
// - 三档预设（严格 2 / 均衡 4 / 宽松 7，TS L309-343）；阈值滑块始终可拖（TS L332-340）；
// - 推荐保留徽章（TS L68-75：score = fileSize*1000 + mtime ms，最高分者，平手取先出现者）；
// - 成员上限 12 + 展开/收起（TS L10/77-79/135-145）；
// - 分段 Tab 计数徽标（TS L366-379）；
// - 成员文件大小（TS L42-44）；
// - 100 组分页 + 加载更多（TS L11/291-296/406-416）；
// - 空态区分：未扫描 → 先运行扫描；扫描过无该类型结果 → 对应空态（TS L383-393）；
// - 操作后局部更新（TS L201-270）：resolve/toggle 成功后就地 patch，避免整页重拉。
//
// Cut 4 / 4c-2g：910 行 -> 4 文件（行为不变）。本文件只留外壳：
// 4 个状态（viewModel / 两个 pending / showAdvancedScan）、装配 init、页面接线、
// 两个确认弹窗与工具栏；视图模型在 DuplicatesViewModel.swift，分段视图在
// DuplicatesView+Sections.swift，分组卡在 DuplicatesGroupCardView.swift。
// 会话页迁移（M1）：窗口 chrome / 页签 / 返回 / 页面级可见性交给 GatherSessionPage，
// 导航（图库/照片）改从 environment 的 navigator 取。
import SwiftUI
import GatherProtocol

public struct DuplicatesView: View {
    @State private var viewModel: DuplicatesViewModel
    /// 所属会话工作区：VM 与页面骨架（GatherSessionPage）都从这里取。
    private let workspace: SessionWorkspace
    private let culling: any CullingAPI
    /// 破坏性动作的待确认上下文：非空即弹确认框；命令只在确认分支发出。
    @State private var pendingResolution: PendingGroupResolution?
    @State private var pendingMemberDecision: PendingMemberDecision?
    /// 高级扫描参数（阈值）的展开状态（F13：与相似度/人脸页同一套渐进披露规则）。
    @State private var showAdvancedScan = false

    /// 生产装配（Cut 4 / 4a-2a-2）：VM 来自会话工作区（workspace.duplicates）。
    /// 扫描结果/阈值/分组展开/分页都挂在 VM 上，切页签销毁页面后仍由
    /// workspace 保留；外壳不再缓存/替换 VM。
    ///
    /// 会话页迁移（M1）：页面只接 workspace + culling；返回 / 页签 / 图库 /
    /// 成员照片入口一律从 environment 的 navigator 取，不再接收导航闭包。
    package init(workspace: SessionWorkspace, culling: any CullingAPI) {
        _viewModel = State(initialValue: workspace.duplicates)
        self.workspace = workspace
        self.culling = culling
    }

    // Cut 4 / 4a-3b-2b：语言源由外壳经 environment 下发（RootView / SessionPageHost）。
    @Environment(\.languageStore) private var languageStore
    /// 成员照片入口（图库直达某张照片）；navigator 为 nil 时（预览/布局测试）无操作。
    @Environment(\.navigator) private var navigator: RootNavigation?
    /// 设置入口：C1 状态胶囊的「去设置」直接调环境动作，不再收 onOpenSettings。
    @Environment(\.openSettings) private var openSettings
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    public var body: some View {
        // 骨架（页签行 / 返回 / canvas 背景 / 副标题 / 页面级可见性）由
        // GatherSessionPage 统一负责；本页只提供内容 + 自己的工具栏与生命周期。
        GatherSessionPage(page: .duplicates, workspace: workspace, subtitle: l10n("重复照片检测")) {
            content
        }
    }

    /// 页面内容：横幅 + 扫描控件 + 分组列表（原 body，逐字下移）。
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = viewModel.errorMessage {
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
            ScrollView {
                VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
                    DuplicatesScanControls(viewModel: viewModel, showAdvancedScan: $showAdvancedScan)
                    if viewModel.isLoading || viewModel.isScanning {
                        DuplicatesLoadingIndicator(viewModel: viewModel)
                    }
                    if let result = viewModel.scanResult {
                        Text(l10n.format("完全重复：%lld 组 · 视觉相似：%lld 组 · 总计重复：%lld 张", result.exactGroups.count, result.visualGroups.count, result.totalDuplicates))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                        // C-#7：阈值改过之后旧数字必须显式标为过期，不能让上一个档位
                        // 的结论冒充当前设置的结果。
                        if viewModel.isScanResultStale {
                            Label(
                                l10n.format("当前匹配强度为 %lld，上面的结果来自 %lld；请重新扫描。", viewModel.threshold, viewModel.scannedThreshold ?? viewModel.threshold),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(GatherFont.secondary)
                            .foregroundStyle(GatherTheme.warningText)
                        }
                    }
                    Text(l10n("扫描会先识别内容完全一致的文件，再查找视觉近似候选；不会删除照片。"))
                        .font(GatherFont.labelRegular)
                        .foregroundStyle(.secondary)
                    DuplicatesTabSelector(viewModel: viewModel)
                    if viewModel.filteredGroups.isEmpty {
                        DuplicatesEmptyState(viewModel: viewModel)
                    } else {
                        // 惰性渲染：大组列表不预先布局全部卡片（ScrollView 内）。
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(viewModel.visibleFilteredGroups, id: \.id) { group in
                                DuplicatesGroupCard(
                                    group: group,
                                    viewModel: viewModel,
                                    onResolve: { pendingResolution = $0 },
                                    onSetMemberKept: { pendingMemberDecision = $0 },
                                    onOpenPhoto: openPhoto
                                )
                            }
                            if viewModel.remainingGroupCount > 0 {
                                Button(l10n.format("加载更多（还有 %lld 组）", viewModel.remainingGroupCount)) {
                                    viewModel.loadMoreGroups()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(GatherMetrics.Layout.pageGutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 成员保留状态确认挂在 ScrollView 节点：与组处置确认（外层 VStack）
            // 分属不同视图节点，避免两个 confirmationDialog 抢同一呈现宿主。
            .gatherDestructiveConfirm(
                pending: $pendingMemberDecision,
                title: l10n("确认更改这张照片的保留状态？"),
                confirmLabel: { $0.confirmLabel.resolve(with: l10n) },
                message: { $0.scopeText(with: l10n) },
                onConfirm: { pending in
                    Task {
                        await viewModel.setMemberKept(
                            pending.member, isKept: pending.isKept, confirmed: true
                        )
                    }
                },
                onCancel: { pending in
                    // 动作本身也只存 key + 参数；点取消时用页面语言渲染后交给 notice。
                    viewModel.reportCancellation(pending.cancelCopy.resolve(with: l10n))
                }
            )
        }
        .task { await viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: GatherEventCenter.jobProgress)) { notification in
            guard let event = notification.object as? GatherJobEvent else { return }
            viewModel.applyJobEvent(event)
        }
        // 组处置 / 成员保留状态：确认后才构造 Confirmed 调用 DuplicateAPI，
        // 取消只写可见文案（不发请求）。
        .gatherDestructiveConfirm(
            pending: $pendingResolution,
            title: l10n("确认处理这个重复组？"),
            confirmLabel: { $0.confirmLabel.resolve(with: l10n) },
            confirmRole: { $0.confirmRole },
            message: { $0.scopeText(with: l10n) },
            onConfirm: { pending in
                Task {
                    await viewModel.resolveGroup(
                        pending.group, resolution: pending.resolution, confirmed: true
                    )
                }
            },
            onCancel: { pending in
                viewModel.reportCancellation(pending.cancelCopy.resolve(with: l10n))
            }
        )
        .toolbar {
            GatherSessionToolbar(
                sessionId: viewModel.sessionId,
                culling: culling,
                onOpenSettings: { openSettings() },
                refreshTitle: l10n("刷新"),
                refreshHelp: l10n("刷新重复照片"),
                refreshDisabled: viewModel.isLoading || viewModel.isScanning,
                onRefresh: { Task { await viewModel.load() } }
            )
        }
    }

    /// 成员照片 → 图库（photoId 直达）。navigator 为 nil（预览/布局测试）时无操作。
    /// 旧实现由外壳经 onOpenPhoto 闭包注入；M1 后外壳不再持有导航闭包，
    /// 该入口改从 environment 的 navigator 取。
    private func openPhoto(_ photoId: String) {
        navigator?.openGallery(viewModel.sessionId, photoId: photoId)
    }
}

#if DEBUG
#Preview("Duplicates · 重复分组") {
    PreviewFactory.duplicatesPage()
}
#endif
