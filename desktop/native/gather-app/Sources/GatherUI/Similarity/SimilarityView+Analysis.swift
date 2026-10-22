// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityView+Analysis.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出分析控制（原 332-451 行）：
// 分组范围 / 匹配强度 / 高级参数 / 开始分析 / 重新聚类。
// 纯搬移：Picker 绑定、阈值草稿防抖调用点、busy 禁用与文案逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

extension SimilarityView {

    // MARK: 分析控制（TS AnalysisPanel）

    var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("分析控制"))
                .font(.headline)
            // 旧版两张手绘「模式卡」（primarySoft 底 + 主色描边 + 说明行）
            // → 原生分段控件 + 次要说明行。
            LabeledContent(l10n("分组范围")) {
                groupingModePicker
            }
            Text(groupingModeHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent(l10n("匹配强度")) {
                presetPicker
            }
            Text(l10n("建议从「均衡」开始；需要更精细控制时再展开高级参数。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            DisclosureGroup(l10n("高级参数")) {
                VStack(alignment: .leading, spacing: 10) {
                    // TS: threshold range 0–30 step 1（对齐 SliderInput.tsx 联动：
                    // 滑块拖动实时更新 + 数字框键入精确值 blur/回车钳制到范围）。
                    // 键入变更同样触发阈值档切换防抖（thresholdDraftChanged）。
                    SliderInputIntView(
                        title: l10n("相似度阈值"),
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
                    Text(l10n("0（严格）— 30（宽松）"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SliderInputIntView(
                        title: l10n("最小组大小"),
                        value: $viewModel.minGroupSize,
                        range: 2...10
                    )
                }
                .padding(.top, 6)
            }
            HStack(spacing: 12) {
                // 开始分析：busy 时禁用并显示处理中文案。
                Button(viewModel.isAnalyzing ? l10n("处理中…") : l10n("开始分析")) {
                    viewModel.startAnalyze()
                }
                .gatherPrimaryActionButton()
                .disabled(viewModel.isAnalyzing)
                if viewModel.result != nil {
                    Button(viewModel.isReclustering ? l10n("聚类中…") : l10n("重新聚类")) {
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
            Text(l10n("顺序分组"))
                .tag(SimilarityGroupingMode.sequential)
            Text(l10n("全局分组"))
                .tag(SimilarityGroupingMode.global)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .accessibilityLabel(l10n("分组范围"))
    }

    private var groupingModeHint: String {
        viewModel.groupingMode == .sequential
            ? l10n("只合并导入顺序中连续相似的照片，适合连拍挑片")
            : l10n("在整个工作区查找相似照片，允许跨拍摄顺序聚合")
    }

    /// 匹配强度：旧版手绘 pill 行 → 原生分段控件。
    /// 未命中任何预设（阈值被手动调整）时无选中段，如实反映「自定义」。
    private var presetPicker: some View {
        Picker("", selection: presetSelection) {
            Text(l10n("严格")).tag("strict")
            Text(l10n("均衡")).tag("balanced")
            Text(l10n("宽松")).tag("loose")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
        .accessibilityLabel(l10n("匹配强度"))
        .accessibilityValue(viewModel.activePreset.map(presetTitle) ?? l10n("自定义"))
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
        case "strict": return l10n("严格")
        case "balanced": return l10n("均衡")
        case "loose": return l10n("宽松")
        default: return l10n("自定义")
        }
    }

}
