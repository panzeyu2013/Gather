// desktop/native/gather-app/Sources/GatherUI/Export/ExportView+Preview.swift
// Cut 4 / 4c-2f：导出五段之四（原 ExportView.swift 1084-1150）。
// 纯搬移：计划摘要、空间不足警告、逐项清单与 prefix(8) 截断、空态守卫不变。
import SwiftUI
import Foundation
import GatherProtocol

struct ExportPreviewSection: View {
    let viewModel: ExportViewModel
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        // P1：去抖窗口内旧参数的文件清单不得继续显示（张数摘要行已有同款守卫）。
        if let preview = viewModel.preview, !viewModel.isPlanStale {
            Section(l10n("预览")) {
                LabeledContent(l10n("文件"), value: "\(preview.totalFiles)")
                LabeledContent(l10n("大小"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.totalSizeBytes), countStyle: .file))
                // TS export.tsx:320-325：freeSpaceBytes<0 时隐藏该行且无警告。
                if preview.freeSpaceBytes >= 0 {
                    LabeledContent(l10n("可用空间"), value: ByteCountFormatter.string(fromByteCount: Int64(preview.freeSpaceBytes), countStyle: .file))
                }
                if viewModel.spaceInsufficient {
                    // warning 对比度不足以做正文前景色：改用原生提示条（图标 + 低透明度底色）。
                    NativeBanner(
                        text: l10n("导出文件所需空间超过磁盘可用空间，请更换目标目录"),
                        systemImage: "exclamationmark.triangle.fill",
                        color: GatherTheme.warning
                    )
                }
                // D09：清单描述**输出**（目标名 + 格式 + sidecar），并给出逐项可执行性诊断；
                // 旧实现列的是源文件名 + 源大小，与真正写出的文件无关。
                if preview.sidecarCount > 0 {
                    Text(l10n.format(
                        "将写入 %lld 张照片 + %lld 个 XMP 附属文件，共 %lld 个文件。",
                        preview.photoCount,
                        preview.sidecarCount,
                        preview.physicalFileCount
                    ))
                    .font(.callout)
                }
                if preview.issueCount > 0 {
                    Label(
                        l10n.format("其中 %lld 项存在问题，导出时会失败。", preview.issueCount),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(GatherTheme.warningText)
                }
                ForEach(preview.files.prefix(8), id: \.photoId) { file in
                    HStack(spacing: 6) {
                        Text(file.outputName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if file.includesXmp {
                            Text("+XMP")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let issue = file.issue {
                            Text(l10n.errorText(issue))
                                .font(.caption)
                                .foregroundStyle(GatherTheme.warningText)
                        }
                        Spacer(minLength: 0)
                        Text("\(file.isSizeEstimate ? "≈" : "")" + ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if preview.files.count > 8 {
                    Text(l10n.format("还有 %lld 个文件…", preview.files.count - 8))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
