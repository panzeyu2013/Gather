// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/DescriptiveMetadataTests.swift
// P1 / IPTC：字段表不变量 + 三态语义 + JSON 往返（无 XML，纯契约层）。

import Foundation
import Testing
import GatherProtocol

@Suite("DescriptiveMetadata 契约")
struct DescriptiveMetadataTests {

    @Test("字段表覆盖 32 个字段且 qname 唯一")
    func descriptorTableIsComplete() {
        #expect(XMPFieldDescriptor.all.count == 32)
        #expect(Set(XMPFieldDescriptor.all.map(\.qname)).count == 32)
        #expect(Set(XMPFieldDescriptor.all.map(\.field)) == Set(DescriptiveField.allCases))
        #expect(XMPFieldDescriptor.byField.count == 32)
    }

    @Test("命名空间前缀与 URI 一一对应（防止写错命名空间）")
    func prefixesMatchNamespaces() {
        let expected: [String: String] = [
            "dc": XMPNamespaces.dc,
            "photoshop": XMPNamespaces.photoshop,
            "xmpRights": XMPNamespaces.xmpRights,
            "Iptc4xmpCore": XMPNamespaces.iptcCore,
            "Iptc4xmpExt": XMPNamespaces.iptcExt,
        ]
        for descriptor in XMPFieldDescriptor.all {
            #expect(descriptor.namespace == expected[descriptor.prefix], "\(descriptor.qname) 的命名空间不对")
            #expect(descriptor.qname.hasPrefix(descriptor.prefix + ":"))
        }
    }

    @Test("contact 部分成员合并；空结构显式清空（模板不得整块删成员）")
    func contactMergesMembers() {
        let base = DescriptiveMetadata(contactInfo: DescriptiveContact(
            city: "上海", email: "a@b.c", telephone: "123"))
        let partial = DescriptiveMetadata(contactInfo: DescriptiveContact(email: "c@d.e"))
        let merged = base.applying(partial)
        #expect(merged.contactInfo?.city == "上海", "模板未填的成员必须保留")
        #expect(merged.contactInfo?.telephone == "123")
        #expect(merged.contactInfo?.email == "c@d.e")

        var cleared = DescriptiveMetadata()
        cleared.clear(.contactInfo)
        let after = base.applying(cleared)
        #expect(after.contactInfo?.isEmpty == true, "显式清空仍然有效")
    }

    @Test("列表字段形状与 set 归一化一致")
    func listShapesNormalize() {
        var metadata = DescriptiveMetadata()
        metadata.set(.text("张三"), for: .creator)
        #expect(metadata.creator == ["张三"])
        metadata.set(.list(["a", "b"]), for: .personInImage)
        #expect(metadata.personInImage == ["a", "b"])
        metadata.set(.list([]), for: .personInImage)
        #expect(metadata.personInImage == [])
        #expect(metadata.value(for: .personInImage) != nil, "空数组是显式清空，不是未设置")
    }

    @Test("三态：nil 不触碰 / 空串清空 / 有值写入")
    func triStateSemantics() {
        var base = DescriptiveMetadata(title: "旧标题", city: "北京")
        #expect(base.value(for: .caption) == nil)

        let template = DescriptiveMetadata(title: "", city: "上海")
        let merged = base.applying(template)
        #expect(merged.title == "", "空串必须覆盖为清空")
        #expect(merged.city == "上海")
        #expect(merged.nonNilFieldCount == 2)

        base.set(nil, for: .title)
        #expect(base.value(for: .title) == nil)
        #expect(base.nonNilFieldCount == 1)
    }

    @Test("JSONValue 往返保真（含 contact 结构）")
    func jsonRoundTrip() throws {
        let original = DescriptiveMetadata(
            title: "标题",
            creator: ["张三"],
            subjectCode: ["01000000"],
            contactInfo: DescriptiveContact(city: "北京", email: "a@b.c"),
            additionalModelInfo: "备注"
        )
        let json = try JSONValue(encoding: original)
        let decoded = try json.decode(DescriptiveMetadata.self)
        #expect(decoded == original)
        #expect(try JSONValue(encoding: DescriptiveMetadata()).decode(DescriptiveMetadata.self).isEmpty)
    }

    @Test("MetadataWriteAttributes 携带 descriptive 时不为空，空描述仍视为空")
    func writeAttributesCarryDescriptive() {
        let withTitle = MetadataWriteAttributes(descriptive: DescriptiveMetadata(title: "T"))
        #expect(!withTitle.isEmpty)
        #expect(withTitle.asJSONValue["descriptive"] != nil)

        let emptyDescriptive = MetadataWriteAttributes(descriptive: DescriptiveMetadata())
        #expect(emptyDescriptive.isEmpty, "全 nil 的 descriptive 不能触发写盘")

        let restored = MetadataWriteAttributes(jsonValue: withTitle.asJSONValue)
        #expect(restored.descriptive?.title == "T")
    }
}
