// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Toolbox.swift
// Cut 4 / 4c-2e：分析与索引工具箱（质量分析入口 analyzeQuality），原 1078-1101 行。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 工具箱（原生保留入口）

    var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("分析与索引")).font(.title3.weight(.semibold))
            // 文案只说真实存在的操作（旧版承诺「查看/取消」但界面没有这两个入口）。
            Text(l10n("扫描索引与质量分析会入队后台任务，进度显示在「当前任务」中；失败的任务可重试。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(l10n("扫描索引"), systemImage: "magnifyingglass") { Task { await viewModel.scanIndex() } }
                    .disabled(viewModel.isWorking)
                    .help(l10n("重新扫描工作区，让索引保持最新"))
                Button(l10n("分析质量"), systemImage: "wand.and.stars") { Task { await viewModel.analyzeQuality() } }
                    .disabled(viewModel.isWorking)
                    .help(l10n("为照片计算技术质量评分"))
                Button(l10n("打开挑片")) { onOpenTab(viewModel.sessionId, .culling) }
                    .help(l10n("切换到挑片页面"))
                Button(l10n("打开人脸")) { onOpenTab(viewModel.sessionId, .faceKw) }
                    .help(l10n("切换到人脸关键词页面"))
            }
        }
        .gatherCard()
    }
}
