// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataApplyBatchStoreTests.swift
// P1 / B3：批次记录（undo 输入）——最近优先、去重、保留上限、撤销标记。

import Foundation
import Testing
import GatherTestSupport
import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("模板套用批次")
struct MetadataApplyBatchStoreTests {
    private func store() throws -> MetadataApplyBatchStore {
        let db = try makeTestDB()
        return MetadataApplyBatchStore(settings: SettingsService(repo: SettingsRepo(connection: db)))
    }

    private func batch(_ id: String, _ title: String? = "旧标题") -> MetadataApplyBatch {
        MetadataApplyBatch(
            id: id, templateId: "t1", templateName: "婚礼", appliedAt: "2026-10-26T00:00:00Z",
            snapshots: [MetadataApplySnapshot(photoId: "p1", filepath: "/a.cr3",
                                              before: DescriptiveMetadata(title: title))]
        )
    }

    @Test("最新的在前；同 id 覆盖不重复")
    func recordOrdering() throws {
        let s = try store()
        try s.record(batch("b1"))
        try s.record(batch("b2"))
        #expect(s.list().map(\.id) == ["b2", "b1"])
        try s.record(batch("b1", "改过"))
        #expect(s.list().map(\.id) == ["b1", "b2"])
        #expect(s.get(id: "b1")?.snapshots.first?.before.title == "改过")
    }

    @Test("保留上限 20 条，超限淘汰最旧")
    func retention() throws {
        let s = try store()
        for i in 0..<22 { try s.record(batch("b\(i)")) }
        #expect(s.list().count == MetadataApplyBatchStore.retention)
        #expect(s.list().first?.id == "b21")
        #expect(s.get(id: "b0") == nil)
    }

    @Test("撤销标记后 latest 跳过该批次")
    func undoMark() throws {
        let s = try store()
        try s.record(batch("b1"))
        try s.record(batch("b2"))
        try s.markUndone(id: "b2")
        #expect(s.latest()?.id == "b1")
        #expect(s.get(id: "b2")?.undone == true)
    }
}
