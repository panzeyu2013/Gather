// desktop/native/gather-core/Sources/GatherCore/Image/RAWDecoder.swift
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

/// RAWDecoder 解码结果（对齐 TS DecodeResult：buffer + format + 宽高）。
public struct RAWDecodeResult: Equatable {
    public let buffer: Data
    public let format: String
    public let width: Int
    public let height: Int

    public init(buffer: Data, format: String, width: Int, height: Int) {
        self.buffer = buffer
        self.format = format
        self.width = width
        self.height = height
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
    /// sharp.supportedExtensions 全集（含 RAW）。
    public static let supportedExtensions: Set<String> = [
        ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp",
        ".cr2", ".cr3", ".nef", ".nrw", ".arw",
        ".raf", ".dng", ".orf", ".rw2", ".pef",
        ".srw", ".srf", ".x3f", ".3fr", ".fff",
        ".mef", ".mos", ".iiq", ".eip", ".erf",
        ".kdc", ".mrw",
    ]

    public static func supports(_ ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
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
    public static func getThumbnail(path: String, size: Int, quality: Double = 0.8) throws -> RAWDecodeResult {
        try decodeScaled(path: path, maxPixel: max(size, 1), quality: quality)
    }

    /// 预览：fit-inside 缩放（不放大），方向变换后 JPEG 编码。
    public static func getPreview(path: String, maxDimension: Int, quality: Double = 1.0) throws -> RAWDecodeResult {
        try decodeScaled(path: path, maxPixel: max(maxDimension, 1), quality: quality)
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
        guard !ext.isEmpty, supportedExtensions.contains(".\(ext)") else {
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
        // RAW 判定复用共享表（PhotoRepo.rawExtensions），避免两处清单漂移。
        if PhotoRepo.rawExtensions.contains(ext) {
            if let filter = CIRAWFilter(imageURL: url) {
                return filter.outputImage
            }
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
    #endif

    /// 9x8 灰度像素网格（72 字节）——dHash 输入（TS: sharp resize(9, 8,
    /// { fit: 'fill' }).grayscale().raw()）。非等比拉伸到 9x8（fill 语义），
    /// 输出 top-down 行序（CGContext 默认左下原点，须翻转对齐 sharp raw）。
    public static func pixels9x8(path: String, maxPixel: Int? = nil) -> [UInt8]? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = makeImage(from: source, maxPixel: maxPixel) else { return nil }
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
    public static func decodeScaled(path: String, maxPixel: Int?, quality: Double) throws -> RAWDecodeResult {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, supportedExtensions.contains(".\(ext)") else {
            throw RAWDecoderError.unsupportedExtension(ext.isEmpty ? path : ".\(ext)")
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RAWDecoderError.cannotOpenSource(path)
        }
        guard let image = makeImage(from: source, maxPixel: maxPixel) else {
            throw RAWDecoderError.noImage(path)
        }
        let width = image.width
        let height = image.height
        guard let jpeg = encodeJPEG(image, quality: quality) else {
            throw RAWDecoderError.jpegEncodeFailed(path)
        }
        return RAWDecodeResult(buffer: jpeg, format: "jpeg", width: width, height: height)
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
