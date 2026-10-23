// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceKeywordingView+Steps.swift
// Cut 4 / 4c-2b：步骤骨架（横幅 / 步骤内容路由 / 分段控件，原 1226-1341 行）
// 与 StepItem（原 1014-1024 行）。纯搬移：VStack 子项顺序与门控语义不变。
import SwiftUI

extension FaceKeywordingView {
    private struct StepItem {
        let key: FaceKeywordingViewModel.Step
        /// Cut 4 / 4b-2b：只存 key，渲染期解析。
        let label: LocalizedText
    }

    private var stepItems: [StepItem] { [
        StepItem(key: .analyze, label: LocalizedText("分析")),
        StepItem(key: .review, label: LocalizedText("审核")),
        StepItem(key: .writeback, label: LocalizedText("写回")),
    ] }

    // MARK: - 页面骨架（横幅 / 步骤内容）

    @ViewBuilder
    var bannerStack: some View {
        // 审核动作错误经内联错误块就近展示（reviewActionError 与 errorMessage
        // 同源），避免横幅双提示；其余操作错误仍走横幅。
        if let error = viewModel.errorMessage, viewModel.reviewActionError == nil {
            NativeBanner(
                text: l10n.format("操作失败：%@", CommandErrorText.resolve(error, with: l10n)),
                color: GatherTheme.error
            )
                // 通用回退文案时，不可读的原文（英文诊断）留在悬停提示里。
                .help(viewModel.errorTooltip.map { l10n.resolve($0) } ?? "")
                .padding(.horizontal, 24)
                .padding(.top, 10)
        }
        if let notice = viewModel.notice {
            NativeBanner(text: notice.resolve(with: l10n), color: GatherTheme.success)
                .padding(.horizontal, 24)
                .padding(.top, 10)
        }
        // 部分失败（encodingFailures > 0）：页面级 warning 常驻，分析成功后
        // 自动跳到审核步骤也能看见，避免"有脸没被处理"被伪装成一切正常。
        if let warning = viewModel.encodingFailureWarning {
            NativeBanner(text: l10n.resolve(warning), color: GatherTheme.warning)
                .padding(.horizontal, 24)
                .padding(.top, 10)
        }
    }

    /// 内容宽度统一：旧版分析 860 / 写回 800 两个魔法宽度，切换步骤时页面
    /// 左右边缘会跳动；审核步骤改由 HSplitView 占满可用宽度。
    private static let contentMaxWidth: CGFloat = 900

    @ViewBuilder
    var stepContent: some View {
        switch viewModel.step {
        case .analyze:
            ScrollView {
                stepAnalyze
                    .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(GatherMetrics.Layout.pageGutter)
            }
        case .review:
            stepReview
        case .writeback:
            ScrollView {
                stepWriteback
                    .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(GatherMetrics.Layout.pageGutter)
            }
        }
    }

    // MARK: - 步骤选择（原生分段控件）

    /// TS index.tsx steps 的三步向导：手绘胶囊换成系统分段控件；门控保留
    /// （已过步骤与当前步骤可回点，下一步仅在分析完成后可进入）。
    var stepPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(l10n("步骤"), selection: stepSelection) {
                ForEach(stepItems, id: \.key) { item in
                    Text(l10n.resolve(item.label)).tag(item.key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .controlSize(.small)
            .accessibilityLabel(l10n("人脸关键词步骤"))
            .help(l10n("在分析、审核、写回之间切换"))
            if let stepGateHint {
                Label(l10n.resolve(stepGateHint), systemImage: "info.circle")
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, GatherMetrics.Layout.pageGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 分段控件无法逐段禁用：非法选择被拒绝并给出可见说明，而不是静默忽略
    /// （旧版用 opacity 0.55 + tooltip 表达同样的门控）。
    private var stepSelection: Binding<FaceKeywordingViewModel.Step> {
        Binding(
            get: { viewModel.step },
            set: { newValue in
                guard canEnter(newValue) else {
                    stepGateHint = LocalizedText("请先完成人脸分析，再进入后续步骤。")
                    return
                }
                stepGateHint = nil
                viewModel.setStep(newValue)
            }
        )
    }

    private func canEnter(_ step: FaceKeywordingViewModel.Step) -> Bool {
        let target = stepIndex(step)
        let current = currentStepIndex
        if target <= current { return true }
        return target == current + 1 && viewModel.analysisDone
    }

    private func stepIndex(_ step: FaceKeywordingViewModel.Step) -> Int {
        switch step {
        case .analyze: return 0
        case .review: return 1
        case .writeback: return 2
        }
    }

    private var currentStepIndex: Int { stepIndex(viewModel.step) }

    var bindable: Bindable<FaceKeywordingViewModel> { Bindable(viewModel) }
}
