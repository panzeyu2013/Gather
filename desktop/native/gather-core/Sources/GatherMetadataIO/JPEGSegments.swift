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
//
// P1 下一波（plan §3.2.7）：段解析抽成 `JPEGSegmentScanner`（顺序喂字节的状态机），
// 内存路径（`JPEGDocument`，测试/纯函数）与磁盘路径（`EmbeddedJPEGSession` 的
// 1MiB 顺序读）**共用同一份实现**，两条路径不会再漂移。`JPEGDocument` 的 scan
// 改为原 data 的零拷贝切片，去掉了 `[UInt8](data)` 的整文件拷贝。
import Foundation
import CryptoKit

/// 内嵌元数据写盘的稳定错误码（对齐 SidecarXMPError 的形态）。
enum EmbeddedJPEGError: Error, Equatable, CustomStringConvertible {
    case notJPEG
    case truncated(offset: Int64)
    case noScan
    case segmentTooLarge(marker: UInt8, bytes: Int)
    case layoutUnsupported(String)
    /// 头部（SOI…SOS）超过上限：内嵌写回拒绝比整文件更贵的慢路径。
    case headerTooLarge(bytes: Int64)

    var code: String {
        switch self {
        case .notJPEG: "EMBEDDED_NOT_JPEG"
        case .truncated: "EMBEDDED_JPEG_TRUNCATED"
        case .noScan: "EMBEDDED_JPEG_NO_SCAN"
        case .segmentTooLarge: "EMBEDDED_SEGMENT_TOO_LARGE"
        case .layoutUnsupported: "EMBEDDED_LAYOUT_UNSUPPORTED"
        case .headerTooLarge: "EMBEDDED_HEADER_TOO_LARGE"
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
        case .headerTooLarge(let bytes):
            "EMBEDDED_HEADER_TOO_LARGE: bytes=\(bytes)"
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

/// SOI → SOS 的段扫描器：只前向消费字节，产出头部段表与扫描段起点。
///
/// 用法（两条路径共用）：
/// ```
/// var scanner = JPEGSegmentScanner()
/// while let chunk = 读一块() {
///     if try scanner.feed(chunk) { break }   // true = 已到达 SOS
/// }
/// try scanner.finish()                      // 未到达 SOS → truncated
/// ```
///
/// 内存：已消费字节不再持有（`buffer` 只保留"最后一个不完整段"的尾部），
/// 所以文件多大都与扫描器内存无关；段载荷复制一次（与旧实现一致）。
struct JPEGSegmentScanner {
    /// 已解析的头部段（顺序即文件顺序）。
    private(set) var segments: [JPEGSegment] = []
    /// SOS 标记（0xFF 0xDA 的第一个字节）在文件中的绝对偏移；nil = 尚未到达。
    private(set) var scanOffset: Int64?
    /// 到达 SOS 时"已经读进缓冲"的扫描段前缀字节（调用方哈希后从这里继续读，
    /// 避免把同一段字节再读一遍）。
    private(set) var scanRemainder = Data()

    /// 尚未解析完的尾部字节（含已到 SOS 时的剩余字节，直到被取走）。
    private var buffer = Data()
    /// buffer 首字节在文件中的绝对偏移。
    private var bufferBase: Int64 = 0
    private var sawSOI = false

    /// 喂入下一块（严格顺序）。返回 true 表示已到达 SOS，此后不得再喂。
    mutating func feed(_ chunk: Data) throws -> Bool {
        if scanOffset != nil { return true }
        if chunk.isEmpty { return false }
        // 首次喂入直接复用调用方的存储（大文件路径下避免一次整段拷贝）；
        // 之后的追加只复制"最后一个不完整段"的尾部（≤ 64KB 级）。
        if buffer.isEmpty {
            buffer = chunk
        } else {
            buffer.append(chunk)
        }
        return try scanAvailable()
    }

    /// 结束喂入：仍未到达 SOS 即文件截断（绝不返回半解析结果）。
    func finish() throws {
        guard scanOffset == nil else { return }
        throw EmbeddedJPEGError.truncated(offset: bufferBase)
    }

    /// 消费当前缓冲里所有完整段，返回是否到达 SOS。
    private mutating func scanAvailable() throws -> Bool {
        let end = buffer.endIndex
        var cursor = buffer.startIndex
        if !sawSOI {
            guard buffer.count >= 2 else { return false }
            guard buffer[cursor] == 0xFF,
                  buffer[buffer.index(after: cursor)] == 0xD8 else {
                throw EmbeddedJPEGError.notJPEG
            }
            cursor = buffer.index(cursor, offsetBy: 2)
            sawSOI = true
        }
        while cursor < end {
            guard buffer[cursor] == 0xFF else {
                throw EmbeddedJPEGError.truncated(offset: absolute(cursor))
            }
            // 0xFF 可以重复出现（填充字节）：跳过连续的 0xFF 取标记码。
            var code = buffer.index(after: cursor)
            while code < end, buffer[code] == 0xFF { code = buffer.index(after: code) }
            guard code < end else { break }
            let marker = buffer[code]
            if marker == 0xDA {
                // SOS：其后全部是熵编码数据。没有 EOI 也算合法（读侧只要求能解码），
                // 但绝不截断或重排这部分字节。
                let start = absolute(cursor)
                let remainder = Data(buffer[cursor...])
                scanOffset = start
                scanRemainder = remainder
                buffer = Data()
                bufferBase = start + Int64(remainder.count)
                return true
            }
            if marker == 0xD9 {
                throw EmbeddedJPEGError.noScan
            }
            // 无长度字段的标记：TEM(0x01) 与 RSTn(0xD0…0xD7)。
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                cursor = buffer.index(after: code)
                continue
            }
            let lengthHigh = buffer.index(after: code)
            guard lengthHigh < end else { break }
            let lengthLow = buffer.index(after: lengthHigh)
            guard lengthLow < end else { break }
            let length = Int(buffer[lengthHigh]) << 8 | Int(buffer[lengthLow])
            guard length >= 2 else {
                throw EmbeddedJPEGError.layoutUnsupported(
                    "段长度 < 2 (marker=0x\(String(marker, radix: 16)))")
            }
            let payloadStart = buffer.index(after: lengthLow)
            guard let payloadEnd = buffer.index(code, offsetBy: length + 1, limitedBy: end) else {
                break
            }
            segments.append(JPEGSegment(
                marker: marker, payload: Data(buffer[payloadStart..<payloadEnd])))
            cursor = payloadEnd
        }
        bufferBase = absolute(cursor)
        buffer = buffer[cursor...]
        return false
    }

    /// 缓冲内下标 → 文件绝对偏移。
    private func absolute(_ index: Data.Index) -> Int64 {
        bufferBase + Int64(buffer.distance(from: buffer.startIndex, to: index))
    }
}

/// 头部重建（纯函数）：段表 + 编辑指令 → SOI…SOS 之前的字节。
/// `JPEGDocument.rebuilding`（需要拼 scan）与流式写盘（只写头部）共用它。
enum JPEGHeaderWriter {
    /// 重建头部。未编辑的段逐字节保留；新段插入位置：
    /// 最后一个 Exif APP1 之后 → 否则最后一个 APP0 之后 → 否则紧跟 SOI。
    static func rebuild(
        segments: [JPEGSegment],
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
        return output
    }
}

/// 已解析的 JPEG：头部段表 + 扫描段。内存路径（测试/纯函数/restore）用，
/// 写盘快路径只借用它的段扫描与头部重建逻辑，不构造整份 data。
struct JPEGDocument {
    let segments: [JPEGSegment]
    /// SOS 标记的绝对偏移 = 头部字节数。
    let scanOffset: Int64
    /// SOS 标记起到文件末尾（含 EOI 与可能的尾部字节），逐字节不解析。
    /// 是原 data 的零拷贝切片（旧实现整段复制过一次）。
    let scan: Data

    init(data: Data) throws {
        // 旧实现的早期守卫（<4 字节 / 无 SOI 一律 notJPEG）保持不变：错误码是外部契约。
        guard data.count >= 4,
              data[data.startIndex] == 0xFF,
              data[data.index(after: data.startIndex)] == 0xD8 else {
            throw EmbeddedJPEGError.notJPEG
        }
        var scanner = JPEGSegmentScanner()
        if try scanner.feed(data), let offset = scanner.scanOffset {
            segments = scanner.segments
            scanOffset = offset
            scan = data[data.index(data.startIndex, offsetBy: Int(offset))...]
            return
        }
        try scanner.finish()
        throw EmbeddedJPEGError.truncated(offset: Int64(data.count))
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

    /// 重建整份文件（头部 + scan）。未编辑的段逐字节保留。
    func rebuilding(
        xmp: JPEGSegmentEdit = .keep,
        iptc: JPEGPhotoshopEdit = .keep
    ) throws -> Data {
        var output = try JPEGHeaderWriter.rebuild(segments: segments, xmp: xmp, iptc: iptc)
        output.append(scan)
        return output
    }
}
