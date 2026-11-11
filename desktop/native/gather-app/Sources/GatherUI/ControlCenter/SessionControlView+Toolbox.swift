// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Toolbox.swift
// Cut 4 / 4c-2e：分析与索引工具箱（质量分析入口 analyzeQuality），原 1078-1101 行。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 工具箱（原生保留入口）

    var actionCard: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("分析与索引")).font(.title3.weight(.semibold))
            // 文案只说真实存在的操作（旧版承诺「查看/取消」但界面没有这两个入口）。
            Text(l10n("扫描索引与质量分析会入队后台任务，进度显示在「当前任务」中；失败的任务可重试。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: GatherMetrics.Space.s) {
                Button(l10n("扫描索引"), systemImage: "magnifyingglass") { Task { await viewModel.scanIndex() } }
                    .gatherButton(.secondary)
                    .disabled(viewModel.isWorking || viewModel.session?.sourcePath.isEmpty != false)
                    .help(viewModel.session?.sourcePath.isEmpty != false
                          ? l10n("请先设置工作区根目录")
                          : l10n("重新扫描工作区，让索引保持最新"))
                Button(l10n("分析质量"), systemImage: "wand.and.stars") { Task { await viewModel.analyzeQuality() } }
                    .gatherButton(.secondary)
                    .disabled(viewModel.isWorking)
                    .help(l10n("为照片计算技术质量评分"))
                Button(l10n("打开挑片")) { navigator?.open(.culling, in: viewModel.sessionId) }
                    .gatherButton(.tertiary)
                    .help(l10n("切换到挑片页面"))
                Button(l10n("打开人脸")) { navigator?.open(.faceKw, in: viewModel.sessionId) }
                    .gatherButton(.tertiary)
                    .help(l10n("切换到人脸关键词页面"))
            }
            // Wave5 batch2（E1/E2）：AI 初审的可见状态（未启用/等待扫描/生成中/
            // 已生成 N 条/待人脸分析/跳过或未完成原因）。状态由 Host 写入 store。
            Divider()
            AITriageStatusRow(sessionId: viewModel.sessionId)
            // Wave3（task-24）：目录包导出/导入 + 外部 XMP 迁移。
            // 成功后的 .library 广播走 VM（发布点登记在 SessionControlViewModel.swift）。
            MigrationCenterCard(
                sessionId: viewModel.sessionId,
                notifyLibraryChanged: { viewModel.postMigrationLibraryChange() }
            )
        }
        .gatherCard()
    }
}


/// AI 初审状态行（Wave5 batch2 / E1+E2）。
///
/// 只读 `AITriageStatusStore`（Host 侧 AITriageImportTrigger 写）：
/// - 导入后没有 entry 的会话整行隐藏（不硬编码"未启用"误导老会话）；
/// - 失败/跳过/超时都必须可见，不能只留在日志里。
struct AITriageStatusRow: View {
    let sessionId: String
    @State private var store = AITriageStatusStore.shared
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        if let phase = store.phase(sessionId: sessionId) {
            HStack(alignment: .firstTextBaseline, spacing: GatherMetrics.Space.xs) {
                Image(systemName: icon(phase))
                    .font(GatherFont.secondary)
                    .foregroundStyle(tint(phase))
                    .accessibilityHidden(true)
                Text(text(phase))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func icon(_ phase: AITriageStatusStore.Phase) -> String {
        switch phase {
        case .notEnabled: return "sparkles"
        case .waitingIndex, .waitingQuality: return "hourglass"
        case .waitingFace: return "person.crop.circle.badge.exclamationmark"
        case .generating: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .skipped, .stopped: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ phase: AITriageStatusStore.Phase) -> Color {
        switch phase {
        case .notEnabled, .skipped: return GatherTheme.secondaryText
        case .waitingIndex, .waitingQuality, .waitingFace, .stopped:
            return GatherTheme.warningText
        case .generating: return GatherTheme.infoText
        case .done: return GatherTheme.successText
        case .failed: return GatherTheme.errorText
        }
    }

    private func text(_ phase: AITriageStatusStore.Phase) -> String {
        switch phase {
        case .notEnabled:
            return l10n("AI 初审：未启用（可在设置中开启）")
        case .waitingIndex:
            return l10n("AI 初审：等待扫描")
        case .waitingQuality:
            return l10n("AI 初审：质量分析中")
        case .waitingFace:
            return l10n("AI 初审：待人脸分析（本次先按无脸信号生成）")
        case .generating:
            return l10n("AI 初审：生成建议中")
        case .done(let keep, let reject, let review):
            return l10n.format(
                "AI 初审：已生成 %lld 条建议（保留 %lld · 淘汰 %lld · 待复核 %lld）",
                Int64(keep + reject + review), Int64(keep), Int64(reject), Int64(review))
        case .skipped(let reason):
            return l10n.format("AI 初审：已跳过（%@）", reasonText(reason))
        case .stopped(let reason):
            return l10n.format("AI 初审：未完成（%@）", reasonText(reason))
        case .failed(let reason):
            return l10n.format("AI 初审：失败（%@）", reasonText(reason))
        }
    }

    /// 诊断串 → 可读原因。字面量与 `AITriageStopReason`（GatherApplication）同一口径；
    /// GatherUI 不能 import 领域层，故在此保留唯一一份 UI 映射（新增 reason 时成对改）。
    private func reasonText(_ raw: String) -> String {
        switch raw {
        case "quality-timeout":
            return l10n("质量分析仍在后台继续，可稍后刷新")
        case "index-timeout":
            return l10n("等待索引超时，可稍后在挑片页生成")
        case "index-not-succeeded":
            return l10n("索引未成功")
        case "quality-enqueue-failed":
            return l10n("质量分析未能入队")
        case "quality-failed":
            return l10n("质量分析失败")
        case "quality-cancelled", "quality-interrupted":
            return l10n("质量分析被中止")
        case "cancelled":
            return l10n("已取消")
        case "triage-disabled":
            return l10n("建议功能未开启")
        default:
            return raw
        }
    }
}
