// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataTemplatePlannerTests.swift
// P1 / B2：模板批量计划（pure）——三态、冲突、清空、幂等。

import Foundation
import Testing
import GatherProtocol
@testable import GatherApplication

@Suite("元数据模板计划")
struct MetadataTemplatePlannerTests {

    private func template() -> DescriptiveMetadata {
        DescriptiveMetadata(
            title: "新标题",
            copyrightNotice: "",
            city: "上海",
            personInImage: ["张三"]
        )
    }

    @Test("模板未设置字段不入计划；只列被显式设置的字段")
    func onlyExplicitFields() {
        let plan = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1",
            current: DescriptiveMetadata(), disk: nil
        )
        let planned = Set(plan.fields.map { $0.field })
        #expect(planned == Set([.city, .copyrightNotice, .personInImage, .title]))
    }

    @Test("有值 → write；同值 → unchanged；空模板 + 有现值 → clear")
    func actions() {
        let current = DescriptiveMetadata(title: "新标题", city: "北京")
        let plan = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1", current: current, disk: current
        )
        let byField = Dictionary(uniqueKeysWithValues: plan.fields.map { ($0.field, $0.action) })
        #expect(byField[.title] == .unchanged)
        #expect(byField[.city] == .write)
        #expect(byField[.copyrightNotice] == .unchanged, "空模板 + 现值 nil = 无事可做")
        #expect(byField[.personInImage] == .write)
        #expect(plan.writeCount == 2)
        #expect(plan.clearCount == 0)
        #expect(plan.changed)
    }

    @Test("清空：空模板覆盖有现值 → clear")
    func clearAction() {
        let current = DescriptiveMetadata(copyrightNotice: "旧版权")
        let plan = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1", current: current, disk: current
        )
        let action = plan.fields.first { $0.field == .copyrightNotice }?.action
        #expect(action == .clear)
        #expect(plan.clearCount == 1)
    }

    @Test("外部改动默认 conflict，不覆盖；overwrite 策略才写")
    func conflictPolicy() {
        let cached = DescriptiveMetadata(city: "上海")
        let disk = DescriptiveMetadata(city: "C1 里改过")
        let keep = MetadataTemplatePlanner.plan(template: template(), photoId: "p1", current: cached, disk: disk)
        #expect(keep.fields.first { $0.field == .city }?.action == .conflict)
        #expect(keep.conflictCount == 1)

        let overwrite = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1", current: cached, disk: disk, policy: .overwrite
        )
        #expect(overwrite.fields.first { $0.field == .city }?.action == .write)
    }

    @Test("keepExternal：模板清空同样判冲突，绝不删外部新值")
    func clearConflictsWithExternal() {
        let current = DescriptiveMetadata(copyrightNotice: "旧版权")
        let disk = DescriptiveMetadata(copyrightNotice: "C1 里改过")
        let plan = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1", current: current, disk: disk)
        #expect(plan.fields.first { $0.field == .copyrightNotice }?.action == .conflict)
    }

    @Test("缓存无该字段但盘上有值：keepExternal 视为冲突（未知不得覆盖）")
    func unknownCacheIsConflictUnderKeepExternal() {
        let disk = DescriptiveMetadata(title: "盘上标题")
        let plan = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1", current: DescriptiveMetadata(), disk: disk)
        #expect(plan.fields.first { $0.field == .title }?.action == .conflict)
        #expect(plan.conflictCount == 1)

        // overwrite 是显式覆盖：同一份输入必须判 write。
        let overwrite = MetadataTemplatePlanner.plan(
            template: template(), photoId: "p1", current: DescriptiveMetadata(), disk: disk,
            policy: .overwrite)
        #expect(overwrite.fields.first { $0.field == .title }?.action == .write)
        #expect(overwrite.conflictCount == 0)
    }

    @Test("批量汇总：N 张里只统计会改动的张数")
    func batch() {
        let plans = MetadataTemplatePlanner.planBatch(
            template: template(),
            photos: [
                ("p1", DescriptiveMetadata(), nil),
                ("p2", DescriptiveMetadata(title: "新标题", city: "上海", personInImage: ["张三"]), nil),
            ]
        )
        #expect(plans.count == 2)
        #expect(plans.filter(\.changed).count == 1)
        #expect(plans[0].fields.count == 4)
    }
}
