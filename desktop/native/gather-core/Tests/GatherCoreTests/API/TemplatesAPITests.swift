// Tests/GatherCoreTests/API/TemplatesAPITests.swift
// R1/R5：模板命名空间（CRUD + apply 领域校验），取代 TemplateService/TemplateServiceTests。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/TemplatesAPI (R1-R5)")
struct TemplatesAPITests {
    private func makeAPI() async throws -> (GatherAPI, String) {
        let path = storeTempPath("templates-api")
        return (try await GatherAPI.open(path: path), path)
    }

    private func config(threshold: Double = 12, minGroupSize: Int = 3) -> WorkflowTemplateConfig {
        WorkflowTemplateConfig(
            similarity: WorkflowTemplateSimilarity(threshold: threshold, minGroupSize: minGroupSize),
            face: WorkflowTemplateFace(eps: 0.5, minSamples: 2, detectorConfidence: 0.7),
            faceLibrary: WorkflowTemplateFaceLibrary(enabled: true, matchThreshold: 0.6),
            duplicate: WorkflowTemplateDuplicate(enabled: false, visualThreshold: 4),
            writeback: WorkflowTemplateWriteback(createAlbums: true, addPrefix: false, markUngrouped: true, writeIPTC: false)
        )
    }

    @Test func crudRoundTrip() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        let created = try await api.templates.create(name: "T", description: "d", config: config())
        #expect(try await api.templates.list().map(\.id) == [created.id])
        #expect(try await api.templates.get(id: created.id)?.config.similarity.threshold == 12)

        let updated = try await api.templates.update(id: created.id, fields: TemplateUpdateFields(name: "T2"))
        #expect(updated?.name == "T2")
        #expect(try await api.templates.update(id: "missing", fields: TemplateUpdateFields(name: "X")) == nil)

        try await api.templates.delete(id: created.id)
        #expect(try await api.templates.list().isEmpty)
    }

    @Test func applyUpdatesValidatesTemplateSessionAndStatus() async throws {
        let (api, path) = try await makeAPI()
        defer { removeStoreFiles(path) }

        let template = try await api.templates.create(name: "T", description: "", config: config(threshold: 0.8))
        let session = try await api.sessions.create(name: "S", source: "folder", sourcePath: "/p")

        // draft 允许：返回固定键序的设置项，不改动任何存储。
        let updates = try await api.templates.applyUpdates(templateId: template.id, sessionId: session.id)
        #expect(updates == [
            TemplateSettingUpdate(key: "default_threshold", value: "0.8"),
            TemplateSettingUpdate(key: "default_min_group_size", value: "3"),
            TemplateSettingUpdate(key: "default_eps", value: "0.5"),
            TemplateSettingUpdate(key: "default_min_samples", value: "2"),
            TemplateSettingUpdate(key: "detect_confidence", value: "0.7"),
        ])

        // photos_loaded 允许。
        try await api.sessions.updateStatus(id: session.id, status: "photos_loaded")
        _ = try await api.templates.applyUpdates(templateId: template.id, sessionId: session.id)

        // 其他状态：TS 逐字消息。
        try await api.sessions.updateStatus(id: session.id, status: "indexed")
        await #expect(throws: TemplateError.invalidSessionStatus("indexed")) {
            _ = try await api.templates.applyUpdates(templateId: template.id, sessionId: session.id)
        }
        #expect(
            String(describing: TemplateError.invalidSessionStatus("indexed"))
                == "Cannot apply template to session with status \"indexed\". Expected draft or photos_loaded."
        )

        await #expect(throws: TemplateError.templateNotFound) {
            _ = try await api.templates.applyUpdates(templateId: "nope", sessionId: session.id)
        }
        await #expect(throws: TemplateError.sessionNotFound) {
            _ = try await api.templates.applyUpdates(templateId: template.id, sessionId: "nope")
        }
        #expect(String(describing: TemplateError.sessionNotFound) == "SESSION_NOT_FOUND")
        #expect(TemplateError.templateNotFound.gatherCode == .TEMPLATE_NOT_FOUND)
        #expect(TemplateError.invalidSessionStatus("x").gatherCode == nil)
    }
}
