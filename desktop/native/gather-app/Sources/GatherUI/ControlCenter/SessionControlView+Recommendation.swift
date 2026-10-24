// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Recommendation.swift
// Cut 4 / 4c-2e：推荐下一步卡片 + deriveRecommendedNextView（原 934-1038 行）。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 推荐下一步（对齐 deriveRecommendedNextView）

    /// 推荐下一步只在**不与「待处理事项」重复**时渲染（F07）。
    ///
    /// 旧实现让「待处理事项 · 已挑片但尚未导出」和「推荐下一步 · 导出成品」
    /// 同时出现，两张卡都在说「去导出」；XMP 冲突、分析过期、失败任务同样成对
    /// 出现。同一动作只保留优先级列表里的那一行，推荐卡专注它独有的建议
    ///（例如「开始挑片」）。
    private func isDuplicateRecommendation(_ next: RecommendedNextView, status: WorkspaceStatus) -> Bool {
        // action == nil（一切正常）时也不重复渲染：inbox 已经给出「全部正常」。
        guard let action = next.action else { return true }
        let inbox = inboxItems(
            status,
            truncatedImport: viewModel.session?.truncatedImport ?? false,
            with: l10n
        ).filter { $0.kind != .scanIncomplete }
        return inbox.contains { $0.action == action }
    }

    @ViewBuilder
    var recommendationCard: some View {
        Group {
            if let status = viewModel.workspaceStatus {
                let view = recommendedNextView(status)
                if !isDuplicateRecommendation(view, status: status) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb").foregroundStyle(GatherTheme.warning)
                            .accessibilityHidden(true)
                        Text(l10n("推荐下一步")).font(GatherFont.sectionTitle)
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(view.title).font(.callout.weight(.semibold))
                            Text(view.detail).font(GatherFont.secondary).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let action = view.action {
                            Button(view.actionLabel) { perform(action) }
                                .gatherPrimaryActionButton().controlSize(.small)
                        }
                    }
                }
                }
            }
        }
        .gatherCard()
    }

    /// deriveRecommendedNextView（workspace-view.ts L210-276）：6 种 action 映射为
    /// 中文标题/详情/按钮文案；未知 action 兜底为 done（一切正常）而非裸枚举字符串
    /// （对齐 TS L273-274 return done）。
    private func recommendedNextView(_ status: WorkspaceStatus) -> RecommendedNextView {
        guard let next = status.recommendedNext else {
            return RecommendedNextView(
                title: l10n("一切正常"), detail: l10n("工作区状态良好，无待办事项"),
                actionLabel: "", action: nil
            )
        }
        switch next.action {
        case "scan_incomplete":
            return RecommendedNextView(
                title: l10n("等待索引完成"), detail: l10n("后台索引正在进行，完成后照片数量将精确显示"),
                actionLabel: l10n("查看进度"), action: .showStages
            )
        case "resolve_conflicts":
            // G-1（审计 5）：推荐动作必须与待办**同一个枚举**，否则
            // isDuplicateRecommendation 的「动作相等」判据失效 → 同屏两张同义卡，
            // 两个按钮都叫「逐条裁决」，一个带筛选一个不带（D10 + F07 的合流回归）。
            return RecommendedNextView(
                title: l10n("裁决 XMP 冲突"), detail: l10n("冲突会阻塞写回同步，先逐条裁决再继续"),
                actionLabel: l10n("逐条裁决"), action: .reviewXmpConflicts
            )
        case "re_analyze":
            let faceOnly = status.staleAnalyses.allSatisfy { $0.kind == .face }
            return RecommendedNextView(
                // 标题按真实落点生成：人脸过期时点的是「重新分析人脸」，
                // 旧实现标题写死「重新分析相似度」而动作却去人脸页。
                title: faceOnly ? l10n("重新分析人脸") : l10n("重新分析相似度"),
                detail: l10n("新增照片未参与分组，重新分析可合并剩余重复项"),
                actionLabel: l10n("重新分析"),
                action: faceOnly ? .reviewStaleAnalysis : .navigateSimilarity
            )
        case "retry_jobs":
            return RecommendedNextView(
                title: l10n("重试失败任务"), detail: l10n("存在失败的后台任务，先重试再继续"),
                actionLabel: l10n("重试失败任务"), action: .retryFailedJobs
            )
        case "start_culling":
            return RecommendedNextView(
                title: l10n("开始挑片"), detail: l10n("工作区已就绪，从挑片开始整理"),
                actionLabel: l10n("去挑片"), action: .navigateTab(.culling)
            )
        case "export":
            return RecommendedNextView(
                title: l10n("导出成品"), detail: l10n("挑片已完成，导出最终成品"),
                actionLabel: l10n("去导出"), action: .navigateTab(.export)
            )
        default:
            return RecommendedNextView(
                title: l10n("一切正常"), detail: l10n("工作区状态良好，无待办事项"),
                actionLabel: "", action: nil
            )
        }
    }
}
