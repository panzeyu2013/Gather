// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Range.swift
// Cut 4 / 4c-2f：导出五段之二（原 ExportView.swift 894-937）。
// 纯搬移：范围 Picker、张数摘要/空范围/计算中/计划失败四种状态逐字未动。
import SwiftUI
import GatherProtocol

struct ExportRangeSection: View {
    @Bindable var viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 导出范围（F04）：范围决定「哪些照片会被写出」，必须在格式/命名之前先回答，
    /// 并给出与预览、确认弹窗、实际输出**同源**的张数摘要（都来自同一次
    /// export.preview 计划）。旧实现固定发送整个工作区范围，界面却引导用户
    /// 「挑片完成后导出最终成品」，承诺与结果不符。
    var body: some View {
        Section(l10n("导出范围")) {
            Picker(l10n("导出范围"), selection: $viewModel.scope) {
                Text(l10n.resolve(ExportConfirmation.scopeLabel(for: .filtered)))
                    .tag(ExportScope.filtered)
                Text(l10n.resolve(ExportConfirmation.scopeLabel(for: .session)))
                    .tag(ExportScope.session)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel(l10n("导出范围"))

            // 张数摘要只在计划与当前参数同源时显示（N03）：参数一变，
            // refreshPlan 会立刻把 preview 作废，这里不会残留旧范围的数字。
            if let preview = viewModel.preview, !viewModel.isPlanStale {
                LabeledContent(l10n("本次将导出")) {
                    Text(l10n.format("%lld 个文件", preview.totalFiles))
                        .monospacedDigit()
                }
                if viewModel.scope == .filtered, preview.totalFiles == 0 {
                    Text(l10n("当前没有「保留」的照片：请先在挑片页做出保留决策，或把范围改为「工作区全部照片」。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.destinationIsEmpty {
                Text(l10n("选择导出目录后显示本次将导出的文件数。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if viewModel.isPlanning || viewModel.isPlanRefreshScheduled {
                // 去抖 pending 期间也要占位（否则参数一变摘要行整行消失、无任何提示）。
                Text(l10n("正在计算本次导出的文件数…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let planError = viewModel.planError {
                Text(l10n.format("无法计算导出计划：%@", CommandErrorText.resolve(planError, with: l10n)))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.errorText)
            }
        }
    }
}
