// desktop/native/gather-app/Sources/GatherUI/Culling/CullingTriageCard.swift
// P0 / T0：检查器里的“技术质量建议（Beta）”卡片。
//
// 职责：
//   - 展示生成状态/计数/过期提示；
//   - 触发 generate / apply（应用前置确认 sheet）；
//   - 一键进入复核队列（切网格 + 只看待复核 + 低置信优先）；
//   - 不显示裸 confidence，不做 XMP 写入。
import SwiftUI
import GatherProtocol

struct CullingTriageCard: View {
    let viewModel: CullingViewModel
    @Binding var layoutMode: CullingLayoutMode
    let isBusy: Bool

    @State private var showApplyConfirmation = false
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private var summary: TriageSummary? { viewModel.triageSummary }
    private var busy: Bool { isBusy || viewModel.isTriageBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            if let error = viewModel.triageError {
                Text(CommandErrorText.resolve(error, with: l10n))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary {
                if summary.stale {
                    Label(l10n("技术质量建议已过期，请重新生成"), systemImage: "exclamationmark.triangle.fill")
                        .font(GatherFont.secondary)
                        .foregroundStyle(GatherTheme.warning)
                }

                Text(l10n.format(
                    "已分析 %lld%%",
                    viewModel.triageCoveragePercent
                ))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                Text(l10n.format(
                    "建议保留 %lld · 建议淘汰 %lld · 待复核 %lld",
                    summary.counts.keep,
                    summary.counts.reject,
                    summary.counts.review
                ))
                .font(GatherFont.labelRegular)
                .fixedSize(horizontal: false, vertical: true)

                if summary.counts.coverage < 0.999 {
                    Text(l10n("质量分析覆盖不足，未分析照片将进入复核。"))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let triage = viewModel.currentAsset?.triage {
                    currentSuggestion(triage)
                }

                actions(summary: summary)
            } else {
                Text(l10n("尚未生成技术质量建议，请先生成"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                generateButton(hasSummary: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showApplyConfirmation) {
            applyConfirmation
        }
    }

    // MARK: - 当前照片建议

    private func currentSuggestion(_ triage: TriageSuggestion) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack(spacing: GatherMetrics.Space.s) {
                Text(l10n("当前照片"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                Text(CullingDisplayFormat.triageVerdictTitle(triage.verdict, with: l10n))
                    .font(GatherFont.secondary.weight(.semibold))
                    .foregroundStyle(CullingDisplayFormat.triageColor(triage.verdict))
            }
            if !triage.reasons.isEmpty {
                HStack(spacing: GatherMetrics.Space.xs) {
                    ForEach(0..<min(2, triage.reasons.count), id: \.self) { index in
                        Text(CullingDisplayFormat.triageReasonTitle(triage.reasons[index].code, with: l10n))
                            .font(GatherFont.secondary)
                            .padding(GatherMetrics.Space.xs)
                            .background(
                                Capsule().fill(GatherTheme.surfaceMuted)
                            )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 动作

    @ViewBuilder
    private func actions(summary: TriageSummary) -> some View {
        generateButton(hasSummary: true)

        HStack(spacing: GatherMetrics.Space.s) {
            Button {
                showApplyConfirmation = true
            } label: {
                Label(l10n("应用建议"), systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !viewModel.canApplyTriage)
            .help(l10n("应用建议"))

            Button {
                layoutMode = .grid
                Task { await viewModel.showTriageReviewQueue() }
            } label: {
                Label(l10n("进入复核队列"), systemImage: "rectangle.grid.2x2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            // stale 时页面行被门控全部隐藏，进入队列只会得到空网格。
            .disabled(busy || summary.counts.review == 0 || summary.stale)
            .help(summary.stale ? l10n("建议已过期，请先重新生成") : l10n("复核队列"))
        }
    }

    private func generateButton(hasSummary: Bool) -> some View {
        Button {
            Task { await viewModel.generateTriage(force: hasSummary) }
        } label: {
            if viewModel.isTriageBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    hasSummary ? l10n("重新生成建议") : l10n("生成建议"),
                    systemImage: "sparkles"
                )
            }
        }
        .buttonStyle(.bordered)
        .disabled(busy || !viewModel.canGenerateTriage)
        .help(l10n("技术质量建议（Beta）"))
    }

    // MARK: - 应用确认

    private var applyConfirmation: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("应用建议？"))
                .font(GatherFont.sectionTitle)

            if let counts = summary?.counts {
                Text(l10n.format(
                    "将应用 %lld 条建议（保留 %lld / 淘汰 %lld）。",
                    counts.keep + counts.reject,
                    counts.keep,
                    counts.reject
                ))
                .font(GatherFont.body)
            }

            Text(l10n("不会写入 XMP，只修改 Gather 的保留/淘汰决策；可在挑片页撤销。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(l10n("跳过人工决策与低置信项。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(l10n("取消")) { showApplyConfirmation = false }
                    .keyboardShortcut(.cancelAction)
                Button(l10n("确认应用")) {
                    showApplyConfirmation = false
                    Task { _ = await viewModel.applyTriage() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !viewModel.canApplyTriage)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 360)
    }
}
