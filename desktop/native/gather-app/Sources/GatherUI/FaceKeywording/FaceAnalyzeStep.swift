// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceAnalyzeStep.swift
// Cut 4 / 4c-2b：Step 1 分析（原 1343-1514 行）+ 分析阶段文案（原 2160-2171 行）。
import SwiftUI
import GatherProtocol

extension FaceKeywordingView {
    // MARK: - Step 1 分析（TS StepAnalyze）

    var stepAnalyze: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelsGuidanceStrip
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(l10n("匹配强度")).font(GatherFont.cardTitle)
                    Spacer()
                    phaseBadge
                }
                presetSelector
                Text(l10n("建议从「均衡」开始，之后可在审核阶段拆分或合并人物。"))
                    .font(GatherFont.secondary).foregroundStyle(.secondary)
                DisclosureGroup(l10n("高级参数")) {
                    VStack(alignment: .leading, spacing: 14) {
                        // TS range slider（渐变轨道）+ 数字输入（SliderInput）。
                        SliderInputView(title: l10n("人脸相似度"), value: bindable.eps, range: 0.3...0.95, step: 0.01)
                            .disabled(viewModel.analysisPhase == .running)
                        Text(l10n("人脸相似度下限 0.30–0.95：只有相似度不低于该值才归为同一人，数值越大分组越严格。"))
                            .font(GatherFont.secondary).foregroundStyle(.secondary)
                        SliderInputIntView(title: l10n("最少出现次数"), value: bindable.minSamples, range: 2...20)
                            .disabled(viewModel.analysisPhase == .running)
                        Text(l10n("每个簇最少包含的人脸数量（2–20）。"))
                            .font(GatherFont.secondary).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                // 分析失败/取消：与页面横幅同源的原生提示条（不再是手绘 error 色块）。
                if let error = viewModel.errorMessage,
                   viewModel.analysisPhase == .failed || viewModel.analysisPhase == .cancelled {
                    NativeBanner(
                        text: CommandErrorText.resolve(error, with: l10n),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.error
                    )
                    // 回落通用文案时，原始诊断只在此 tooltip 出现。
                    .help(viewModel.errorTooltip.map { l10n.resolve($0) } ?? "")
                }
                if viewModel.analysisPhase == .running { analysisProgress }
                HStack(spacing: 12) {
                    if viewModel.analysisPhase == .running {
                        Button(role: .destructive) {
                            Task { await viewModel.cancel() }
                        } label: {
                            Label(l10n("取消"), systemImage: "stop.fill")
                        }
                        .help(l10n("停止正在运行的人脸分析"))
                    } else if viewModel.analysisPhase == .done {
                        Button(l10n("仅重新聚类"), systemImage: "arrow.triangle.2.circlepath") {
                            // 先弹确认（影响面真实计数），确认分支才发 fkw.recluster。
                            let impact = viewModel.reclusterImpact()
                            pendingRecluster = PendingFaceRecluster(
                                clusterCount: impact.clusterCount,
                                boundClusterCount: impact.boundClusterCount
                            )
                        }
                        .gatherPrimaryActionButton()
                        .help(l10n("按当前参数重建全部人脸簇（会还原人工绑定）"))
                    } else {
                        Button(l10n("开始分析"), systemImage: "play.fill") {
                            Task { await viewModel.analyze() }
                        }
                        .gatherPrimaryActionButton()
                        .help(l10n("对新增照片运行人脸检测与聚类"))
                    }
                }
                // 旧版「分析结果：<core 枚举>…」行已删除：状态由 phaseBadge 与页面
                // 横幅承载，不再把 done/failed/cancelled 原文插进中文界面。
            }
            .gatherCard()
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    /// TS StepAnalyze.guidance：warning 提示条 +「前往设置」按钮
    /// （旧版导航 /settings；回调为 nil 时按钮禁用）。
    @ViewBuilder
    private var modelsGuidanceStrip: some View {
        if viewModel.modelsMissing {
            HStack(spacing: 8) {
                NativeBanner(
                    text: l10n("人脸模型不可用，请前往设置恢复内置模型或重新选择。"),
                    systemImage: "exclamationmark.triangle.fill",
                    color: GatherTheme.warning
                )
                Button(l10n("前往设置")) { onOpenSettings?() }
                    .disabled(onOpenSettings == nil)
                    .gatherPrimaryActionButton()
                    .controlSize(.small)
                    .help(onOpenSettings == nil
                        ? l10n("当前窗口没有设置入口")
                        : l10n("打开设置检查人脸模型"))
            }
        }
    }

    /// 分析阶段徽标（原生 GatherBadge；warning 不再充当正文前景色）。
    private var phaseBadge: some View {
        GatherBadge(l10n.resolve(viewModel.analysisPhase.label), tone: phaseTone)
    }

    private var phaseTone: GatherBadgeTone {
        switch viewModel.analysisPhase {
        case .idle: return .neutral
        case .running: return .accent
        case .done: return .success
        case .failed: return .error
        case .cancelled: return .neutral
        }
    }

    /// TS StepAnalyze presetSelector：三个手绘按钮 → 系统分段控件
    /// （自动获得键盘遍历、系统选中高亮与正确的禁用渲染）。
    private var presetSelector: some View {
        Picker(l10n("匹配强度"), selection: presetSelection) {
            ForEach(FaceKeywordingViewModel.presets) { preset in
                Text(l10n.resolve(preset.title)).tag(Optional(preset.name))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(viewModel.analysisPhase == .running)
        .help(l10n("按预设调整相似度下限与最少出现次数"))
    }

    /// 高级参数被手改后 activePreset 为 nil → 分段控件无选中项（合法状态）。
    private var presetSelection: Binding<String?> {
        Binding(
            get: { viewModel.activePreset },
            set: { name in
                guard let name else { return }
                viewModel.applyPreset(name)
            }
        )
    }

    /// TS AnalyzeProgress：相位文本 + (n/N) + 系统线性进度条。
    private var analysisProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.progressPhaseText(viewModel.progressPhase))
                    .font(.callout)
                Spacer()
                if viewModel.progressTotal > 0 {
                    Text("\(viewModel.progressCurrent)/\(viewModel.progressTotal)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if viewModel.progressTotal > 0 {
                ProgressView(value: progressRatio)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(l10n("分析进度"))
                    .accessibilityValue("\(Int((progressRatio * 100).rounded()))%")
            } else {
                // TS AnalyzeProgress：total == 0（indeterminate）时相位文本
                // 恒显示，轨道省略；补处理中文案对齐旧版（StepAnalyze.tsx:26-29）。
                HStack(spacing: 8) {
                    ProgressView()
                    Text(l10n("处理中…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var progressRatio: Double {
        guard viewModel.progressTotal > 0 else { return 0 }
        return Double(viewModel.progressCurrent) / Double(viewModel.progressTotal)
    }
}

private extension FaceKeywordingViewModel.AnalysisPhase {
    /// Cut 4 / 4b-2b：只存 key，渲染期由 View 的 l10n 解析。
    var label: LocalizedText {
        switch self {
        case .idle: return LocalizedText("未开始")
        case .running: return LocalizedText("分析中")
        case .done: return LocalizedText("已完成")
        case .failed: return LocalizedText("失败")
        case .cancelled: return LocalizedText("已取消")
        }
    }
}
