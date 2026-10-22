// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Progress.swift
// Cut 4 / 4c-2f：导出五段之一（原 ExportView.swift 856-892）。
// 纯搬移：进度条/百分比/文件名文案、无障碍标签与布局不变。
import SwiftUI

struct ExportProgressSection: View {
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// 导出中实时进度（TS export.tsx:334-346）：原生线性 ProgressView + 百分比 +
    /// `第 N/N 张 · 文件名`；executeExport 进行中但首帧进度未到（exportProgress
    /// == nil）时显示「正在准备导出…」。
    var body: some View {
        if let progress = viewModel.exportProgress {
            Section(l10n("正在导出照片…")) {
                LabeledContent(l10n("进度")) {
                    Text(percentText)
                        .monospacedDigit()
                        .foregroundStyle(GatherTheme.accent)
                }
                ProgressView(value: Double(progress.current) / Double(max(1, progress.total)))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(l10n("导出进度"))
                    .accessibilityValue(Text(percentText))
                Text(l10n.format("第 %lld/%lld 张%@", progress.current, progress.total, currentFileSuffix))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.isExporting {
            Section(l10n("正在准备导出…")) {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(l10n("导出进度"))
            }
        }
    }

    private var percentText: String {
        viewModel.progressPercent.map { "\($0)%" } ?? ""
    }

    private var currentFileSuffix: String {
        guard let name = viewModel.currentFileName, !name.isEmpty else { return "" }
        return " · \(name)"
    }
}
