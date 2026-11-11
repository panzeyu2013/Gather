// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataSyncBar.swift
// P1 下一波 §3.1.5：元数据写回的"同步与备份"状态条。
//
// 读数只有一个来源：MetadataAPI.syncState（metadata/template 两个模块合并后的
// 交付计数 + 备份体积 + 逐文件行）。动作只有两个：
// - 确认同步：只在"C1 待重载"（requiresReloadAck && 有 written）时出现，
//   reload 成功后自动确认，按钮随之消失；
// - 结束同步：确认 sheet 写明"删除 N 份备份，XMP 保留"，绝不 restore。
//
// 失败可见：结束后协议返回的 state.notices（XMP_CONFIRM_INCOMPLETE / XMP_FINALIZE_*）
// 逐条展示（第一条 + 其余计数），不是静默 0 条。
//
// 本视图不持有业务状态机、不缓存跨会话数据：切换 sessionId 即重新拉取。
import SwiftUI
import GatherProtocol

struct MetadataSyncBar: View {
    let sessionId: String
    let api: any MetadataAPI

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }
    /// G9：本状态条也要能走 C1 的 reload + 手动 ack 通道。
    ///
    /// 为什么不新开一条旁路：C1 通道属于会话工作区的挑片 VM（组合根把协调器接到
    /// 那上面），同一会话复用它的串行队列与 ack 语义，才不会与自动 reload 打架。
    @Environment(\.sessionWorkspace) private var workspace

    @State private var state: MetadataDeliveryState?
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var showFinalizeConfirm = false
    /// C1 reload/ack 动作的忙碌位（与本状态条自己的 confirm/finalize 分开：
    /// 两种动作的粒度不同，共用一个会更早把按钮禁掉）。
    @State private var isC1ActionBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.xs) {
            HStack(spacing: GatherMetrics.Space.s) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(GatherFont.label)
                    .foregroundStyle(.secondary)
                Text(l10n("同步与备份"))
                    .font(GatherFont.label)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if awaitingReloadAck {
                    Text(l10n("待 C1 重载"))
                        .font(.caption)
                        .foregroundStyle(GatherTheme.warningText)
                }
                if awaitingReloadAck, workspace?.culling != nil {
                    c1ActionButtons
                }
                if awaitingReloadAck {
                    Button(l10n("确认同步")) { Task { await confirm() } }
                        // 与 Face/Similarity 的 C1 结清动作保持同一层级：流程收尾，不是页面主 CTA。
                        .gatherButton(.secondary, size: .small)
                        .disabled(isBusy)
                        .help(l10n("元数据已写盘，但 Capture One 还没加载；在 C1 中执行 Load Metadata 后确认同步"))
                }
                if (state?.synced ?? 0) > 0 {
                    Button(l10n("结束同步")) { showFinalizeConfirm = true }
                        .gatherButton(.destructive, size: .small)
                        .disabled(isBusy)
                        .help(l10n("删除本次写回的备份与交付记录；XMP 文件保留，不会还原"))
                }
                Menu {
                    Button(l10n("立即清理已确认备份"), role: .destructive) {
                        Task { await cleanup() }
                    }
                    .disabled(isBusy)
                } label: {
                    Image(systemName: "trash")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(l10n("删除已确认交付的备份与交付记录；XMP 文件保留"))
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isBusy)
                .help(l10n("刷新同步状态"))
                .accessibilityLabel(l10n("刷新同步状态"))
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(GatherTheme.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resultText {
                Text(resultText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, GatherMetrics.Space.m)
        .padding(.vertical, GatherMetrics.Space.s)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(GatherTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(GatherTheme.hairline, lineWidth: 1)
        )
        .task(id: sessionId) { await refresh() }
        .onReceive(GatherEventChannel.c1SyncStatus.publisher) { event in
            // 写回/确认/收尾都会广播 c1-sync-status：订阅中的会话立即重拉。
            guard event == sessionId else { return }
            Task { await refresh() }
        }
        .confirmationDialog(
            l10n("结束同步？"),
            isPresented: $showFinalizeConfirm,
            titleVisibility: .visible
        ) {
            Button(l10n("结束并删除备份"), role: .destructive) { Task { await finalize() } }
            Button(l10n("取消"), role: .cancel) {}
        } message: {
            Text(l10n.format(
                "将删除 %lld 份备份（%@），XMP 文件保留；其它模块仍在用的共享文件会留到最后一次结束。",
                state?.backupCount ?? 0,
                backupText))
        }
    }

    // MARK: - C1 通道（G9：元数据/模板写回与挑片页一致）

    /// 写盘后让 C1 重载 + 手动 Load 的显式 ack。
    ///
    /// 两个动作都复用挑片 VM 的抛错版本：与自动 reload 同一串行队列，成功/失败
    /// 由本状态条自己上屏（不写挑片页的 notice/errorMessage）。
    @ViewBuilder
    private var c1ActionButtons: some View {
        Button(l10n("在 Capture One 中加载元数据")) { Task { await reloadInCaptureOne() } }
            .gatherButton(.secondary, size: .small)
            .disabled(isBusy || isC1ActionBusy)
            .help(l10n("让 Capture One 重新读取本次写回（对 C1 当前选中的照片生效）"))
        Button(l10n("我已在 Capture One 手动加载元数据")) {
            Task { await acknowledgeManualLoad() }
        }
        .gatherButton(.secondary, size: .small)
        .disabled(isBusy || isC1ActionBusy)
        .help(l10n("在 Capture One 手动执行 Load Metadata 后点击；记录重载确认，解除确认/结束同步的门禁"))
    }

    private func reloadInCaptureOne() async {
        guard let culling = workspace?.culling, !isC1ActionBusy else { return }
        isC1ActionBusy = true
        defer { isC1ActionBusy = false }
        do {
            try await culling.reloadCaptureOneThrowing()
            errorText = nil
            resultText = l10n("Capture One 已重新加载元数据，现在可以确认同步")
            await refresh()
        } catch {
            errorText = c1ErrorText(error)
        }
    }

    private func acknowledgeManualLoad() async {
        guard let culling = workspace?.culling, !isC1ActionBusy else { return }
        isC1ActionBusy = true
        defer { isC1ActionBusy = false }
        do {
            try await culling.acknowledgeManualReloadThrowing()
            errorText = nil
            resultText = l10n("已记录手动加载，可以确认同步")
            await refresh()
        } catch {
            errorText = c1ErrorText(error)
        }
    }

    /// C1 动作错误 → 渲染期文案（VM 已把错误转成 CommandError 载体）。
    private func c1ErrorText(_ error: Error) -> String {
        if let command = error as? CommandError {
            return CommandErrorText.resolve(command, with: l10n)
        }
        return APIErrorPresentation.message(for: error, with: l10n)
    }

    // MARK: - 派生显示

    private var summaryText: String {
        guard let state else { return l10n("读取中…") }
        return l10n.format(
            "待写回 %lld · 待确认 %lld · 可结束 %lld · 备份 %@",
            state.pending,
            state.written,
            state.synced,
            backupText)
    }

    private var backupText: String {
        let bytes = state?.backupBytes ?? 0
        guard bytes > 0 else { return l10n("0 KB") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 只在"C1 待重载"时出现：门禁生效 + 仍有已写盘未确认的行。
    private var awaitingReloadAck: Bool {
        guard let state else { return false }
        return state.requiresReloadAck && state.written > 0
    }

    // MARK: - 动作


    /// 设置页/检查器的“立即清理”：只删已确认交付的备份与行，XMP 保留。
    private func cleanup() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let summary = try await api.cleanupRetention(
                Confirmed(
                    MetadataCleanupInput(sessionId: sessionId, ignoreReloadAck: true),
                    source: .userDialog))
            // #11：清理/确认/结清都改了 deliveries 行（常驻页的计数与胶囊状态都读它），
            // 必须发 .metadata；origin 用本组件名，避免挑片页把自己的写回当外部变更跳过。
            GatherEventCenter.postDomainChange(
                .metadata, sessionId: sessionId, origin: "metadata-sync-bar")
            await refresh()
            errorText = nil
            resultText = l10n.format(
                "已清理 %lld 份备份，保留 %lld，跳过 %lld",
                summary.deleted, summary.retained, summary.skipped)
            if let first = summary.errors.first {
                // 保留层拼的是 "CODE: 参数 reason=…"（参数已过 pathToken 脱敏）。
                // 直接上屏等于把英文码与内部诊断丢给用户：码值走 L10n 码表漏斗
                //（与 CullingViewModel.funnelErrorText / deliveryErrorText 同一口径），
                // 原文只进日志。未登记的 METADATA_RETENTION_* 码会落到通用文案——
                // 那是码表缺条目，不是这里该拼散文的地方（见修复报告待办）。
                errorText = l10n.errorText(first)
                GatherLogger.log(
                    "metadata.cleanup errors: \(summary.errors.joined(separator: " | "))",
                    level: .warn)
            }
        } catch {
            errorText = APIErrorPresentation.message(for: error, with: l10n)
        }
    }

    private func refresh() async {
        do {
            let fetched = try await api.syncState(sessionId)
            state = fetched
            errorText = nil
            // syncState 通常没有 notices；保留展示以防服务端把上一轮失败带回来。
            if let first = fetched.notices.first {
                resultText = noticeText(fetched.notices, first: first)
            }
        } catch {
            errorText = APIErrorPresentation.message(for: error, with: l10n)
        }
    }

    private func confirm() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let updated = try await api.confirmSync(Confirmed(reference, source: .userDialog))
            // #11：清理/确认/结清都改了 deliveries 行（常驻页的计数与胶囊状态都读它），
            // 必须发 .metadata；origin 用本组件名，避免挑片页把自己的写回当外部变更跳过。
            GatherEventCenter.postDomainChange(
                .metadata, sessionId: sessionId, origin: "metadata-sync-bar")
            state = updated
            errorText = nil
            resultText = l10n("已确认同步")
        } catch {
            errorText = APIErrorPresentation.message(for: error, with: l10n)
        }
    }

    private func finalize() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let reference = try SessionReference(sessionId: sessionId)
            let updated = try await api.finalizeSync(Confirmed(reference, source: .userDialog))
            // #11：清理/确认/结清都改了 deliveries 行（常驻页的计数与胶囊状态都读它），
            // 必须发 .metadata；origin 用本组件名，避免挑片页把自己的写回当外部变更跳过。
            GatherEventCenter.postDomainChange(
                .metadata, sessionId: sessionId, origin: "metadata-sync-bar")
            state = updated
            errorText = nil
            if let first = updated.notices.first {
                // 失败/跳过必须逐条可见（§3.1.5），不能显示"成功 0 条"。
                resultText = noticeText(updated.notices, first: first)
            } else if let deleted = updated.finalizedDeleted,
                      let retained = updated.finalizedRetained,
                      let skipped = updated.finalizedSkipped {
                resultText = l10n.format(
                    "已清理 %lld 份交付，保留 %lld，跳过 %lld",
                    deleted, retained, skipped)
            } else if updated.synced == 0 && updated.written == 0 {
                resultText = l10n("已结束同步（XMP 保留）")
            } else {
                resultText = l10n.format(
                    "仍有 %lld 个文件未结束（共享文件或待确认项），稍后可重试。",
                    updated.synced + updated.written)
            }
        } catch {
            errorText = APIErrorPresentation.message(for: error, with: l10n)
        }
    }

    /// notices 逐条可读：第一条 + 其余计数（避免长列表撑爆状态条）。
    private func noticeText(_ notices: [String], first: String) -> String {
        guard notices.count > 1 else { return first }
        return l10n.format("%@（另有 %lld 条）", first, notices.count - 1)
    }
}
