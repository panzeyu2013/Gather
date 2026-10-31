// desktop/native/gather-app/Sources/GatherUI/Export/DeliveryConfirmSheet.swift
// P2-1：整套交付确认。确认前不执行；确认后执行的是冻结的 OutputRunInput。
import SwiftUI
import GatherProtocol

struct DeliveryConfirmSheet: View {
    let input: OutputRunInput
    let preflight: DeliveryPreflightSummary
    let onConfirm: (OutputRunInput) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// 空间不足或全部配方预检失败时不允许开始交付。
    private var canStart: Bool {
        preflight.hasEnoughSpace && preflight.failedRecipeNames.count < preflight.recipeCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GatherMetrics.Space.m) {
            Text(l10n("开始整套交付？"))
                .font(GatherFont.pageTitle)
            Text(l10n("将按以下配方写入交付目录。确认后不会再弹参数编辑；已有同名文件由配方/导出策略处理。"))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)

            LabeledContent(l10n("目标目录")) {
                Text(input.destinationRoot)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent(l10n("范围")) {
                Text(l10n.resolve(ExportConfirmation.scopeLabel(for: input.scope)))
            }
            if input.scope == .selected {
                LabeledContent(l10n("所选照片")) {
                    Text(l10n.format("%lld 张", input.selectedPhotoIds?.count ?? 0))
                }
            }
            LabeledContent(l10n("配方")) {
                Text(l10n.format("%lld 个", input.recipes.count))
            }
            if input.contactSheet != nil {
                Text(l10n("包含联系表"))
            }
            if input.gallery != nil {
                Text(l10n("包含 Web 画廊与客户校样"))
            }
            LabeledContent(l10n("预计文件")) {
                Text(l10n.format("%lld 个 · %@", preflight.totalFiles, sizeText(preflight.totalSizeBytes)))
            }
            if !preflight.hasEnoughSpace {
                Text(l10n.format(
                    "空间不足：预计需要 %@，可用 %@。",
                    sizeText(preflight.totalSizeBytes), sizeText(preflight.freeSpaceBytes)))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
            }
            if preflight.issueCount > 0 {
                Text(l10n.format(
                    "预检发现 %lld 项源文件问题，确认后可能被跳过。",
                    preflight.issueCount))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
            }
            if !preflight.failedRecipeNames.isEmpty {
                Text(l10n.format(
                    "以下配方预检失败：%@",
                    preflight.failedRecipeNames.joined(separator: "、")))
                    .font(GatherFont.secondary)
                    .foregroundStyle(GatherTheme.errorText)
            }

            Divider()
            HStack(spacing: GatherMetrics.Space.s) {
                Spacer()
                Button(l10n("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .gatherButton(.secondary)
                Button(l10n("开始交付")) {
                    onConfirm(input)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .gatherButton(.primary)
                // P2-1：空间不足或所有配方预检失败时不放行（红字不是拦截）。
                .disabled(!canStart)
            }
        }
        .padding(GatherMetrics.Space.xl)
        .frame(width: 560)
    }
}
