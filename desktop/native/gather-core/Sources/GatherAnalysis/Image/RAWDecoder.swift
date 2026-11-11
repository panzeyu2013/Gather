// desktop/native/gather-core/Sources/GatherAnalysis/Image/RAWDecoder.swift
// Phase 2 任务 2.1 剩余（macOS 专属）：CoreImage/ImageIO 解码管线，
// 替代 sharp-decoder.ts（libvips）+ sips-decoder.ts（AppleScript sips）。
//
// TS 源：
//   desktop/src/main/services/image/decoders/sharp-decoder.ts
//   desktop/src/main/services/image/decoders/sips-decoder.ts
//
// 迁移方式：重写（仅保留能力契约）。行为对齐点：
//   - supports(ext)：覆盖 sharp.supportedExtensions + sips.rawExtensions 全集；
//   - getDimensions：ImageIO properties 读 PixelWidth/Height，orientation 5-8
//     交换宽高（sharp-decoder 的 RAW/TIFF orientation 语义一致）；
//   - getThumbnail：CGImageSourceCreateThumbnailAtIndex（验收硬性要求），
//     kCGImageSourceCreateThumbnailWithTransform 处理 EXIF 方向，输出 JPEG；
//   - getPreview：同 thumbnail API（maxPixelSize = maxDimension），方向变换
//     后 JPEG 编码，语义对齐 sharp 的 resize(fit inside, withoutEnlargement)。
//
// 仅 macOS（ImageIO/CoreGraphics 系统框架）；Linux 构建时整个文件被
// canImport 条件排除，不影响 GatherCore 其余部分。

#if canImport(ImageIO)
import Foundation
import GatherProtocol
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#if canImport(CoreImage)
import CoreImage
#endif

/// 区域解码结果：只把**可见区域**渲染出来，而不是整图
///（Bridge / Capture One 的 tiled detail）。
public struct RAWRegionDecodeResult: Equatable, Sendable {
    /// 区域 JPEG（已应用 EXIF/RAW 方向）。
    public let buffer: Data
    public let regionWidth: Int
    public let regionHeight: Int
    /// 整图（已应用方向）的像素尺寸：归一化矩形 → 像素矩形换算的基准。
    public let fullWidth: Int
    public let fullHeight: Int

    public init(buffer: Data, regionWidth: Int, regionHeight: Int, fullWidth: Int, fullHeight: Int) {
        self.buffer = buffer
        self.regionWidth = regionWidth
        self.regionHeight = regionHeight
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
    }
}

/// 解码来源（B3 快档诊断用，internal：不扩公共 API 面）。
///
/// - embedded：结果来自容器内嵌 JPEG 预览（只缩小/不放大，最快）；
/// - full：结果来自整图解码（RAW 真解 / 位图直解 / P0-8 兜底）。
enum RAWDecodeSource: String, Equatable, Sendable {
    case embedded
    case full
}

/// RAWDecoder 解码结果（对齐 TS DecodeResult：buffer + format + 宽高）。
public struct RAWDecodeResult: Equatable {
    public let buffer: Data
    public let format: String
    public let width: Int
    public let height: Int
    /// B3 快档诊断：本次结果来自内嵌预览还是整解。
    ///
    /// internal（不扩公共面）：测试经 @testable 断言快档是否命中，日志在
    /// decodeScaled 内按 debug 级输出。公开构造恒为 .full；本类型在本模块外
    /// 只被按 buffer/format/宽高消费，诊断字段不构成公开契约。
    let decodeSource: RAWDecodeSource

    /// 公开构造：诊断默认记 full（外部只按 buffer/format/宽高消费）。
    public init(buffer: Data, format: String, width: Int, height: Int) {
        self.buffer = buffer
        self.format = format
        self.width = width
        self.height = height
        self.decodeSource = .full
    }

    init(buffer: Data, format: String, width: Int, height: Int, decodeSource: RAWDecodeSource) {
        self.buffer = buffer
        self.format = format
        self.width = width
        self.height = height
        self.decodeSource = decodeSource
    }
}

public enum RAWDecoderError: Error, Equatable {
    case unsupportedExtension(String)
    case cannotOpenSource(String)
    case noImage(String)
    case dimensionsUnavailable(String)
    case jpegEncodeFailed(String)
}

/// CoreImage/ImageIO 解码器（替代 sharp + sips，含 RAW）。
public enum RAWDecoder {
    /// **统一白名单**（Wave5 / F4）：直接引用 `PhotoFileTypes.supportedExtensions`，
    /// 不再维护第二张字面量表。摄取 / 索引 / 解码三处由同一份清单驱动：
    /// `IngestService` 与 `IndexerService` 曾各有一张更窄的 RAW 清单，导致
    /// `.iiq/.3fr/.x3f/.mrw` 等可解码的 RAW 在导入时被静默跳过（P0-8 只修了解码侧）。
    public static let supportedExtensions: Set<String> = PhotoFileTypes.supportedExtensions

    /// 由 ImageIO 按内容合成/解码的位图格式（P0-8）：
    /// HEIC/HEIF 是 iPhone 直出，PSD 取合成扁平图。
    /// 这些格式的缩略图 API 可能因容器特性失败，失败时走「整图解码 → 缩放」兜底；
    /// 两条路都走不通按 unsupportedExtension 上报（UI 走占位符，不崩）。
    static let compositeDecodeExtensions: Set<String> = [".heic", ".heif", ".psd"]

    public static func supports(_ ext: String) -> Bool {
        PhotoFileTypes.isSupported(ext)
    }

    /// 读取图片尺寸；不可读时抛 RAWDecoderError（TS 语义：w/h <= 0 抛错）。
    public static func getDimensions(path: String) throws -> (width: Int, height: Int) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RAWDecoderError.cannotOpenSource(path)
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw RAWDecoderError.dimensionsUnavailable(path)
        }
        var width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        if orientation >= 5 && orientation <= 8 {
            swap(&width, &height)
        }
        if width <= 0 || height <= 0 {
            throw RAWDecoderError.dimensionsUnavailable(path)
        }
        return (width, height)
    }

    /// 缩略图：CGImageSourceCreateThumbnailAtIndex + 方向变换 + JPEG 编码。
    /// - Parameter allowEmbeddedPreview: 查看器/预取路径传 true 用 RAW 内嵌 JPEG 快档；
    ///   导出/打印/联系表/质量分析等需要像素保真的路径保持默认 false（真解）。
    public static func getThumbnail(
        path: String, size: Int, quality: Double = 0.8, allowEmbeddedPreview: Bool = false
    ) throws -> RAWDecodeResult {
        try decodeScaled(
            path: path, maxPixel: max(size, 1), quality: quality,
            allowEmbeddedPreview: allowEmbeddedPreview)
    }

    /// 预览：fit-inside 缩放（不放大），方向变换后 JPEG 编码。
    public static func getPreview(
        path: String, maxDimension: Int, quality: Double = 1.0, allowEmbeddedPreview: Bool = false
    ) throws -> RAWDecodeResult {
        try decodeScaled(
            path: path, maxPixel: max(maxDimension, 1), quality: quality,
            allowEmbeddedPreview: allowEmbeddedPreview)
    }

    /// **区域解码**（tiled detail）：只渲染归一化矩形覆盖的那块像素。
    ///
    /// 为什么需要它：查看器放大到 4×/8× 时，整图解码再放大等于把整幅图
    /// （几千万元素）materialize 一遍，而屏幕上只看得到其中一小块。Bridge /
    /// Capture One 都是按可见区域解码——内存与解码耗时都只跟**可见像素**成正比。
    ///
    /// - Parameter normalizedRect: 左上原点的归一化矩形（与系统 bbox 约定一致）；
    ///   与整图求交后按像素取整，自动钳制到有效范围。
    /// - Parameter maxPixel: 区域输出的最长边上限（不再向上采样：只缩小不放大）。
    public static func decodeRegion(
        path: String,
        normalizedRect: CGRect,
        maxPixel: Int,
        quality: Double = 1.0
    ) throws -> RAWRegionDecodeResult {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, PhotoFileTypes.isSupported(ext) else {
            throw RAWDecoderError.unsupportedExtension(ext.isEmpty ? path : ".\(ext)")
        }
        #if canImport(CoreImage)
        let url = URL(fileURLWithPath: path)
        guard let source = regionSourceImage(url: url, extension: ext) else {
            throw RAWDecoderError.cannotOpenSource(path)
        }
        // CIImage 的原点在**左下**：把左上原点的归一化矩形翻过来。
        let extent = source.extent
        let fullW = Int(extent.width.rounded())
        let fullH = Int(extent.height.rounded())
        guard fullW > 0, fullH > 0 else { throw RAWDecoderError.noImage(path) }
        let clamped = normalizedRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            throw RAWDecoderError.noImage(path)
        }
        let pixelRect = CGRect(
            x: extent.minX + clamped.minX * extent.width,
            y: extent.minY + (1 - clamped.maxY) * extent.height,
            width: max(1, clamped.width * extent.width),
            height: max(1, clamped.height * extent.height)
        ).integral.intersection(extent)
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1 else {
            throw RAWDecoderError.noImage(path)
        }
        let cropped = source.cropped(to: pixelRect)
        // 只缩小不放大：maxPixel 大于区域本身时保持原始像素。
        let longest = max(pixelRect.width, pixelRect.height)
        let scale = min(1, CGFloat(max(maxPixel, 1)) / longest)
        let output = scale < 1
            ? cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : cropped
        let renderRect = output.extent.integral
        guard let cgImage = regionContext.createCGImage(output, from: renderRect),
              let jpeg = encodeJPEG(cgImage, quality: quality) else {
            throw RAWDecoderError.noImage(path)
        }
        return RAWRegionDecodeResult(
            buffer: jpeg,
            regionWidth: cgImage.width,
            regionHeight: cgImage.height,
            fullWidth: fullW,
            fullHeight: fullH
        )
        #else
        throw RAWDecoderError.unsupportedExtension(path)
        #endif
    }

    #if canImport(CoreImage)
    /// 共享 CIContext：创建开销大（GPU 管线），必须复用。
    private static let regionContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 区域解码的图像源：RAW 走 CIRAWFilter（能按需渲染指定区域），
    /// 其它格式走 CIImage(contentsOf:) 并烘焙 EXIF 方向。
    private static func regionSourceImage(url: URL, extension ext: String) -> CIImage? {
        // RAW 判定复用共享表（PhotoFileTypes.rawExtensions，Cut 3a / E-01：
        // 原引用 Persistence 层 Repo 的扩展名表，属 Analysis→Persistence 反向依赖）。
        // ext 由 pathExtension 得到、**不含点**；点号/大小写规范化由
        // PhotoFileTypes.isRAW 内部完成（两边不各写一套约定）。
        if PhotoFileTypes.isRAW(ext) {
            if let filter = CIRAWFilter(imageURL: url) {
                return filter.outputImage
            }
        }
        if let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            return image
        }
        // P0-8：CIImage 不认的位图（典型是 PSD 的合成扁平图）退回 ImageIO 直解，
        // 再包成 CIImage 供区域裁剪。该兜底不带方向变换：PSD 没有 EXIF 方向语义。
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = makeImage(from: source, maxPixel: nil)
                ?? fallbackImage(from: source, maxPixel: nil) else { return nil }
        return CIImage(cgImage: decoded)
    }
    #endif

    /// 9x8 灰度像素网格（72 字节）——dHash 输入（TS: sharp resize(9, 8,
    /// { fit: 'fill' }).grayscale().raw()）。非等比拉伸到 9x8（fill 语义），
    /// 输出 top-down 行序（CGContext 默认左下原点，须翻转对齐 sharp raw）。
    public static func pixels9x8(path: String, maxPixel: Int? = nil) -> [UInt8]? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = makeImage(from: source, maxPixel: maxPixel)
                ?? fallbackImage(from: source, maxPixel: maxPixel) else { return nil }
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpaceCreateDeviceGray() as CGColorSpace?,
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        // 翻转坐标系：内存第 0 行 = 图像顶部（sharp raw 的 top-down 行序）。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// 缩放解码公共路径：maxPixel <= 0 表示不缩放（全尺寸）。
    public static func decodeScaled(
        path: String, maxPixel: Int?, quality: Double, allowEmbeddedPreview: Bool = false
    ) throws -> RAWDecodeResult {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, PhotoFileTypes.isSupported(ext) else {
            throw RAWDecoderError.unsupportedExtension(ext.isEmpty ? path : ".\(ext)")
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RAWDecoderError.cannotOpenSource(path)
        }
        // B3 / RAW 嵌入 JPEG 快档（20-culling-viewer §2 B3）：缩略图/预览优先用
        // 容器里的内嵌 JPEG 预览，避免为 1024px 缩略图整解 50MP RAW。判定全部
        // 收在纯函数 embeddedPreviewAcceptable 里（格式 / 请求档位 / 可用像素比例）；
        // 这里只做 I/O。快档任意一步失败（无内嵌 / 太小 / 编码失败）都静默回退
        // 现有整解——错误分类与 1:1 / 区域解码语义完全不变。
        if allowEmbeddedPreview,
           let maxPixel,
           maxPixel <= embeddedPreviewMaxRequestedPixels,
           PhotoFileTypes.isRAW(ext),
           let fast = embeddedPreviewResult(
               source: source, ext: ext, maxPixel: maxPixel, quality: quality) {
            return fast
        }
        // P0-8：缩略图 API 失败时退回「整图解码 → 缩放」兜底（HEIC/HEIF/PSD
        // 这类由 ImageIO 按内容合成的格式，容器里没有内嵌缩略图时最常触发）。
        guard let image = makeImage(from: source, maxPixel: maxPixel)
            ?? fallbackImage(from: source, maxPixel: maxPixel) else {
            // 声明支持却解不出来的 HEIC/HEIF/PSD 按"扩展名不受支持"上报：
            // 上层（网格/查看器）据此走占位符，而不是把 noImage 当崩溃扩散。
            if compositeDecodeExtensions.contains(".\(ext)") {
                throw RAWDecoderError.unsupportedExtension(".\(ext)")
            }
            throw RAWDecoderError.noImage(path)
        }
        let width = image.width
        let height = image.height
        guard let jpeg = encodeJPEG(image, quality: quality) else {
            throw RAWDecoderError.jpegEncodeFailed(path)
        }
        return RAWDecodeResult(buffer: jpeg, format: "jpeg", width: width, height: height)
    }

    // MARK: - B3 / RAW 嵌入 JPEG 快档

    /// RAW 快档的请求上限：只给缩略图/预览档（<=4096）用内嵌 JPEG；
    /// 1:1 与区域解码（tiled detail）仍走真解——那是判合焦的数据源。
    static let embeddedPreviewMaxRequestedPixels = 4_096
    /// 内嵌预览必须达到请求边长的 75%，否则放大糊；不达标就回退整解。
    static let embeddedPreviewMinimumRatio = 0.75

    /// 内嵌预览是否可接受的纯决策（供单测；不做 I/O）。
    ///
    /// - Parameters:
    ///   - embedded: 内嵌预览在请求档位下实际可用的最长边像素
    ///     （已按请求缩小；内嵌原生 >= 请求时等于请求值）。
    ///   - requested: 调用方请求的最长边像素（getThumbnail size / getPreview maxDimension）。
    ///   - ext: 文件扩展名（可带点/大写；归一化在 PhotoFileTypes.isRAW 内完成）。
    static func embeddedPreviewAcceptable(embedded: Int, requested: Int, ext: String) -> Bool {
        guard requested > 0, requested <= embeddedPreviewMaxRequestedPixels else { return false }
        guard embedded > 0 else { return false }
        guard PhotoFileTypes.isRAW(ext) else { return false }
        return Double(embedded) >= Double(requested) * embeddedPreviewMinimumRatio
    }

    /// 尝试用内嵌 JPEG 预览出结果；nil = 没有内嵌 / 太小 / 编码失败（调用方回退整解）。
    private static func embeddedPreviewResult(
        source: CGImageSource,
        ext: String,
        maxPixel: Int,
        quality: Double
    ) -> RAWDecodeResult? {
        guard let image = embeddedPreviewImage(from: source, maxPixel: maxPixel) else { return nil }
        let available = max(image.width, image.height)
        guard embeddedPreviewAcceptable(embedded: available, requested: maxPixel, ext: ext) else {
            return nil
        }
        guard let jpeg = encodeJPEG(image, quality: quality) else { return nil }
        GatherLogger.log(
            "raw decode: embedded preview \(image.width)x\(image.height) (requested \(maxPixel))",
            level: .debug)
        return RAWDecodeResult(
            buffer: jpeg,
            format: "jpeg",
            width: image.width,
            height: image.height,
            decodeSource: .embedded)
    }

    /// 取容器内嵌预览（只读内嵌，绝不从整图生成）。
    ///
    /// 两个 FromImage* 都显式 false：没有内嵌预览时返回 nil，交给整解路径；
    /// WithTransform 保留 EXIF/RAW 方向语义（与旧整解路径同口径）。
    private static func embeddedPreviewImage(from source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func makeImage(from source: CGImageSource, maxPixel: Int?) -> CGImage? {
        if let maxPixel {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// CGImageSource 直解兜底（P0-8）：整图解码 → 按 EXIF 方向摆正 → 缩到 maxPixel。
    ///
    /// 只在主路径 `CGImageSourceCreateThumbnailAtIndex` 返回 nil 时才走：
    /// HEIC/HEIF/PSD 这类容器没有内嵌缩略图时，缩略图 API 可能直接失败，
    /// 而整图解码（ImageIO 会合成 PSD 的扁平图）仍然可用。
    /// 方向用 CoreImage 的 EXIF 语义摆正，与缩略图主路径的 WithTransform 一致；
    /// 只缩小不放大（maxPixel 大于原图时保持原始像素）。
    static func fallbackImage(from source: CGImageSource, maxPixel: Int?) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let full = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            .flatMap { $0[kCGImagePropertyOrientation] as? Int } ?? 1
        #if canImport(CoreImage)
        var image = CIImage(cgImage: full)
        if orientation != 1 {
            image = image.oriented(forExifOrientation: Int32(orientation))
        }
        if let maxPixel {
            let longest = max(image.extent.width, image.extent.height)
            if longest > CGFloat(max(maxPixel, 1)) {
                let scale = CGFloat(max(maxPixel, 1)) / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let rect = image.extent.integral
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return regionContext.createCGImage(image, from: rect)
        #else
        guard let maxPixel else { return full }
        let longest = max(full.width, full.height)
        guard longest > max(maxPixel, 1) else { return full }
        let scale = CGFloat(max(maxPixel, 1)) / CGFloat(longest)
        let width = max(1, Int((CGFloat(full.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(full.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
        #endif
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
