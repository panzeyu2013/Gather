// desktop/native/gather-app/Sources/GatherUI/Similarity/SimilarityMemberCellView.swift
// Cut 4 / 4c-2h：从 SimilarityView.swift 移出成员单元格（原 944-1004 行，
// private -> internal）。纯搬移：92pt 缩略图、文件名、hover、单击打开、
// 右键菜单与无障碍合并逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 成员单元格（TS memberItem：92pt 方形缩略图 + 文件名 + hover）

struct SimilarityMemberCellView: View {
    let path: String
    /// 打开这张照片（第三轮审计 E）：成员原先只有「在 Finder 中显示」，
    /// 看得见却打不开——用户要自己回图库再找一遍。
    var onOpenPhoto: ((String) -> Void)? = nil

    private static let thumbSize = 92.0

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Cut 4 / 4b-2c：上下文菜单文案同样在渲染期按下发语言解析。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    var body: some View {
        VStack(spacing: 2) {
            PhotoThumbnailView(
                path: path,
                size: 256,
                placeholderSize: CGSize(width: Self.thumbSize, height: Self.thumbSize)
            )
            .frame(width: Self.thumbSize, height: Self.thumbSize)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // 文件名是内容语义 → .callout（旧版 10pt footnote）。
            Text((path as NSString).lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            // 单击即打开（与「关联照片」网格、全局图库卡片一致）。
            onOpenPhoto?(path)
        }
        .contextMenu {
            if onOpenPhoto != nil {
                Button(l10n("查看照片")) { onOpenPhoto?(path) }
                Divider()
            }
            if let url = finderURLForPath(path) {
                Button(l10n("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .help((path as NSString).lastPathComponent)
        .accessibilityElement(children: .combine)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
