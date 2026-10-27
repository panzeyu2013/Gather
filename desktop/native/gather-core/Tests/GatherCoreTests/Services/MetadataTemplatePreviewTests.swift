// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataTemplatePreviewTests.swift
// P1 / B2：预览汇总（不碰 IO，输入是两份快照）。

import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

@Suite("模板预览汇总")
struct MetadataTemplatePreviewTests {
    private func template() -> MetadataTemplate {
        MetadataTemplate(
            id: "t1", name: "婚礼",
            fields: DescriptiveMetadata(title: "婚礼 2026", city: "上海"),
            createdAt: "", updatedAt: ""
        )
    }

    @Test("汇总：改动张数/字段数/冲突数分别计数")
    func aggregates() {
        let preview = MetadataTemplatePreviewBuilder.build(
            template: template(),
            photos: [
                ("p1", DescriptiveMetadata(), nil),                                   // 2 个 write
                ("p2", DescriptiveMetadata(title: "婚礼 2026", city: "上海"), nil),      // 0
                ("p3", DescriptiveMetadata(title: "婚礼 2026", city: "北京"), DescriptiveMetadata(title: "婚礼 2026", city: "C1 改过")),
            ]
        )
        #expect(preview.totalPhotos == 3)
        #expect(preview.changedPhotos == 1)
        #expect(preview.changedFields == 2)
        #expect(preview.conflictFields == 1)
        #expect(preview.isEmpty == false)
    }

    @Test("全部无可写动作 → isEmpty（UI 据此禁用确认）")
    func emptyPreview() {
        let preview = MetadataTemplatePreviewBuilder.build(
            template: template(),
            photos: [("p1", DescriptiveMetadata(title: "婚礼 2026", city: "上海"), nil)]
        )
        #expect(preview.isEmpty)
        #expect(preview.changedPhotos == 0)
        #expect(preview.conflictFields == 0)
    }

    @Test("overwrite 策略下冲突转为写入")
    func overwritePolicy() {
        let preview = MetadataTemplatePreviewBuilder.build(
            template: template(),
            photos: [("p1", DescriptiveMetadata(city: "上海"), DescriptiveMetadata(city: "外部"))],
            policy: .overwrite
        )
        #expect(preview.conflictFields == 0)
        #expect(preview.changedFields == 2)
    }
}
