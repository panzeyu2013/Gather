// desktop/native/gather-app/Sources/GatherUI/Culling/CullingInfoBar.swift
// Cut 4 / 4c-2a：infoBar（位置计数 / 保留淘汰未处理统计 / 同步状态与同步菜单 / 重置）。
// 原 CullingView.swift 2331-2472 + 2479-2503 + 2806-2823 行，逐字搬移。
import SwiftUI
import GatherProtocol

// MARK: infoBar（grid-row 3：位置计数 + 保留/淘汰/未处理统计 + 同步状态 + 同步按钮）。
struct CullingInfoBar: View {
    let viewModel: CullingViewModel
    let isBusy: Bool
    @Binding var pendingAction: PendingCullingAction?

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        // 约束循环修复（A1，与工具栏行同类）：本行原先是不带滚动的 HStack，
        // 最小宽度 = 子控件 + 长文本之和——同步失败时的错误文案 + 重试按钮 +
        // 「同名 RAW/JPEG 共用 XMP…」整句 + 4~5 位计数，这些**只在实际数据下
        // 出现**的内容一旦同时出现就会顶破最小窗口的 680pt 预算。
        // 放进横向滚动容器后，本行的最小宽度不再等于内容总宽。
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
            // 上一张/下一张：可见按钮承载 ←/→ 裸键快捷键（取代窗口级 NSEvent 监听）。
            HStack(spacing: 2) {
                Button { viewModel.retreatCurrent() } label: {
                    Image(systemName: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help(l10n("上一张（←）"))
                .accessibilityLabel(l10n("上一张"))
                Button { viewModel.advanceCurrent() } label: {
                    Image(systemName: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help(l10n("下一张（→）"))
                .accessibilityLabel(l10n("下一张"))
            }
            if let page = viewModel.page {
                Text("\(currentIndex + 1) / \(viewModel.page?.total ?? page.assets.count)")
                    .font(GatherFont.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .accessibilityLabel(l10n.format("第 %lld 张，共 %lld 张", currentIndex + 1, viewModel.page?.total ?? page.assets.count))
            }
            if let summary = viewModel.summary {
                countItem(l10n.format("保留 %lld", summary.kept), color: GatherTheme.success)
                countItem(l10n.format("淘汰 %lld", summary.rejected), color: GatherTheme.error)
                countItem(l10n.format("未处理 %lld", summary.pending), color: .secondary)
            }
            // linkedNotice：同名 RAW/JPEG 共享 XMP 提示（对齐旧版 Culling.tsx:1393-1397）。
            if let current = viewModel.currentAsset, current.linkedVariantCount > 1 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GatherTheme.warning)
                        .accessibilityHidden(true)
                    Text(l10n.format("同名 RAW/JPEG 共用 XMP，星级和颜色将同步到 %lld 个条目", current.linkedVariantCount))
                        .font(GatherFont.secondary)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            // 原为 Spacer()（把同步区推到最右）。横向滚动容器里 Spacer 没有
            // 可分配空间，改为固定分隔线：语义上把「照片信息」与「同步动作」分开。
            Divider().frame(height: 16)
            if let sync = viewModel.syncStatus {
                HStack(spacing: 4) {
                    Circle()
                        .fill(sync.failed + sync.conflict > 0 ? GatherTheme.error : GatherTheme.success)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(syncStatusText(sync))
                        .font(GatherFont.secondaryStrong)
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            if let syncError = viewModel.lastSyncError {
                // Cut 4 / 4a-3b-1：同步类错误同样是渲染期本地化（VM 只存码/参数）。
                let syncErrorText = CommandErrorText.resolve(syncError, with: l10n)
                Text(syncErrorText)
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
                    .lineLimit(1)
                    .help(syncErrorText)
                Button(l10n("重试")) { Task { await viewModel.load() } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(GatherTheme.errorText)

            }
            Menu {
                Button(l10n("立即写入 XMP")) { Task { await viewModel.flush() } }
                    .disabled(isBusy)
                Menu {
                    Button(l10n("评分")) { pendingAction = .writeback(.rating) }
                    Button(l10n("颜色标签")) { pendingAction = .writeback(.colorLabel) }
                    Button(l10n("挑片关键词")) { pendingAction = .writeback(.keyword) }
                } label: {
                    Label(l10n("写回 XMP…"), systemImage: "square.and.arrow.up")
                }
                .disabled(!hasDecisions || isBusy)
                .help(l10n("把已决策照片的当前评分/色标/挑片关键词写回 XMP"))
                if (viewModel.syncStatus?.written ?? 0) > 0 {
                    Button(l10n("在 Capture One 中加载元数据")) { Task { await viewModel.reloadCaptureOne() } }
                        .disabled(!viewModel.canLoadMetadata || isBusy)
                        .help(syncLoadHint)
                    Button(l10n("已在 Capture One 加载")) { Task { await viewModel.confirmSync() } }
                        .disabled(!viewModel.canConfirmSync || isBusy)
                        .help(syncConfirmHint)
                }
                if (viewModel.syncStatus?.failed ?? 0) > 0 {
                    Button(l10n("重试失败项")) { pendingAction = .retryFailedWriteback }
                        .disabled(isBusy)
                }
                if (viewModel.syncStatus?.synced ?? 0) > 0 {
                    Button(l10n("保留 XMP 并结束")) { pendingAction = .finalizeSync }
                        .disabled(isBusy)
                    Button(l10n("恢复原 XMP"), role: .destructive) { pendingAction = .cleanup }
                        .disabled(!viewModel.canCleanup)
                        .help(syncCleanupHint)
                }
            } label: {
                Label(l10n("同步…"), systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)

            .help(l10n("先在 Capture One 中 Load Metadata，再返回 Gather 确认同步"))
            Button(l10n("重置挑片"), role: .destructive) { pendingAction = .reset }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(GatherTheme.errorText)

            }
            .font(GatherFont.secondary)
            .padding(.horizontal, GatherMetrics.Layout.pageGutter)
            .frame(minHeight: GatherMetrics.Chrome.infoBar)
        }
        .background(GatherTheme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    /// 写回入口可用性：没有已决策照片就没有可写回的计划（服务端会抛 CULLING_NO_DECISIONS）。
    private var hasDecisions: Bool {
        viewModel.decidedPhotoCount > 0
    }

    /// 逐按钮禁用 hint（对齐旧版 c1-sync-controls.ts 的独立 title 提示粒度）。
    private var syncLoadHint: String {
        switch viewModel.syncFlowState() {
        case .synced: return l10n("已完成同步，无需再次加载元数据")
        case .failed: return l10n("存在写入失败项，请先重试")
        case .conflict: return l10n("存在 XMP 冲突，请先裁决")
        default: return l10n("没有可加载的已写入元数据")
        }
    }

    private var syncConfirmHint: String {
        switch viewModel.syncFlowState() {
        case .synced: return l10n("已完成同步")
        default:
            return viewModel.reloadAcked
                ? l10n("请先等待写入完成或处理失败项")
                : l10n("请先在 Capture One 中加载元数据，再确认同步")
        }
    }

    private var syncCleanupHint: String {
        viewModel.syncFlowState() == .synced
            ? l10n("已完成清理")
            : l10n("请先加载元数据并确认同步，再执行清理")
    }

    /// 对齐旧版 syncLabel 六档文案：已同步 / N 个冲突 / N 个失败 /
    /// N 待写入 / N 已写入 / N 已载入。
    ///
    /// internal（非 private）供 SyncStatusCopyTests 直测。它与控制中心的
    /// syncStatusText 是**两个语域**（这里是紧凑计数，控制中心是状态句），
    /// 但结论必须一致——G 报告指出旧实现在 items 为空时**无条件**返回
    /// 「XMP 已同步」：若计数查询与行查询不同步（counts 非零而 items 为空），
    /// 同一份 outbox 状态会得到相反结论。
    func syncStatusText(_ sync: MetadataSyncSummary) -> String {
        let hasCounts = sync.conflict + sync.failed + sync.pending + sync.writing + sync.written + sync.synced > 0
        if sync.items.isEmpty && !hasCounts { return l10n("XMP 已同步") }
        if sync.conflict > 0 { return l10n.format("%lld 个 XMP 冲突", sync.conflict) }
        if sync.failed > 0 { return l10n.format("%lld 个 XMP 写入失败", sync.failed) }
        if sync.pending + sync.writing > 0 { return l10n.format("%lld 个 XMP 等待写入", sync.pending + sync.writing) }
        if sync.written > 0 { return l10n.format("%lld 个 XMP 已写入，等待 Capture One 加载", sync.written) }
        if sync.synced > 0 { return l10n.format("%lld 个 XMP 已确认加载", sync.synced) }
        return l10n("XMP 已同步")
    }

    /// 行内计数：语义色只做圆点，数字保持主文字色。
    private func countItem(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(text)
                .font(GatherFont.secondary)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var currentIndex: Int {
        guard let id = viewModel.currentPhotoId,
              let found = viewModel.page?.assets.firstIndex(where: { $0.photo.id == id }) else { return 0 }
        return found
    }
}
