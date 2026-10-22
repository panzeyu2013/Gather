// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityView+Writeback.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出写回面板与确认准备（原 244-254、
// 453-629 行）：关键词输入 / 预览 / XMP 写回预览明细 / 写回报告与三按钮门控。
// 纯搬移：设置 pending 的状态写回点、按钮禁用条件、提示文案逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

extension SimilarityView {

    /// 先准备预览（无预览自动生成），再弹出带真实影响范围的确认框。
    private func requestWritebackConfirmation() async {
        guard let preview = await viewModel.prepareWritebackConfirmation(), !preview.items.isEmpty else { return }
        pendingWriteback = PendingSimilarityWriteback(
            groupCount: viewModel.selectedGroupIds.count,
            affectedPhotos: preview.affectedPhotos,
            itemCount: preview.items.count,
            keywords: viewModel.parsedWritebackKeywords,
            samplePath: preview.items.first?.xmpPath
        )
    }

    // MARK: 写回面板（TS KeywordWritebackPanel + WritebackReport + c1-sync-controls）

    var writebackPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n("分组关键字写回"))
                    .font(.headline)
                Spacer(minLength: 0)
                // 计数属于内容语义 → .callout（旧版 10pt footnote）。
                Text(l10n.format("已选 %lld 组", viewModel.selectedGroupIds.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(l10n("选择相似分组，关键词会合并写入每张照片旁的 .xmp 文件，不修改原图。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent(l10n("关键词")) {
                TextField(
                    l10n("输入关键词，多个关键词用逗号分隔"),
                    text: $viewModel.writebackKeywords
                )
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 400)
                .accessibilityLabel(l10n("关键词"))
                .onSubmit {
                    Task { await viewModel.previewKeywordWriteback() }
                }
            }
            HStack(spacing: 12) {
                Button(l10n("预览")) {
                    Task { await viewModel.previewKeywordWriteback() }
                }
                .disabled(!viewModel.canPreviewWriteback)
                // 写回：busy 时禁用并显示处理中文案。
                Button(viewModel.isSyncBusy ? l10n("处理中…") : l10n("写入 XMP")) {
                    Task { await requestWritebackConfirmation() }
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canPreviewWriteback)
            }
            Text(l10n("写入后在 Capture One 中选择这些照片，执行「图像 → 加载元数据」；确认关键词已进入目录后，再点击「确认同步」和「清理」。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let notice = viewModel.notice {
                Text(notice.resolve(with: l10n))
                    .font(.callout)
            }
            if let preview = viewModel.writebackPreview {
                writebackPreviewList(preview)
            } else if viewModel.result != nil {
                Text(l10n("选择分组并生成预览后才可以写回。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let result = viewModel.writebackResult {
                writebackReport(result)
            }
        }
        .gatherCard()
    }

    /// 写回预览明细（TS writebackPreview：before→after 关键词、新建/更新、
    /// 共享数、外部冲突、来源；超过 50 条计数提示）。
    private func writebackPreviewList(_ preview: WritebackPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n("XMP 写回预览"))
                .font(.subheadline.weight(.semibold))
            Text(l10n.format("预览完成：%lld 张照片将合并这些关键词。", preview.affectedPhotos))
                .font(.callout)
            VStack(spacing: 0) {
                ForEach(preview.items.prefix(SimilarityViewModel.previewItemLimit), id: \.xmpPath) { item in
                    writebackPreviewRow(item)
                    Divider()
                }
                if preview.items.count > SimilarityViewModel.previewItemLimit {
                    Text(l10n.format("另有 %lld 项未展开", preview.items.count - SimilarityViewModel.previewItemLimit))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func writebackPreviewRow(_ item: WritebackItem) -> some View {
        let preview = item.preview
        let before = preview?.before.keywords ?? []
        let after = preview?.after.keywords ?? item.keywords
        return VStack(alignment: .leading, spacing: 4) {
            // 文件名是内容语义 → .callout（旧版 10pt footnote）。
            Text(URL(fileURLWithPath: item.xmpPath).lastPathComponent)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .help(item.xmpPath)
                .textSelection(.enabled)
            Text("\(writebackKeywordsText(before)) → \(writebackKeywordsText(after))")
                .font(.callout)
                .lineLimit(1)
                .textSelection(.enabled)
            HStack(spacing: 0) {
                Text(preview?.willCreate == true ? l10n("新建 XMP") : l10n("更新 XMP"))
                if (preview?.sharedPhotoCount ?? 1) > 1 {
                    Text(l10n.format(" · %lld 张共享", preview?.sharedPhotoCount ?? 1))
                }
                if preview?.externalChanged == true {
                    Text(l10n(" · 检测到外部冲突"))
                }
                Text(l10n(" · 来源：相似组"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func writebackKeywordsText(_ keywords: [String]) -> String {
        keywords.isEmpty ? l10n("无关键词") : keywords.joined(separator: "、")
    }

    /// 写回结果（TS WritebackReport：三色统计卡 + 失败项列表 + 门控操作行）。
    private func writebackReport(_ result: WritebackResult) -> some View {
        let controls = viewModel.syncControls
        return VStack(alignment: .leading, spacing: 10) {
            // 同步状态文案（TS syncStatusCopy）。
            Text(l10n.format("同步状态：%@", l10n.resolve(controls.statusText)))
                .font(.callout)
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
            HStack(spacing: 12) {
                if !result.failedItems.isEmpty {
                    Button(l10n("重试失败项")) {
                        pendingRetry = PendingSimilarityRetry(
                            paths: result.failedItems.map { $0.xmpPath.isEmpty ? $0.photoPath : $0.xmpPath }
                        )
                    }
                    .disabled(viewModel.isSyncBusy)
                }
                // 确认同步：仅 c1Read + 已写入 + ack（或 safeToCleanup）可用。
                Button(l10n("确认同步")) {
                    pendingConfirmSync = PendingSimilarityConfirmSync()
                }
                .disabled(viewModel.isSyncBusy || !controls.canConfirmSync)
                .help(controls.confirmHint.map { l10n.resolve($0) } ?? "")
                // 清理：仅 safeToCleanup 可用。
                Button(l10n("清理"), role: .destructive) {
                    pendingCleanup = PendingSimilarityCleanup(writtenCount: viewModel.syncView?.written ?? 0)
                }
                .disabled(viewModel.isSyncBusy || !controls.canCleanup)
                .help(controls.cleanupHint.map { l10n.resolve($0) } ?? "")
            }
            // 两步流第一步：加载元数据（TS reloadRow + loadHint）。
            HStack(spacing: 12) {
                Button(l10n("在 Capture One 中加载元数据")) {
                    Task { await viewModel.loadMetadataInCaptureOne() }
                }
                .disabled(viewModel.isSyncBusy || !controls.canLoadMetadata)
                .help(controls.loadHint.map { l10n.resolve($0) } ?? "")
                Text(controls.canLoadMetadata
                    ? l10n("先在 Capture One 中 Load Metadata，再返回 Gather 确认同步")
                    : (controls.loadHint.map { l10n.resolve($0) } ?? ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

}
