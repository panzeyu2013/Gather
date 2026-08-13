// desktop/native/gather-app/Sources/GatherApp/Support/PhotoThumbnailView.swift
// 3.2/3.3 共享缩略图视图：原生 RAWDecoder 的 SwiftUI 适配。
// TS 源: desktop/src/renderer/api/image.ts thumbnailUrl(path, size)
// 页面同进程直连 RAWDecoder（库内路径 → 解码 JPEG → NSImage，失败显示占位符）。
// NSCache 做进程内内存缓存。
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
    /// 图片适配模式：默认 .fill（封面裁切，用于缩略图网格）；查看器传 .fit
    /// （整图可见，对齐旧版 object-fit: contain 的查看器交互语义）。
    var contentMode: ContentMode

    @State private var image: NSImage?
    @State private var failed = false
    @State private var loading = false

    public init(path: String, size: Int = 512, placeholderSize: CGSize? = nil, preview: Bool = false, contentMode: ContentMode = .fill) {
        self.path = path
        self.size = size
        self.placeholderSize = placeholderSize
        self.preview = preview
        self.contentMode = contentMode
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                // TS: thumbError —— 感叹号 + 文件名。
                ZStack {
                    Rectangle().fill(GatherTheme.backgroundSecondary)
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            } else {
                Rectangle()
                    .fill(GatherTheme.backgroundSecondary)
                    .overlay {
                        if loading {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: placeholderSize?.width, height: placeholderSize?.height)
        .task(id: cacheKey) {
            await load()
        }
    }

    private func load() async {
        // 任务启动时的 key：写回前与当前属性比对，丢弃过期任务的解码结果。
        let key = cacheKey
        if let cached = PhotoThumbnailCache.image(for: key) {
            image = cached
            failed = false
            return
        }
        // cacheKey 已变（复用单元格/列表回收）：清掉旧图，避免闪烁错图。
        image = nil
        failed = false
        loading = true
        // RAW 解码（100-800ms）移出主线程：RAWDecoder 为无状态静态方法，
        // 可安全在后台调用；完成后回主线程设置 image。
        let path = path
        let size = size
        let preview = preview
        do {
            let data = try await Task.detached(priority: .utility) {
                try PhotoThumbnailDecoder.decode(path: path, size: size, preview: preview)
            }.value
            // Task.detached 不继承取消：key 已变时丢弃旧结果（短暂错图修复）。
            guard key == cacheKey else { return }
            guard let nsImage = NSImage(data: data) else {
                failed = true
                loading = false
                return
            }
            PhotoThumbnailCache.setImage(nsImage, for: key)
            image = nsImage
        } catch {
            // 过期任务的失败同样不应污染新 key 的状态。
            guard key == cacheKey else { return }
            failed = true
        }
        loading = false
    }

    private var cacheKey: String {
        "\(preview ? "preview" : "thumb"):\(path)#\(size)"
    }
}

/// 后台解码闸门：并发上限 4（对齐 TS thumbnail_concurrency 默认值）。
/// 解码在线程池执行，信号量钳制并发；NSCache 读写由 PhotoThumbnailCache 加锁。
public enum PhotoThumbnailDecoder {
    private static let semaphore = DispatchSemaphore(value: 4)

    public static func decode(path: String, size: Int, preview: Bool) throws -> Data {
        semaphore.wait()
        defer { semaphore.signal() }
        let decoded: RAWDecodeResult
        if preview {
            decoded = try RAWDecoder.getPreview(path: path, maxDimension: size)
        } else {
            decoded = try RAWDecoder.getThumbnail(path: path, size: size)
        }
        return decoded.buffer
    }
}

/// 缩略图加载缓存（进程内，键 = 模式 + path + size）。
public enum PhotoThumbnailCache {
    /// 审计 P1-性能：2048px preview ≈16MB/张，浏览 1 万张可致 GB 级内存。
    /// 按解码尺寸计入 cost：256 桶 ≈1MB、1024 ≈4MB、2048 ≈16MB（粗估
    /// NSImage 位深/缩放开销），全缓存上限 512MB 后按 LRU 淘汰。
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 512 * 1024 * 1024
        return cache
    }()
    private static let lock = NSLock()

    public static func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key as NSString)
    }

    public static func setImage(_ image: NSImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        let size = image.size.width * image.size.height
        // 粗估：RGBA 4B/像素 + 20% 元数据开销；小图下限 256KB 防过度淘汰。
        let cost = max(256 * 1024, Int(size * 4 * 1.2))
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
