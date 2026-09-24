// desktop/native/gather-core/Sources/GatherCore/Metadata/MetadataProviderContract.swift
// TS 源: desktop/src/main/services/metadata/metadata-writer.interface.ts（MetadataWriter /
// MetadataReader / MetadataWriteAttributes）+ metadata.service.ts 的 exifr/sharp 接入点
//
// 注入点设计（3.4 页面的宿主职责，实现留在 gather-app）：
// - XMPProvider：TS `MetadataWriterRouter.selectSidecar()`（XMP 侧车 writer）的
//   Swift 侧等价物。所有 XMP 读写（readKeywords/readAttributes/writeAttributes/
//   backup/restore）+ 文件存在性/删除都经此注入；host 的 exiftool/文件系统实现
//   后续落地。协调器/写回/变更服务只依赖本协议，零文件系统依赖，Linux 可单测。
// - EmbeddedXMPReader：TS `MetadataWriterRouter.selectForRead()`（JPEG 内嵌 XMP
//   读取，exiftool 池），仅供 MetadataService 的有效属性合成使用。
// - ExifProvider / ImageDimensionsProvider：TS `exifr.parse` / `sharp(path).metadata()`
//   的宿主职责（EXIF 解析与缩略图尺寸提取）。
// - C1BridgeProvider：capture-one osascript 桥契约（见 CaptureOneSyncState.swift）。
//
// TS MetadataWriteAttributes 的键集与 MetadataWriteAttributes 的 Codable JSON 形状
// 逐字一致（keywords/rating/label/dateTaken/latitude/longitude）。

import Foundation

/// TS: MetadataWriteAttributes —— XMP 可写属性集。
public struct MetadataWriteAttributes: Codable, Equatable, Sendable {
    public var keywords: [String]? // TS: keywords?
    public var rating: Double? // TS: rating?
    public var label: String? // TS: label?
    public var dateTaken: String? // TS: dateTaken?
    public var latitude: Double? // TS: latitude?
    public var longitude: Double? // TS: longitude?

    public init(
        keywords: [String]? = nil,
        rating: Double? = nil,
        label: String? = nil,
        dateTaken: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.keywords = keywords
        self.rating = rating
        self.label = label
        self.dateTaken = dateTaken
        self.latitude = latitude
        self.longitude = longitude
    }

    /// TS: `Object.keys(attributes).length === 0`（corrupt sidecar 守卫）。
    public var isEmpty: Bool {
        keywords == nil && rating == nil && label == nil
            && dateTaken == nil && latitude == nil && longitude == nil
    }

    /// TS: `{ ...attributes }`（仅存在的键）。
    public var asJSONValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let keywords { object["keywords"] = .array(keywords.map { .string($0) }) }
        if let rating { object["rating"] = .number(rating) }
        if let label { object["label"] = .string(label) }
        if let dateTaken { object["dateTaken"] = .string(dateTaken) }
        if let latitude { object["latitude"] = .number(latitude) }
        if let longitude { object["longitude"] = .number(longitude) }
        return .object(object)
    }

    /// 从 JSONValue（outbox base_values/patch 语义）构造。
    public init(jsonValue: JSONValue) {
        self.init(
            keywords: jsonValue["keywords"]?.arrayValue,
            rating: jsonValue["rating"]?.numberValue,
            label: jsonValue["label"]?.stringValue,
            dateTaken: jsonValue["dateTaken"]?.stringValue,
            latitude: jsonValue["latitude"]?.numberValue,
            longitude: jsonValue["longitude"]?.numberValue
        )
    }
}

/// TS: MetadataReader + MetadataWriter（XMP 侧车 writer 的最小面）。
/// 实现由 gather-app 宿主提供（exiftool/文件系统桥，3.4 页面阶段），
/// 本层所有服务只依赖该协议。
public protocol XMPProvider: Sendable {
    /// TS: MetadataReader.readKeywords —— 读取照片的 XMP 关键词（失败抛错，
    /// 调用方按 TS 语义处理：preview 里 corrupt/missing 视为空列表）。
    func readKeywords(photoPath: String) async throws -> [String]

    /// TS: MetadataReader.readAttributes —— 读取可写属性（keywords/rating/label/...）。
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes

    /// TS: MetadataWriter.writeAttributes —— 将属性写入 XMP（原子替换）。
    func writeAttributes(photoPath: String, attributes: MetadataWriteAttributes) async throws

    /// TS: MetadataWriter.backup —— 写前安全备份，返回备份路径；原文件不存在时
    /// 宿主返回空串（对应 TS 侧"无原始 sidecar 时无备份"语义）。
    func backup(photoPath: String) async throws -> String

    /// TS: MetadataWriter.restore —— 从备份恢复原文件。
    func restore(photoPath: String, backupPath: String) async throws

    /// TS: `fs.existsSync(path)`（preview 的 willCreate / 协调器的 cleanup 判定）。
    func fileExists(_ path: String) -> Bool

    /// TS: `fs/promises.unlink(path)`（cleanup 删除无备份的 sidecar、orphan 处理）。
    func removeFile(_ path: String) async throws
}

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
