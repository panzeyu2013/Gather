// desktop/native/gather-app/Sources/GatherUI/Culling/CullingTriageCard.swift
// P0 / T0：检查器里的“技术质量建议（Beta）”卡片。
//
// 职责：
//   - 展示生成状态/计数/过期提示；
//   - 触发 generate / apply（应用前置确认 sheet）；
//   - 一键进入复核队列（切网格 + 只看待复核 + 低置信优先）；
//   - 置信度只显示三档（高/中/低），裸值与各信号贡献放进「为什么」popover；
//   - 提供阈值校准入口（样本不足时禁用"应用"），不做 XMP 写入。
import SwiftUI
import GatherProtocol

struct CullingTriageCard: View {
    let viewModel: CullingViewModel
    @Binding var layoutMode: CullingLayoutMode
    let isBusy: Bool

    @State private var showApplyConfirmation = false
    /// §3.11.2：校准面板依赖（组合根注入 CullingAPI 的校准方法；nil = 未接线）。
    var calibration: TriageCalibrationBridge?
    @State private var showCalibration = false
    /// 「为什么」popover 的展开状态（每次点开才渲染，避免列表里预计算）。
    @State private var showWhy = false
    /// 校准面板状态：打开 sheet 时创建并按需拉取（关闭即丢弃，不占挑片 VM）。
    @State private var calibrationModel: TriageCalibrationViewModel?
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
                if viewModel.triageUsesModelSignals, let review = viewModel.currentModelReview {
                    signals(review)
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
        .task(id: viewModel.currentAsset?.photo.id) {
            await viewModel.loadModelReview()
        }
        .sheet(isPresented: $showApplyConfirmation) {
            applyConfirmation
        }
        .sheet(isPresented: $showCalibration) {
            calibrationSheet
        }
        .task(id: showCalibration) {
            guard showCalibration else { return }
            let model = calibrationModel ?? TriageCalibrationViewModel()
            calibrationModel = model
            await model.refresh(calibration)
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
            confidenceRow(triage)
        }
    }

    // MARK: - 置信度三档 + 为什么（§3.11.3）

    /// 三档 + 「为什么」：列表里只给档位，裸值/信号/历史精确率放进 popover，
    /// 既不制造假精度，又能在用户追问时给出全部依据。
    private func confidenceRow(_ triage: TriageSuggestion) -> some View {
        HStack(spacing: GatherMetrics.Space.s) {
            Label(tierTitle(confidenceTier(triage.confidence)), systemImage: tierIcon(triage.confidence))
                .font(GatherFont.secondary)
                .foregroundStyle(tierColor(triage.confidence))
            Button {
                showWhy.toggle()
            } label: {
                Label(l10n("为什么"), systemImage: "questionmark.circle")
                    .font(GatherFont.secondary)
            }
            .buttonStyle(.plain)
            .help(l10n("为什么给出这条建议"))
            .popover(isPresented: $showWhy) {
                whyPopover(triage)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func confidenceTier(_ confidence: Double) -> TriageConfidenceTier {
        TriageConfidenceTier.tier(
            for: confidence,
            thresholds: calibrationModel?.model?.confidenceThresholds ?? .default)
    }

    private func tierTitle(_ tier: TriageConfidenceTier) -> String {
        switch tier {
        case .high: return l10n("高置信")
        case .medium: return l10n("中等置信")
        case .low: return l10n("低置信")
        }
    }

    private func tierIcon(_ confidence: Double) -> String {
        switch confidenceTier(confidence) {
        case .high: return "checkmark.seal.fill"
        case .medium: return "questionmark.circle.fill"
        case .low: return "exclamationmark.triangle.fill"
        }
    }

    private func tierColor(_ confidence: Double) -> Color {
        switch confidenceTier(confidence) {
        case .high: return GatherTheme.success
        case .medium: return .secondary
        case .low: return GatherTheme.warning
        }
    }

    /// 「为什么」：裸置信度、各信号贡献、校准桶的历史精确率（有样本才显示）。
    private func whyPopover(_ triage: TriageSuggestion) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            Text(l10n.format("置信度 %.2f", triage.confidence))
                .font(GatherFont.labelRegular)
                .monospacedDigit()
            // 明说口径：这是规则打分，不是"命中概率"。
            Text(l10n("置信度来自规则打分，不是概率；下方是各信号贡献。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if triage.reasons.isEmpty {
                Text(l10n("没有触发具体信号"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(triage.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(CullingDisplayFormat.triageReasonTitle(reason.code, with: l10n))
                        .font(GatherFont.secondary)
                }
            }
            if let precision = bucketPrecision(triage.confidence) {
                Divider()
                Text(l10n.format("该置信区间的历史精确率 %.0f%%（样本 ≥ %lld）",
                                 precision * 100,
                                 Int64(triageBucketSamples(triage.confidence))))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(l10n("该置信区间还没有人工样本，暂时无法给出历史精确率。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(GatherMetrics.Space.m)
        .frame(minWidth: 260, alignment: .leading)
    }

    /// 当前置信度所在的 10 分桶（0.0–0.1 … 0.9–1.0）。
    private func calibrationBucket(_ confidence: Double) -> TriageCalibrationPanelModel.Bucket? {
        guard let buckets = calibrationModel?.model?.buckets, !buckets.isEmpty else { return nil }
        let index = min(buckets.count - 1, max(0, Int((min(1, max(0, confidence)) * 10).rounded(.down))))
        return buckets[index]
    }

    private func bucketPrecision(_ confidence: Double) -> Double? {
        guard let bucket = calibrationBucket(confidence), bucket.keepSuggestions >= 5 else { return nil }
        return bucket.precision
    }

    private func triageBucketSamples(_ confidence: Double) -> Int {
        calibrationBucket(confidence)?.keepSuggestions ?? 0
    }

    // MARK: - 模型信号

    /// W1：把"为什么"从标签升级为可读数值（眼睛/合焦/表情/审美/工具图）。
    private func signals(_ review: ModelReviewResult) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Text(l10n("模型信号"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
            HStack(spacing: GatherMetrics.Space.s) {
                if let eyes = review.eyesOpenScore {
                    chip(eyes >= 0.6 ? l10n("眼睛睁开")
                         : (eyes <= 0.35 ? l10n("主体闭眼") : l10n("眼睛半闭")))
                }
                if let focus = review.faceFocusScore {
                    chip(l10n.format("人脸合焦 %.2f", focus))
                }
                if let smile = review.smileScore, smile >= 0.5 {
                    chip(l10n("面带微笑"))
                }
                if review.isUtilityImage == true {
                    chip(l10n("截图或文档，不是照片"))
                }
                if let aesthetic = review.aestheticScore {
                    chip(l10n.format("审美 %.2f", aesthetic))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(GatherFont.secondary)
            .padding(GatherMetrics.Space.xs)
            .background(Capsule().fill(GatherTheme.surfaceMuted))
    }

    // MARK: - 动作

    @ViewBuilder
    private func actions(summary: TriageSummary) -> some View {
        generateButton(hasSummary: true)

        Button {
            showCalibration = true
        } label: {
            Label(l10n("校准阈值"), systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .help(calibration == nil
              ? l10n("校准未接线")
              : l10n("用人工反馈校准置信度阈值（只在你确认后写入设置）"))

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

    // MARK: - 校准面板（§3.11.2）

    private var calibrationSheet: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("校准置信度阈值"))
                .font(GatherFont.sectionTitle)

            Text(l10n("样本只取人工决定（手动改选与客户校样回传）；AI 自动应用不计入。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = calibrationModel?.error {
                Text(CommandErrorText.resolve(error, with: l10n))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let model = calibrationModel?.model {
                sampleLine(model)
                bucketChart(model)
                suggestions(model)
            } else if calibrationModel?.isBusy == true {
                ProgressView().controlSize(.small)
            } else {
                Text(l10n("暂时读不到校准报告"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(l10n("关闭")) { showCalibration = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(GatherMetrics.Space.l)
        .frame(minWidth: 460, minHeight: 320)
    }

    private func sampleLine(_ model: TriageCalibrationPanelModel) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            Text(l10n.format("人工样本 %lld / 最少 %lld", model.samples, model.minSamples))
                .font(GatherFont.labelRegular)
                .monospacedDigit()
            if let disabled = model.disabledReason {
                Label(disabled, systemImage: "exclamationmark.triangle.fill")
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.warning)
            }
            Text(l10n.format("当前阈值：保留 %.2f · 淘汰 %.2f · 可执行下限 %.2f",
                             model.currentKeep, model.currentReject, model.currentMinExecutable))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let precision = model.currentKeepPrecision {
                Text(l10n.format("当前阈值下 keep 精确率 %.0f%%", precision * 100))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// 10 桶曲线（柱高 = 该桶 keep 精确率；无样本的桶画成空槽）。
    private func bucketChart(_ model: TriageCalibrationPanelModel) -> some View {
        HStack(alignment: .bottom, spacing: GatherMetrics.Space.xs) {
            ForEach(model.buckets) { bucket in
                VStack(spacing: GatherMetrics.Space.xs) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bucket.precision == nil
                              ? GatherTheme.surfaceMuted
                              : GatherTheme.accent.opacity(0.75))
                        .frame(width: 18, height: max(2, CGFloat((bucket.precision ?? 0) * 60)))
                    Text(l10n.format("%.1f", bucket.lowerBound))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(l10n.format("置信度 %.1f–%.1f：keep 建议 %lld，其中一致 %lld",
                                  bucket.lowerBound, bucket.upperBound,
                                  Int64(bucket.keepSuggestions), Int64(bucket.agreedKeep)))
            }
        }
        .frame(height: 80, alignment: .bottom)
    }

    private func suggestions(_ model: TriageCalibrationPanelModel) -> some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.s) {
            if model.suggestions.isEmpty {
                Text(l10n("样本里没有可用的 keep 建议，暂时给不出建议阈值。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.suggestions) { suggestion in
                HStack(spacing: GatherMetrics.Space.s) {
                    VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
                        Text(l10n.format("保精确率 %.0f%% → 阈值 %.2f",
                                         suggestion.target * 100, suggestion.confidence))
                            .font(GatherFont.labelRegular)
                            .monospacedDigit()
                        Text(l10n.format("届时 keep %lld · reject %lld · review %lld（样本 %lld）",
                                         Int64(suggestion.keep), Int64(suggestion.reject),
                                         Int64(suggestion.review), Int64(suggestion.samples)))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button(l10n("应用")) {
                        Task { await calibrationModel?.apply(suggestion, bridge: calibration) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(calibrationModel?.canApply != true)
                }
            }
            if let applied = calibrationModel?.appliedThreshold {
                Text(l10n.format("已应用阈值 %.2f；建议已失效，重新生成后会按新阈值判定。", applied))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.successText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(l10n("应用只改三个置信度设置，不改策略版本；不会自动应用任何建议。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
