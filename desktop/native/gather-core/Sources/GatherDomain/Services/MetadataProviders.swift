// desktop/native/gather-core/Sources/GatherDomain/Services/MetadataProviders.swift
// TS 源: desktop/src/main/services/metadata/metadata-writer.interface.ts（MetadataWriter /
// MetadataReader / MetadataWriteAttributes）+ metadata.service.ts 的 exifr/sharp 接入点
//
// 注入点设计（3.4 页面的宿主职责，实现留在 gather-app）：
// - XMPProvider：WP2a 已下移到 GatherProtocol/Protocol/XMPProvider.swift（交付
//   依赖面，Delivery 只能依赖 Protocol + Persistence）。
// - EmbeddedXMPReader：TS `MetadataWriterRouter.selectForRead()`（JPEG 内嵌 XMP
//   读取，exiftool 池），仅供 MetadataService 的有效属性合成使用。
// - ExifProvider / ImageDimensionsProvider：TS `exifr.parse` / `sharp(path).metadata()`
//   的宿主职责（EXIF 解析与缩略图尺寸提取）。
//
// WP2a：XMPProvider / MetadataWriteAttributes 已下移到
// GatherProtocol/Protocol/XMPProvider.swift（GatherDelivery 的依赖面）。

import Foundation
import GatherProtocol

/// TS: MetadataWriterRouter.selectForRead() —— 内嵌 XMP 读取（仅 JPEG 走宿主
/// exiftool 池；RAW/侧车模式由 XMPProvider 直接服务，不注入本协议）。
public protocol EmbeddedXMPReader: Sendable {
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes
}

/// TS: exifr.parse 的分段输出（ifd0/exif/gps/xmp/dc/iptc，mergeOutput: false）。
public struct MetadataParseSegments: Equatable, Sendable {
    public var ifd0: JSONValue?
    public var exif: JSONValue?
    public var gps: JSONValue?
    public var xmp: JSONValue?
    public var dc: JSONValue?
    public var iptc: JSONValue?

    public init(ifd0: JSONValue? = nil, exif: JSONValue? = nil, gps: JSONValue? = nil, xmp: JSONValue? = nil, dc: JSONValue? = nil, iptc: JSONValue? = nil) {
        self.ifd0 = ifd0
        self.exif = exif
        self.gps = gps
        self.xmp = xmp
        self.dc = dc
        self.iptc = iptc
    }
}

/// TS: exifr.parse（宿主职责）。返回 nil 表示解析失败（走 sharp 兜底）。
public protocol ExifProvider: Sendable {
    /// isJpeg = true 时按 TS 选项 `{ xmp: true, iptc: true, mergeOutput: false }`
    /// 解析（内嵌 XMP/IPTC 分段参与有效属性合成）；RAW 仅 `{ mergeOutput: false }`。
    func parse(filePath: String, isJpeg: Bool) async throws -> MetadataParseSegments?
}

/// TS: `sharp(filePath).metadata()`（宿主职责，尺寸/文件大小/格式兜底）。
public protocol ImageDimensionsProvider: Sendable {
    func metadata(filePath: String) async throws -> (width: Int?, height: Int?, size: Int?, format: String?)?
}
