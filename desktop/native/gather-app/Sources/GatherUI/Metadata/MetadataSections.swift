// desktop/native/gather-app/Sources/GatherUI/Metadata/MetadataSections.swift
// P1 / A3：只读元数据面板（拍摄参数 / IPTC Core / IPTC Extension / 文件），
// 三处 inspector 共用。
//
// 数据来源：PhotoMetadataDetail（缓存投影，不触发磁盘解析）。视图只做排版，
// 所有格式化规则在 MetadataDisplay（直测）。
// IPTC 两组都显示全部字段（未填写显示 "—"）：这是"全字段面板"，不是"已填摘要"。
import SwiftUI
import GatherProtocol

struct MetadataSections: View {
    /// nil = 尚未加载（面板显示占位而不是空表）。
    let detail: PhotoMetadataDetail?
    /// 多选时的资产数（>1 时面板顶部提示"仅显示主文件"）。
    var selectionCount: Int = 1

    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        if let detail {
            GatherInspectorSection(l10n("拍摄参数")) {
                rows(MetadataDisplay.exifRows(detail.exif, l10n: { l10n($0) }))
            }
            GatherInspectorSection(l10n("IPTC Core")) {
                iptcGroup(MetadataDisplay.iptcCoreFields, detail.descriptive)
            }
            GatherInspectorSection(l10n("IPTC Extension")) {
                iptcGroup(MetadataDisplay.iptcExtensionFields, detail.descriptive)
            }
            GatherInspectorSection(l10n("文件")) {
                VStack(alignment: .leading, spacing: 4) {
                    row(l10n("文件名"), detail.filename)
                    row(l10n("路径"), detail.filepath)
                    // 内嵌模式下「写目标」是照片本身：显示成侧车会让用户以为没写进去。
                    row(l10n(detail.xmpPath == detail.filepath ? "写入目标" : "侧车"),
                        detail.hasXMP ? detail.xmpPath : l10n("无（尚未写入 XMP）"))
                    if selectionCount > 1 {
                        Text(l10n("已选多张，仅显示主文件"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            GatherInspectorSection(l10n("拍摄参数")) {
                Text(l10n("尚未选择照片"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 一组 IPTC 字段：顶部显示已填数，下面逐字段（空值显示占位符）。
    private func iptcGroup(_ fields: [DescriptiveField], _ descriptive: DescriptiveMetadata) -> some View {
        let rows = MetadataDisplay.fieldRows(fields, descriptive, l10n: { l10n($0) })
        let filled = rows.filter(\.isFilled).count
        return VStack(alignment: .leading, spacing: 4) {
            Text(l10n.format("%lld / %lld 已填写", filled, fields.count))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.label) { metadataRow($0) }
        }
    }

    private func rows(_ rows: [MetadataDisplayRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                Text(l10n("尚未解析"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.label) { metadataRow($0) }
            }
        }
    }

    private func metadataRow(_ item: MetadataDisplayRow) -> some View {
        row(item.label, item.isFilled ? item.value : l10n("尚未填写"))
            .opacity(item.isFilled ? 1 : 0.55)
    }

    /// 标签列固定宽度 + 值列可选中（元数据要能复制到别处）。
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
