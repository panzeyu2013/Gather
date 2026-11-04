// desktop/native/gather-core/Sources/GatherApplication/Services/Metadata/MetadataDiskReader.swift
// 盘上属性的读取与合成（#6 S1：从 MetadataService 切出的第二刀）。
//
// 职责：把「内嵌 XMP + sidecar」读成一份有效属性，并回答一次读盘能回答的问题
// （是否可内嵌读、快照是否 embeddedReadable）。这一簇的硬约束：
// - 每张照片**只读一次 sidecar**：同一次读取同时服务校验与缓存投影；
// - 每张照片**只解析一次 EXIF**：调用方把 parsed 传进来，不在这里再解析；
// - embeddedReadable 的语义（nil parse / throw 都算不可读）必须原样保留，
//   否则「清空 JPEG 内嵌字段」会谎报成功。
//
// 无状态（三个依赖都是构造后不变的 let），故直接 Sendable。
import Foundation
import GatherProtocol

public struct MetadataDiskReader: Sendable {
    private let xmp: any XMPProvider
    private let exif: (any ExifProvider)?
    private let embeddedReader: (any EmbeddedXMPReader)?

    init(
        xmp: any XMPProvider,
        exif: (any ExifProvider)?,
        embeddedReader: (any EmbeddedXMPReader)?
    ) {
        self.xmp = xmp
        self.exif = exif
        self.embeddedReader = embeddedReader
    }

        /// TS: readEffectiveAttributes —— 内嵌读取 + sidecar 读取合并（后者覆盖前者）。
    func readEffectiveAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        if let embeddedReader {
            let embedded = try await embeddedReader.readAttributes(photoPath: photoPath)
            let sidecar = try await xmp.readAttributes(photoPath: photoPath)
            return MetadataAttributes.mergeAttributes(embedded, sidecar)
        }
        return try await xmp.readAttributes(photoPath: photoPath)
    }

    /// P0 / B1：**盘上现状**的统一读取入口（模板预览/写回、triage undo 用）。
    ///
    /// 与 readEffectiveAttributesOnce 的差别：
    /// - 面向"任意路径"（不是 session 内照片），不做缓存投影；
    /// - JPEG 走内嵌解析（XMP + IPTC）再叠加 sidecar；RAW 只读 sidecar；
    /// - 解析失败不抛错，退化为 sidecar 读（模板 preview 的 disk=nil 语义由调用方处理）。
    ///
    /// 为什么必须读内嵌：Bridge/Lightroom 把 caption/版权写在 JPEG 的 IPTC-IIM 里，
    /// 只读 .xmp 会让 preview 把"盘上已有值"当成未知（keepExternal 失效），
    /// 也会让 triage undo 拿到错误的"当前星级"。
    public func diskAttributes(photoPath: String) async throws -> MetadataWriteAttributes {
        let sidecar = try await xmp.readAttributes(photoPath: photoPath)
        return await diskSnapshot(photoPath: photoPath, sidecar: sidecar).attributes
    }

    /// 盘上合成值 + "内嵌是否读得到"。
    ///
    /// P1：JPEG 的 APP1 读不到时（parse 返回 nil 或抛错）不能当成"没有内嵌信息"——
    /// 清空类写入在看不到内嵌值的情况下必须按**不确定**处理，否则会谎报清空成功。
    struct DiskSnapshot {
        let attributes: MetadataWriteAttributes
        let embeddedReadable: Bool
    }

    /// 已读 sidecar 的盘上值合成（写后回读用：一次 sidecar 读同时服务校验与缓存投影）。
    ///
    /// P1：JPEG 必须叠加内嵌 IPTC/XMP。sidecar 只是 JPEG 的"可写投影"，Bridge/C1
    /// 写的标题/版权仍在 APP1 里；只看 sidecar 会把它们从缓存投影里清掉。
    func diskSnapshot(
        photoPath: String,
        sidecar: MetadataWriteAttributes
    ) async -> DiskSnapshot {
        guard Self.isJpegPath(photoPath), let exif else {
            return DiskSnapshot(attributes: sidecar, embeddedReadable: true)
        }
        do {
            guard let parsed = try await exif.parse(filePath: photoPath, isJpeg: true) else {
                // 读不到 APP1：无法判定内嵌值，标记不可读。
                return DiskSnapshot(attributes: sidecar, embeddedReadable: false)
            }
            guard let embedded = MetadataAttributes.embeddedAttributesFromParse(parsed) else {
                return DiskSnapshot(attributes: sidecar, embeddedReadable: true)
            }
            return DiskSnapshot(
                attributes: MetadataAttributes.mergeAttributes(embedded, sidecar), embeddedReadable: true)
        } catch {
            // 内嵌解析失败：退化为只读 sidecar（面板不阻断），但标记不可读供清空判定用。
            GatherLogger.log(
                "diskAttributes embedded parse failed (path token=\(TSPath.basename(photoPath))): "
                    + "\(error)", level: .debug)
            return DiskSnapshot(attributes: sidecar, embeddedReadable: false)
        }
    }

    /// JPEG 判定（扩展名大小写不敏感）。
    static func isJpegPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
    }

    /// TS: readEffectiveAttributesOnce —— 单次读取路径：
    /// - RAW / sidecar-mode（TS: selected === sidecar）：一次 sidecar 读。
    /// - JPEG 且内嵌派生可用（IPTC-only 关键词之外）：从已解析段派生 + 一次 sidecar 读。
    /// - 其余回退 readEffectiveAttributes（exiftool 池）。
    func readEffectiveAttributesOnce(
        photoPath: String,
        parsed: MetadataParseSegments,
        isJpeg: Bool
    ) async throws -> MetadataWriteAttributes {
        if !isJpeg {
            return try await xmp.readAttributes(photoPath: photoPath)
        }
        if let embedded = MetadataAttributes.embeddedAttributesFromParse(parsed) {
            let sidecar = try await xmp.readAttributes(photoPath: photoPath)
            return MetadataAttributes.mergeAttributes(embedded, sidecar)
        }
        return try await readEffectiveAttributes(photoPath: photoPath)
    }
}
