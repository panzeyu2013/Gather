// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Stages.swift
// Cut 4 / 4c-2e：三硬阶段进度条 + deriveStageMarks 推导（原 664-776 行）。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 三硬阶段进度条（对齐 deriveStageMarks + index.tsx stageBar）

    var stagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("阶段进度")).font(.title3.weight(.semibold))
            if let status = viewModel.workspaceStatus {
                stageTrack(stageMarks(status.stage, with: l10n))
                if status.softFlags.culled || status.softFlags.exported {
                    HStack(spacing: 8) {
                        if status.softFlags.culled { GatherBadge(l10n("已挑片"), tone: .accent) }
                        if status.softFlags.exported { GatherBadge(l10n("已导出"), tone: .accent) }
                    }
                }
            }
        }
        .gatherCard()
    }

    /// 阶段标记（internal：WorkspaceStageMarksTests 直测 deriveStageMarks）。
    struct StageMark: Identifiable, Equatable {
        let id: String
        let label: String
        let reached: Bool
        let current: Bool
    }

    /// deriveStageMarks（workspace-view.ts L187-199）：created 窗口（一跳化导入后
    /// 0 张照片）时高亮第一个硬阶段；未达阶段以实线描边标记呈现。
    /// Cut 4 / 4b-2f：标签按传入的 l10n 解析（测试显式传语言，不走 .zhCN 兜底）。
    func stageMarks(_ stage: WorkspaceStage, with l10n: L10n) -> [StageMark] {
        let order = ["imported", "indexed", "analyzed"]
        let labels: [String: String] = [
            "imported": l10n("已导入"),
            "indexed": l10n("已索引"),
            "analyzed": l10n("已分析"),
        ]
        let reachedIndex = stage == .created ? -1 : (order.firstIndex(of: stage.rawValue) ?? -1)
        return order.enumerated().map { index, id in
            StageMark(
                id: id,
                label: labels[id] ?? id,
                reached: index <= reachedIndex,
                current: stage == .created ? index == 0 : index == reachedIndex
            )
        }
    }

    /// 三阶段轨迹：等宽列 + 列内左右两段连接线，圆点与连接线共用同一垂直中心。
    /// 旧实现把连接线放在列之间并各占 `maxWidth: .infinity`，连接线被拉伸后
    /// 圆点位置取决于相邻标题宽度，标题与圆点必然错位；等宽列 + 列内线段
    /// 让三个圆点等距、线段与圆点中心严格对齐（也去掉了手绘底色/发光）。
    private func stageTrack(_ marks: [StageMark]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                VStack(spacing: 6) {
                    ZStack {
                        HStack(spacing: 0) {
                            connectorSegment(filled: mark.reached, hidden: index == 0)
                            Color.clear.frame(width: stageDotDiameter)
                            connectorSegment(
                                filled: marks.indices.contains(index + 1) ? marks[index + 1].reached : false,
                                hidden: index == marks.count - 1
                            )
                        }
                        stageDot(mark)
                    }
                    Text(mark.label)
                        .font(.callout)
                        .fontWeight(mark.current ? .semibold : .regular)
                        .foregroundStyle(mark.reached || mark.current ? GatherTheme.primaryText : GatherTheme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityValue(stageAccessibilityValue(mark))
            }
        }
        .padding(.vertical, 2)
    }

    private var stageDotDiameter: CGFloat { 20 }

    private func connectorSegment(filled: Bool, hidden: Bool) -> some View {
        Capsule()
            .fill(filled ? GatherTheme.accent : GatherTheme.separator)
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .opacity(hidden ? 0 : 1)
    }

    private func stageDot(_ mark: StageMark) -> some View {
        Group {
            if mark.reached {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(GatherTheme.success)
            } else if mark.current {
                Image(systemName: "circle.inset.filled")
                    .foregroundStyle(GatherTheme.accent)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(GatherTheme.secondaryText)
            }
        }
        .font(.title3)
        .frame(width: stageDotDiameter, height: stageDotDiameter)
        .accessibilityHidden(true)
    }

    private func stageAccessibilityValue(_ mark: StageMark) -> String {
        if mark.reached { return l10n("已完成") }
        if mark.current { return l10n("进行中") }
        return l10n("未开始")
    }
}
