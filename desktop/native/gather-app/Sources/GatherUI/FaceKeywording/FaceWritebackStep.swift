// desktop/native/gather-app/Sources/GatherUI/FaceKeywording/FaceWritebackStep.swift
// Cut 4 / 4c-2b：Step 3 写回（原 1832-2063 行）+ 写回确认准备（原 1180-1190 行）。
import SwiftUI
import GatherProtocol

extension FaceKeywordingView {
    /// 先准备预览（无预览自动生成），再弹出带真实影响范围的确认框。
    private func requestWritebackConfirmation() async {
        guard await viewModel.prepareWritebackConfirmation(),
              let preview = viewModel.preview else { return }
        pendingWriteback = PendingFaceWriteback(
            clusterCount: viewModel.boundClusters.count,
            affectedPhotos: preview.affectedPhotos,
            itemCount: preview.items.count,
            samplePath: preview.items.first?.xmpPath
        )
    }

    // MARK: - Step 3 写回（TS StepWriteback）

    var stepWriteback: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n("关键字写回")).font(GatherFont.sectionTitle)
            writebackStats
            boundPreview
            if viewModel.preview != nil { xmpPreview }
            HStack(spacing: 9) {
                Button(l10n("生成预览"), systemImage: "eye") { Task { await viewModel.previewWriteback() } }
                    .disabled(!viewModel.analysisDone)
                    .help(l10n("列出将写入的 XMP 项，不写盘"))
                // 确认写回：分析完成后恒可用；无预览时自动补一次预览再写回
                // （TS handleExecute，StepWriteback.tsx:53-69, 195-203）。
                Button(l10n("确认写回"), systemImage: "square.and.arrow.down") {
                    Task { await requestWritebackConfirmation() }
                }
                .gatherPrimaryActionButton()
                .disabled(!viewModel.canWriteback)
                .help(l10n("确认后写入 XMP 附属文件；不修改原始照片"))
            }
            if !viewModel.analysisDone {
                // 前置条件写在可见文案里：.help 在禁用按钮上不会显示。
                Label(l10n("请先完成人脸分析，才能生成预览并写回。"), systemImage: "info.circle")
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
            if let result = viewModel.writebackResult {
                resultSection(result)
            } else if viewModel.preview != nil {
                // TS StepWriteback.tsx:205-226：预览生成后即显示操作行
                // （重试失败项 / C1 重新加载 / 确认同步 / 清理），
                // 写回报告统计卡仅在有写回结果后出现。
                reportActionsRow
                    .gatherCard()
            }
        }
    }

    /// TS stats：**写回前的影响范围**用内联统计文本（.plain，系统文本样式），
    /// 不再是三张与「写回结果」同权重的大数字卡；warning 不再充当数字前景色。
    private var writebackStats: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            GatherStatCard(value: viewModel.boundClusters.count, label: l10n("已绑定簇"), style: .plain)
            GatherStatCard(value: viewModel.totalAffected, label: l10n("受影响照片"), style: .plain)
            GatherStatCard(value: viewModel.unboundClusters.count, label: l10n("未绑定并跳过"), style: .plain)
            Spacer(minLength: 0)
        }
    }

    /// TS preview 面板：绑定簇预览（roleName + keywords + 前 5 文件名）。
    /// 用共享分组容器；不再嵌套第二个滚动区（页面本身可滚动）。
    @ViewBuilder
    private var boundPreview: some View {
        if viewModel.boundClusters.isEmpty {
            Text(l10n("暂无已绑定簇，请先在审核步骤绑定角色。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .gatherCard()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.boundClusters.enumerated()), id: \.element.id) { index, cluster in
                    boundPreviewRow(cluster)
                    if index < viewModel.boundClusters.count - 1 { Divider() }
                }
            }
            .gatherCard()
        }
    }

    private func boundPreviewRow(_ cluster: FaceClusterData) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(cluster.binding?.roleName ?? "")
                    .font(.body.weight(.semibold))
                GatherBadge(l10n.format("%lld 个人脸样本", cluster.size))
                if let keywords = cluster.binding?.keywords, !keywords.isEmpty {
                    Text(keywords.joined(separator: ", "))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ForEach(cluster.members.prefix(5), id: \.memberId) { member in
                Text(member.filename)
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if cluster.members.count > 5 {
                Text(l10n.format("还有 %lld 名成员", cluster.members.count - 5))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// TS xmpPreview：前 50 行三行明细（文件名 / before→after / 标记行），
    /// max-height 240 滚动。
    @ViewBuilder
    private var xmpPreview: some View {
        if let preview = viewModel.preview {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.format("XMP 写回预览 · 共 %lld 项 · %lld 张照片受影响", preview.totalCount, preview.affectedPhotos))
                    .font(GatherFont.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(preview.items.prefix(50), id: \.xmpPath) { item in
                            xmpPreviewRow(item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 240)
                .gatherCard(cornerRadius: GatherTheme.Radius.panel)
                if preview.items.count > 50 {
                    Text(l10n.format("还有 %lld 项…", preview.items.count - 50))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func xmpPreviewRow(_ item: WritebackItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(xmpKeywordsText(item.preview?.before.keywords)) → \(xmpKeywordsText(item.preview?.after.keywords ?? item.keywords))")
                .font(GatherFont.secondary)
                .lineLimit(2)
                .foregroundStyle(.secondary)
                // 截断的差异需要出口：完整路径留在 tooltip，文本可选中复制。
                .textSelection(.enabled)
                .help(item.xmpPath)
            Text(xmpMarkerText(item))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(l10n.format("XMP 写回项 %@", URL(fileURLWithPath: item.xmpPath).lastPathComponent))
    }

    private func xmpMarkerText(_ item: WritebackItem) -> String {
        var parts: [String] = []
        if let preview = item.preview {
            parts.append(preview.willCreate ? l10n("新建 XMP") : l10n("更新 XMP"))
            if preview.sharedPhotoCount > 1 { parts.append(l10n.format("%lld 张共享", preview.sharedPhotoCount)) }
            if preview.externalChanged { parts.append(l10n("检测到外部冲突")) }
        }
        parts.append(l10n("来源：人脸关键词"))
        return parts.joined(separator: " · ")
    }

    private func xmpKeywordsText(_ keywords: [String]?) -> String {
        let joined = (keywords ?? []).joined(separator: "、")
        return joined.isEmpty ? l10n("无关键词") : joined
    }

    /// TS WritebackReport：已写入/失败/已跳过三色统计卡 + 失败项明细 +
    /// 重试/确认同步/清理 + reload 行。
    private func resultSection(_ result: WritebackResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("写回报告")).font(GatherFont.cardTitle)
            WritebackReportCard(
                written: result.written,
                failed: result.failed,
                skipped: result.skipped,
                failedItems: result.failedItems.map { item in
                    WritebackFailureItem(
                        id: item.xmpPath,
                        path: item.photoPath.isEmpty ? item.xmpPath : item.photoPath,
                        message: item.errorMessage
                    )
                }
            )
            reportActionsRow
        }
        .gatherCard()
    }

    /// TS WritebackReport actions（StepWriteback.tsx:205-226）：预览生成后即
    /// 可见，无需等待写回结果。重试失败项仅在存在失败项时显示；清理备份
    /// 仅在确认同步后显示（旧版 onCleanup = syncConfirmed ? handleCleanup
    /// : undefined，WritebackReport.tsx:86-95）。help 只描述动作本身，
    /// 前置条件写在可见文案里（.help 在禁用按钮上不会显示）。
    private var reportActionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let result = viewModel.writebackResult, !result.failedItems.isEmpty {
                    Button(l10n("重试失败项")) {
                        pendingRetry = PendingFaceRetry(
                            paths: result.failedItems.map { $0.xmpPath.isEmpty ? $0.photoPath : $0.xmpPath }
                        )
                    }
                    .disabled(viewModel.isWritingBack)
                    .help(l10n.format("重新写入 %lld 个失败项", result.failedItems.count))
                }
                Button(l10n("Capture One 重新加载")) { Task { await viewModel.reloadCaptureOne() } }
                    .disabled(viewModel.isWritingBack)
                    .help(l10n("让 Capture One 重新读取已写入的元数据"))
                Button(l10n("确认同步")) { pendingConfirmSync = PendingFaceConfirmSync() }
                    .disabled(viewModel.isWritingBack)
                    .help(l10n("结清本次写回，之后才可清理备份"))
                if viewModel.isSyncConfirmed {
                    Button(role: .destructive) {
                        pendingCleanup = PendingFaceCleanup(writtenCount: viewModel.writebackResult?.written ?? 0)
                    } label: {
                        Text(l10n("清理备份"))
                    }
                    .disabled(viewModel.isWritingBack)
                    .help(l10n("删除本次写回生成的 XMP 备份文件"))
                }
            }
            if !viewModel.isSyncConfirmed {
                Text(l10n("「清理备份」会在确认同步后开放。"))
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
