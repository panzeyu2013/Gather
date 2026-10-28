// desktop/native/gather-app/Tests/GatherAppTests/MetadataEditorDraftTests.swift
// P0 / B2：单张元数据编辑器的差异计算（只提交改动字段 / 空值清空 / contact 整块）。
import Foundation
import Testing
import GatherProtocol
@testable import GatherUI

@Suite("元数据编辑器差异")
struct MetadataEditorDraftTests {
    @Test("没改动：返回 nil，按钮禁用")
    func unchangedProducesNil() {
        let values: [DescriptiveField: String] = [.caption: "旧说明", .city: "上海"]
        #expect(MetadataEditorDraft.changes(
            values: values, initial: values,
            contact: DescriptiveContact(), initialContact: DescriptiveContact()) == nil)
        #expect(MetadataEditorDraft.changedFieldCount(
            values: values, initial: values,
            contact: DescriptiveContact(), initialContact: DescriptiveContact()) == 0)
    }

    @Test("只提交改动字段：空文本 = 显式清空，列表按顿号/逗号拆")
    func onlyChangedFieldsAreSubmitted() {
        let initial: [DescriptiveField: String] = [
            .caption: "旧说明", .city: "上海", .personInImage: "张三、李四",
        ]
        var values = initial
        values[.caption] = "新说明"
        values[.city] = "  "
        values[.personInImage] = "张三, 王五"

        let edited = MetadataEditorDraft.changes(
            values: values, initial: initial,
            contact: DescriptiveContact(), initialContact: DescriptiveContact())
        #expect(edited?.caption == "新说明")
        #expect(edited?.city == "", "空白 = 显式清空（value(for:) 非 nil）")
        #expect(edited?.personInImage == ["张三", "王五"])
        #expect(edited?.title == nil, "未改动的字段不出现（nil = 不触碰）")
        #expect(MetadataEditorDraft.changedFieldCount(
            values: values, initial: initial,
            contact: DescriptiveContact(), initialContact: DescriptiveContact()) == 3)
    }

    @Test("contact 改动算一个字段，且整块随补丁提交")
    func contactCountsAsOneField() {
        let initialContact = DescriptiveContact(city: "上海", telephone: "123")
        let contact = DescriptiveContact(city: "北京")
        let edited = MetadataEditorDraft.changes(
            values: [:], initial: [:], contact: contact, initialContact: initialContact)
        #expect(edited?.contactInfo == contact)
        #expect(MetadataEditorDraft.changedFieldCount(
            values: [:], initial: [:], contact: contact, initialContact: initialContact) == 1)
    }
}
