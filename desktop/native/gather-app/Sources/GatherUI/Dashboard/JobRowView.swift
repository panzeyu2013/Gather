// desktop/native/gather-app/Sources/GatherUI/Dashboard/JobRowView.swift
// Cut 4 / 4c-2i：自 DashboardView.swift 原样移出（任务行；原 597-718 行）。
// 行为/布局/文案不变：full/compact 两态、状态徽标、进度条、行内动作。
import SwiftUI
import GatherProtocol

// MARK: - 任务行（TS Jobs 页统一行格式：身份列 + 状态徽标 + 进度条 + 操作）

struct JobRowView: View {
    let job: AnalysisJobData
    var compact = false
    /// 工作区显示名（空串 = 未知；旧实现显示 scopeId 前 8 位 UUID，已删除）。
    var scopeName: String = ""
    let onCancel: () -> Void
    let onRetry: () -> Void

    /// Cut 4 / 4b-1：错误/相位文案在渲染期按当前语言解析。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .padding(.vertical, 2)
    }

    /// 非 compact 行：TS Jobs.module.css .row 四列（身份 flexible≥180 /
    /// 状态 90 / 进度 flexible / 操作 80）。身份列改弹性下限：窄窗口收缩、
    /// 宽窗口舒展，英文类型文案不截断。
    private var fullBody: some View {
        HStack(spacing: 16) {
            identityColumn
                .frame(minWidth: 180, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
            statusBadge
                .frame(width: 90, alignment: .leading)
            progressBar
                .frame(maxWidth: .infinity)
            actions
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// compact 行：TS .rowCompact 两列（身份 flexible + 状态 100），无进度无操作。
    private var compactBody: some View {
        HStack(spacing: 16) {
            identityColumn
            Spacer(minLength: 0)
            statusBadge
                .frame(width: 100, alignment: .trailing)
        }
    }

    /// TS .identity 列：类型 strong +「工作区 · 名称」+「尝试 N 次」+ 错误。
    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.typeLabel(job.type, with: l10n))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(scopeText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !compact {
                Text(l10n.format("尝试 %lld 次", job.attemptCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !job.errorMessage.isEmpty {
                // 错误码经漏斗翻译；tooltip 同样不直显原始诊断（细节只进日志）。
                Text(l10n.jobErrorMessage(job.errorMessage))
                    .font(.callout)
                    .foregroundStyle(GatherTheme.error)
                    .lineLimit(1)
                    .help(l10n.jobErrorMessage(job.errorMessage))
            }
        }
    }

    private var scopeText: String {
        scopeName.isEmpty
            ? l10n("工作区")
            : l10n.format("工作区 · %@", scopeName)
    }

    /// 状态：GatherBadge 主题语义色编码（成功/失败/警告/信息/主色）。
    private var statusBadge: some View {
        GatherBadge(status: job.status, l10n: l10n)
    }

    /// 进度：原生 ProgressView（GatherProgressBar 内部已换系统控件），
    /// 标签文案仍在条上方显示 百分比 + 相位（pct = round(current/total)）。
    private var progressBar: some View {
        GatherProgressBar(
            fraction: Double(DashboardViewModel.progressPercent(of: job)) / 100,
            fill: GatherTheme.accent,
            label: "\(DashboardViewModel.progressPercent(of: job))% \(l10n.progressPhaseText(job.progressMessage))",
            accessibilityText: Self.typeLabel(job.type, with: l10n)
        )
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if job.status == .queued || job.status == .running {
                Button(l10n("取消"), action: onCancel)
            }
            if job.status == .failed || job.status == .interrupted || job.status == .cancelled {
                Button(l10n("重试"), action: onRetry)
            }
        }
    }

    /// TS JOB_TYPE_KEYS（jobs.type.* 中文键值）。
    static func typeLabel(_ type: AnalysisJobType, with l10n: L10n) -> String {
        switch type {
        case .metadataScan: return l10n("照片索引与元数据")
        case .checksumBackfill: return l10n("文件校验和补全")
        case .similarityAnalyze: return l10n("相似照片分析")
        case .faceAnalyze: return l10n("人脸分析")
        case .duplicateScan: return l10n("重复照片扫描")
        case .qualityScore: return l10n("技术质量分析")
        case .exportExecute: return l10n("照片导出")
        case .thumbnailBuild: return l10n("缩略图生成")
        }
    }
}
