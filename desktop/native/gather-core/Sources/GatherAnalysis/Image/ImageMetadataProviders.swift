// desktop/native/gather-core/Sources/GatherApplication/Services/ImageMetadataProviders.swift
// 宿主职责的 ImageIO 实现：EXIF 分段读取 + 尺寸/大小/格式兜底。
//
// 语义（与 Protocol 注释一致）：
// - ExifProvider.parse 返回 nil = 解析失败（调用方走兜底），绝不用空字典冒充成功；
//   分段字典只有在确实存在该段时才非 nil。
// - ImageDimensionsProvider.metadata 返回 nil = 无法读取；宽高为 nil = ImageIO 未给出该值。
//
// 关键键名与 MetadataService 消费端严格对齐：
//   ifd0: Make/Model/ImageWidth/ImageHeight/Rating
//   exif: DateTimeOriginal/ISO/LensModel/FocalLength/FNumber/ExposureTime/Make/Model/ExifImageWidth/ExifImageHeight
//   gps:  latitude/longitude/altitude

import CoreGraphics
import Foundation
import GatherProtocol
import ImageIO
import UniformTypeIdentifiers

/// TS: exifr.parse —— ImageIO 实现（JPEG 追加内嵌 XMP/IPTC 分段）。
public struct ImageIOExifProvider: ExifProvider {
    public init() {}

    public func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = Self.dictionary(rawProperties[kCGImagePropertyExifDictionary])
        let tiff = Self.dictionary(rawProperties[kCGImagePropertyTIFFDictionary])
        let gps = Self.dictionary(rawProperties[kCGImagePropertyGPSDictionary])
        let iptc = Self.dictionary(rawProperties[kCGImagePropertyIPTCDictionary])

        var ifd0: [String: JSONValue] = [:]
        ifd0["Make"] = Self.string(tiff[kCGImagePropertyTIFFMake as String])
        ifd0["Model"] = Self.string(tiff[kCGImagePropertyTIFFModel as String])
        ifd0["ImageWidth"] = Self.number(rawProperties[kCGImagePropertyPixelWidth])
        ifd0["ImageHeight"] = Self.number(rawProperties[kCGImagePropertyPixelHeight])
        ifd0["Orientation"] = Self.number(tiff[kCGImagePropertyTIFFOrientation as String])
        ifd0["Rating"] = Self.number(tiff["Rating"])

        var exifSegment: [String: JSONValue] = [:]
        exifSegment["DateTimeOriginal"] = Self.string(exif[kCGImagePropertyExifDateTimeOriginal as String])
        exifSegment["DateTimeDigitized"] = Self.string(exif[kCGImagePropertyExifDateTimeDigitized as String])
        exifSegment["Make"] = Self.string(tiff[kCGImagePropertyTIFFMake as String])
        exifSegment["Model"] = Self.string(tiff[kCGImagePropertyTIFFModel as String])
        exifSegment["ExifImageWidth"] = Self.number(exif[kCGImagePropertyExifPixelXDimension as String])
        exifSegment["ExifImageHeight"] = Self.number(exif[kCGImagePropertyExifPixelYDimension as String])
        exifSegment["LensModel"] = Self.string(exif[kCGImagePropertyExifLensModel as String])
        exifSegment["FocalLength"] = Self.number(exif[kCGImagePropertyExifFocalLength as String])
        exifSegment["FNumber"] = Self.number(exif[kCGImagePropertyExifFNumber as String])
        exifSegment["ExposureTime"] = Self.exposureTime(exif[kCGImagePropertyExifExposureTime as String])
        exifSegment["ISO"] = Self.firstNumber(exif[kCGImagePropertyExifISOSpeedRatings as String])

        var gpsSegment: [String: JSONValue] = [:]
        if let latitude = Self.rawNumber(gps[kCGImagePropertyGPSLatitude as String]) {
            let ref = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) ?? "N"
            gpsSegment["latitude"] = .number(ref == "S" ? -latitude : latitude)
        }
        if let longitude = Self.rawNumber(gps[kCGImagePropertyGPSLongitude as String]) {
            let ref = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) ?? "E"
            gpsSegment["longitude"] = .number(ref == "W" ? -longitude : longitude)
        }
        gpsSegment["altitude"] = Self.number(gps[kCGImagePropertyGPSAltitude as String])

        var xmpSegment: [String: JSONValue] = [:]
        var dcSegment: [String: JSONValue] = [:]
        var xmpPresentKeys = Set<String>()
        if isJpeg {
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
               let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
                for tag in tags {
                    // 契约：xmp 分段用**本地名**（Rating/Label/…），与消费端
                    // MetadataService.embeddedAttributesFromParse（xmp["Rating"]/["Label"]）
                    // 严格一致；dc:* 归 dc 分段（dc["subject"] = 关键词数组）。
                    // IPTC 只在顶层 iptc 分段出现（消费端读 parsed.iptc），此处不再复制。
                    guard let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
                    let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
                    let value = CGImageMetadataTagCopyValue(tag)
                    // 存在即记录（值可能为空）：读侧据此区分"没有该字段"与"显式清空"。
                    xmpPresentKeys.insert(name)
                    if prefix == "dc" {
                        if name == "subject" {
                            dcSegment["subject"] = .array(Self.stringList(value).map { .string($0) })
                        } else {
                            dcSegment[name] = Self.json(value)
                        }
                        continue
                    }
                    xmpSegment[name] = Self.json(value)
                }
            }
        }

        return MetadataParseSegments(
            ifd0: ifd0.isEmpty ? nil : .object(ifd0),
            exif: exifSegment.isEmpty ? nil : .object(exifSegment),
            gps: gpsSegment.isEmpty ? nil : .object(gpsSegment),
            xmp: xmpSegment.isEmpty ? nil : .object(xmpSegment),
            dc: dcSegment.isEmpty ? nil : .object(dcSegment),
            iptc: iptc.isEmpty ? nil : .object(iptc.mapValues { Self.json($0) }),
            xmpPresentKeys: xmpPresentKeys
        )
    }

    // MARK: - 取值助手

    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }
        if let dict = value as? [CFString: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dict { result[(key as String)] = item }
            return result
        }
        return [:]
    }

    private static func string(_ value: Any?) -> JSONValue? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return .string(text)
    }

    private static func number(_ value: Any?) -> JSONValue? {
        if let number = value as? NSNumber { return .number(number.doubleValue) }
        if let number = value as? Double { return .number(number) }
        if let number = value as? Int { return .number(Double(number)) }
        return nil
    }

    private static func rawNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        return nil
    }

    private static func firstNumber(_ value: Any?) -> JSONValue? {
        if let values = value as? [Any] { return values.first.flatMap { number($0) } }
        return number(value)
    }

    /// TS: exifr 把 ExposureTime 归一为秒数字符串（"1/250" 形式由消费端展示）。
    private static func exposureTime(_ value: Any?) -> JSONValue? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        if seconds >= 1 { return .number(seconds) }
        let denominator = Int((1 / seconds).rounded())
        return .string("1/" + String(denominator))
    }

    /// 标签值 → JSON。
    ///
    /// 关键：ImageIO 对**数组型 XMP 属性**（dc:subject 等 rdf:Bag/Seq）返回的是
    /// 「CGImageMetadataTag 数组」——元素本身还是标签，值要再取一层。旧实现对这类
    /// 元素走 String(describing:) 兜底，产出
    /// "Optional(<CGImageMetadataTag 0x…> dc:[0] = alpha)" 伪值：它会被当成真实
    /// 关键词进入元数据缓存/写回路径（实测：JPEG 内嵌 XMP/IPTC 关键词全部损坏）。
    /// 这里对 CGImageMetadataTag 递归取值；其余未知类型仍保持旧的 description 兜底。
    private static func json(_ value: Any?) -> JSONValue {
        if let value {
            if let text = value as? String { return .string(text) }
            if let number = value as? NSNumber { return .number(number.doubleValue) }
            if let list = value as? [Any] { return .array(list.map { json($0) }) }
            if let dict = value as? [String: Any] {
                return .object(dict.mapValues { json($0) })
            }
            // CF 运行时判型 + 解包（CGImageMetadataTag 是 CF 类型，Swift 对 CF 类型的
            // 条件转换被编译器判为恒真而禁用，故走 typeID）。
            let object = value as AnyObject
            if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
                return json(CGImageMetadataTagCopyValue(object as! CGImageMetadataTag))
            }
        }
        return .string(String(describing: value))
    }

    /// dc:subject 的字符串列表：与旧实现同为「只收字符串元素」，额外把标签元素
    /// 递归解包后再取字符串（非数组/非字符串一律丢弃，不造伪值）。
    private static func stringList(_ value: Any?) -> [String] {
        guard case .array(let items) = json(value) else { return [] }
        return items.compactMap { $0.stringValue }
    }
}

/// TS: sharp(filePath).metadata() —— ImageIO 实现。
public struct ImageIODimensionsProvider: ImageDimensionsProvider {
    public init() {}

    public func metadata(filePath: String) async throws -> (width: Int?, height: Int?, size: Int?, format: String?)? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let size = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? NSNumber)??.intValue
        var format: String?
        if let uti = CGImageSourceGetType(source) as String? {
            format = UTType(uti)?.preferredFilenameExtension
        }
        if format == nil || format?.isEmpty == true {
            format = url.pathExtension.lowercased()
        }
        return (width: width, height: height, size: size, format: format)
    }
}
