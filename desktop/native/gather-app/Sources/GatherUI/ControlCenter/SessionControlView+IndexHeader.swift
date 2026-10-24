// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+IndexHeader.swift
// Cut 4 / 4c-2e：索引进度内容行 + deriveWorkspaceHeaderCopy 推导（原 584-662 行）。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 索引进度（对齐 deriveWorkspaceHeaderCopy；内容行，不是页头）

    @ViewBuilder
    var indexRow: some View {
        if let status = viewModel.workspaceStatus {
            let copy = indexHeaderCopy(status, session: viewModel.session, with: l10n)
            HStack(spacing: 10) {
                switch copy.mode {
                case .scanning:
                    Text(copy.text).font(GatherFont.secondary)
                    if copy.total > 0 {
                        ProgressView(value: Double(copy.done), total: Double(copy.total))
                            .progressViewStyle(.linear)
                        if let percent = copy.percent {
                            Text(indexPercentText(percent, with: l10n))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .error:
                    // 状态色只落在图标上，正文保持系统前景色（彩色正文对比度不足）。
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GatherTheme.error)
                            .accessibilityHidden(true)
                        Text(copy.text).font(GatherFont.secondary)
                    }
                    Button(l10n("重试")) { Task { await viewModel.retryIndex() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(l10n("重新排队索引扫描"))
                case .count:
                    Text(copy.text).font(GatherFont.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// deriveWorkspaceHeaderCopy（workspace-view.ts L289-322）：索引活跃/失败期间
    /// 绝不把阶段计数当权威数据展示；截断导入在索引成功（精确总数落定）前保留 "≥"。
    /// internal（非 private）：IndexProgressTests 直接测纯推导（对齐 index-progress.test.ts）。
    /// Cut 4 / 4b-2f：文案全部按**传入的** l10n 解析（渲染期取 env，测试显式传语言）。
    func indexHeaderCopy(_ status: WorkspaceStatus, session: SessionData?, with l10n: L10n) -> IndexHeaderCopy {
        if status.stage == .created || status.indexing.status == .active {
            if status.indexing.total > 0 {
                return IndexHeaderCopy(
                    mode: .scanning,
                    text: l10n.format("正在索引 %lld / %lld", status.indexing.done, status.indexing.total),
                    // 对齐 index-progress.test.ts：percent 钳制 0...100（防御服务端越界）。
                    percent: min(max(status.indexing.percent, 0), 100),
                    done: status.indexing.done,
                    total: status.indexing.total
                )
            }
            return IndexHeaderCopy(mode: .scanning, text: l10n("扫描中…"), percent: nil, done: 0, total: 0)
        }
        if status.indexing.status == .failed {
            return IndexHeaderCopy(mode: .error, text: l10n("索引失败"), percent: nil, done: 0, total: 0)
        }
        let photoCount = session?.photoCount ?? 0
        if photoCount == 0 {
            return IndexHeaderCopy(mode: .count, text: l10n("暂无照片"), percent: nil, done: 0, total: 0)
        }
        if (session?.truncatedImport ?? false) && status.stage != .indexed {
            return IndexHeaderCopy(mode: .count, text: l10n.format("已索引 ≥%lld 张照片", photoCount), percent: nil, done: 0, total: 0)
        }
        return IndexHeaderCopy(mode: .count, text: l10n.format("已索引 %lld 张照片", photoCount), percent: nil, done: 0, total: 0)
    }

    /// 索引百分比标签：模板 `%lld%%` 里的 `%%` 是**字面百分号**（不是第二个占位符），
    /// 交给 String(format:) 后渲染成单个 `%`（"已索引 98%"）。
    /// internal（非 private）：IndexHeaderCopyTests 直接断言百分号语义。
    func indexPercentText(_ percent: Double, with l10n: L10n) -> String {
        l10n.format("已索引 %lld%%", Int(percent.rounded()))
    }
}
