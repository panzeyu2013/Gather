// desktop/native/gather-core/Tests/GatherCoreTests/Image/RAWDecoderEmbeddedPreviewTests.swift
// Wave5 / Batch4（B3 RAW 嵌入 JPEG 快档）回归测试。
//
// 覆盖：
// - embeddedPreviewAcceptable 纯决策：RAW/非 RAW、请求档位上限（<=4096）、
//   可用像素比例（>=75%）、非法输入；
// - 用 CGImageDestination 生成「主图 + 内嵌 JPEG 预览」的 JPEG 夹具，
//   改名为 .dng 伪装 RAW：
//   * 小缩略图（128）命中内嵌快档（decodeSource == .embedded）且方向正确；
//   * 大缩略图（1024）内嵌预览不够大 → 回退整解（.full）且尺寸符合旧语义；
//   * 请求 >4096 → 不尝试快档，走整解；
// - 非 RAW（.jpg）完全不进入快档；
// - 公开构造的 RAWDecodeResult 诊断默认 .full（不扩公共面）。
//
// 真机 RAW 抽查项（本文件无法覆盖，需在验收机执行）：
// 1. 典型机型（CR3/NEF/ARW/DNG）在 256/512/1024 缩略图下命中的内嵌预览尺寸
//    是否 >= 请求 75%（日志 debug 级 "raw decode: embedded preview"）；
// 2. 内嵌预览方向是否与旧整解一致（portrait 图、orientation 6/8）；
// 3. 预览档 2560（查看器）是否按预期回退整解（内嵌 1616 < 1920）；
// 4. 快档与整解的缩略图肉眼差异（双 JPEG 压缩）是否可接受。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherAnalysis
@testable import GatherProtocol

struct RAWDecoderEmbeddedPreviewTests {
    // ── 夹具 ──

    private struct TestError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// 生成「主图 + 内嵌 JPEG 预览」的文件；ext 用来伪装 RAW（内容仍是 JPEG，
    /// ImageIO 按内容解码，扩展名只用于命中 RAWDecoder 的格式分支）。
    private func makeJPEG(
        width: Int,
        height: Int,
        orientation: Int = 1,
        embedThumbnail: Bool = true,
        ext: String = "jpg"
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-rawdecoder-embedded-\(UUID().uuidString).\(ext)")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError("CGContext failed") }
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestError("makeImage failed") }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw TestError("destination failed") }
        var props: [CFString: Any] = [:]
        if embedThumbnail { props[kCGImageDestinationEmbedThumbnail] = true }
        if orientation != 1 { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestError("finalize failed") }
        try (data as Data).write(to: url)
        return url
    }

    private func cleanup(_ urls: [URL]) {
        for url in urls {
            do { try FileManager.default.removeItem(at: url) } catch {
                // 测试清理失败不影响断言（临时目录会由系统回收）。
            }
        }
    }

    // ── 纯决策 ──

    @Test func embeddedPreviewAcceptableMatrix() {
        // 请求档位上限：<=4096 才尝试快档（1:1 / 大图仍真解）。
        #expect(RAWDecoder.embeddedPreviewMaxRequestedPixels == 4_096)
        #expect(RAWDecoder.embeddedPreviewMinimumRatio == 0.75)

        // 原生大于请求：ImageIO 会缩到请求值，可用像素 == 请求值 → 接受。
        #expect(RAWDecoder.embeddedPreviewAcceptable(embedded: 1_024, requested: 1_024, ext: "dng"))
        // 刚好 75%：接受（边界含等号）。
        #expect(RAWDecoder.embeddedPreviewAcceptable(embedded: 768, requested: 1_024, ext: ".DNG"))
        #expect(RAWDecoder.embeddedPreviewAcceptable(embedded: 768, requested: 1_024, ext: " .Cr3 "))
        // 低于 75%：拒绝（避免放大糊）。
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 767, requested: 1_024, ext: "nef"))
        // 4096 边界与超限。
        #expect(RAWDecoder.embeddedPreviewAcceptable(embedded: 3_072, requested: 4_096, ext: "arw"))
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 3_071, requested: 4_096, ext: "arw"))
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 8_192, requested: 4_097, ext: "arw"))
        // 非 RAW：完全不变（快档只服务 RAW）。
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 2_048, requested: 1_024, ext: "jpg"))
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 2_048, requested: 1_024, ext: "heic"))
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 2_048, requested: 1_024, ext: "png"))
        // 非法输入。
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 0, requested: 1_024, ext: "dng"))
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 1_024, requested: 0, ext: "dng"))
        #expect(!RAWDecoder.embeddedPreviewAcceptable(embedded: 1_024, requested: -1, ext: "dng"))
    }

    // ── 伪装 RAW 的快档命中 ──

    @Test func smallThumbnailUsesEmbeddedPreview() throws {
        let url = try makeJPEG(width: 2_000, height: 1_500, ext: "dng")
        defer { cleanup([url]) }

        let thumb = try RAWDecoder.getThumbnail(
            path: url.path, size: 128, allowEmbeddedPreview: true)
        #expect(thumb.decodeSource == .embedded, "128px 缩略图应命中内嵌 JPEG 快档")
        #expect(thumb.format == "jpeg")
        #expect(max(thumb.width, thumb.height) == 128, "输出应缩到请求档位")
        let ratio = Double(thumb.width) / Double(thumb.height)
        #expect(abs(ratio - 4.0 / 3.0) < 0.03, "保持主图长宽比：\(thumb.width)x\(thumb.height)")
        #expect(thumb.buffer.count > 2 && thumb.buffer[0] == 0xFF && thumb.buffer[1] == 0xD8)
    }

    @Test func embeddedPreviewAppliesOrientationTransform() throws {
        // orientation 6 = 顺时针 90°：主图 2000x1500，摆正后是 1500x2000（竖）。
        let url = try makeJPEG(width: 2_000, height: 1_500, orientation: 6, ext: "dng")
        defer { cleanup([url]) }

        let thumb = try RAWDecoder.getThumbnail(
            path: url.path, size: 128, allowEmbeddedPreview: true)
        #expect(thumb.decodeSource == .embedded)
        #expect(thumb.width < thumb.height, "内嵌快档必须保留方向变换（竖构图）：\(thumb.width)x\(thumb.height)")
        #expect(max(thumb.width, thumb.height) == 128)
    }

    @Test func oversizedRequestSkipsFastPath() throws {
        let url = try makeJPEG(width: 2_000, height: 1_500, ext: "dng")
        defer { cleanup([url]) }

        // 5000 > 4096：按规则不尝试快档，走整解（这里主图 2000x1500，不放大）。
        let preview = try RAWDecoder.getPreview(
            path: url.path, maxDimension: 5_000, allowEmbeddedPreview: true)
        #expect(preview.decodeSource == .full, ">4096 的请求必须走整解")
        #expect(preview.width == 2_000 && preview.height == 1_500, "整解口径：不放大")
    }

    // ── 回退与边界 ──

    @Test func largeThumbnailFallsBackWhenEmbeddedTooSmall() throws {
        // 内嵌预览 160x120（ImageIO 默认档）：请求 1024 时 160 < 768 → 必须回退整解。
        let url = try makeJPEG(width: 2_000, height: 1_500, ext: "dng")
        defer { cleanup([url]) }

        let thumb = try RAWDecoder.getThumbnail(
            path: url.path, size: 1_024, allowEmbeddedPreview: true)
        #expect(thumb.decodeSource == .full, "内嵌预览不足 75% 时必须回退整解")
        #expect(thumb.width == 1_024 && thumb.height == 768, "回退后仍是旧缩放语义")
    }

    @Test func nonRawFormatsNeverUseFastPath() throws {
        // 同样的「主图 + 内嵌预览」文件，扩展名是 .jpg：非 RAW 不走快档。
        let url = try makeJPEG(width: 2_000, height: 1_500, ext: "jpg")
        defer { cleanup([url]) }

        let thumb = try RAWDecoder.getThumbnail(
            path: url.path, size: 128, allowEmbeddedPreview: true)
        #expect(thumb.decodeSource == .full, "JPEG/PNG/HEIC 等非 RAW 行为不变")
        #expect(max(thumb.width, thumb.height) == 128)
    }

    @Test func publicResultDefaultsToFullSource() throws {
        let result = RAWDecodeResult(
            buffer: Data([0xFF, 0xD8]), format: "jpeg", width: 10, height: 10)
        #expect(result.decodeSource == .full, "公开构造不携带内部快档诊断")
    }
}
