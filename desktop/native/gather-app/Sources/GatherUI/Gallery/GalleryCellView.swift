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
                        chip(
                            text: l10n("离线"),
                            icon: "exclamationmark.triangle.fill",
                            iconColor: GatherTheme.error
                        )
                    }
                    if photo.variantCount > 1 {
                        chip(text: l10n.format("RAW+JPEG · %lld", photo.variantCount))
                    }
                }
                Text(photo.filename)
                    .font(.callout)
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
                                .init(color: .black.opacity(0.55), location: 0.45),
                                .init(color: .black.opacity(0.82), location: 1),
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
        // TS: 单元格圆角 10（--radius-sm）；选中态 = 系统选中色描边
        //（旧版 .cellSelected outline 2px inset，无填充底色）。
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color(nsColor: .selectedContentBackgroundColor)
                        : (isHovered ? GatherTheme.accent.opacity(0.55) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        // TS: .cell:hover —— box-shadow 0 3px 14px rgba(0,0,0,.45) + brightness(1.05)
        // 的原生等价：shadowMd（radius 9 / y 3）+ 缩略图亮度 0.03。
        .shadow(color: isHovered ? GatherTheme.shadowMd : Color.clear, radius: 9, y: 3)
        .onHover { isHovered = $0 }
    }

    /// 照片上的信息芯片：自带深色底 + 白字（不依赖照片亮度，也不会白压亮色）。
    private func chip(text: String, icon: String? = nil, iconColor: Color = .white) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
            }
            Text(text)
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.66)))
    }

    /// 选中勾：系统选中色 + 选中文字色（旧版为主色圆 + 白勾，深色下 ≈2.7:1）。
    private var selectionCheck: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(
                Color(nsColor: .alternateSelectedControlTextColor),
                Color(nsColor: .selectedContentBackgroundColor)
            )
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityHidden(true)
    }
}
