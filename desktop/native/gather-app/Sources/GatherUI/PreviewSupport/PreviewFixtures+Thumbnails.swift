#if DEBUG
import AppKit
import Foundation

// desktop/native/gather-app/Sources/GatherUI/PreviewSupport/PreviewFixtures+Thumbnails.swift
// Cut 4 / 4c-1 Preview 纯色缩略图 seeder 的纯移动拆分（不读盘 / 不写盘）。
// 成员文本与拆分前逐字一致；只在 DEBUG 编译。

// MARK: - 纯色缩略图（不读盘 / 不写盘）

/// 把固定纯色占位图放进进程内 PhotoThumbnailCache，命中页面真实解码路径。
///
/// 为什么不是 ImageDecoderPort：解码成功会触发 ThumbnailDiskCache.store（写盘）。
/// Preview 是只读/静态展示，占位色块已满足要求（任务书 §3 允许 SF Symbol/占位色块）。
@MainActor
enum PreviewThumbnailSeeder {
    private static var seeded = false

    static func seedOnce() {
        guard !seeded else { return }
        seeded = true
        let colors: [NSColor] = [
            .systemTeal, .systemIndigo, .systemOrange, .systemPink,
            .systemGreen, .systemBlue, .systemPurple, .systemYellow,
        ]
        for (index, path) in PreviewData.thumbnailPaths.enumerated() {
            let image = solidImage(colors[index % colors.count])
            for size in [256, 512, 1024, 2048] {
                PhotoThumbnailCache.setImage(
                    image,
                    for: PhotoThumbnailCache.key(path: path, size: size, preview: false)
                )
                PhotoThumbnailCache.setImage(
                    image,
                    for: PhotoThumbnailCache.key(path: path, size: size, preview: true)
                )
            }
            // FaceCropThumbnailView 的键不走 PhotoThumbnailCache.key（无 preview 位）。
            for size in [256, 512] {
                PhotoThumbnailCache.setImage(image, for: "facecrop:\(path)#\(size)")
            }
        }
    }

    private static func solidImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 96, height: 72), flipped: false) { rect in
            color.setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.black.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 18, dy: 14)).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: CGRect(x: 60, y: 46, width: 10, height: 10)).fill()
            return true
        }
    }
}
#endif
