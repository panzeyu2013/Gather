// desktop/native/gather-app/Sources/GatherUI/ControlCenter/SessionControlView+Sync.swift
// Cut 4 / 4c-2e：元数据同步卡片 + 状态阶梯文案（原 1103-1172 行，逐字搬移）。

import SwiftUI
import GatherProtocol

extension SessionControlView {
    // MARK: 元数据同步（保留计数 + 中文状态说明）

    var syncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("元数据同步")).font(GatherFont.sectionTitle)
            if let sync = viewModel.syncStatus {
                HStack(spacing: 16) {
                    syncCount(l10n("待处理"), sync.pending)
                    syncCount(l10n("写入中"), sync.writing)
                    syncCount(l10n("已写入"), sync.written)
                    syncCount(l10n("失败"), sync.failed, emphasized: sync.failed > 0)
                    syncCount(l10n("冲突"), sync.conflict, emphasized: sync.conflict > 0)
                    Spacer()
                }
                // 状态色只落在图标上；正文保持系统前景色（彩色正文对比度不足）。
                HStack(spacing: 6) {
                    // 只有「全部确认」才是绿色勾；待写入/写入中/待 C1 读取都是进行中
                    //（黄色），与胶囊的四色调映射一致（F08）。
                    if sync.failed + sync.conflict > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(GatherTheme.error)
                            .accessibilityHidden(true)
                    } else if sync.pending + sync.writing + sync.written > 0 {
                        Image(systemName: "clock")
                            .foregroundStyle(GatherTheme.warning)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(GatherTheme.success)
                            .accessibilityHidden(true)
                    }
                    Text(syncStatusText(sync, with: l10n)).font(GatherFont.secondary)
                }
            } else {
                Text(l10n("暂无同步状态")).font(GatherFont.secondary).foregroundStyle(.secondary)
            }
        }
        .gatherCard()
    }

    private func syncCount(_ title: String, _ value: Int, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(GatherFont.labelRegular).foregroundStyle(.secondary)
            Text("\(value)")
                .font(GatherFont.bodyStrong.monospacedDigit())
                .monospacedDigit()
                .foregroundStyle(emphasized ? GatherTheme.errorText : GatherTheme.primaryText)
        }
        .accessibilityElement(children: .combine)
    }

    /// 同步状态文案（F08）：与 C1 状态胶囊同一套阶梯，同一屏不再出现互相矛盾的结论。
    ///
    /// 阶梯：待写入 → Gather 正在写入 → 已写入待读取（等 C1 读取）→ 已同步。
    /// 旧实现只看 failed/conflict/pending/writing，written > 0（Gather 已写入但
    /// Capture One 还没读回）时正文已经说「元数据已全部同步」，而同一屏顶部的
    /// 胶囊写着「已写入待读取 1」。
    /// internal（非 private）：SyncStatusCopyTests 直测状态阶梯。
    /// Cut 4 / 4b-2f：状态句按传入的 l10n 解析（测试显式传语言）。
    func syncStatusText(_ sync: MetadataSyncSummary, with l10n: L10n) -> String {
        if sync.conflict > 0 { return l10n("存在 XMP 冲突，请先裁决") }
        if sync.failed > 0 { return l10n("有写入失败项，请先重试") }
        if sync.writing > 0 { return l10n("Gather 正在写入 XMP…") }
        if sync.pending > 0 {
            return l10n.format("待写入 %lld 项：Gather 尚未写入 XMP", sync.pending)
        }
        if sync.written > 0 { return l10n("已写入待读取：等待 Capture One 读取元数据") }
        if sync.synced > 0 { return l10n("已同步：Capture One 已读取") }
        return l10n("没有待同步的元数据")
    }
}
