// desktop/native/gather-app/Tests/GatherAppTests/SidecarXMPProviderTests.swift
// SidecarXMPProvider 直测（该 provider 此前全仓零测试，R4 补齐）：
// 空文档骨架 / 缺三元素插入 / 属性形式规整 / Urgency 兄弟元素 / 大写 .XMP 回退 /
// 未知命名空间保留 / 写后校验失败的类型化错误 / 损坏文档 / 空写入不建文件 / 备份恢复。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

// MARK: - 测试基建

private func makeTempDirectory() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-xmp-tests-" + UUID().uuidString, isDirectory: true).path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func writeText(_ path: String, _ content: String) throws {
    try content.write(toFile: path, atomically: true, encoding: .utf8)
}

private func readText(_ path: String) throws -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

/// xmp:Label 元素内的文本（用于断言 Urgency 没有被塞进 Label 文本）。
private func labelText(in document: String) -> String? {
    guard let start = document.range(of: "<xmp:Label>"),
          let end = document.range(of: "</xmp:Label>", range: start.upperBound..<document.endIndex)
    else { return nil }
    return String(document[start.upperBound..<end.lowerBound])
}

/// 元素块（开标签到闭标签）的区间。
private func elementRange(in document: String, element: String) -> Range<String.Index>? {
    guard let open = document.range(of: "<" + element),
          let close = document.range(of: "</" + element + ">", range: open.upperBound..<document.endIndex)
    else { return nil }
    return open.lowerBound..<close.upperBound
}

/// 元素是否位于 rdf:Description 的子元素层（而非嵌套在别的属性元素里）。
private func isChildOfDescription(_ document: String, element: String) -> Bool {
    guard let descriptionOpen = document.range(of: "<rdf:Description"),
          let descriptionClose = document.range(of: "</rdf:Description>", range: descriptionOpen.upperBound..<document.endIndex),
          let element = elementRange(in: document, element: element)
    else { return false }
    return element.lowerBound > descriptionOpen.upperBound && element.upperBound < descriptionClose.lowerBound
}

private let bareDescriptionDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="">
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
"""

private let attributeFormDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
      xmp:Rating="5" xmp:Label="Green" photoshop:Urgency="2">
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
"""

private let labelWithUrgencyDoc = """
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
      <xmp:Label>Green</xmp:Label>
      <photoshop:Urgency>2</photoshop:Urgency>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
"""

// MARK: - 测试

@Suite("SidecarXMPProvider")
struct SidecarXMPProviderTests {
    @Test("空文档：写出完整骨架并把三个字段插入 rdf:Description")
    func writesFullSkeletonIntoMissingSidecar() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(
            photoPath: photo,
            attributes: MetadataWriteAttributes(keywords: ["a", "b"], rating: 4, label: "Green"))

        let document = try readText(TSPath.xmpSidecarPath(photo))
        #expect(document.contains("<x:xmpmeta"))
        #expect(document.contains("<rdf:RDF"))
        #expect(document.contains("</rdf:Description>"))
        #expect(document.contains("<rdf:li>a</rdf:li>"))
        #expect(document.contains("<rdf:li>b</rdf:li>"))
        #expect(document.contains("<xmp:Rating>4.0</xmp:Rating>"))
        #expect(document.contains("<xmp:Label>Green</xmp:Label>"))
        #expect(document.contains("<photoshop:Urgency>2</photoshop:Urgency>"))
        #expect(isChildOfDescription(document, element: "dc:subject"))
        #expect(isChildOfDescription(document, element: "xmp:Rating"))
        #expect(isChildOfDescription(document, element: "photoshop:Urgency"))

        let attributes = try await provider.readAttributes(photoPath: photo)
        #expect(attributes.keywords == ["a", "b"])
        #expect(attributes.rating == 4)
        #expect(attributes.label == "Green")
    }

    @Test("无三元素：插入到 rdf:Description 内并补齐命名空间声明，未知内容逐字保留")
    func insertsMissingElementsAndKeepsUnknownNamespaces() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let xmpPath = TSPath.xmpSidecarPath(photo)
        let original = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="">
              <foo:custom xmlns:foo="http://example.com/foo">keepme</foo:custom>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try writeText(xmpPath, original)
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(
            photoPath: photo,
            attributes: MetadataWriteAttributes(keywords: ["k"], rating: 5, label: "Red"))

        let document = try readText(xmpPath)
        #expect(document.contains("<foo:custom"))
        #expect(document.contains("keepme"))
        #expect(document.contains("xmlns:foo="))
        #expect(document.contains("xmlns:xmp="))
        #expect(document.contains("xmlns:dc="))
        #expect(document.contains("xmlns:photoshop="))
        #expect(isChildOfDescription(document, element: "dc:subject"))
        #expect(isChildOfDescription(document, element: "xmp:Rating"))
        #expect(isChildOfDescription(document, element: "xmp:Label"))

        let attributes = try await provider.readAttributes(photoPath: photo)
        #expect(attributes.keywords == ["k"])
        #expect(attributes.rating == 5)
        #expect(attributes.label == "Red")
    }

    @Test("属性形式：读取识别 rdf:Description 属性；写入删除属性并落为元素")
    func normalizesAttributeFormProperties() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let xmpPath = TSPath.xmpSidecarPath(photo)
        try writeText(xmpPath, attributeFormDoc)
        let provider = SidecarXMPProvider()

        let before = try await provider.readAttributes(photoPath: photo)
        #expect(before.rating == 5)
        #expect(before.label == "Green")

        try await provider.writeAttributes(
            photoPath: photo, attributes: MetadataWriteAttributes(rating: 3, label: "Red"))

        let document = try readText(xmpPath)
        #expect(!document.contains("xmp:Rating=\"5\""))
        #expect(!document.contains("xmp:Label=\"Green\""))
        #expect(!document.contains("photoshop:Urgency=\"2\""))
        #expect(document.contains("<xmp:Rating>3.0</xmp:Rating>"))
        #expect(document.contains("<xmp:Label>Red</xmp:Label>"))
        #expect(document.contains("<photoshop:Urgency>1</photoshop:Urgency>"))
        #expect(isChildOfDescription(document, element: "photoshop:Urgency"))

        let after = try await provider.readAttributes(photoPath: photo)
        #expect(after.rating == 3)
        #expect(after.label == "Red")
    }

    @Test("已有 Label 且带 Urgency：Urgency 是 rdf:Description 的子元素，不在 Label 文本内")
    func urgencyStaysSiblingOfLabel() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let xmpPath = TSPath.xmpSidecarPath(photo)
        try writeText(xmpPath, labelWithUrgencyDoc)
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(label: "Blue"))

        let document = try readText(xmpPath)
        #expect(labelText(in: document) == "Blue")
        #expect(labelText(in: document)?.contains("Urgency") == false)
        #expect(document.contains("<photoshop:Urgency>3</photoshop:Urgency>"))
        #expect(isChildOfDescription(document, element: "photoshop:Urgency"))
        #expect(try await provider.readAttributes(photoPath: photo).label == "Blue")
    }

    @Test("大写 .XMP sidecar：读写落在实际存在的文件上，不另建小写 sidecar")
    func uppercaseSidecarIsReadAndWrittenInPlace() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let upperPath = dir + "/photo.XMP"
        try writeText(upperPath, bareDescriptionDoc)
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(rating: 2))

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
        let sidecars = entries.filter { $0.lowercased() == "photo.xmp" }
        #expect(sidecars.count == 1)
        #expect(sidecars.first == "photo.XMP")
        #expect(try readText(upperPath).contains("<xmp:Rating>2.0</xmp:Rating>"))
        #expect(try await provider.readAttributes(photoPath: photo).rating == 2)
    }

    @Test("写后校验失败：抛类型化错误码并携带 xmpPath 与字段名")
    func verificationFailureIsTyped() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        // 故障注入：写盘前把刚插入的 Rating 元素删掉，模拟盘上没生效的写入器。
        let provider = SidecarXMPProvider(writeTransform: { document in
            document.replacingOccurrences(of: "<xmp:Rating>5.0</xmp:Rating>", with: "")
        })

        do {
            try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(rating: 5))
            Issue.record("expected verification failure")
        } catch let error as SidecarXMPError {
            #expect(error.code == "XMP_WRITE_VERIFICATION_FAILED")
            #expect(error.xmpPath.hasSuffix("photo.xmp"))
            let detail: String = "unexpected error case: " + String(describing: error)
            guard case .verificationFailed(_, let field, let expected, let actual) = error else {
                Issue.record(Comment(rawValue: detail))
                return
            }
            #expect(field == .rating)
            #expect(expected == "5.0")
            #expect(actual == "nil")
        }
    }

    @Test("损坏 sidecar：写入抛类型化 documentCorrupt，读取按空属性处理")
    func corruptSidecarRejectsWrite() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        try writeText(TSPath.xmpSidecarPath(photo), "<x:xmpmeta><unclosed>")
        let provider = SidecarXMPProvider()

        do {
            try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(rating: 3))
            Issue.record("expected documentCorrupt")
        } catch let error as SidecarXMPError {
            #expect(error.code == "XMP_DOCUMENT_CORRUPT")
        }

        let attributes = try await provider.readAttributes(photoPath: photo)
        #expect(attributes.rating == nil)
        #expect(attributes.keywords == nil)
        #expect(attributes.label == nil)
    }

    @Test("空写入：不创建 sidecar、不改写已有内容")
    func emptyAttributesDoNotTouchDisk() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes())
        #expect(!FileManager.default.fileExists(atPath: TSPath.xmpSidecarPath(photo)))
    }

    @Test("空关键词与无映射 Label：写空 rdf:Bag 并删除旧 Urgency")
    func emptyKeywordsAndUnmappedLabel() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let xmpPath = TSPath.xmpSidecarPath(photo)
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(
            photoPath: photo, attributes: MetadataWriteAttributes(keywords: ["x"], label: "Green"))
        try await provider.writeAttributes(
            photoPath: photo, attributes: MetadataWriteAttributes(keywords: [], label: "None"))

        let document = try readText(xmpPath)
        #expect(!document.contains("<rdf:li>"))
        #expect(!document.contains("photoshop:Urgency"))
        let attributes = try await provider.readAttributes(photoPath: photo)
        #expect(attributes.keywords == nil)
        #expect(attributes.label == "None")
    }

    @Test("备份与恢复：保留原内容；无 sidecar 时备份路径为空")
    func backupAndRestoreRoundTrip() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/photo.cr3"
        let provider = SidecarXMPProvider()

        #expect(try await provider.backup(photoPath: photo) == "")

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(rating: 1))
        let backupPath = try await provider.backup(photoPath: photo)
        #expect(!backupPath.isEmpty)
        #expect(provider.fileExists(backupPath))

        try await provider.writeAttributes(photoPath: photo, attributes: MetadataWriteAttributes(rating: 2))
        #expect(try await provider.readAttributes(photoPath: photo).rating == 2)

        try await provider.restore(photoPath: photo, backupPath: backupPath)
        #expect(try await provider.readAttributes(photoPath: photo).rating == 1)
        // restore 是**拷贝**语义：备份必须留存。清理流程统一为"先删行、后删备份"，
        // 若删行失败可原样重试；若 restore 消费掉备份，"恢复成功→删行失败"会让该行
        // 永久卡在 backupMissing（审查 N6）。
        #expect(provider.fileExists(backupPath))
    }

    @Test("多 rdf:Description：合并成单块后写入，两块字段都保留（P2）")
    func writesMultiDescriptionDocument() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/multi.cr3"
        let xmpPath = TSPath.xmpSidecarPath(photo)
        let original = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <photoshop:City>上海</photoshop:City>
            </rdf:Description>
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <dc:description><rdf:Alt><rdf:li xml:lang="x-default">旧说明</rdf:li></rdf:Alt></dc:description>
              <xmp:Rating>2</xmp:Rating>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try writeText(xmpPath, original)
        let provider = SidecarXMPProvider()

        try await provider.writeAttributes(
            photoPath: photo,
            attributes: MetadataWriteAttributes(
                rating: 5, descriptive: DescriptiveMetadata(caption: "新说明")))

        let document = try readText(xmpPath)
        #expect(document.components(separatedBy: "<rdf:Description").count - 1 == 1,
                "两块必须合并成一块，实际：\(document)")
        #expect(document.contains("<photoshop:City>上海</photoshop:City>"), "第一块之外的字段不得丢")
        #expect(document.contains("新说明"))
        #expect(try await provider.readAttributes(photoPath: photo).rating == 5,
                "写后回读：星级必须落盘")
        // 旧值不得残留成第二个 dc:description（补丁只针对合并后的唯一块）。
        #expect(document.components(separatedBy: "<dc:description>").count - 1 == 1)
    }

    @Test("多 rdf:Description 但 rdf:about 不同：拒绝写入（不猜语义）")
    func rejectsMultiDescriptionWithDifferentSubjects() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let photo = dir + "/multi-about.cr3"
        let xmpPath = TSPath.xmpSidecarPath(photo)
        let original = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="urn:a"><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">A</dc:title></rdf:Description>
            <rdf:Description rdf:about="urn:b"><dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">B</dc:title></rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try writeText(xmpPath, original)
        let provider = SidecarXMPProvider()
        await #expect(throws: SidecarXMPError.self) {
            try await provider.writeAttributes(
                photoPath: photo, attributes: MetadataWriteAttributes(rating: 3))
        }
    }
}
