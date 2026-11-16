// desktop/native/gather-app/Sources/GatherUI/Culling/CullingToolbar.swift
// Cut 4 / 4c-2a：顶部工具栏（范围 / 历史撤销重做 / 对比 / 质量分析），
// 原 CullingView.swift 1922-2149 + 2474-2477 + 2827-2899 行，逐字搬移。
// 键盘快捷键：可见控件上的 .keyboardShortcut（任意焦点下窗口级生效）；空格键由
// 查看器的 .onKeyPress 处理——不再使用 NSEvent 局部监听，也不屏蔽控件焦点。
import SwiftUI
import GatherProtocol

// MARK: 顶部工具栏（撤销/重做 + 范围 + 自动前进 + 对比 + 质量分析）。
// 筛选与导航分组已经移入右侧检查器：工具栏只保留高频模式与瞬时动作，
// 既降低视觉噪声，也把高度还给查看器。
struct CullingToolbar: View {
    let viewModel: CullingViewModel
    let isBusy: Bool
    @Binding var layoutMode: CullingLayoutMode
    /// P1-9：同步/写回/重置动作与布局无关；网格布局也必须能打开。
    @Binding var pendingAction: PendingCullingAction?

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        // 完整工具栏在宽窗口保留全部可见控件；内容区（默认窗口扣掉侧栏与
        // 检查器）放不下时，自动切到紧凑菜单，避免“分析”按钮被检查器边缘裁切。
        ViewThatFits(in: .horizontal) {
            fullToolbar
                .fixedSize(horizontal: true, vertical: false)
            compactToolbar
        }
        .background(GatherTheme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var fullToolbar: some View {
        // 10 → 12：动作条是每次进页都会看见的"第一层"，控件之间留一点空气，
        // 比把 7 个控件挤成一条更像 macOS 应用而不是仪表盘。
        HStack(spacing: GatherMetrics.Space.m) {
            undoRedoButtons

            Divider().frame(height: 18)

            labeledPicker(l10n("范围")) {
                Picker(l10n("范围"), selection: scopeBinding) {
                    ForEach(ScopeMode.allCases, id: \.self) { scope in
                        Text(l10n.resolve(scope.title)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .fixedSize()
            }

            Toggle(l10n("自动前进"), isOn: autoAdvanceBinding)
                .toggleStyle(.checkbox)
                .fixedSize()

            labeledPicker(l10n("布局")) {
                Picker(l10n("布局"), selection: $layoutMode) {
                    ForEach(CullingLayoutMode.allCases, id: \.self) { mode in
                        Label(l10n(mode.titleKey), systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .fixedSize()
            }

            Divider().frame(height: 18)

            CullingSyncControls(
                viewModel: viewModel,
                isBusy: isBusy,
                pendingAction: $pendingAction
            )

            filterChip

            qualityAnalysisBlock
                .fixedSize()
        }
        .padding(.horizontal, GatherMetrics.Space.xl)
        .padding(.vertical, GatherMetrics.Space.controlGap)
    }

    private var compactToolbar: some View {
        HStack(spacing: GatherMetrics.Space.s) {
            undoRedoButtons

            Menu {
                Picker(l10n("范围"), selection: scopeBinding) {
                    ForEach(ScopeMode.allCases, id: \.self) { scope in
                        Text(l10n.resolve(scope.title)).tag(scope)
                    }
                }
                Divider()
                Toggle(l10n("自动前进"), isOn: autoAdvanceBinding)
                Picker(l10n("布局"), selection: $layoutMode) {
                    ForEach(CullingLayoutMode.allCases, id: \.self) { mode in
                        Text(l10n(mode.titleKey)).tag(mode)
                    }
                }
            } label: {
                Label(l10n("显示"), systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n("范围、自动前进与布局"))

            filterChip

            CullingSyncControls(
                viewModel: viewModel,
                isBusy: isBusy,
                pendingAction: $pendingAction,
                compact: true
            )

            compactQualityAnalysis

            Spacer(minLength: 0)
        }
        .padding(.horizontal, GatherMetrics.Space.l)
        .padding(.vertical, GatherMetrics.Space.controlGap)
    }

    @ViewBuilder
    private var filterChip: some View {
        if viewModel.activeFilterCount > 0 {
            Button {
                Task { await viewModel.resetFilters() }
            } label: {
                Text(l10n.format("筛选 %lld", viewModel.activeFilterCount))
                    .font(GatherFont.label)
                    .padding([.horizontal], GatherMetrics.Space.s)
                    .padding([.vertical], GatherMetrics.Space.xxs)
                    .background(Capsule().fill(GatherTheme.surfaceMuted))
            }
            .buttonStyle(.plain)
            .help(l10n("点击清除筛选"))
        }
    }

    private var compactQualityAnalysis: some View {
        HStack(spacing: GatherMetrics.Space.controlGap) {
            Button {
                Task { await viewModel.analyzeQuality() }
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .labelStyle(.iconOnly)
            .gatherIconButton()
            .disabled(viewModel.isQualityBusy)
            .help(viewModel.isQualityBusy ? l10n("质量分析中…") : l10n("分析技术质量"))
            .accessibilityLabel(l10n("分析技术质量"))

            if let job = viewModel.qualityJob, job.progressTotal > 0,
               job.status == .queued || job.status == .running || job.status == .cancelling {
                ProgressView(
                    value: Double(min(job.progressCurrent, job.progressTotal)),
                    total: Double(job.progressTotal)
                )
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 56)
                Text("\(qualityProgressPercent(job))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { viewModel.cancelQualityAnalysis() } label: {
                    Image(systemName: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .gatherIconButton()
                .help(l10n("取消质量分析"))
                .accessibilityLabel(l10n("取消质量分析"))
            }
        }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: GatherMetrics.Space.xs) {
            // 挑片撤销是自建栈（不是 NSUndoManager）；⌘Z/⇧⌘Z 由 CullingView 的
            // focused-scope 命令接管 Edit 菜单，按钮只保留点击与禁用态。
            Button { Task { await viewModel.undo() } } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .gatherIconButton()
            .disabled(viewModel.undoOperation == nil || isBusy)
            .help(l10n("撤销（⌘Z）"))
            .accessibilityLabel(l10n("撤销"))

            Button { Task { await viewModel.redo() } } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .gatherIconButton()
            .disabled(viewModel.redoOperation == nil || isBusy)
            .help(l10n("重做（⇧⌘Z）"))
            .accessibilityLabel(l10n("重做"))
        }
    }

    private var qualityAnalysisBlock: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Button(viewModel.isQualityBusy ? l10n("质量分析中…") : l10n("分析技术质量")) {
                Task { await viewModel.analyzeQuality() }
            }
            .gatherButton(.secondary)
            .disabled(viewModel.isQualityBusy)

            if let job = viewModel.qualityJob, job.progressTotal > 0,
               job.status == .queued || job.status == .running || job.status == .cancelling {
                ProgressView(
                    value: Double(min(job.progressCurrent, job.progressTotal)),
                    total: Double(job.progressTotal)
                )
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: 150)
                HStack(spacing: GatherMetrics.Space.controlGap) {
                    Text("\(qualityProgressPercent(job))% \(l10n.progressPhaseText(job.progressMessage))")
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(l10n("取消")) {
                        viewModel.cancelQualityAnalysis()
                    }
                    .gatherButton(.secondary, size: .small)
                }
            }
        }
    }

    private func labeledPicker<PickerView: View>(
        _ title: String,
        @ViewBuilder picker: () -> PickerView
    ) -> some View {
        HStack(spacing: GatherMetrics.Space.xs) {
            Text(title)
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
            picker().labelsHidden()
        }
    }

    private func qualityProgressPercent(_ job: AnalysisJobData) -> Int {
        guard job.progressTotal > 0 else { return 0 }
        return min(100, max(0, Int((Double(job.progressCurrent) / Double(job.progressTotal) * 100).rounded())))
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { viewModel.autoAdvance },
            set: { viewModel.autoAdvance = $0 }
        )
    }

    private var scopeBinding: Binding<ScopeMode> {
        Binding(
            get: { viewModel.scopeMode },
            set: { value in Task { await viewModel.setScope(value) } }
        )
    }
}
