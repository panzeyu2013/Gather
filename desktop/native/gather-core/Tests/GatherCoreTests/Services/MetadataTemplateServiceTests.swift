// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataTemplateServiceTests.swift
// P1 / B2：apply/undo 的纯映射部分（writeAttributes / beforeSnapshot）——
// 服务层的 IO 编排由宿主集成测覆盖，这里钉死"计划 → 写盘载荷"的语义。

import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

@Suite("模板套用载荷")
struct MetadataTemplateServiceTests {
    private let template = DescriptiveMetadata(
        title: "婚礼 2026", copyrightNotice: "", city: "上海"
    )

    @Test("只把 write/clear 的字段放进载荷；unchanged/conflict 不写")
    func payloadOnlyChangedFields() {
        let plan = MetadataTemplatePlanner.plan(
            template: template,
            photoId: "p1",
            current: DescriptiveMetadata(title: "婚礼 2026", copyrightNotice: "旧版权"),
            disk: DescriptiveMetadata(title: "婚礼 2026", copyrightNotice: "旧版权")
        )
        let attributes = plan.writeAttributes(template: template)
        #expect(attributes?.descriptive?.title == nil, "同值不写")
        #expect(attributes?.descriptive?.copyrightNotice == "", "清空必须显式写空")
        #expect(attributes?.descriptive?.city == "上海")
    }

    @Test("全部无动作时不产生空写（返回 nil）")
    func noopProducesNil() {
        let plan = MetadataTemplatePlanner.plan(
            template: template, photoId: "p1",
            current: DescriptiveMetadata(title: "婚礼 2026", city: "上海"), disk: nil
        )
        #expect(plan.writeAttributes(template: template) == nil)
    }

    @Test("beforeSnapshot 只记被触碰字段的原值")
    func beforeSnapshotOnlyTouched() {
        let plan = MetadataTemplatePlanner.plan(
            template: template, photoId: "p1",
            current: DescriptiveMetadata(creator: ["张三"], copyrightNotice: "旧版权"),
            disk: nil
        )
        let before = plan.beforeSnapshot
        #expect(before.copyrightNotice == "旧版权")
        #expect(before.title == nil, "原本没有的字段不记")
        #expect(before.creator == nil, "模板没碰的字段不记")
    }

    @Test("冲突策略 keepExternal 时冲突字段不进载荷")
    func conflictExcluded() {
        let plan = MetadataTemplatePlanner.plan(
            template: template, photoId: "p1",
            current: DescriptiveMetadata(city: "上海"),
            disk: DescriptiveMetadata(city: "外部改过")
        )
        #expect(plan.conflictCount == 1)
        #expect(plan.writeAttributes(template: template)?.descriptive?.city == nil)
    }
}
