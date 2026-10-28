// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Inbox.swift
// Cut 4 / 4c-2e：Action Inbox 卡片 + deriveInboxItems 推导（原 778-932 行）。
// MAX_FAILED_JOB_ROWS 随卡片一起搬出（SessionControlView+Jobs 跨文件复用）。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    /// TS: MAX_FAILED_JOB_ROWS —— 失败任务最多显示 3 行。
    static let maxFailedJobRows = 3

    // MARK: Action Inbox（对齐 deriveInboxItems：固定优先级序列表）

    var inboxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l10n("待处理事项")).font(GatherFont.sectionTitle)
                Text(l10n("按优先级排序")).font(GatherFont.labelRegular).foregroundStyle(.secondary)
            }
            if let status = viewModel.workspaceStatus {
                let items = inboxItems(
                    status,
                    truncatedImport: viewModel.session?.truncatedImport ?? false,
                    with: l10n
                ).filter { $0.kind != .scanIncomplete }
                if items.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(GatherTheme.success)
                            .accessibilityHidden(true)
                        Text(l10n("全部正常")).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        inboxRow(item)
                    }
                }
            }
        }
        .gatherCard()
    }

    private func inboxRow(_ item: InboxItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            let icon = inboxIcon(item.kind)
            Image(systemName: icon.name).foregroundStyle(icon.color).frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                if let detail = item.detail {
                    // 错误明细是内容语义：用 .callout 而不是 .footnote。
                    Text(detail).font(GatherFont.secondary).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(item.actionLabel) { perform(item.action) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    /// deriveInboxItems（workspace-view.ts L70-169）：7 类固定优先级聚合，
    /// 失败任务最多 3 行；错误码仅展示可翻译文案，原始诊断不落 UI。
    /// Cut 4 / 4b-2f：文案按传入的 l10n 解析（含 jobTypeLabel 的类型名）。
    func inboxItems(_ status: WorkspaceStatus, truncatedImport: Bool, with l10n: L10n) -> [InboxItem] {
        var items: [InboxItem] = []
        let truncatedImport = truncatedImport

        let indexingActive = status.stage == .created || status.indexing.status == .active
        let scanIncomplete = indexingActive
            || status.indexing.status == .failed
            || (truncatedImport && status.stage == .imported)
        if scanIncomplete {
            items.append(InboxItem(
                id: "scan_incomplete", kind: .scanIncomplete,
                label: l10n("索引未完成，照片数量暂不精确"), detail: nil,
                actionLabel: l10n("查看进度"), action: .showStages
            ))
        }

        if status.xmp.conflict > 0 {
            items.append(InboxItem(
                id: "xmp_conflict", kind: .xmpConflict,
                label: l10n.format("%lld 个 XMP 冲突待裁决", status.xmp.conflict), detail: nil,
                actionLabel: l10n("逐条裁决"), action: .reviewXmpConflicts
            ))
        }

        if !status.staleAnalyses.isEmpty {
            let faceOnly = status.staleAnalyses.allSatisfy { $0.kind == .face }
            let names = status.staleAnalyses
                .map { $0.kind == .similarity ? l10n("相似度") : l10n("人脸") }
                .joined(separator: "、")
            items.append(InboxItem(
                id: "analysis_stale", kind: .analysisStale,
                label: l10n.format("%@分析已过期，新增照片未参与分析", names), detail: nil,
                actionLabel: l10n("重新分析"),
                // D10：人脸过期要直达**分析步骤**（旧实现只切页，用户还得自己找入口）；
                // 相似度过期仍走相似度页（其分析入口就在页首）。
                action: faceOnly ? .reviewStaleAnalysis : .navigateSimilarity
            ))
        }

        if status.xmp.pending > 0 {
            items.append(InboxItem(
                id: "xmp_pending", kind: .xmpPending,
                label: l10n.format("%lld 个 XMP 待写入", status.xmp.pending), detail: nil,
                actionLabel: l10n("检查"), action: .navigateTab(.culling)
            ))
        }

        if status.offlinePhotos > 0 {
            items.append(InboxItem(
                id: "offline_photos", kind: .offlinePhotos,
                label: l10n.format("%lld 张照片离线（源文件不可读）", status.offlinePhotos), detail: nil,
                actionLabel: l10n("查看"), action: .reviewOfflinePhotos
            ))
        }

        for (index, job) in status.failedJobs.prefix(Self.maxFailedJobRows).enumerated() {
            // 错误码不在翻译表时 detail 置 nil 不渲染（对齐 TS L148-150：
            // 原始诊断不落 UI 文案）。
            // 明细在 job.message，不在 job.code 里：只传码会把 {{detail}} 插成空串
            // （控制中心显示「…失败（）」，而同一任务的 JobRowView 用 jobErrorMessage 是对的）。
            // 注意：JobService 落库的 message 本身就是「CODE: 散文」，重复拼接会把英文码
            // 印两遍，所以先判 message 是否已以码开头。
            let raw: String
            if job.message.isEmpty {
                raw = job.code
            } else if job.message.hasPrefix(job.code) {
                raw = job.message
            } else {
                raw = job.code + ": " + job.message
            }
            let detail = l10n.resolvedTemplate(for: raw)
            items.append(InboxItem(
                id: "job_failed-\(index)", kind: .jobFailed,
                label: l10n.format("%@任务失败", Self.jobTypeLabel(job.type, with: l10n)), detail: detail,
                actionLabel: l10n("重试"), action: .retryJob(job.id)
            ))
        }

        if status.softFlags.culled && !status.softFlags.exported {
            items.append(InboxItem(
                id: "export_pending", kind: .exportPending,
                label: l10n("已挑片但尚未导出"), detail: nil,
                actionLabel: l10n("去导出"), action: .navigateTab(.export)
            ))
        }

        return items
    }

    /// JOB_TYPE_KEYS（workspace-view.ts L43-53）：未知类型回退原始字符串。
    private static func jobTypeLabel(_ type: String, with l10n: L10n) -> String {
        switch type {
        case "metadata.scan": l10n("索引")
        case "similarity.analyze": l10n("相似度分析")
        case "fkw.analyze", "face.analyze": l10n("人脸分析")
        case "dup.scan", "duplicate.scan": l10n("重复扫描")
        case "output.run": l10n("导出")
        case "quality.analyze", "quality.score": l10n("技术分析")
        case "navigation.analyze": l10n("导航分析")
        case "culling.writeback": l10n("挑片写回")
        case "sim.writeback": l10n("相似组写回")
        default: type
        }
    }

    private func inboxIcon(_ kind: InboxKind) -> (name: String, color: Color) {
        switch kind {
        case .scanIncomplete: return ("magnifyingglass", GatherTheme.accent)
        case .xmpConflict: return ("exclamationmark.triangle.fill", GatherTheme.error)
        case .analysisStale: return ("clock.arrow.circlepath", GatherTheme.warning)
        case .xmpPending: return ("arrow.up.doc", GatherTheme.accent)
        case .offlinePhotos: return ("photo", .secondary)
        case .jobFailed: return ("xmark.circle.fill", GatherTheme.error)
        case .exportPending: return ("square.and.arrow.up", GatherTheme.accent)
        }
    }
}