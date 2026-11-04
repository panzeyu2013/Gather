// desktop/native/gather-core/Sources/GatherProtocol/Protocol/MetadataProviders.swift
// 元数据读取端口的纯接口（#1 C4：从 Application 上移）。
//
// 为什么放 Protocol：实现住在 GatherAnalysis（ImageIO），消费方在 Application 与
// GatherMetadataIO；接口放中间层，两个消费方都不用反向依赖。
import Foundation

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
