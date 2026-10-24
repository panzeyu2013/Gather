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
    @Binding var compareCount: Int

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
        .background(GatherTheme.contentBackground)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var fullToolbar: some View {
        HStack(spacing: 10) {
            undoRedoButtons

            Divider().frame(height: 18)

            labeledPicker(l10n("范围")) {
                Picker(l10n("范围"), selection: scopeBinding) {
                    ForEach(CullingViewModel.ScopeMode.allCases, id: \.self) { scope in
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

            labeledPicker(l10n("对比")) {
                Picker(l10n("对比"), selection: $compareCount) {
                    Text(l10n("单图")).tag(1)
                    Text(l10n("2 图")).tag(2)
                    Text(l10n("4 图")).tag(4)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .fixedSize()
            }

            Divider().frame(height: 18)

            qualityAnalysisBlock
                .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            undoRedoButtons

            Menu {
                Picker(l10n("范围"), selection: scopeBinding) {
                    ForEach(CullingViewModel.ScopeMode.allCases, id: \.self) { scope in
                        Text(l10n.resolve(scope.title)).tag(scope)
                    }
                }
                Divider()
                Toggle(l10n("自动前进"), isOn: autoAdvanceBinding)
                Picker(l10n("对比"), selection: $compareCount) {
                    Text(l10n("单图")).tag(1)
                    Text(l10n("2 图")).tag(2)
                    Text(l10n("4 图")).tag(4)
                }
            } label: {
                Label(l10n("显示"), systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n("范围、自动前进与对比布局"))

            compactQualityAnalysis

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var compactQualityAnalysis: some View {
        HStack(spacing: 6) {
            Button {
                Task { await viewModel.analyzeQuality() }
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .labelStyle(.iconOnly)
            .disabled(viewModel.isQualityBusy)
            .help(viewModel.isQualityBusy ? l10n("质量分析中…") : l10n("分析技术质量"))

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
            }
        }
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 4) {
            // 菜单 undo:/redo: 走 NSUndoManager，而挑片撤销是自建栈；在完整
            // focused-scope 落地前，按钮自己挂 ⌘Z/⇧⌘Z（挑片页无文本输入框）。
            Button { Task { await viewModel.undo() } } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(viewModel.undoOperation == nil || isBusy)
            .help(l10n("撤销（⌘Z）"))
            .accessibilityLabel(l10n("撤销"))

            Button { Task { await viewModel.redo() } } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(viewModel.redoOperation == nil || isBusy)
            .help(l10n("重做（⇧⌘Z）"))
            .accessibilityLabel(l10n("重做"))
        }
    }

    private var qualityAnalysisBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(viewModel.isQualityBusy ? l10n("质量分析中…") : l10n("分析技术质量")) {
                Task { await viewModel.analyzeQuality() }
            }
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
                HStack(spacing: 6) {
                    Text("\(qualityProgressPercent(job))% \(l10n.progressPhaseText(job.progressMessage))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button(l10n("取消")) {
                        viewModel.cancelQualityAnalysis()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func labeledPicker<PickerView: View>(
        _ title: String,
        @ViewBuilder picker: () -> PickerView
    ) -> some View {
        HStack(spacing: 4) {
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

    private var scopeBinding: Binding<CullingViewModel.ScopeMode> {
        Binding(
            get: { viewModel.scopeMode },
            set: { value in Task { await viewModel.setScope(value) } }
        )
    }
}
