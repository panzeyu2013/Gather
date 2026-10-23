// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlJobRow.swift
// Cut 4 / 4c-2e：任务行叶子 View，从 SessionControlView.jobRow 原样搬出
// （原 1211-1269 行）；重试入口改为闭包，调用点仍是 viewModel.retry(job)，
// 状态守卫（failed / interrupted / cancelled）不变。

import SwiftUI
import GatherProtocol

struct SessionControlJobRow: View {
    let job: AnalysisJobData
    let l10n: L10n
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: jobStatusSymbol(job.status))
                .foregroundStyle(jobStatusColor(job.status))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(l10n.jobTypeText(job.type.rawValue))
                    GatherBadge(status: job.status, l10n: l10n)
                    Spacer(minLength: 0)
                }
                if job.progressTotal > 0 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(job.progressCurrent), total: Double(job.progressTotal))
                            .progressViewStyle(.linear)
                        Text("\(job.progressCurrent)/\(job.progressTotal)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(l10n.progressPhaseText(job.progressMessage))
                            .font(GatherFont.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if [.failed, .interrupted, .cancelled].contains(job.status) {
                Button(l10n("重试")) { onRetry() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(l10n("重新排队该任务"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func jobStatusSymbol(_ status: AnalysisJobStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        case .interrupted: return "pause.circle"
        case .cancelling: return "stop.circle"
        }
    }

    private func jobStatusColor(_ status: AnalysisJobStatus) -> Color {
        switch status {
        case .queued, .cancelled: return GatherTheme.secondaryText
        case .running, .cancelling: return GatherTheme.accent
        case .succeeded: return GatherTheme.success
        case .failed: return GatherTheme.error
        case .interrupted: return GatherTheme.warning
        }
    }
}
