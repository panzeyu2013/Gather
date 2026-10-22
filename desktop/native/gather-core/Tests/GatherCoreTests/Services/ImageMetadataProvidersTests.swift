// ImageIO 宿主 provider 的真实图片测试（拒绝"只断言协议被调用"）。
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GatherProtocol
@testable import GatherPersistence
@testable import GatherAnalysis
@testable import GatherApplication

@Suite("ImageMetadataProviders")
struct ImageMetadataProvidersTests {
    private func makeJPEG(at path: String, exifDate: String, model: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(
                domain: "ImageMetadataProvidersTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 JPEG destination: \(path)"])
        }
        let context = CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try #require(context?.makeImage())
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: model,
                kCGImagePropertyTIFFMake: "GatherCam",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.2304,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.4737,
                kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination), "测试图片必须真的写成 JPEG")
    }

    @Test("真实 JPEG：dateTaken/cameraModel/GPS 必须解析出非空值")
    func parsesRealJpeg() async throws {
        let dir = NSTemporaryDirectory() + "gather-exif-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/shot.jpg"
        try makeJPEG(at: path, exifDate: "2024:05:01 10:20:30", model: "X-T5")

        let provider = ImageIOExifProvider()
        let segments = try #require(await provider.parse(filePath: path, isJpeg: true), "解析失败不得返回空字典冒充成功")
        #expect(segments.exif?["DateTimeOriginal"]?.stringValue == "2024:05:01 10:20:30")
        #expect(segments.ifd0?["Model"]?.stringValue == "X-T5")
        #expect(segments.ifd0?["Make"]?.stringValue == "GatherCam")
        #expect(segments.gps?["latitude"]?.numberValue == 31.2304)
        #expect(segments.gps?["longitude"]?.numberValue == 121.4737)

        let dimensions = try #require(await ImageIODimensionsProvider().metadata(filePath: path))
        #expect(dimensions.width == 8)
        #expect(dimensions.height == 6)
        #expect((dimensions.size ?? 0) > 0)
        #expect(dimensions.format == "jpeg" || dimensions.format == "jpg")

        // 无法解析 → nil（走兜底），不是空分段。
        let missing = dir + "/missing.jpg"
        #expect(try await provider.parse(filePath: missing, isJpeg: true) == nil)
        #expect(try await ImageIODimensionsProvider().metadata(filePath: missing) == nil)
    }

    @Test("内嵌 XMP：rating/label 走消费端契约读出（无侧车也不丢星级/色标）")
    func parsesEmbeddedXMPAttributes() async throws {
        let dir = NSTemporaryDirectory() + "gather-xmp-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/xmp.jpg"
        let url = URL(fileURLWithPath: path)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try #require(context?.makeImage())
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, NSNumber(value: 3)))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "Green" as CFString))
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        #expect(CGImageDestinationFinalize(destination))

        let segments = try #require(await ImageIOExifProvider().parse(filePath: path, isJpeg: true))
        // 消费端契约（MetadataService.embeddedAttributesFromParse）：xmp 用本地名。
        // ImageIO 可能把 XMP 数值以字符串存回（"3"）：消费端两种都接受（见 embeddedAttributesFromParse）。
        let rawRating = segments.xmp?["Rating"]
        #expect(rawRating?.numberValue == 3 || rawRating?.stringValue == "3")
        #expect(segments.xmp?["Label"]?.stringValue == "Green")
        let attributes = try #require(MetadataService.embeddedAttributesFromParse(segments))
        #expect(attributes.rating == 3, "内嵌 XMP rating 必须派生为星级")
        #expect(attributes.label == "Green", "内嵌 XMP label 必须派生为色标")
    }

    /// 回归：数组型 XMP 属性（dc:subject = rdf:Bag）与 IPTC 关键词必须解出真实字符串。
    /// 旧实现对 CGImageMetadataTag 元素走 String(describing:) 兜底，产出
    /// "Optional(<CGImageMetadataTag 0x…> dc:[0] = alpha)" 伪关键词并被缓存/写回。
    @Test("内嵌 XMP/IPTC 关键词：数组元素必须解包为真实字符串（不得产出标签伪值）")
    func parsesEmbeddedKeywordArrays() async throws {
        let dir = NSTemporaryDirectory() + "gather-kw-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // (1) 内嵌 XMP dc:subject（ImageIO 把数组元素返回为 CGImageMetadataTag）。
        let xmpPath = dir + "/xmp-kw.jpg"
        try writeJPEG(at: xmpPath, iptc: nil, xmpSubject: ["alpha", "beta"])
        let xmpSegments = try #require(await ImageIOExifProvider().parse(filePath: xmpPath, isJpeg: true))
        #expect(xmpSegments.dc?["subject"] == .array([.string("alpha"), .string("beta")]))
        #expect(MetadataService.embeddedAttributesFromParse(xmpSegments)?.keywords == ["alpha", "beta"])

        // (2) IPTC 关键词：顶层 iptc 段是唯一 IPTC 出口（xmp 段不再复制一份无消费者的副本）。
        let iptcPath = dir + "/iptc-kw.jpg"
        try writeJPEG(at: iptcPath, iptc: [kCGImagePropertyIPTCKeywords: ["iptc-a", "iptc-b"]], xmpSubject: nil)
        let iptcSegments = try #require(await ImageIOExifProvider().parse(filePath: iptcPath, isJpeg: true))
        #expect(iptcSegments.iptc?["Keywords"] != nil, "IPTC 必须在顶层 iptc 段可读")
        #expect(iptcSegments.xmp?["iptc"] == nil, "IPTC 不得再复制进 xmp 段")
        #expect(MetadataService.embeddedAttributesFromParse(iptcSegments)?.keywords == ["iptc-a", "iptc-b"])
    }

    /// 写一张带 IPTC 或内嵌 XMP dc:subject 的真实 JPEG。
    private func writeJPEG(at path: String, iptc: [CFString: Any]?, xmpSubject: [String]?) throws {
        let url = URL(fileURLWithPath: path)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try #require(context?.makeImage())
        if let xmpSubject {
            let metadata = CGImageMetadataCreateMutable()
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, "dc:subject" as CFString, xmpSubject as CFArray))
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        } else {
            var properties: [CFString: Any] = [:]
            if let iptc { properties[kCGImagePropertyIPTCDictionary] = iptc }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination), "测试图片必须真的写成 JPEG")
    }

    /// 变异守卫：GPS ref === 'S'/'W' 必须取负（南纬/西经），且曝光 >= 1 秒保持秒数字。
    @Test("南/西半球 GPS 符号与曝光时间边界：1s 保持数字、0.004s 归一为 1/250")
    func parsesSouthernWesternGPSAndExposureBoundary() async throws {
        let dir = NSTemporaryDirectory() + "gather-gps-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let provider = ImageIOExifProvider()

        // 悉尼经纬度（南纬/西经）：ref 不是装饰，符号必须为负。
        let southPath = dir + "/south.jpg"
        try makeGPSJPEG(at: southPath, lat: 33.8688, latRef: "S", lon: 151.2093, lonRef: "W", exposure: 1.0)
        let south = try #require(await provider.parse(filePath: southPath, isJpeg: true))
        #expect(south.gps?["latitude"]?.numberValue == -33.8688, "S 必须取负")
        #expect(south.gps?["longitude"]?.numberValue == -151.2093, "W 必须取负")
        // 恰为 1 秒是 >= 1 的边界：必须仍是数字 1，不得退化成 "1/1" 字符串。
        #expect(south.exif?["ExposureTime"] == .number(1.0), "1 秒曝光必须保持秒数字")

        // 北纬/东经对照（避免"无条件取负"式修复）＋ 不足 1 秒的 1/分母 归一。
        let northPath = dir + "/north.jpg"
        try makeGPSJPEG(at: northPath, lat: 31.2304, latRef: "N", lon: 121.4737, lonRef: "E", exposure: 0.004)
        let north = try #require(await provider.parse(filePath: northPath, isJpeg: true))
        #expect(north.gps?["latitude"]?.numberValue == 31.2304)
        #expect(north.gps?["longitude"]?.numberValue == 121.4737)
        #expect(north.exif?["ExposureTime"] == .string("1/250"), "不足 1 秒必须归一为 1/分母")
    }

    /// 写一张可控 GPS 符号与曝光时间的真实 JPEG。
    private func makeGPSJPEG(
        at path: String, lat: Double, latRef: String, lon: Double, lonRef: String, exposure: Double?
    ) throws {
        let url = URL(fileURLWithPath: path)
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = try #require(context?.makeImage())
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: "X-T5",
                kCGImagePropertyTIFFMake: "GatherCam",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: lat,
                kCGImagePropertyGPSLatitudeRef: latRef,
                kCGImagePropertyGPSLongitude: lon,
                kCGImagePropertyGPSLongitudeRef: lonRef,
            ],
        ]
        if let exposure {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifExposureTime: exposure,
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:20:30",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination), "测试图片必须真的写成 JPEG")
    }
}
