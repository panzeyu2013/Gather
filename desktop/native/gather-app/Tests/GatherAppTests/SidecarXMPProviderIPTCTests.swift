// desktop/native/gather-app/Tests/GatherAppTests/SidecarXMPProviderIPTCTests.swift
// P1 / IPTC：表驱动补丁器的写入/读取/清空/保留/写后校验（宿主层直测）。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

private func makeTempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-iptc-" + UUID().uuidString, isDirectory: true).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func makePhoto(_ dir: String, name: String = "IMG_0001.CR3") throws -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    try Data([0x00]).write(to: URL(fileURLWithPath: path))
    return path
}

@Suite("IPTC sidecar 写入")
struct SidecarXMPProviderIPTCTests {

    private func fullMetadata() -> DescriptiveMetadata {
        DescriptiveMetadata(
            title: "落日 & 海",
            caption: "说明文本",
            creator: ["张三"],
            creatorJobTitle: "摄影师",
            credit: "工作室",
            source: "Gather",
            copyrightNotice: "© 2026 张三",
            usageTerms: "仅限一次使用",
            webStatement: "https://example.com/license",
            headline: "标题",
            captionWriter: "李四",
            jobIdentifier: "JOB-1",
            subjectCode: ["01000000"],
            scene: ["01120000"],
            intellectualGenre: "纪实",
            location: "外滩",
            city: "上海",
            state: "上海",
            country: "中国",
            countryCode: "CHN",
            dateCreated: "2026-10-25",
            contactInfo: DescriptiveContact(city: "上海", email: "a@b.c", telephone: "123"),
            personInImage: ["张三", "李四"],
            event: "婚礼",
            organisationInImage: ["某公司"],
            sublocation: "南京东路",
            worldRegion: "华东",
            provinceState: "上海市",
            modelReleaseStatus: "已签署",
            propertyReleaseStatus: "未签署",
            digitalSourceType: "digitalCapture",
            additionalModelInfo: "临时演员"
        )
    }

    @Test("32 字段全部写入并按形状序列化，读回逐字段相等")
    func writesAllFieldsAndReadsBack() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir)
        let provider = SidecarXMPProvider()
        let metadata = fullMetadata()

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(descriptive: metadata))
        let sidecar = try String(contentsOfFile: (dir as NSString).appendingPathComponent("IMG_0001.xmp"), encoding: .utf8)

        // 形状断言：alt / seq / bag / structure 各自出现在正确的命名空间下。
        #expect(sidecar.contains("<dc:title>"))
        #expect(sidecar.contains("<rdf:Alt>"))
        #expect(sidecar.contains("xml:lang=\"x-default\""))
        #expect(sidecar.contains("<dc:creator>"))
        #expect(sidecar.contains("<rdf:Seq>"))
        #expect(sidecar.contains("<Iptc4xmpExt:PersonInImage>"))
        #expect(sidecar.contains("<rdf:Bag>"))
        #expect(sidecar.contains("<Iptc4xmpCore:CreatorContactInfo>"))
        #expect(sidecar.contains("<Iptc4xmpCore:CiEmailWork>a@b.c</Iptc4xmpCore:CiEmailWork>"))
        #expect(sidecar.contains("xmlns:Iptc4xmpExt=\"http://iptc.org/std/Iptc4xmpExt/2008-02-29/\""))
        #expect(sidecar.contains("&amp;"), "& 必须被转义")

        let readBack = try await provider.readAttributes(photoPath: photo)
        #expect(readBack.descriptive == metadata)
    }

    @Test("空串/空数组 = 显式清空：元素被移除，读回为 nil")
    func clearsFields() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0002.NEF")
        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "旧标题", city: "北京", personInImage: ["甲"])
        ))
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "", city: "", personInImage: [])
        ))
        let sidecar = try String(contentsOfFile: (dir as NSString).appendingPathComponent("IMG_0002.xmp"), encoding: .utf8)
        #expect(!sidecar.contains("<dc:title>"))
        #expect(!sidecar.contains("<photoshop:City>"))
        #expect(!sidecar.contains("PersonInImage"))

        let readBack = try await provider.readAttributes(photoPath: photo)
        #expect(readBack.descriptive?.title == nil)
        #expect(readBack.descriptive?.city == nil)
        #expect(readBack.descriptive?.personInImage == nil)
    }

    @Test("triage 私有命名空间信号：写入可读回，空串清除且不影响其它字段")
    func writesTriageSignal() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0007.CR3")
        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            rating: 3, descriptive: DescriptiveMetadata(title: "保留标题"),
            triageSignal: "keep"))
        let sidecar = try String(contentsOfFile: (dir as NSString).appendingPathComponent("IMG_0007.xmp"), encoding: .utf8)
        #expect(sidecar.contains("xmlns:gather=\"https://gather.app/ns/triage/1.0/\""))
        #expect(sidecar.contains("<gather:Triage>keep</gather:Triage>"))
        let readBack = try await provider.readAttributes(photoPath: photo)
        #expect(readBack.triageSignal == "keep")
        #expect(readBack.rating == 3)
        #expect(readBack.descriptive?.title == "保留标题")

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            triageSignal: ""))
        let cleared = try String(
            contentsOfFile: (dir as NSString).appendingPathComponent("IMG_0007.xmp"), encoding: .utf8)
        #expect(!cleared.contains("gather:Triage"))
        #expect(try await provider.readAttributes(photoPath: photo).triageSignal == nil)
    }

    @Test("多语言 alt：写 x-default 保留其它语言，读回取 x-default")
    func preservesAlternateLanguages() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0006.JPG")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0006.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:title>
                <rdf:Alt>
                  <rdf:li xml:lang="x-default">旧默认</rdf:li>
                  <rdf:li xml:lang="en">English title</rdf:li>
                  <rdf:li xml:lang="de">Deutscher Titel</rdf:li>
                </rdf:Alt>
              </dc:title>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "新默认")))
        let after = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(after.contains(">新默认</rdf:li>"))
        #expect(after.contains("English title"), "英文标题不得被覆盖丢失")
        #expect(after.contains("Deutscher Titel"), "德文标题不得被覆盖丢失")
        let readBack = try await provider.readAttributes(photoPath: photo)
        #expect(readBack.descriptive?.title == "新默认", "读回优先 x-default")

        // 清空只清 x-default，其它语言的 rdf:li 必须保留（否则撤销/翻译永久丢失）。
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "")))
        let cleared = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(cleared.contains("<dc:title>"))
        #expect(cleared.contains("<rdf:li xml:lang=\"x-default\"></rdf:li>"))
        #expect(cleared.contains("English title"), "清空默认语言不得删其它语言")
        #expect(cleared.contains("Deutscher Titel"))
        #expect(try await provider.readAttributes(photoPath: photo).descriptive?.title == nil)
    }

    @Test("紧凑属性形式的 contact 成员可读回，写入时清掉旧属性")
    func readsCompactContactAttributes() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0008.CR3")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0008.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
                Iptc4xmpCore:CiAdrCity="上海"
                Iptc4xmpCore:CiEmailWork="a@b.c"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        let provider = SidecarXMPProvider()
        let before = try await provider.readAttributes(photoPath: photo).descriptive?.contactInfo
        #expect(before?.city == "上海")
        #expect(before?.email == "a@b.c")

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(
                city: "上海", email: "a@b.c", telephone: "123"))))
        let after = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(!after.contains("CiAdrCity=\"上海\""), "旧属性必须清掉，避免与结构重复")
        let readBack = try await provider.readAttributes(photoPath: photo).descriptive?.contactInfo
        #expect(readBack?.city == "上海")
        #expect(readBack?.email == "a@b.c")
        #expect(readBack?.telephone == "123")
    }

    @Test("未知命名空间与未知字段逐字节保留")
    func preservesForeignContent() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0003.ARW")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0003.xmp")
        let foreign = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:my="http://example.com/my/1.0/">
              <my:Custom>保留我</my:Custom>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try foreign.write(toFile: sidecarPath, atomically: true, encoding: .utf8)

        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(title: "新标题")
        ))
        let after = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(after.contains("<my:Custom>保留我</my:Custom>"))
        #expect(after.contains("<dc:title>"))
    }

    @Test(".text 字段被外部写成 Lang Alt：读 x-default，写入保留其它语言")
    func textFieldStoredAsLangAlt() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0013.CR3")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0013.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <photoshop:City>
                <rdf:Alt>
                  <rdf:li xml:lang="x-default">北京</rdf:li>
                  <rdf:li xml:lang="fr">Pékin</rdf:li>
                </rdf:Alt>
              </photoshop:City>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        let provider = SidecarXMPProvider()
        #expect(try await provider.readAttributes(photoPath: photo).descriptive?.city == "北京",
                "不能把语言串接成 北京Pékin")
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            rating: 4))
        let xml = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(xml.contains("Pékin"), "无关写入不得删其它语言")
        #expect(try await provider.readAttributes(photoPath: photo).descriptive?.city == "北京")
    }

    @Test("contact 结构的嵌套 rdf:Description 不算第二块：后续写入仍可用")
    func nestedDescriptionDoesNotBlockWrites() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0010.CR3")
        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            descriptive: DescriptiveMetadata(contactInfo: DescriptiveContact(city: "上海"))))
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            rating: 5))
        let readBack = try await provider.readAttributes(photoPath: photo)
        #expect(readBack.rating == 5)
        #expect(readBack.descriptive?.contactInfo?.city == "上海")
        let sidecar = (dir as NSString).appendingPathComponent("IMG_0010.xmp")
        let xml = try String(contentsOfFile: sidecar, encoding: .utf8)
        if let start = xml.range(of: "<Iptc4xmpCore:CreatorContactInfo>"),
           let end = xml.range(of: "</Iptc4xmpCore:CreatorContactInfo>",
                               range: start.upperBound..<xml.endIndex) {
            let contactBlock = String(xml[start.lowerBound..<end.upperBound])
            #expect(!contactBlock.contains("xmp:Rating"),
                    "新字段不能追加进 contact 的内层 rdf:Description")
        }
    }

    @Test("自闭合空元素可被替换，不产生重复元素")
    func replacesSelfClosingElement() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0012.CR3")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0012.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:subject/>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        let provider = SidecarXMPProvider()
        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
            keywords: ["keep"]))
        let xml = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(xml.components(separatedBy: "<dc:subject").count - 1 == 1)
        #expect(try await provider.readAttributes(photoPath: photo).keywords == ["keep"])
    }

    @Test("contact 属性 + 元素混存：读回合并，后续写入不丢属性成员")
    func mergesMixedContactForms() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0011.CR3")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0011.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
                Iptc4xmpCore:CiEmailWork="a@b.c">
              <Iptc4xmpCore:CreatorContactInfo>
                <rdf:Description>
                  <Iptc4xmpCore:CiAdrCity>上海</Iptc4xmpCore:CiAdrCity>
                </rdf:Description>
              </Iptc4xmpCore:CreatorContactInfo>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        let provider = SidecarXMPProvider()
        let before = try await provider.readAttributes(photoPath: photo).descriptive?.contactInfo
        #expect(before?.email == "a@b.c")
        #expect(before?.city == "上海")

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(rating: 4))
        let after = try await provider.readAttributes(photoPath: photo).descriptive?.contactInfo
        #expect(after?.email == "a@b.c", "星级写入不得删 contact 属性成员")
        #expect(after?.city == "上海")
    }

    @Test("多 rdf:Description：写入显式拒绝，避免重复属性/旧值胜出")
    func refusesMultipleDescriptions() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0009.CR3")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0009.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <photoshop:City>上海</photoshop:City>
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <photoshop:City>北京</photoshop:City>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        await #expect(throws: SidecarXMPError.self) {
            try await SidecarXMPProvider().writeAttributes(
                photoPath: photo, attributes: MetadataWriteAttributes(
                    descriptive: DescriptiveMetadata(title: "x")))
        }
        let after = try String(contentsOfFile: sidecarPath, encoding: .utf8)
        #expect(after == document, "拒绝写入时文件必须保持原样")
    }

    @Test("写后校验：盘上没生效时抛 descriptive 校验错误")
    func verificationFailureIsTyped() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0004.CR2")
        // 故障注入：把 City 元素改写掉，构造"写了但没生效"的盘面。
        let provider = SidecarXMPProvider(writeTransform: { document in
            document.replacingOccurrences(of: "上海", with: "被篡改")
        })
        await #expect(throws: SidecarXMPError.self) {
            try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(
                descriptive: DescriptiveMetadata(city: "上海")
            ))
        }
    }

    @Test("读取：紧凑属性形式与元素形式都能取到 IPTC 文本字段")
    func readsAttributeAndElementForms() async throws {
        let dir = try makeTempDir()
        let photo = try makePhoto(dir, name: "IMG_0005.dng")
        let sidecarPath = (dir as NSString).appendingPathComponent("IMG_0005.xmp")
        let document = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
                photoshop:City="广州">
              <Iptc4xmpCore:Location>天河</Iptc4xmpCore:Location>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try document.write(toFile: sidecarPath, atomically: true, encoding: .utf8)
        let readBack = try await SidecarXMPProvider().readAttributes(photoPath: photo)
        #expect(readBack.descriptive?.city == "广州")
        #expect(readBack.descriptive?.location == "天河")
    }
}
