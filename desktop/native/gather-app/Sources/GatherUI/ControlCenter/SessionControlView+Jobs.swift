// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Jobs.swift
// Cut 4 / 4c-2e：当前任务卡片（活跃 / 需处理 / 已完成历史折叠），原 1174-1209 行。
// 任务行叶子 View 见 SessionControlJobRow.swift。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 当前任务（本地化状态/类型/进度文案）

    /// 当前任务（F07）：只列活跃任务与失败/中断任务；已完成历史默认折叠。
    /// 没有活跃任务时只给一行说明，不再用大卡片承载一段历史。
    var jobsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("当前任务")).font(GatherFont.sectionTitle)
            if viewModel.activeJobs.isEmpty && viewModel.attentionJobs.isEmpty {
                Text(l10n("没有进行中的任务。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.activeJobs, id: \.id) { job in
                    SessionControlJobRow(job: job, l10n: l10n, onRetry: { viewModel.retry(job) })
                }
                // 失败任务最多 3 行（TS MAX_FAILED_JOB_ROWS 语义），其余在历史里。
                ForEach(Array(viewModel.attentionJobs.prefix(Self.maxFailedJobRows)), id: \.id) { job in
                    SessionControlJobRow(job: job, l10n: l10n, onRetry: { viewModel.retry(job) })
                }
            }
            if !viewModel.historyJobs.isEmpty {
                DisclosureGroup(isExpanded: $showJobHistory) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.historyJobs, id: \.id) { job in
                            SessionControlJobRow(job: job, l10n: l10n, onRetry: { viewModel.retry(job) })
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(l10n.plural("已完成任务（%lld）", count: viewModel.historyJobs.count))
                        .font(GatherFont.secondary)
                }
            }
        }
        .gatherCard()
    }
}
