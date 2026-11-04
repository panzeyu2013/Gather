// desktop/native/gather-core/Tests/GatherCoreTests/MetadataIO/XMPPacketReaderTests.swift
// P1 下一波 §3.2.5：XMP 包（APP1）+ IPTC-IIM（APP13/0x0404）→ 属性，不调用 ImageIO。
//
// 钉死：属性形式与元素形式都读、rdf:Bag/Seq/Alt 形状、命名空间别名、结构（contact）、
// present-but-empty 阻断 IIM 回退、gather:Triage、lr:hierarchicalSubject、坏包返回 nil。

import Foundation
import Testing
import GatherApplication
import GatherProtocol
@testable import GatherMetadataIO

// MARK: - 夹具

private func packet(_ body: String) -> Data {
    let xml = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
            xmlns:gather="https://gather.app/ns/triage/1.0/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
    \(body)
        </rdf:Description>
      </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
    return Data(xml.utf8)
}

/// APP13 资源区（0x0404 = IIM）。
private func iimPayload(caption: String? = nil, keywords: [String] = [], city: String? = nil) throws -> Data {
    var datasets: [IIMDataset] = []
    if let caption { datasets.append(IIMDataset(key: .caption, value: Data(caption.utf8))) }
    for keyword in keywords {
        datasets.append(IIMDataset(key: .keywords, value: Data(keyword.utf8)))
    }
    if let city { datasets.append(IIMDataset(key: .city, value: Data(city.utf8))) }
    let encoded = try IPTCIIM(datasets: datasets).encoded()
    return PhotoshopIRBList.encode([
        PhotoshopIRB(resourceID: PhotoshopIRB.iptcNAA, name: Data(), data: encoded)
    ])
}

// MARK: - 测试

@Suite("XMP 包读取（不靠 ImageIO）")
struct XMPPacketReaderTests {

    @Test("元素形式：dc:subject / xmp:Rating / xmp:Label / 描述性字段 / gather:Triage")
    func readsElementForm() throws {
        let data = packet("""
            <xmp:Rating>4</xmp:Rating>
            <xmp:Label>Green</xmp:Label>
            <dc:subject><rdf:Bag><rdf:li>婚礼</rdf:li><rdf:li>probe</rdf:li></rdf:Bag></dc:subject>
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">标题A</rdf:li><rdf:li xml:lang="zh-Hans">标题B</rdf:li></rdf:Alt></dc:title>
            <photoshop:City>上海</photoshop:City>
            <gather:Triage>keep</gather:Triage>
        """)
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: []))
        #expect(reading.attributes.rating == 4)
        #expect(reading.attributes.label == "Green")
        #expect(reading.attributes.keywords == ["婚礼", "probe"])
        #expect(reading.attributes.descriptive?.title == "标题A", "rdf:Alt 只取 x-default")
        #expect(reading.attributes.descriptive?.city == "上海")
        #expect(reading.attributes.triageSignal == "keep")
        #expect(reading.segments.xmpPresentKeys.contains("subject"))
        #expect(reading.segments.dc?["subject"] != nil)
        #expect(reading.segments.xmp?["Rating"] != nil)
        // 命名空间声明不得被当成属性值读进分段（旧实现对属性形式的容忍度更高）。
        #expect(reading.segments.xmp?["dc"] == nil)
        #expect(!reading.segments.xmpPresentKeys.contains("xmp"))
    }

    @Test("属性形式：rdf:Description 上的 xmp:Rating/xmp:Label 也要读")
    func readsAttributeForm() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmp:Rating="2" xmp:Label="Blue"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let reading = try #require(XMPPacketReader.read(
            xmpPacket: Data(xml.utf8), photoshopIRBPayloads: []))
        #expect(reading.attributes.rating == 2)
        #expect(reading.attributes.label == "Blue")
    }

    @Test("命名空间别名：dc 绑到别的前缀，仍进 dc 分段")
    func resolvesNamespaceAliases() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:d="http://purl.org/dc/elements/1.1/"
                xmlns:g="https://gather.app/ns/triage/1.0/" g:Triage="reject">
              <d:subject><rdf:Bag><rdf:li>alias</rdf:li></rdf:Bag></d:subject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        let reading = try #require(XMPPacketReader.read(
            xmpPacket: Data(xml.utf8), photoshopIRBPayloads: []))
        #expect(reading.attributes.keywords == ["alias"])
        #expect(reading.attributes.triageSignal == "reject")
        #expect(reading.segments.dc?["subject"] != nil)
    }

    @Test("结构：Iptc4xmpCore:CreatorContactInfo 读成成员字典")
    func readsContactStructure() throws {
        let data = packet("""
            <Iptc4xmpCore:CreatorContactInfo>
              <rdf:Description Iptc4xmpCore:CiAdrCity="北京"
                  Iptc4xmpCore:CiEmailWork="a@example.com">
                <Iptc4xmpCore:CiUrlWork>https://example.com</Iptc4xmpCore:CiUrlWork>
              </rdf:Description>
            </Iptc4xmpCore:CreatorContactInfo>
        """)
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: []))
        let contact = try #require(reading.attributes.descriptive?.contactInfo)
        #expect(contact.city == "北京")
        #expect(contact.email == "a@example.com")
        #expect(contact.url == "https://example.com")
    }

    @Test("present-but-empty：XMP 空元素阻断 IIM 旧值复活")
    func emptyXMPBlocksIIMFallback() throws {
        let data = packet("""
            <photoshop:City/>
            <dc:subject><rdf:Bag></rdf:Bag></dc:subject>
        """)
        let iim = try iimPayload(caption: "IIM标题", keywords: ["oldIIM"], city: "上海")
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: [iim]))
        #expect(reading.attributes.descriptive?.city == nil, "XMP 空 City 必须阻断 IIM 回退")
        #expect(reading.attributes.keywords == nil, "空 dc:subject 必须阻断 IIM 关键词回退")
        #expect(reading.attributes.descriptive?.caption == "IIM标题", "未出现的字段才回退 IIM")
    }

    @Test("没有 XMP 包：只用 IIM 组装（相机直出）")
    func readsIIMOnly() throws {
        let iim = try iimPayload(caption: "相机标题", keywords: ["a", "b"], city: "杭州")
        let reading = try #require(XMPPacketReader.read(xmpPacket: nil, photoshopIRBPayloads: [iim]))
        #expect(reading.attributes.keywords == ["a", "b"])
        #expect(reading.attributes.descriptive?.caption == "相机标题")
        #expect(reading.attributes.descriptive?.city == "杭州")
        #expect(reading.attributes.rating == nil)
        #expect(reading.segments.iptc?["Keywords"] != nil)
    }

    @Test("XMP 与 IIM 同时有值：XMP 优先（与 ImageIO 路径同口径）")
    func xmpWinsOverIIM() throws {
        let data = packet("""
            <photoshop:City>XMP城市</photoshop:City>
            <dc:subject><rdf:Bag><rdf:li>xmpKeyword</rdf:li></rdf:Bag></dc:subject>
        """)
        let iim = try iimPayload(keywords: ["iimKeyword"], city: "IIM城市")
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: [iim]))
        #expect(reading.attributes.descriptive?.city == "XMP城市")
        #expect(reading.attributes.keywords == ["xmpKeyword"])
    }

    @Test("lr:hierarchicalSubject 交给 W3（不进 dc:subject）")
    func readsHierarchicalKeywords() throws {
        let data = packet("""
            <dc:subject><rdf:Bag><rdf:li>叶子</rdf:li></rdf:Bag></dc:subject>
            <lr:hierarchicalSubject><rdf:Bag>
              <rdf:li>人物|新娘</rdf:li><rdf:li>地点|上海</rdf:li>
            </rdf:Bag></lr:hierarchicalSubject>
        """)
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: []))
        #expect(reading.hierarchicalKeywords == ["人物|新娘", "地点|上海"])
        #expect(
            Set(reading.attributes.keywords ?? []) == Set(["人物|新娘", "地点|上海", "叶子"]),
            "attributes.keywords 是两套列表的合并视图；写回时再按风格拆开")
    }

    @Test("坏包（非 XML / 非 UTF-8）返回 nil，由调用方回退 ImageIO")
    func unreadablePacketReturnsNil() throws {
        #expect(XMPPacketReader.read(xmpPacket: Data("not xml at all".utf8), photoshopIRBPayloads: []) == nil)
        #expect(XMPPacketReader.read(xmpPacket: Data([0xFF, 0xFE, 0x00]), photoshopIRBPayloads: []) == nil)
        #expect(XMPPacketReader.read(xmpPacket: Data("<x:xmpmeta".utf8), photoshopIRBPayloads: []) == nil)
    }

    @Test("NUL 填充（ImageIO 常见）不影响解析")
    func toleratesNULPadding() throws {
        var data = packet("<xmp:Rating>3</xmp:Rating>")
        data.append(0)
        data.append(0)
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: []))
        #expect(reading.attributes.rating == 3)
    }

    @Test("IIM 损坏：读侧当 IIM 不存在（不误判整张不可读）")
    func corruptedIIMIsIgnored() throws {
        let data = packet("<xmp:Rating>1</xmp:Rating>")
        let broken = PhotoshopIRBList.encode([
            PhotoshopIRB(resourceID: PhotoshopIRB.iptcNAA, name: Data(), data: Data([0x1C, 0x02]))
        ])
        let reading = try #require(XMPPacketReader.read(xmpPacket: data, photoshopIRBPayloads: [broken]))
        #expect(reading.attributes.rating == 1)
        #expect(reading.attributes.keywords == nil)
    }

    @Test("段表入口：从 JPEG 头部段表直接读属性（会话用的那条）")
    func readsFromSegments() throws {
        let xmp = JPEGSegment(
            marker: 0xE1, payload: JPEGSegment.xmpIdentifier + packet("<xmp:Rating>5</xmp:Rating>"))
        let attributes = try #require(XMPPacketReader.attributes(segments: [xmp]))
        #expect(attributes.rating == 5)
    }
}
