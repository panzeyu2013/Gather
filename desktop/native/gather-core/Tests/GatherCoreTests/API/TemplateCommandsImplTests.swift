// Tests/GatherCoreTests/API/TemplateCommandsImplTests.swift
// R5：template 域命令实现直测（批次 B4）。
// 覆盖旧分支语义：create/list/get/update 的读写与 TEMPLATE_NOT_FOUND、
// delete / apply 的 confirmed 门控、apply 的设置写入、
// 模板与会话状态错误传播、设置写入失败不被吞掉、错误串逐字一致。
import Foundation
import Testing
@testable import GatherCore

/// 设置写入失败注入：第二次 upsert 抛错，验证 apply 不吞错。
private struct SettingsWriteFailure: Error, Equatable {}

private actor FailingSettingsStore: SettingsStore {
    private let inner: SQLiteSettingsStore
    private var writes = 0

    init(inner: SQLiteSettingsStore) {
        self.inner = inner
    }

    func all() async throws -> [SettingRecord] {
        try await inner.all()
    }

    func get(_ key: String) async throws -> SettingRecord? {
        try await inner.get(key)
    }

    func upsert(_ key: String, value: String) async throws {
        writes += 1
        if writes == 2 {
            throw SettingsWriteFailure()
        }
        try await inner.upsert(key, value: value)
    }

    func upsert(_ entries: [SettingRecord]) async throws {
        try await inner.upsert(entries)
    }
}

@Suite("API/TemplateCommandsImpl (R5)")
struct TemplateCommandsImplTests {
    /// 目录直连 harness：TemplatesAPI + SettingsAPI 与命令实现共享同一临时库。
    private func makeHarness() async throws -> (
        impl: TemplateCommandsImpl, settings: SettingsAPI, db: SQLiteDatabase, path: String
    ) {
        let path = storeTempPath("template-commands")
        let db = try await makeMigratedStore(path: path)
        let settings = SettingsAPI(store: SQLiteSettingsStore(database: db))
        let templates = TemplatesAPI(
            templates: SQLiteTemplateStore(database: db),
            sessions: SQLiteSessionStore(database: db)
        )
        return (TemplateCommandsImpl(templates: templates, settings: settings), settings, db, path)
    }

    private func makeConfig(threshold: Double = 10) -> WorkflowTemplateConfig {
        WorkflowTemplateConfig(
            similarity: WorkflowTemplateSimilarity(threshold: threshold, minGroupSize: 2),
            face: WorkflowTemplateFace(eps: 0.6, minSamples: 2, detectorConfidence: 0.5),
            faceLibrary: WorkflowTemplateFaceLibrary(enabled: true, matchThreshold: 0.5),
            duplicate: WorkflowTemplateDuplicate(enabled: true, visualThreshold: 0.9),
            writeback: WorkflowTemplateWriteback(
                createAlbums: true, addPrefix: false, markUngrouped: true, writeIPTC: false)
        )
    }

    @Test("create/list/get/update roundtrip keeps trimmed name and config")
    func crudRoundtrip() async throws {
        let (impl, _, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        let created = try await impl.create(TemplateCreateParams(
            name: "  Portrait  ", config: makeConfig(threshold: 12)))
        #expect(created.name == "Portrait")
        #expect(created.description == "")
        #expect(created.config.similarity.threshold == 12)

        let list = try await impl.list()
        #expect(list.map(\.id) == [created.id])

        let got = try await impl.get(TemplateGetParams(templateId: created.id))
        #expect(got == created)

        let updated = try await impl.update(TemplateUpdateParams(
            templateId: created.id, name: "Portrait v2", config: makeConfig(threshold: 20)))
        #expect(updated.name == "Portrait v2")
        #expect(updated.config.similarity.threshold == 20)
        #expect(updated.description == "")
        let reread = try await impl.get(TemplateGetParams(templateId: created.id))
        #expect(reread == updated)
    }

    @Test("get and update throw TEMPLATE_NOT_FOUND for a missing template")
    func missingThrowsNotFound() async throws {
        let (impl, _, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        await #expect(throws: TemplateCommandsError.notFound) {
            try await impl.get(TemplateGetParams(templateId: "missing"))
        }
        await #expect(throws: TemplateCommandsError.notFound) {
            try await impl.update(TemplateUpdateParams(templateId: "missing", name: "x"))
        }
    }

    @Test("create rejects a blank or overlong name with INVALID_PARAM:name")
    func createValidatesName() async throws {
        let (impl, _, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        await #expect(throws: TemplateCommandsError.invalidParam("name")) {
            try await impl.create(TemplateCreateParams(name: "   ", config: makeConfig()))
        }
        await #expect(throws: TemplateCommandsError.invalidParam("name")) {
            try await impl.create(TemplateCreateParams(
                name: String(repeating: "n", count: 4097), config: makeConfig()))
        }
    }

    @Test("delete requires confirmation and then removes the template")
    func deleteGateAndEffect() async throws {
        let (impl, _, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let created = try await impl.create(
            TemplateCreateParams(name: "T", config: makeConfig()))

        await #expect(throws: TemplateCommandsError.deleteConfirmRequired) {
            try await impl.delete(
                TemplateDeleteParams(templateId: created.id, confirmed: false))
        }
        #expect(try await impl.list().count == 1)

        try await impl.delete(TemplateDeleteParams(templateId: created.id, confirmed: true))
        #expect(try await impl.list().isEmpty)
    }

    @Test("apply requires confirmation and writes the expanded settings")
    func applyGateAndWritesSettings() async throws {
        let (impl, settings, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let created = try await impl.create(TemplateCreateParams(
            name: "T", config: makeConfig(threshold: 12)))
        try await insertSession(db, "s1")

        await #expect(throws: TemplateCommandsError.applyConfirmRequired) {
            try await impl.apply(TemplateApplyParams(
                templateId: created.id, sessionId: "s1", confirmed: false))
        }
        let before = await settings.all()
        #expect(before["default_threshold"] == "10", "未确认时不得写入任何设置")

        try await impl.apply(TemplateApplyParams(
            templateId: created.id, sessionId: "s1", confirmed: true))
        let threshold = await settings.value("default_threshold")
        let minGroupSize = await settings.value("default_min_group_size")
        let eps = await settings.value("default_eps")
        let minSamples = await settings.value("default_min_samples")
        let confidence = await settings.value("detect_confidence")
        #expect(threshold == "12.0")
        #expect(minGroupSize == "2")
        #expect(eps == "0.6")
        #expect(minSamples == "2")
        #expect(confidence == "0.5")
    }

    @Test("apply propagates template and session domain errors")
    func applyPropagatesDomainErrors() async throws {
        let (impl, _, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let created = try await impl.create(
            TemplateCreateParams(name: "T", config: makeConfig()))

        await #expect(throws: TemplateError.templateNotFound) {
            try await impl.apply(TemplateApplyParams(
                templateId: "missing", sessionId: "s1", confirmed: true))
        }
        await #expect(throws: TemplateError.sessionNotFound) {
            try await impl.apply(TemplateApplyParams(
                templateId: created.id, sessionId: "missing", confirmed: true))
        }

        try await insertSession(db, "s2")
        _ = try await db.run(
            "UPDATE sessions SET status = 'indexed' WHERE id = ?", [.text("s2")])
        await #expect(throws: TemplateError.invalidSessionStatus("indexed")) {
            try await impl.apply(TemplateApplyParams(
                templateId: created.id, sessionId: "s2", confirmed: true))
        }
    }

    @Test("apply propagates a settings write failure instead of swallowing it")
    func applyPropagatesWriteFailure() async throws {
        let path = storeTempPath("template-commands-failing")
        let db = try await makeMigratedStore(path: path)
        defer { removeStoreFiles(path) }
        let templates = TemplatesAPI(
            templates: SQLiteTemplateStore(database: db),
            sessions: SQLiteSessionStore(database: db)
        )
        let failing = SettingsAPI(
            store: FailingSettingsStore(inner: SQLiteSettingsStore(database: db)))
        let impl = TemplateCommandsImpl(templates: templates, settings: failing)
        let created = try await impl.create(
            TemplateCreateParams(name: "T", config: makeConfig()))
        try await insertSession(db, "s1")

        await #expect(throws: SettingsWriteFailure()) {
            try await impl.apply(TemplateApplyParams(
                templateId: created.id, sessionId: "s1", confirmed: true))
        }
        // 第二项失败前首项已写入（非事务语义），但错误未被吞掉。
        let first = await failing.value("default_threshold")
        #expect(first == "10.0")
    }

    @Test("error descriptions and gather codes match the legacy strings")
    func errorStrings() {
        #expect(TemplateCommandsError.notFound.description == "TEMPLATE_NOT_FOUND")
        #expect(TemplateCommandsError.invalidParam("name").description == "INVALID_PARAM:name")
        #expect(TemplateCommandsError.deleteConfirmRequired.description == "TEMPLATE_DELETE_CONFIRM_REQUIRED")
        #expect(TemplateCommandsError.applyConfirmRequired.description == "TEMPLATE_APPLY_CONFIRM_REQUIRED")
        #expect(TemplateCommandsError.notFound.gatherCode == .TEMPLATE_NOT_FOUND)
        #expect(TemplateCommandsError.deleteConfirmRequired.gatherCode == .TEMPLATE_DELETE_CONFIRM_REQUIRED)
        #expect(TemplateCommandsError.applyConfirmRequired.gatherCode == .TEMPLATE_APPLY_CONFIRM_REQUIRED)
        #expect(TemplateCommandsError.invalidParam("name").gatherCode == nil)
    }
}
