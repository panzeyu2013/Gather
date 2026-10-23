// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Result.swift
// Cut 4 / 4c-2f：导出五段之五（原 ExportView.swift 1152-1183）。
// 纯搬移：成功/失败/跳过、errors.prefix(3) 截断、报告按钮与路径展示不变。
import SwiftUI
import GatherProtocol

struct ExportResultSection: View {
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        if let result = viewModel.result {
            Section(l10n("结果")) {
                Text(l10n.format("导出完成：成功 %lld，失败 %lld，跳过 %lld", result.exported, result.failed, result.skipped))
                    .font(.callout)
                    .foregroundStyle(result.failed > 0 ? GatherTheme.errorText : GatherTheme.successText)
                // 对齐 TS export.tsx:91：错误明细最多 3 条。
                ForEach(result.errors.prefix(3), id: \.self) { error in
                    Text(ExportViewModel.translateErrorLine(error, with: l10n))
                        .font(.callout)
                        .foregroundStyle(GatherTheme.errorText)
                }
                HStack(spacing: 8) {
                    Button(l10n("生成 CSV 报告")) {
                        Task { await viewModel.generateReport(format: .csv) }
                    }
                    Button(l10n("生成 Markdown 报告")) {
                        Task { await viewModel.generateReport(format: .md) }
                    }
                }
                if let report = viewModel.report {
                    Text(report.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
