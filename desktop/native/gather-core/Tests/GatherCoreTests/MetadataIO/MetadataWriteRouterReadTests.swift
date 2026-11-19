// desktop/native/gather-core/Tests/GatherCoreTests/MetadataIO/MetadataWriteRouterReadTests.swift
// P1-1 回归：内嵌读的基线必须来自 XMP，而不是 ImageIO。
//
// 为什么需要：`CGImageProperties` 不暴露 lr 命名空间，只用 ImageIO 当基线时
// `lr:hierarchicalSubject` 读不出来，而写侧会从 `attributes.keywords` 反推两套列表
// ——结果是"改一个星级，Lightroom 的层级关键词被拍平成单段"。
//
// 只测读：最小 SOI + APP1(XMP) 头即可（扫描器到 EOF 就停，不需要 SOS/scan 段）。

import Foundation
import Testing
import GatherProtocol
import GatherTestSupport
@testable import GatherMetadataIO

// MARK: - 夹具

/// 一个 XMP 包正文（命名空间与生产一致）。
private func xmpPacket(_ body: String) -> Data {
    let xml = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
    \(body)
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    return Data(xml.utf8)
}

/// SOI + 一个 APP1 段（"http://ns.adobe.com/xap/1.0/\0" + 包）。不写 SOS：扫描器到 EOF 停。
private func jpegHeader(withXMP packet: Data) -> Data {
    let namespace = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
    var payload = namespace
    payload.append(packet)
    let length = UInt16(payload.count + 2)
    var segment = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
    segment.append(payload)
    var data = Data([0xFF, 0xD8])   // SOI
    data.append(segment)
    return data
}

private func writeTempJPEG(_ data: Data) throws -> String {
    // task-43：目录统一走共享 TempHygiene 登记路径（文件内容仍真实落盘）。
    let directory = try GatherTestSupport.makeTempDir(prefix: "gather-router-xmp")
    let path = (directory as NSString).appendingPathComponent("photo.jpg")
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

// MARK: - 用例

@Suite("内嵌 XMP 读（P1-1）")
struct MetadataWriteRouterReadTests {
    @Test("lr:hierarchicalSubject 还原成路径：层级关键词不会被扁平基线拍平")
    func keepsHierarchicalKeywords() throws {
        let packet = xmpPacket("""
            <dc:subject><rdf:Bag><rdf:li>Paris</rdf:li></rdf:Bag></dc:subject>
            <lr:hierarchicalSubject><rdf:Bag><rdf:li>Travel|Paris</rdf:li></rdf:Bag></lr:hierarchicalSubject>
        """)
        let path = try writeTempJPEG(jpegHeader(withXMP: packet))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let attributes = try #require(
            MetadataWriteRouter.readEmbeddedXMPAttributes(photoPath: path))
        // dc 的叶子 "Paris" 被 lr 的层级叶子吸收（KeywordCodec.merge），只剩路径。
        #expect(attributes.keywords == ["Travel|Paris"])
    }

    @Test("没有 XMP 段 → nil：调用方保留 ImageIO 基线，不乱改")
    func noXMPReturnsNil() throws {
        let path = try writeTempJPEG(Data([0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MetadataWriteRouter.readEmbeddedXMPAttributes(photoPath: path) == nil)
    }

    @Test("坏包 → nil（fail-closed，不抛错也不猜）")
    func corruptPacketReturnsNil() throws {
        let path = try writeTempJPEG(jpegHeader(withXMP: Data("<not-xmp".utf8)))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(MetadataWriteRouter.readEmbeddedXMPAttributes(photoPath: path) == nil)
    }

    @Test("文件不存在 → nil，不抛错")
    func missingFileReturnsNil() {
        #expect(MetadataWriteRouter.readEmbeddedXMPAttributes(photoPath: "/nonexistent/gather.jpg") == nil)
    }
}
