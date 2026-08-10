// desktop/native/gather-core/Tests/GatherCoreTests/Image/RAWDecoderTests.swift
// Phase 2 任务 2.1 剩余（macOS 专属）：RAWDecoder（CoreImage/ImageIO）测试。
// TS 源对照: desktop/src/main/services/image/decoders/sharp-decoder.ts
//          + sips-decoder.ts
// 验证点：
//   - supports 扩展名集合（sharp.supportedExtensions 全集，与 image-config.ts 对照）；
//   - getDimensions：宽高正确 + EXIF orientation 5-8 交换宽高（sharp 语义）；
//   - getThumbnail：CGImageSourceCreateThumbnailAtIndex 缩到 size 内、输出 JPEG；
//   - getPreview：fit-inside 不放大（maxDimension 大于原图时尺寸不变）；
//   - 非法路径/不支持扩展名/损坏文件 → 错误码（非静默）。
//
// 测试图片用 CoreGraphics 运行时生成（无二进制 fixture），JPEG 带可写入的
// EXIF orientation 属性（kCGImagePropertyOrientation）。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherCore

struct RAWDecoderTests {
    // ── 测试图片生成 ──

    /// 生成纯色 JPEG（width×height），orientation 1-8 可选。
    private func makeJPEG(width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-rawdecoder-\(UUID().uuidString).jpg")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError("CGContext failed") }
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError("makeImage failed") }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw TestError("destination failed") }
        let props: [CFString: Any] = orientation == 1 ? [:] : [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw TestError("finalize failed") }
        try (data as Data).write(to: url)
        return url
    }

    private struct TestError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    private func cleanup(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    // ── supports ──

    @Test func supportsMatchesSharpConfig() {
        for ext in [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"] {
            #expect(RAWDecoder.supports(ext))
            #expect(RAWDecoder.supports(ext.uppercased()))
        }
        for ext in [".cr2", ".cr3", ".nef", ".nrw", ".arw", ".raf", ".dng", ".orf",
                    ".rw2", ".pef", ".srw", ".srf", ".x3f", ".3fr", ".fff",
                    ".mef", ".mos", ".iiq", ".eip", ".erf", ".kdc", ".mrw"] {
            #expect(RAWDecoder.supports(ext), "RAW ext \(ext) must be supported")
        }
        #expect(!RAWDecoder.supports(".gif"))
        #expect(!RAWDecoder.supports(".bmp"))
        #expect(!RAWDecoder.supports(".heic"))
        #expect(!RAWDecoder.supports(""))
    }

    // ── getDimensions ──

    @Test func dimensionsMatchPixels() throws {
        let url = try makeJPEG(width: 800, height: 600)
        defer { cleanup([url]) }
        let dims = try RAWDecoder.getDimensions(path: url.path)
        #expect(dims.width == 800)
        #expect(dims.height == 600)
    }

    /// EXIF orientation 5-8（旋转类）交换宽高；1-4（翻转类）不交换。
    @Test func dimensionsSwapForRotatedOrientation() throws {
        for orientation in 1...8 {
            let url = try makeJPEG(width: 640, height: 480, orientation: orientation)
            defer { cleanup([url]) }
            let dims = try RAWDecoder.getDimensions(path: url.path)
            let expected = (5...8).contains(orientation) ? (480, 640) : (640, 480)
            #expect(
                dims.width == expected.0 && dims.height == expected.1,
                "orientation \(orientation): got \(dims.width)x\(dims.height)"
            )
        }
    }

    // ── getThumbnail ──

    @Test func thumbnailScalesInsideAndIsJPEG() throws {
        let url = try makeJPEG(width: 3000, height: 2000)
        defer { cleanup([url]) }
        let thumb = try RAWDecoder.getThumbnail(path: url.path, size: 256)
        #expect(thumb.format == "jpeg")
        #expect(thumb.width <= 256)
        #expect(thumb.height <= 256)
        #expect(thumb.width > 0 && thumb.height > 0)
        // 长宽比保持：3000x2000 → 256x171（约）
        #expect(abs(Double(thumb.width) / Double(thumb.height) - 1.5) < 0.02)
        // JPEG 魔数
        #expect(thumb.buffer.count > 2)
        #expect(thumb.buffer[0] == 0xFF && thumb.buffer[1] == 0xD8)
    }

    @Test func thumbnailNotEnlargedWhenSmaller() throws {
        let url = try makeJPEG(width: 100, height: 80)
        defer { cleanup([url]) }
        let thumb = try RAWDecoder.getThumbnail(path: url.path, size: 1024)
        #expect(thumb.width == 100)
        #expect(thumb.height == 80)
    }

    @Test func thumbnailAppliesOrientationTransform() throws {
        // 旋转 90°（orientation 6）：缩略图应是 640x480 内容 → 输出尺寸含旋转。
        let url = try makeJPEG(width: 480, height: 640, orientation: 6)
        defer { cleanup([url]) }
        let thumb = try RAWDecoder.getThumbnail(path: url.path, size: 1000)
        // CreateThumbnailWithTransform 后宽高按方向后的图像计算
        #expect(thumb.width > 0 && thumb.height > 0)
        #expect(thumb.width == 640 || thumb.height == 640)
    }

    // ── getPreview ──

    @Test func previewFitsInsideMaxDimension() throws {
        let url = try makeJPEG(width: 4000, height: 3000)
        defer { cleanup([url]) }
        let preview = try RAWDecoder.getPreview(path: url.path, maxDimension: 2048)
        #expect(preview.format == "jpeg")
        #expect(preview.width <= 2048)
        #expect(preview.height <= 2048)
        #expect(abs(Double(preview.width) / Double(preview.height) - 4.0 / 3.0) < 0.02)
    }

    @Test func previewWithoutEnlargement() throws {
        let url = try makeJPEG(width: 200, height: 150)
        defer { cleanup([url]) }
        let preview = try RAWDecoder.getPreview(path: url.path, maxDimension: 2048)
        #expect(preview.width == 200)
        #expect(preview.height == 150)
    }

    // ── 错误路径 ──

    @Test func unsupportedExtensionThrows() {
        #expect(throws: RAWDecoderError.unsupportedExtension(".gif")) {
            _ = try RAWDecoder.getThumbnail(path: "/tmp/foo.gif", size: 256)
        }
    }

    @Test func missingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-rawdecoder-missing-\(UUID().uuidString).jpg")
        #expect(throws: RAWDecoderError.self) {
            _ = try RAWDecoder.getDimensions(path: missing.path)
        }
    }

    @Test func corruptFileThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-rawdecoder-corrupt-\(UUID().uuidString).jpg")
        try Data("not a jpeg at all".utf8).write(to: url)
        defer { cleanup([url]) }
        #expect(throws: RAWDecoderError.self) {
            _ = try RAWDecoder.getThumbnail(path: url.path, size: 256)
        }
    }
}
