// desktop/native/gather-app/Sources/GatherUI/Library/LibraryCardView.swift
// Cut 4 / 4c-2j：从 LibraryView.swift 移出照片卡（原 789-901 行）。private ->
// internal 以便网格跨文件构造；卡片内容、上下文菜单、无障碍标签与星级文案
// 逐字未动。
import SwiftUI
import AppKit
import GatherProtocol

// MARK: - 照片条目（TS Library card：缩略图 + 文件名 + 星级 + 色标 + 会话）

struct LibraryCardView: View {
    let photo: GlobalPhotoResult
    let onOpen: () -> Void
    /// 「打开所在工作区」：与「打开照片」并列的显式动作（N07）。
    var onOpenSession: () -> Void = {}

    /// Cut 4 / 4b-2d：语言源由外壳经 environment 下发（与页面同一来源），
    /// 卡片与静态文案 helper 不再读进程级语言。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// TS 卡片本体：整项即按钮；不再自绘卡底/描边/悬停阴影，
    /// 缩略图 + 说明文字直接排在窗口底色上（与「照片」App 网格一致）。
    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                thumbnail
                Text(photo.filename)
                    .font(GatherFont.bodyStrong)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                ratingRow
                Text(metadataText)
                    .font(GatherFont.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !photo.keywords.isEmpty {
                    Text(photo.keywords.prefix(4).joined(separator: " · "))
                        .font(GatherFont.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(l10n("打开照片"), action: onOpen)
            Button(l10n("打开所在工作区"), action: onOpenSession)
            if let url = finderURLForPath(photo.filepath) {
                Divider()
                Button(l10n("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        // 按钮自带 .isButton 语义（不再叠加 children: .combine，避免盖掉按钮动作）；
        // 标签取文件名，星级/色标/会话/关键词作为 value 一并读出。
        .accessibilityLabel(photo.filename)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [Self.starText(photo.rating, with: l10n), metadataText]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var metadataText: String {
        l10n.format(
            "%@ · %@",
            photo.label.isEmpty ? l10n("无色标") : photo.label,
            photo.sessionNames.joined(separator: "、")
        )
    }

    private var thumbnail: some View {
        ZStack(alignment: .topTrailing) {
            PhotoThumbnailView(path: photo.filepath, size: 512)
                // 占位/加载中/失败三态同尺寸（防跳动）：固定高 110 并撑满卡宽。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 110)
                .background(GatherTheme.contentBackground)
                .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.thumbnail, style: .continuous))
            if photo.status == "missing" {
                // 角标压在缩略图上：材质底 + 主文字色（不再用红底白字，深色模式对比不足）。
                PhotoOverlayChip(
                    text: l10n("离线"),
                    systemImage: "externaldrive.badge.xmark",
                    iconColor: GatherTheme.error
                )
                .padding(6)
                .help(l10n("离线"))
            }
        }
    }

    /// 星级：品牌 accent 只做强调（自造 hex 星级色已删除）。
    private var ratingRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .imageScale(.small)
                .foregroundStyle(GatherTheme.accent)
                .accessibilityHidden(true)
            Text(Self.starText(photo.rating, with: l10n))
                .font(GatherFont.secondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// TS: rating 星级（★ 重复 + ☆ 补齐）。
    static func starText(_ rating: Double, with l10n: L10n) -> String {
        let count = Int(rating)
        guard count > 0 else { return l10n("未评级") }
        return String(repeating: "★", count: count) + String(repeating: "☆", count: max(0, 5 - count))
    }
}
