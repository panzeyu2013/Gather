// desktop/native/gather-core/Tests/GatherCoreTests/Protocol/MetadataBatchEditPlannerTests.swift
// Wave2 task-13：多选批量直改的 <mixed> 检测 + 逐张预检 + 补丁分组用例。
//
// 覆盖：混合值不默认覆盖、逐字段 write/clear/conflict 动作、外部改动 keepExternal/
// overwrite 两种策略、变量未解析阻断整批、同补丁合组（一次 API 调用 / 一个撤销批次）。
import Foundation
import Testing
@testable import GatherProtocol

@Suite("批量字段编辑预检")
struct MetadataBatchEditPlannerTests {

    private func metadata(
        caption: String? = nil,
        city: String? = nil,
        copyright: String? = nil
    ) -> DescriptiveMetadata {
        var value = DescriptiveMetadata()
        if let caption { value.caption = caption }
        if let city { value.city = city }
        if let copyright { value.copyrightNotice = copyright }
        return value
    }

    private func photo(
        _ id: String,
        cache: DescriptiveMetadata,
        disk: DescriptiveMetadata? = nil,
        filename: String = "IMG_0001.CR3",
        sequence: Int = 1,
        diskKnown: Bool = true
    ) -> MetadataBatchPhotoInput {
        MetadataBatchPhotoInput(
            photoId: id,
            cache: cache,
            disk: disk ?? cache,
            diskKnown: diskKnown,
            filename: filename,
            camera: "X-T5",
            dateTaken: "2026:05:01 10:00:00",
            sequence: sequence)
    }

    @Test func detectsMixedAndCommonValues() {
        let photos = [
            metadata(caption: "A", city: "Paris"),
            metadata(caption: "B", city: "Paris"),
        ]
        #expect(MetadataFieldMix.isMixed(.caption, across: photos))
        #expect(!MetadataFieldMix.isMixed(.city, across: photos))
        #expect(MetadataFieldMix.commonText(.city, across: photos) == "Paris")
        #expect(MetadataFieldMix.commonText(.caption, across: photos) == nil)
        #expect(MetadataFieldMix.commonText(.copyrightNotice, across: photos) == "")
    }

    @Test func writesOnlyChangedFieldsPerPhoto() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .caption: .set(.text("ACME - {filename}")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [
                photo("p1", cache: metadata(), filename: "A.CR3", sequence: 1),
                photo("p2", cache: metadata(), filename: "B.CR3", sequence: 2),
            ])
        #expect(plan.unresolved.isEmpty)
        #expect(plan.writeCount == 2)
        #expect(plan.groups.count == 2)
        #expect(plan.groups[0].photoIds == ["p1"])
        #expect(plan.groups[0].patch.caption == "ACME - A.CR3")
        #expect(plan.groups[1].patch.caption == "ACME - B.CR3")
    }

    @Test func groupsPhotosWithIdenticalPatch() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .copyrightNotice: .set(.text("© 2026 ACME")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [
                photo("p1", cache: metadata()),
                photo("p2", cache: metadata()),
                photo("p3", cache: metadata()),
            ])
        #expect(plan.writeCount == 3)
        #expect(plan.groups.count == 1)
        #expect(plan.groups[0].photoIds == ["p1", "p2", "p3"])
        #expect(plan.canApply)
    }

    @Test func clearOnlyWhereValueExists() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .caption: .clear,
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [
                photo("with", cache: metadata(caption: "旧说明")),
                photo("without", cache: metadata()),
            ])
        #expect(plan.clearCount == 1)
        // 显式清空保三态语义：patch 里是空串（写入器据此删除元素），不是 nil。
        #expect(plan.photos.first { $0.photoId == "with" }?.patch.caption == "")
        #expect(plan.photos.first { $0.photoId == "with" }?.fields.first?.action == .clear)
        #expect(plan.photos.first { $0.photoId == "without" }?.fields.first?.action == .unchanged)
        #expect(plan.groups.count == 1)
        #expect(plan.groups[0].photoIds == ["with"])
    }

    @Test func externallyModifiedIsConflictUnderKeepExternal() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .caption: .set(.text("新说明")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [
                photo("p1", cache: metadata(caption: "缓存旧值"),
                      disk: metadata(caption: "外部新值")),
            ])
        #expect(plan.conflictCount == 1)
        #expect(plan.photos[0].fields.first?.action == .conflict)
        #expect(plan.photos[0].patch.isEmpty)
        #expect(!plan.canApply)
    }

    @Test func overwritePolicyWritesThroughExternalChange() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .caption: .set(.text("新说明")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [
                photo("p1", cache: metadata(caption: "缓存旧值"),
                      disk: metadata(caption: "外部新值")),
            ],
            policy: .overwrite)
        #expect(plan.conflictCount == 0)
        #expect(plan.photos[0].fields.first?.action == .write)
        #expect(plan.groups.count == 1)
    }

    @Test func unresolvedVariablesBlockTheWholePlan() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .caption: .set(.text("客户：{client}")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [photo("p1", cache: metadata())],
            scope: MetadataVariableScope(client: nil))
        #expect(plan.unresolved.count == 1)
        #expect(plan.unresolved.first?.photoId == "p1")
        #expect(plan.unresolved.first?.field == .caption)
        #expect(plan.unresolved.first?.variable.name == "client")
        #expect(!plan.canApply)
        #expect(plan.groups.isEmpty)
    }

    @Test func sequenceFollowsInputOrderAndStart() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .headline: .set(.text("No.{seq:2}")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [
                photo("p1", cache: metadata(), sequence: 1),
                photo("p2", cache: metadata(), sequence: 2),
            ],
            scope: MetadataVariableScope(sequenceStart: 10))
        // sequenceStart 由调用方在构造 photo.sequence 时应用；引擎只消费显式序号。
        #expect(plan.groups[0].patch.headline == "No.01")
        #expect(plan.groups[1].patch.headline == "No.02")
    }

    @Test func unchangedFieldProducesNoPatch() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .city: .set(.text("Paris")),
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [photo("p1", cache: metadata(city: "Paris"))])
        #expect(plan.writeCount == 0)
        #expect(plan.groups.isEmpty)
        #expect(plan.photos[0].fields.first?.action == .unchanged)
        #expect(!plan.canApply)
    }

    @Test func contactInfoIsNotBatchEditable() {
        let edits: [DescriptiveField: MetadataBatchFieldEdit] = [
            .contactInfo: .clear,
        ]
        let plan = MetadataBatchEditPlanner.plan(
            edits: edits,
            photos: [photo("p1", cache: metadata())])
        #expect(plan.photos[0].fields.isEmpty)
    }
}
