// desktop/native/gather-app/Sources/GatherApp/Support/PhotoThumbnailView.swift
// 3.2/3.3 共享缩略图视图：gather-image:// scheme 的 SwiftUI 等价物。
// TS 源: desktop/src/renderer/api/image.ts thumbnailUrl(path, size)
// 差异说明：WKWebView 的 <img src="gather-image://thumbnail?path=&size=">
// 由 GatherImageSchemeHandler 直出 JPEG；SwiftUI 的 AsyncImage 走 URLSession，
// 不支持自定义 scheme，故同进程直连 RAWDecoder（语义等价：库内路径 →
// 解码 JPEG → NSImage，失败显示占位符）。NSCache 做进程内内存缓存。
import SwiftUI
import AppKit
import GatherCore

/// 按需加载的缩略图（对齐 TS GalleryThumbnail 的 IntersectionObserver 懒加载：
/// SwiftUI 惰性容器只会实例化可见行的视图，onAppear 即触发加载）。
public struct PhotoThumbnailView: View {
    let path: String
    var size: Int
    var placeholderSize: CGSize?
    /// true 时走 gather-image://preview 语义（getPreview，大图预览）。
    var preview: Bool

    @State private var image: NSImage?
    @State private var failed = false
    @State private var loading = false

    public init(path: String, size: Int = 512, placeholderSize: CGSize? = nil, preview: Bool = false) {
        self.path = path
        self.size = size
        self.placeholderSize = placeholderSize
        self.preview = preview
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                // TS: thumbError —— 感叹号 + 文件名。
                ZStack {
                    Rectangle().fill(Color(nsColor: .controlBackgroundColor))
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            } else {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if loading {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: placeholderSize?.width, height: placeholderSize?.height)
        .task(id: path) {
            await load()
        }
    }

    private func load() async {
        failed = false
        if let cached = PhotoThumbnailCache.image(for: cacheKey) {
            image = cached
            return
        }
        loading = true
        defer { loading = false }
        do {
            let decoded: RAWDecodeResult
            if preview {
                decoded = try RAWDecoder.getPreview(path: path, maxDimension: size)
            } else {
                decoded = try RAWDecoder.getThumbnail(path: path, size: size)
            }
            guard let nsImage = NSImage(data: decoded.buffer) else {
                failed = true
                return
            }
            PhotoThumbnailCache.setImage(nsImage, for: cacheKey)
            image = nsImage
        } catch {
            failed = true
        }
    }

    private var cacheKey: String {
        "\(preview ? "preview" : "thumb"):\(path)#\(size)"
    }
}

/// 缩略图加载缓存（进程内，键 = 模式 + path + size）。
public enum PhotoThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static let lock = NSLock()

    public static func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key as NSString)
    }

    public static func setImage(_ image: NSImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(image, forKey: key as NSString)
    }
}
