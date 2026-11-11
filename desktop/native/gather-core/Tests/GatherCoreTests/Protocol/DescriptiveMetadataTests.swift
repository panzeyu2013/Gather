// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/DescriptiveMetadataTests.swift
// P1 / IPTC：字段表不变量 + 三态语义 + JSON 往返（无 XML，纯契约层）。

import Foundation
import Testing
import GatherProtocol

@Suite("DescriptiveMetadata 契约")
struct DescriptiveMetadataTests {

    @Test("字段表覆盖 36 个字段且 qname 唯一")
    func descriptorTableIsComplete() {
        #expect(XMPFieldDescriptor.all.count == 36)
        #expect(Set(XMPFieldDescriptor.all.map(\.qname)).count == 36)
        #expect(Set(XMPFieldDescriptor.all.map(\.field)) == Set(DescriptiveField.allCases))
        #expect(XMPFieldDescriptor.byField.count == 36)
    }

    @Test("命名空间前缀与 URI 一一对应（防止写错命名空间）")
    func prefixesMatchNamespaces() {
        let expected: [String: String] = [
            "dc": XMPNamespaces.dc,
            "photoshop": XMPNamespaces.photoshop,
            "xmpRights": XMPNamespaces.xmpRights,
            "Iptc4xmpCore": XMPNamespaces.iptcCore,
            "Iptc4xmpExt": XMPNamespaces.iptcExt,
            // Wave5（batch2）：PLUS LDF（release id 在标准里属于 plus:）。
            "plus": XMPNamespaces.plus,
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

    @Test("Wave5 新增字段：qname/形状/命名空间与 IPTC 2025.1 技术参考一致")
    func wave5FieldDescriptors() {
        let expectations: [(DescriptiveField, String, XMPValueShape, String)] = [
            // field / qname / shape / namespace
            (.instructions, "photoshop:Instructions", .text, XMPNamespaces.photoshop),
            (.eventIdentifier, "Iptc4xmpExt:EventId", .bag, XMPNamespaces.iptcExt),
            (.modelReleaseID, "plus:ModelReleaseID", .bag, XMPNamespaces.plus),
            (.propertyReleaseID, "plus:PropertyReleaseID", .bag, XMPNamespaces.plus),
        ]
        for (field, qname, shape, namespace) in expectations {
            guard let descriptor = XMPFieldDescriptor.descriptor(for: field) else {
                Issue.record("字段 \(field.rawValue) 缺少 XMP 描述符")
                continue
            }
            #expect(descriptor.qname == qname)
            #expect(descriptor.shape == shape)
            #expect(descriptor.namespace == namespace)
        }
    }

    @Test("Wave5 新增字段：文本/列表三态可读写，清空语义不变")
    func wave5FieldsRoundTrip() {
        var metadata = DescriptiveMetadata()
        metadata.set(.text("Embargo until 2026-12-01"), for: .instructions)
        metadata.set(.list(["urn:event:acme-2026"]), for: .eventIdentifier)
        metadata.set(.list(["MR-0001", "MR-0002"]), for: .modelReleaseID)
        metadata.set(.list([]), for: .propertyReleaseID)
        #expect(metadata.instructions == "Embargo until 2026-12-01")
        #expect(metadata.eventIdentifier == ["urn:event:acme-2026"])
        #expect(metadata.modelReleaseID == ["MR-0001", "MR-0002"])
        #expect(metadata.propertyReleaseID == [], "空数组 = 显式清空（不是未设置）")
        #expect(metadata.value(for: .propertyReleaseID) != nil)

        #expect(DescriptiveMetadata().value(for: .instructions) == nil, "nil = 不触碰")
        metadata.clear(.instructions)
        #expect(metadata.value(for: .instructions) != nil, "clear 后是显式清空")
    }

    @Test("受控值表：结构不变量 + 归一化 + 写入前校验")
    func controlledVocabularyTables() {
        // 四张表都非空、值唯一、每个选项自身合法（归一化幂等）。
        let fields: [DescriptiveField] = [.countryCode, .scene, .subjectCode, .digitalSourceType]
        for field in fields {
            guard let options = IPTCControlledVocabulary.options(for: field) else {
                Issue.record("受控值字段 \(field.rawValue) 缺词表")
                continue
            }
            #expect(!options.isEmpty)
            #expect(Set(options.map(\.value)).count == options.count, "词表值必须唯一")
            for option in options {
                #expect(IPTCControlledVocabulary.isValid(option.value, for: field))
                #expect(IPTCControlledVocabulary.normalized(option.value, for: field) == option.value,
                        "词表值必须是归一化后的形态")
                #expect(!option.label.isEmpty)
            }
        }
        // 非受控值字段：原样通过（不误伤自由文本）。
        #expect(IPTCControlledVocabulary.options(for: .city) == nil)
        #expect(IPTCControlledVocabulary.isValid("任意城市", for: .city))
        #expect(!IPTCControlledVocabulary.isControlled(.city))

        // countryCode：大小写归一 + 词表外拒绝（标准是字母码，手打 cn 应写成 CN）。
        #expect(IPTCControlledVocabulary.normalized(" cn ", for: .countryCode) == "CN")
        #expect(IPTCControlledVocabulary.isValid("cn", for: .countryCode))
        #expect(!IPTCControlledVocabulary.isValid("ZZ", for: .countryCode))
        // scene / subjectCode：6/8 位数字码；英文名与错码都算词表外。
        #expect(IPTCControlledVocabulary.isValid("011100", for: .scene))
        #expect(!IPTCControlledVocabulary.isValid("panoramic view", for: .scene))
        #expect(IPTCControlledVocabulary.isValid("01000000", for: .subjectCode))
        #expect(!IPTCControlledVocabulary.isValid("0100000", for: .subjectCode))
        // digitalSourceType：值是 CV 概念的完整 URI（不是短名）。
        #expect(IPTCControlledVocabulary.isValid(
            "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture",
            for: .digitalSourceType))
        #expect(!IPTCControlledVocabulary.isValid("digitalCapture", for: .digitalSourceType))
        // 清空（空串）永远合法。
        #expect(IPTCControlledVocabulary.isValid("", for: .countryCode))

        // 词表规模：场景 24、主题顶层 17、数字来源 18（来自 IPTC CV 服务）。
        #expect(IPTCControlledVocabulary.sceneCodes.count == 24)
        #expect(IPTCControlledVocabulary.subjectCodes.count == 17)
        #expect(IPTCControlledVocabulary.digitalSourceTypes.count == 18)
        #expect(IPTCControlledVocabulary.countryCodes.count >= 90)
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
