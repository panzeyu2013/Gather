// desktop/native/gather-app/Sources/GatherHost/Embedded/JPEGSegments.swift
// JPEG 段表：把 SOI…SOS 之间的头部段解析成「标记 + 载荷」，SOS 之后整体视为 scan
// （熵编码数据，逐字节不解析）。
//
// 为什么需要它：ImageIO 的 CGImageDestinationCopyImageSource 能保像素，但**不会**
// 更新 IPTC-IIM（实测写后 IIM 仍是旧值），而"清空"要求 IIM 数据集消失。唯一可靠的
// 做法是自己改头部段、把 scan 原样拼回去。
//
// 不变量（由 JPEGSegmentsTests 钉死）：
// - 解析 → 原样重建必须字节级相等；
// - 任何编辑都不改变 scan 的 SHA256；
// - 段载荷 + 2 字节长度必须 <= 65535，超限显式失败，绝不静默截断。
import Foundation
import CryptoKit

/// 内嵌元数据写盘的稳定错误码（对齐 SidecarXMPError 的形态）。
enum EmbeddedJPEGError: Error, Equatable, CustomStringConvertible {
    case notJPEG
    case truncated(offset: Int)
    case noScan
    case segmentTooLarge(marker: UInt8, bytes: Int)
    case layoutUnsupported(String)

    var code: String {
        switch self {
        case .notJPEG: "EMBEDDED_NOT_JPEG"
        case .truncated: "EMBEDDED_JPEG_TRUNCATED"
        case .noScan: "EMBEDDED_JPEG_NO_SCAN"
        case .segmentTooLarge: "EMBEDDED_SEGMENT_TOO_LARGE"
        case .layoutUnsupported: "EMBEDDED_LAYOUT_UNSUPPORTED"
        }
    }

    var description: String {
        switch self {
        case .notJPEG:
            "EMBEDDED_NOT_JPEG"
        case .truncated(let offset):
            "EMBEDDED_JPEG_TRUNCATED: offset=\(offset)"
        case .noScan:
            "EMBEDDED_JPEG_NO_SCAN"
        case .segmentTooLarge(let marker, let bytes):
            "EMBEDDED_SEGMENT_TOO_LARGE: marker=0x\(String(marker, radix: 16)) bytes=\(bytes)"
        case .layoutUnsupported(let reason):
            "EMBEDDED_LAYOUT_UNSUPPORTED: " + reason
        }
    }
}

/// 一个头部段（不含长度字段本身）。
struct JPEGSegment: Equatable {
    let marker: UInt8
    let payload: Data

    static let xmpIdentifier = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let exifIdentifier = Data("Exif\0\0".utf8)
    static let photoshopIdentifier = Data("Photoshop 3.0\0".utf8)

    var isAPP0: Bool { marker == 0xE0 }
    var isExif: Bool { marker == 0xE1 && payload.starts(with: Self.exifIdentifier) }
    var isXMP: Bool { marker == 0xE1 && payload.starts(with: Self.xmpIdentifier) }
    var isPhotoshop: Bool { marker == 0xED && payload.starts(with: Self.photoshopIdentifier) }

    /// XMP 包体（去掉命名空间标识）；非 XMP 段返回 nil。
    var xmpPacket: Data? {
        guard isXMP else { return nil }
        return payload.dropFirst(Self.xmpIdentifier.count)
    }

    /// Photoshop IRB 资源区（去掉 "Photoshop 3.0" 标识）；非 APP13 返回 nil。
    var photoshopIRB: Data? {
        guard isPhotoshop else { return nil }
        return payload.dropFirst(Self.photoshopIdentifier.count)
    }
}

/// 段编辑指令：nil 语义不明确，故用显式三态。
enum JPEGSegmentEdit: Equatable {
    case keep
    case remove
    case replace(Data)
}

/// APP13（Photoshop IRB）编辑指令。资源区按载荷拆段，所以用资源列表而不是整块字节。
enum JPEGPhotoshopEdit: Equatable {
    case keep
    case remove
    case replace([PhotoshopIRB])
}

struct JPEGDocument {
    let segments: [JPEGSegment]
    /// SOS 标记起到文件末尾（含 EOI 与可能的尾部字节），逐字节不解析。
    let scan: Data

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw EmbeddedJPEGError.notJPEG
        }
        var index = 2
        var parsed: [JPEGSegment] = []
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else {
                throw EmbeddedJPEGError.truncated(offset: index)
            }
            var cursor = index + 1
            while cursor < bytes.count, bytes[cursor] == 0xFF { cursor += 1 }
            guard cursor < bytes.count else { throw EmbeddedJPEGError.truncated(offset: index) }
            let marker = bytes[cursor]
            if marker == 0xDA {
                // SOS：其后全部是熵编码数据。没有 EOI 也算合法（读侧只要求能解码），
                // 但绝不截断或重排这部分字节。
                scan = Data(bytes[index...])
                segments = parsed
                return
            }
            if marker == 0xD9 {
                throw EmbeddedJPEGError.noScan
            }
            // 无长度字段的标记：TEM(0x01) 与 RSTn(0xD0…0xD7)。
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index = cursor + 1
                continue
            }
            guard cursor + 2 < bytes.count else {
                throw EmbeddedJPEGError.truncated(offset: cursor)
            }
            let length = Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2])
            guard length >= 2 else {
                throw EmbeddedJPEGError.layoutUnsupported("段长度 < 2 (marker=0x\(String(marker, radix: 16)))")
            }
            let payloadStart = cursor + 3
            let payloadEnd = cursor + 1 + length
            guard payloadEnd <= bytes.count else {
                throw EmbeddedJPEGError.truncated(offset: cursor)
            }
            parsed.append(JPEGSegment(marker: marker, payload: Data(bytes[payloadStart..<payloadEnd])))
            index = payloadEnd
        }
        throw EmbeddedJPEGError.truncated(offset: index)
    }

    var xmpPacket: Data? { segments.first(where: \.isXMP)?.xmpPacket }
    var photoshopIRB: Data? { segments.first(where: \.isPhotoshop)?.photoshopIRB }
    /// 全部 APP13 的 IRB 资源区（按段序）。Photoshop 在资源区 >64KB 时会拆成多个
    /// APP13；只取首个会丢资源（缩略图 / 裁剪路径 / 大 IPTC）。
    var photoshopIRBPayloads: [Data] { segments.compactMap(\.photoshopIRB) }

    /// scan 的 SHA256（写前写后必须相等）。
    var scanDigest: String {
        SHA256.hash(data: scan).map { String(format: "%02x", $0) }.joined()
    }

    /// 重建整份文件。未编辑的段逐字节保留；新段插入位置：
    /// 最后一个 Exif APP1 之后 → 否则最后一个 APP0 之后 → 否则紧跟 SOI。
    func rebuilding(
        xmp: JPEGSegmentEdit = .keep,
        iptc: JPEGPhotoshopEdit = .keep
    ) throws -> Data {
        let hasXMP = segments.contains(where: \.isXMP)
        let hasIPTC = segments.contains(where: \.isPhotoshop)
        var insertionIndex = 0
        if let exif = segments.lastIndex(where: \.isExif) {
            insertionIndex = exif + 1
        } else if let app0 = segments.lastIndex(where: \.isAPP0) {
            insertionIndex = app0 + 1
        }

        var output = Data([0xFF, 0xD8])
        var emittedXMP = false
        var emittedIPTC = false

        func appendSegment(marker: UInt8, payload: Data) throws {
            let length = payload.count + 2
            guard length <= 0xFFFF else {
                throw EmbeddedJPEGError.segmentTooLarge(marker: marker, bytes: payload.count)
            }
            output.append(0xFF)
            output.append(marker)
            output.append(UInt8((length >> 8) & 0xFF))
            output.append(UInt8(length & 0xFF))
            output.append(payload)
        }

        func emitPending() throws {
            if !emittedXMP, case .replace(let packet) = xmp, !hasXMP {
                try appendSegment(marker: 0xE1, payload: JPEGSegment.xmpIdentifier + packet)
                emittedXMP = true
            }
            if !emittedIPTC, !hasIPTC {
                try emitPhotoshop()
            }
        }

        /// 把 IRB 资源区按「资源边界」拆成多个 APP13（每段载荷 <= 65533）。
        /// 单个资源超过上限时显式失败，绝不截断或静默丢弃后续资源。
        func emitPhotoshop() throws {
            guard case .replace(let irbs) = iptc, !irbs.isEmpty else {
                emittedIPTC = true
                return
            }
            let limit = 0xFFFF - 2 - JPEGSegment.photoshopIdentifier.count
            var chunk: [PhotoshopIRB] = []
            var chunkBytes = 0
            func flush() throws {
                guard !chunk.isEmpty else { return }
                let payload = JPEGSegment.photoshopIdentifier + PhotoshopIRBList.encode(chunk)
                try appendSegment(marker: 0xED, payload: payload)
                chunk = []
                chunkBytes = 0
            }
            for irb in irbs {
                let size = PhotoshopIRBList.encode([irb]).count
                guard size <= limit else {
                    throw EmbeddedJPEGError.segmentTooLarge(marker: 0xED, bytes: size)
                }
                if chunkBytes + size > limit { try flush() }
                chunk.append(irb)
                chunkBytes += size
            }
            try flush()
            emittedIPTC = true
        }

        for (offset, segment) in segments.enumerated() {
            if offset == insertionIndex { try emitPending() }
            if segment.isXMP {
                switch xmp {
                case .keep:
                    try appendSegment(marker: segment.marker, payload: segment.payload)
                case .remove:
                    break
                case .replace(let packet):
                    // 多个 XMP 段（非标准但真实存在）只保留第一个替换结果，
                    // 否则会写出重复包体（读侧取第一个，语义未定义）。
                    if !emittedXMP {
                        try appendSegment(marker: 0xE1, payload: JPEGSegment.xmpIdentifier + packet)
                        emittedXMP = true
                    }
                }
                continue
            }
            if segment.isPhotoshop {
                switch iptc {
                case .keep:
                    try appendSegment(marker: segment.marker, payload: segment.payload)
                case .remove:
                    break
                case .replace:
                    // 所有 APP13 的资源已合并成一个列表，由首个段一次写出（可能拆成多段）；
                    // 后续原始段不再重复追加，否则会写出重复 IRB 或丢掉没被解析的资源。
                    if !emittedIPTC { try emitPhotoshop() }
                }
                continue
            }
            try appendSegment(marker: segment.marker, payload: segment.payload)
        }
        if insertionIndex >= segments.count { try emitPending() }
        output.append(scan)
        return output
    }
}
