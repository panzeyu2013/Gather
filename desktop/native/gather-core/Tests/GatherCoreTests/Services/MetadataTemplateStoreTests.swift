// desktop/native/gather-core/Tests/GatherCoreTests/Services/MetadataTemplateStoreTests.swift
// P1 / B2：模板存储（settings 单键 JSON）——CRUD、重名、名必填、跨实例可见。

import Foundation
import Testing
import GatherTestSupport
import GatherProtocol
@testable import GatherPersistence
@testable import GatherApplication

@Suite("元数据模板存储")
struct MetadataTemplateStoreTests {
    private func store() throws -> (MetadataTemplateStore, SettingsService, DBConnection) {
        let db = try makeTestDB()
        let service = SettingsService(repo: SettingsRepo(connection: db))
        return (MetadataTemplateStore(settings: service), service, db)
    }

    private func template(_ id: String, _ name: String, title: String? = "标题") -> MetadataTemplate {
        MetadataTemplate(
            id: id, name: name,
            fields: DescriptiveMetadata(title: title, city: "上海"),
            createdAt: "", updatedAt: ""
        )
    }

    @Test("保存后可读回；再次保存同 id 视为更新并保留 createdAt")
    func saveAndUpdate() throws {
        let (store, _, _) = try store()
        let first = try store.save(template("t1", "婚礼"), now: "2026-10-26T00:00:00Z")
        #expect(first.createdAt == "2026-10-26T00:00:00Z")
        #expect(store.list().count == 1)

        let updated = try store.save(template("t1", "婚礼 2026", title: "新标题"), now: "2026-10-27T00:00:00Z")
        #expect(updated.createdAt == "2026-10-26T00:00:00Z")
        #expect(updated.updatedAt == "2026-10-27T00:00:00Z")
        #expect(store.list().count == 1)
        #expect(store.get(id: "t1")?.fields.title == "新标题")
    }

    @Test("名必填、重名拒绝、删除后不可再取")
    func validationAndDelete() throws {
        let (store, _, _) = try store()
        #expect(throws: MetadataTemplateStoreError.self) {
            _ = try store.save(template("t1", "   "), now: "now")
        }
        _ = try store.save(template("t1", "婚礼"), now: "now")
        #expect(throws: MetadataTemplateStoreError.self) {
            _ = try store.save(template("t2", "婚礼"), now: "now")
        }
        try store.delete(id: "t1")
        #expect(store.get(id: "t1") == nil)
        #expect(throws: MetadataTemplateStoreError.self) { try store.delete(id: "t1") }
    }

    @Test("跨实例可见（settings 是唯一真相源），损坏 JSON 视为空表并留证")
    func persistenceAndCorruption() throws {
        let (store, settings, _) = try store()
        _ = try store.save(template("t1", "婚礼"), now: "now")
        let other = MetadataTemplateStore(settings: settings)
        #expect(other.list().count == 1)

        try settings.set(MetadataTemplateStore.settingsKey, value: "{not json")
        #expect(MetadataTemplateStore(settings: settings).list().isEmpty)
        // P2：损坏原文必须留证，否则下一次 save 覆盖后无从排查"模板消失"。
        #expect(settings.get(MetadataTemplateStore.corruptKey, defaultValue: "") == "{not json")
    }

    @Test("数组里单条模板损坏：只丢那一条，其余保留（P2）")
    func dropsOnlyCorruptEntries() throws {
        let (store, settings, _) = try store()
        _ = try store.save(template("t1", "婚礼"), now: "now")
        let valid = settings.get(MetadataTemplateStore.settingsKey, defaultValue: "")
        let mixed = "[" + String(valid.dropFirst().dropLast()) + ",{\"id\":2}]"
        try settings.set(MetadataTemplateStore.settingsKey, value: mixed)

        let reopened = MetadataTemplateStore(settings: settings)
        #expect(reopened.list().map(\.id) == ["t1"], "坏一条不得清空整表")
        #expect(settings.get(MetadataTemplateStore.corruptKey, defaultValue: "")
            == mixed, "整表原文留证")
    }
}
