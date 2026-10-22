// desktop/native/gather-app/Sources/GatherUI/Dashboard/SessionRowView.swift
// Cut 4 / 4c-2i：自 DashboardView.swift 原样移出（工作区行；原 423-595 行）。
// 行为/布局/文案不变：身份列 + 状态徽标 + 计数/冲突/离线 + 创建时间 + 行内动作。
import SwiftUI
import GatherProtocol

// MARK: - 工作区行（原生 List 行）

struct SessionRowView: View {
    let session: SessionData
    /// 4b-2e：卡片计数是延迟本地化文本（VM 只存模板 + 参数，渲染期解析）。
    let photoCountLabel: LocalizedText
    let status: WorkspaceStatus?
    let scanJob: DashboardScanJob?
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onRetryScan: () -> Void

    /// Cut 4 / 4b-1：日期 locale 跟随当前界面语言（渲染期解析，不读进程全局）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// TS 卡片布局：.cardOpen 是整卡按钮（flex:1 内容区），.cardActions 是
    /// 右侧独立按钮组（stopPropagation）——SwiftUI 用 List(selection:) 承载
    /// 选中（⌘/⇧ 原生多选），「进入」按钮与菜单承载动作，不再自绘复选框。
    var body: some View {
        HStack(spacing: 12) {
            identity
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(l10n("打开"), action: onOpen)
            Button(l10n("删除"), role: .destructive, action: onDelete)
        }
    }

    /// 名称 + 状态徽标 + 计数/冲突/离线 + 创建时间。
    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(session.name)
                    .font(.headline)
                    .lineLimit(1)
                statusBadge
            }
            metadataRow
            Text(Self.dateText(session.createdAt, with: l10n))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.name)
        .accessibilityValue(accessibilityValue)
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            Text(photoCountLabel.resolve(with: l10n))
                .font(.callout)
            if let status {
                if status.xmp.pending > 0 {
                    statusPill(
                        l10n.format("待同步写回 %lld", status.xmp.pending),
                        systemImage: "arrow.up.doc",
                        color: GatherTheme.warning
                    )
                }
                if status.xmp.conflict > 0 {
                    statusPill(
                        l10n.format("冲突 %lld", status.xmp.conflict),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.error
                    )
                }
                if !status.failedJobs.isEmpty {
                    statusPill(
                        l10n.plural("失败任务 %lld", count: status.failedJobs.count),
                        systemImage: "xmark.octagon.fill",
                        color: GatherTheme.error
                    )
                }
                if status.offlinePhotos > 0 {
                    Text(l10n.format("离线 %lld", status.offlinePhotos))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }

    /// 状态信号 = 语义色图标 + 低透明度底色；正文保持系统主文字色
    /// （GatherTheme.warning 对比度不足，绝不作为正文前景色）。
    private func statusPill(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }

    private var accessibilityValue: String {
        var parts = [photoCountLabel.resolve(with: l10n)]
        if let status {
            if status.xmp.pending > 0 {
                parts.append(l10n.format("待同步写回 %lld", status.xmp.pending))
            }
            if status.xmp.conflict > 0 {
                parts.append(l10n.format("冲突 %lld", status.xmp.conflict))
            }
            if !status.failedJobs.isEmpty {
                parts.append(l10n.plural("失败任务 %lld", count: status.failedJobs.count))
            }
            if status.offlinePhotos > 0 {
                parts.append(l10n.format("离线 %lld", status.offlinePhotos))
            }
        }
        parts.append(Self.dateText(session.createdAt, with: l10n))
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            // TS retryScan：索引失败行显示「重试」，重新入队 metadata.scan。
            if deriveCardIndexKind(scanJob) == .failed {
                Button(l10n("重试"), action: onRetryScan)
                    .buttonStyle(.bordered)
                    .help(l10n.format("重试 %@", session.name))
            }
            Button(l10n("进入"), action: onOpen)
                .buttonStyle(.bordered)
                .help(l10n.format("打开 %@", session.name))
            Menu {
                Button(l10n("删除"), role: .destructive, action: onDelete)
            } label: {
                Label(l10n("操作"), systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help(l10n("操作"))
        }
    }

    /// TS Badge 状态色（取值已换成系统语义色）。
    private var statusBadge: GatherBadge {
        switch session.status {
        case .draft:
            return .draft(with: l10n)
        case .photosLoaded:
            return .photosLoaded(with: l10n)
        case .analyzing:
            return .running(l10n("分析中"))
        case .review:
            return .review(with: l10n)
        case .completed:
            return .done(l10n("已完成"))
        }
    }

    /// TS Dashboard formatDate（toLocaleDateString：跟随应用语言；
    /// zh 环境输出 2026年8月12日 14:30）。
    private static func dateText(_ iso: String, with l10n: L10n) -> String {
        // C-8（性能审计）：不再每次新建 DateFormatter（每行 2 次 ⇒ 6 个/行/次重绘），
        // 改为进程内缓存实例；**输出与旧实现逐字节一致**（FormatStyle 在 zh 下
        // 会把 09:46 写成 9:46，属展示回归，已放弃该方案）。
        guard let date = parseISO8601Date(iso) else { return iso }
        return DisplayDateFormatters.shared.mediumShort(date, locale: l10n.locale)
    }
}
