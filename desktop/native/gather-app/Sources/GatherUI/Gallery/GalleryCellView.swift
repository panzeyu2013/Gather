// desktop/native/gather-app/Sources/GatherUI/Gallery/GalleryCellView.swift
// Cut 4 / 4c-2c：网格单元（缩略图 + 文件名 + 变体徽标 + 选中勾），原 GalleryView.swift
// 825-938 行逐字搬移；语言源仍从 environment 取。
import SwiftUI
import GatherProtocol

// MARK: - 网格单元（TS GalleryThumbnail：缩略图 + 文件名 + 变体徽标 + 选中勾）

struct GalleryCellView: View {
    let photo: GalleryPhotoData
    let isSelected: Bool
    var thumbnailSize: Int

    /// Cut 4 / 4b-2i：离线芯片 / RAW+JPEG 变体徽标与页面同一语言源
    ///（格子是独立 struct，必须自己从 environment 取；兜底 zhCN 与页面一致）。
    @Environment(\.languageStore) private var languageStore
    private var l10n: L10n { languageStore?.l10n ?? L10n(language: .zhCN) }

    /// TS: .cell:hover —— 悬停投影 + 提亮；选中态由系统选中色承担。
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoThumbnailView(path: photo.filepath, size: thumbnailSize)
                // 占位尺寸固定（防解码完成前后跳动）：始终撑满单元格。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .brightness(isHovered ? 0.03 : 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if photo.status == "missing" {
                        PhotoOverlayChip(
                            text: l10n("离线"),
                            systemImage: "exclamationmark.triangle.fill",
                            iconColor: GatherTheme.error
                        )
                    }
                    if photo.variantCount > 1 {
                        PhotoOverlayChip(text: l10n.format("RAW+JPEG · %lld", photo.variantCount))
                    }
                }
                Text(photo.filename)
                    .font(GatherFont.secondary)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        // 照片底部渐变遮罩（照片查看器的标准做法）。
                        // 旧版渐变只覆盖文字自身的 ~28pt 高度，文字实际落在
                        // 约 35% 黑上，遇到亮照片读不出来；这里加高遮罩并提高
                        // 底部不透明度，保证任何底图上的可读性。
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.45), location: 0.45),
                                .init(color: .black.opacity(0.72), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                selectionCheck
            }
        }
        // 照片单元：统一卡片圆角；选中用品牌色描边，hover 用 hairline。
        .clipShape(RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GatherTheme.Radius.card, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? GatherTheme.selection
                        : (isHovered ? GatherTheme.hairline : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        // 悬停：抬起一层，与选中描边区分。
        .shadow(color: isHovered ? GatherTheme.shadowCard : Color.clear, radius: 8, y: 2)
        .onHover { isHovered = $0 }
    }

    /// 选中勾：品牌选中色 + 白勾。
    private var selectionCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, GatherTheme.selection)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityHidden(true)
    }
}
