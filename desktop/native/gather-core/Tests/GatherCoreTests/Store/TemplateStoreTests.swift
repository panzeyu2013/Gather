// Tests/GatherCoreTests/Store/TemplateStoreTests.swift
// R1：TemplateStore 测试（workflow_templates CRUD + config JSON 往返 + 畸形配置）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/TemplateStore (R1)")
struct TemplateStoreTests {
    private func makeStore() async throws -> (SQLiteTemplateStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "template")
        return (SQLiteTemplateStore(database: database), database, path)
    }

    private func config(
        threshold: Double = 12,
        minGroupSize: Int = 3,
        eps: Double = 0.35,
        writeIPTC: Bool = true
    ) -> WorkflowTemplateConfig {
        WorkflowTemplateConfig(
            similarity: WorkflowTemplateSimilarity(threshold: threshold, minGroupSize: minGroupSize),
            face: WorkflowTemplateFace(eps: eps, minSamples: 2, detectorConfidence: 0.9),
            faceLibrary: WorkflowTemplateFaceLibrary(enabled: true, matchThreshold: 0.6),
            duplicate: WorkflowTemplateDuplicate(enabled: false, visualThreshold: 0.95),
            writeback: WorkflowTemplateWriteback(
                createAlbums: true, addPrefix: false, markUngrouped: true, writeIPTC: writeIPTC
            )
        )
    }

    @Test func createAndGetRoundTripsConfig() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let created = try await store.create(name: "Wedding", description: "desc", config: config())
        #expect(!created.id.isEmpty)
        #expect(created.name == "Wedding")
        #expect(created.description == "desc")
        #expect(!created.createdAt.isEmpty)
        #expect(!created.updatedAt.isEmpty)

        let fetched = try await store.get(id: created.id)
        #expect(fetched == created, "config JSON 往返无损")
        #expect(fetched?.config.similarity.threshold == 12)
        #expect(fetched?.config.similarity.minGroupSize == 3)
        #expect(fetched?.config.face.eps == 0.35)
        #expect(fetched?.config.faceLibrary.enabled == true)
        #expect(fetched?.config.duplicate.enabled == false)
        #expect(fetched?.config.writeback.writeIPTC == true)

        #expect(try await store.get(id: "missing") == nil)
        #expect(try await store.list().map(\.id) == [created.id])
    }

    @Test func listOrdersByUpdatedAtDescending() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let first = try await store.create(name: "First", description: "", config: config())
        let second = try await store.create(name: "Second", description: "", config: config())
        try await database.run(
            "UPDATE workflow_templates SET updated_at = '2026-01-01T00:00:00.000Z' WHERE id = ?",
            [.text(first.id)]
        )
        try await database.run(
            "UPDATE workflow_templates SET updated_at = '2026-05-01T00:00:00.000Z' WHERE id = ?",
            [.text(second.id)]
        )
        #expect(try await store.list().map(\.id) == [second.id, first.id])
    }

    @Test func updatePartialFieldsAndConfig() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let created = try await store.create(name: "A", description: "d", config: config(threshold: 10, writeIPTC: false))

        let renamed = try await store.update(id: created.id, fields: TemplateUpdateFields(name: "B"))
        #expect(renamed?.name == "B")
        #expect(renamed?.description == "d", "未提供字段保持原值")
        #expect(renamed?.config.similarity.threshold == 10)

        let reconfigured = try await store.update(
            id: created.id,
            fields: TemplateUpdateFields(config: config(threshold: 20, writeIPTC: true))
        )
        #expect(reconfigured?.config.similarity.threshold == 20)
        #expect(reconfigured?.config.writeback.writeIPTC == true)
        #expect(reconfigured?.name == "B")

        let untouched = try await store.update(id: created.id, fields: TemplateUpdateFields())
        #expect(untouched?.config.similarity.threshold == 20, "空字段集合 no-op")

        #expect(try await store.update(id: "missing", fields: TemplateUpdateFields(name: "X")) == nil)
    }

    @Test func deleteRemovesRow() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let created = try await store.create(name: "A", description: "", config: config())

        try await store.delete(id: created.id)
        #expect(try await store.get(id: created.id) == nil)
        #expect(try await store.list().isEmpty)
        try await store.delete(id: "missing")
    }

    @Test func malformedConfigThrows() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await database.run(
            """
            INSERT INTO workflow_templates (id, name, description, config, created_at, updated_at)
            VALUES ('broken', 'X', '', '{not-json', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        await #expect(throws: TemplateStoreError.self) {
            _ = try await store.get(id: "broken")
        }

        // 非对象 JSON（"[]"）按空配置处理（TS undefined 字段语义）。
        try await database.run(
            """
            INSERT INTO workflow_templates (id, name, description, config, created_at, updated_at)
            VALUES ('array', 'Y', '', '[]', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        #expect(try await store.get(id: "array")?.config.similarity.threshold == 0)
    }
}
