// desktop/native/gather-core/Sources/GatherApplication/Services/MetadataProviders.swift
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
/// exiftool 池；RAW/sidecar 模式由 XMPProvider 直接服务，不注入本协议）。
public protocol EmbeddedXMPReader: Sendable {
    func readAttributes(photoPath: String) async throws -> MetadataWriteAttributes
}
