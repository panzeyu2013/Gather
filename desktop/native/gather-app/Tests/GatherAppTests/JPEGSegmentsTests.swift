// desktop/native/gather-app/Tests/GatherAppTests/JPEGSegmentsTests.swift
// JPEG 段表：解析/重建的字节级不变量（原样重建相等、scan 哈希不变、超限显式失败）。
//
// 一律在测试内用 ImageIO 生成真实 JPEG（仓库不放二进制夹具），指纹只依赖生成器参数。

import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GatherHost

private func makeJPEG(width: Int = 32, height: Int = 32, iptc: [String: Any]? = nil) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    for y in 0..<height {
        for x in 0..<width {
            context.setFillColor(
                red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                blue: 0.25, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let iptc {
        properties[kCGImagePropertyIPTCDictionary] = iptc
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    let finalized = CGImageDestinationFinalize(destination)
    #expect(finalized)
    return data as Data
}

private func sampleIPTC() -> [String: Any] {
    [
        "Caption/Abstract": "旧标题",
        "CopyrightNotice": "(c) Gather",
        "Keywords": ["wedding", "probe"],
        "City": "Shanghai",
    ]
}

private func sampleXMPPacket(_ text: String) -> Data {
    let packet = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>\
    <x:xmpmeta xmlns:x="adobe:ns:meta/">\
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\
    <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(text)</rdf:li></rdf:Alt></dc:description>\
    </rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
    """
    return Data(packet.utf8)
}

@Suite("JPEG 段表（内嵌写盘底座）")
struct JPEGSegmentsTests {

    @Test("解析后原样重建必须字节级相等")
    func rebuildWithoutEditsIsIdentity() throws {
        let original = try makeJPEG(iptc: sampleIPTC())
        let document = try JPEGDocument(data: original)
        let hasPhotoshopSegment = document.segments.contains { $0.isPhotoshop }
        #expect(hasPhotoshopSegment, "夹具必须带 APP13")
        #expect(try document.rebuilding() == original)
    }

    @Test("替换 XMP：包体落位、scan 哈希不变、其它段逐字节保留")
    func replacingXMDPreservesScan() throws {
        let original = try makeJPEG(iptc: sampleIPTC())
        let document = try JPEGDocument(data: original)
        let packet = sampleXMPPacket("新标题")
        let rebuilt = try document.rebuilding(xmp: .replace(packet))
        let reparsed = try JPEGDocument(data: rebuilt)
        #expect(reparsed.xmpPacket == packet)
        #expect(reparsed.scanDigest == document.scanDigest)
        #expect(reparsed.photoshopIRB == document.photoshopIRB, "IPTC 段不得被 XMP 编辑波及")
        #expect(rebuilt.count != original.count || rebuilt == original)
    }

    @Test("无 XMP 时插入到 Exif/APP0 之后；再解析能读回")
    func insertsXMPWhenAbsent() throws {
        let original = try makeJPEG()
        let document = try JPEGDocument(data: original)
        #expect(document.xmpPacket == nil, "夹具不应带 XMP")
        let packet = sampleXMPPacket("新增标题")
        let rebuilt = try document.rebuilding(xmp: .replace(packet))
        let reparsed = try JPEGDocument(data: rebuilt)
        #expect(reparsed.xmpPacket == packet)
        #expect(reparsed.segments.first?.marker == 0xE0, "APP0 必须仍在最前")
        #expect(reparsed.scanDigest == document.scanDigest)
    }

    @Test("清空 XMP 与 IPTC：两个段都消失，scan 不变")
    func removesBothSegments() throws {
        let original = try makeJPEG(iptc: sampleIPTC())
        let seeded = try JPEGDocument(data: original)
            .rebuilding(xmp: .replace(sampleXMPPacket("待清空")))
        let seededDocument = try JPEGDocument(data: seeded)
        #expect(seededDocument.xmpPacket != nil)
        let cleared = try seededDocument.rebuilding(xmp: .remove, iptc: .remove)
        let reparsed = try JPEGDocument(data: cleared)
        #expect(reparsed.xmpPacket == nil)
        #expect(reparsed.photoshopIRB == nil)
        #expect(reparsed.scanDigest == seededDocument.scanDigest)
    }

    @Test("截断文件显式失败，不返回半解析结果")
    func truncatedFileThrows() throws {
        let original = try makeJPEG(iptc: sampleIPTC())
        let truncated = original.prefix(original.count / 2)
        #expect(throws: EmbeddedJPEGError.self) {
            _ = try JPEGDocument(data: Data(truncated))
        }
    }

    @Test("多个 APP13：keep 原样保留、replace 合并全部 IRB（不得丢弃后续段）")
    func multiAPP13IsMergedAndPreserved() throws {
        let base = try makeJPEG(iptc: sampleIPTC())
        let extra = makeAPP13([
            (0x0425, Data(repeating: 0xAA, count: 32)),
            (0x0409, Data([0x01, 0x02, 0x03])),
        ])
        let original = try injectAPP13(extra, into: base)

        let document = try JPEGDocument(data: original)
        #expect(document.photoshopIRBPayloads.count == 2, "夹具必须有两个 APP13")
        #expect(try document.rebuilding() == original, "keep 必须逐字节保留全部 APP13")

        // 合并全部资源的 IRB 后一次性写回：两个资源都必须还在（含非 0x0404）。
        var merged: [PhotoshopIRB] = []
        for payload in document.photoshopIRBPayloads {
            merged.append(contentsOf: try PhotoshopIRBList.parse(payload))
        }
        #expect(merged.contains { $0.resourceID == 0x0404 })
        #expect(merged.contains { $0.resourceID == 0x0425 })
        #expect(merged.contains { $0.resourceID == 0x0409 })

        let rebuilt = try document.rebuilding(iptc: .replace(merged))
        let reparsed = try JPEGDocument(data: rebuilt)
        #expect(reparsed.scanDigest == document.scanDigest)
        #expect(reparsed.photoshopIRBPayloads.count == 1, "合并后只写一个 APP13")
        let survivors = try PhotoshopIRBList.parse(try #require(reparsed.photoshopIRB))
        #expect(Set(survivors.map(\.resourceID)) == Set([0x0404, 0x0425, 0x0409]))
    }

    @Test("资源区超 64KB：按资源边界拆成多个 APP13，回读资源一个不少")
    func oversizeIRBSplitsAcrossSegments() throws {
        let document = try JPEGDocument(data: makeJPEG())
        let big = (0..<6).map { index in
            PhotoshopIRB(resourceID: UInt16(0x0500 + index), name: Data(), data: Data(repeating: 0x5A, count: 20_000))
        }
        let rebuilt = try document.rebuilding(iptc: .replace(big))
        let reparsed = try JPEGDocument(data: rebuilt)
        #expect(reparsed.photoshopIRBPayloads.count > 1, "6×20KB 必须被拆段")
        var restored: [PhotoshopIRB] = []
        for payload in reparsed.photoshopIRBPayloads {
            restored.append(contentsOf: try PhotoshopIRBList.parse(payload))
        }
        #expect(restored == big)
        #expect(reparsed.scanDigest == document.scanDigest)
    }

    @Test("非 JPEG 显式失败")
    func nonJPEGThrows() throws {
        #expect(throws: EmbeddedJPEGError.self) {
            _ = try JPEGDocument(data: Data("not a jpeg".utf8))
        }
    }

    @Test("段超限（> 65533 载荷）显式失败，不静默截断")
    func oversizeSegmentThrows() throws {
        let document = try JPEGDocument(data: makeJPEG())
        let huge = Data(repeating: 0x20, count: 70_000)
        #expect(throws: EmbeddedJPEGError.self) {
            _ = try document.rebuilding(xmp: .replace(huge))
        }
    }
}

// MARK: - 多 APP13 夹具

/// 构造一个 APP13（Photoshop IRB）段：调用方给出 (resourceID, data) 列表。
private func makeAPP13(_ resources: [(UInt16, Data)]) -> Data {
    var payload = Data("Photoshop 3.0\0".utf8)
    for (id, data) in resources {
        payload.append(contentsOf: [0x38, 0x42, 0x49, 0x4D])  // 8BIM
        payload.append(UInt8((id >> 8) & 0xFF))
        payload.append(UInt8(id & 0xFF))
        payload.append(0)  // Pascal 名长度 0
        payload.append(0)  // 奇数补齐
        let size = data.count
        payload.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        payload.append(data)
        if size % 2 == 1 { payload.append(0) }
    }
    var segment = Data([0xFF, 0xED])
    let length = payload.count + 2
    segment.append(UInt8((length >> 8) & 0xFF))
    segment.append(UInt8(length & 0xFF))
    segment.append(payload)
    return segment
}

/// 把 `segment` 插到第一个 APP13 之后（没有 APP13 时插到 SOI 之后）。
private func injectAPP13(_ segment: Data, into data: Data) throws -> Data {
    let bytes = [UInt8](data)
    var index = 2
    while index + 3 < bytes.count {
        guard bytes[index] == 0xFF else { break }
        let marker = bytes[index + 1]
        if marker == 0xDA { break }
        let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
        let end = index + 2 + length
        if marker == 0xED {
            var out = Data(bytes[0..<end])
            out.append(segment)
            out.append(contentsOf: bytes[end...])
            return out
        }
        index = end
    }
    var out = Data(bytes[0..<2])
    out.append(segment)
    out.append(contentsOf: bytes[2...])
    return out
}
