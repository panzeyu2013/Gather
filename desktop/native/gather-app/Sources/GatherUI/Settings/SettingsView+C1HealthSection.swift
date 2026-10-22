// desktop/native/gather-app/Sources/GatherUI/Settings/SettingsView+C1HealthSection.swift
// Cut 4 / 4c-2d：Capture One 健康分组——四层预检行、耗时/最近同步时间与写回队列 6 格
//（原 SettingsView.swift 1652-1752 行）。纯搬移：Grid 布局与语义色不变。
import SwiftUI
import GatherProtocol

extension SettingsView {

    // MARK: Capture One 健康

    var c1HealthSection: some View {
        Section(l10n("Capture One 健康")) {
            LabeledContent(l10n("四层连接预检")) {
                Button(viewModel.c1Checking
                       ? l10n("检测中…")
                       : l10n("重新检测")) {
                    Task { await viewModel.checkC1Health() }
                }
                .disabled(viewModel.c1Checking)
            }

            if viewModel.c1HealthError {
                checkLine(
                    l10n("预检失败：无法连接 Capture One 自动化通道"),
                    tone: GatherTheme.error,
                    symbol: "xmark.circle.fill"
                )
            } else if let health = viewModel.c1Health {
                checkRow(zh: l10n("Capture One 可达"), passed: health.reachable)
                checkRow(zh: l10n("Capture One 运行中"), passed: health.appRunning)
                checkRow(zh: l10n("文档已打开"), passed: health.documentOpen)
                checkRow(zh: l10n("自动化权限已授权"), passed: health.automationAuthorized)
            } else {
                Text(l10n("正在检测…"))
                    .foregroundStyle(.secondary)
            }

            LabeledContent(
                l10n("最近一次命令耗时"),
                value: viewModel.c1Health.flatMap { $0.latencyMs }.map { "\($0) ms" } ?? "—"
            )
            LabeledContent(
                l10n("最近同步时间"),
                value: viewModel.lastSyncDate.map { SettingsViewModel.dateText($0, with: l10n) } ?? "—"
            )

            queueGrid
        }
    }

    /// 预检结果行：Label + 语义色 + VoiceOver 值（旧版是 ✓/✗ 字形 + 纯颜色）。
    private func checkRow(zh: String, passed: Bool) -> some View {
        checkLine(
            zh,
            tone: passed ? GatherTheme.success : GatherTheme.error,
            symbol: passed ? "checkmark.circle.fill" : "xmark.circle.fill",
            value: passed ? l10n("通过") : l10n("未通过")
        )
    }

    private func checkLine(_ text: String, tone: Color, symbol: String, value: String? = nil) -> some View {
        Label(text, systemImage: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tone)
            .accessibilityValue(value ?? "")
    }

    /// 写回队列计数：原生 Grid，需要行动的数字用语义色。
    @ViewBuilder
    private var queueGrid: some View {
        if let sync = viewModel.syncStatus {
            Grid(horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    queueCell(l10n("待写入"), sync.pending)
                    queueCell(l10n("写入中"), sync.writing)
                    queueCell(l10n("已写入"), sync.written)
                }
                GridRow {
                    queueCell(l10n("已同步"), sync.synced)
                    queueCell(l10n("失败"), sync.failed, alert: true)
                    queueCell(l10n("冲突"), sync.conflict, alert: true)
                }
            }
            .gridColumnAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if viewModel.syncStateError {
            Text(l10n("同步状态读取失败"))
                .foregroundStyle(.secondary)
        } else if viewModel.syncSessionId == nil {
            Text(l10n("无工作区，写回队列来自当前会话"))
                .foregroundStyle(.secondary)
        } else {
            Text(l10n("读取中"))
                .foregroundStyle(.secondary)
        }
    }

    private func queueCell(_ label: String, _ value: Int, alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value, format: .number)
                .font(.title3.monospacedDigit())
                .foregroundStyle(alert && value > 0 ? GatherTheme.warning : Color.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
