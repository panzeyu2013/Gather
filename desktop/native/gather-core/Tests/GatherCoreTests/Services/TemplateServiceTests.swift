// desktop/native/gather-core/Tests/GatherCoreTests/Services/TemplateServiceTests.swift
// TemplateService 行为测试（Phase 3.5）。
// TS 源: desktop/src/main/services/template/template.service.ts（TS 无单测，
// 按 template.ipc.ts 契约补测：CRUD 往返 / 排序 / 更新语义 / apply 与设置联动 /
// 错误消息逐字对齐）。

import Foundation
import Testing
@testable import GatherCore

private struct TemplateHarness {
    let db: DBConnection
    let service: TemplateService
    let sessionId: String
}

private func makeTemplateHarness(sessionStatus: String = "draft") throws -> TemplateHarness {
    let db = try makeMigratedDB()
    let service = TemplateService(connection: db)
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "T", source: "folder")
    if sessionStatus != "draft" {
        _ = try db.prepare("UPDATE sessions SET status = ? WHERE id = ?")
            .run([.text(sessionStatus), .text(session.id)])
    }
    return TemplateHarness(db: db, service: service, sessionId: session.id)
}

private func makeConfig() -> WorkflowTemplateConfig {
    WorkflowTemplateConfig(
        similarity: WorkflowTemplateSimilarity(threshold: 0.8, minGroupSize: 3),
        face: WorkflowTemplateFace(eps: 0.5, minSamples: 2, detectorConfidence: 0.7),
        faceLibrary: WorkflowTemplateFaceLibrary(enabled: true, matchThreshold: 0.6),
        duplicate: WorkflowTemplateDuplicate(enabled: false, visualThreshold: 4),
        writeback: WorkflowTemplateWriteback(createAlbums: true, addPrefix: false, markUngrouped: true, writeIPTC: false)
    )
}

@Suite("TemplateService CRUD")
struct TemplateCrudTests {
    @Test("create persists and get returns the full template data")
    func createAndGet() throws {
        let harness = try makeTemplateHarness()
        let config = makeConfig()

        let created = try harness.service.create(name: "Face Workflow", description: "desc", config: config)

        #expect(!created.id.isEmpty)
        #expect(created.name == "Face Workflow")
        #expect(created.description == "desc")
        #expect(created.config == config)
        #expect(!created.createdAt.isEmpty)
        #expect(!created.updatedAt.isEmpty)
        #expect(created.createdAt == created.updatedAt)

        let fetched = try harness.service.get(id: created.id)
        #expect(fetched == created)
    }

    @Test("get returns nil for an unknown id")
    func getMissing() throws {
        let harness = try makeTemplateHarness()
        #expect(try harness.service.get(id: "nope") == nil)
    }

    @Test("update applies partial fields and bumps updated_at")
    func updatePartial() async throws {
        let harness = try makeTemplateHarness()
        let created = try harness.service.create(name: "A", description: "", config: makeConfig())

        // 同毫秒内 create+update 的 ISO 时间戳相同（TS 语义仅"update 刷新
        // updated_at"），等待 2ms 确保断言稳定。
        try await Task.sleep(nanoseconds: 2_000_000)
        let updated = try harness.service.update(
            id: created.id,
            fields: TemplateUpdateFields(name: "B", config: makeConfig())
        )

        #expect(updated.name == "B")
        #expect(updated.description == "")  // 未提供的字段保持不变
        #expect(updated.config == makeConfig())
        #expect(updated.updatedAt != created.updatedAt)
    }

    @Test("update with no fields returns the existing row untouched")
    func updateNoop() throws {
        let harness = try makeTemplateHarness()
        let created = try harness.service.create(name: "A", description: "", config: makeConfig())

        let updated = try harness.service.update(id: created.id, fields: TemplateUpdateFields())

        #expect(updated == created)
    }

    @Test("update throws TEMPLATE_NOT_FOUND for an unknown id")
    func updateMissing() throws {
        let harness = try makeTemplateHarness()
        #expect(throws: TemplateServiceError.templateNotFound) {
            _ = try harness.service.update(
                id: "nope", fields: TemplateUpdateFields(name: "B"))
        }
        #expect(String(describing: TemplateServiceError.templateNotFound) == "TEMPLATE_NOT_FOUND")
    }

    @Test("delete removes the template")
    func delete() throws {
        let harness = try makeTemplateHarness()
        let created = try harness.service.create(name: "A", description: "", config: makeConfig())

        try harness.service.delete(id: created.id)

        #expect(try harness.service.get(id: created.id) == nil)
        #expect(try harness.service.list().isEmpty)
    }

    @Test("list orders by updated_at DESC")
    func listOrdering() throws {
        let harness = try makeTemplateHarness()
        let first = try harness.service.create(name: "First", description: "", config: makeConfig())
        let second = try harness.service.create(name: "Second", description: "", config: makeConfig())
        // 触碰 first 的 updated_at，使其排到最前。
        _ = try harness.service.update(id: first.id, fields: TemplateUpdateFields(description: "touched"))

        let list = try harness.service.list()

        #expect(list.map(\.id) == [first.id, second.id])
    }
}

@Suite("TemplateService apply")
struct TemplateApplyTests {
    @Test("settingsUpdates returns the template settings in fixed key order")
    func settingsUpdatesReturnTemplateConfig() throws {
        let harness = try makeTemplateHarness()
        let config = makeConfig()
        let template = try harness.service.create(name: "T", description: "", config: config)

        let updates = try harness.service.settingsUpdates(templateId: template.id, sessionId: harness.sessionId)

        // R5：服务只产出待写入项，落库由调用方经 SettingsAPI 完成。
        #expect(updates == [
            TemplateSettingUpdate(key: "default_threshold", value: "0.8"),
            TemplateSettingUpdate(key: "default_min_group_size", value: "3"),
            TemplateSettingUpdate(key: "default_eps", value: "0.5"),
            TemplateSettingUpdate(key: "default_min_samples", value: "2"),
            TemplateSettingUpdate(key: "detect_confidence", value: "0.7"),
        ])
    }

    @Test("apply accepts draft and photos_loaded sessions")
    func applyAcceptedStatuses() throws {
        let draft = try makeTemplateHarness(sessionStatus: "draft")
        let template = try draft.service.create(name: "T", description: "", config: makeConfig())
        #expect(throws: Never.self) {
            _ = try draft.service.settingsUpdates(templateId: template.id, sessionId: draft.sessionId)
        }

        let loaded = try makeTemplateHarness(sessionStatus: "photos_loaded")
        let template2 = try loaded.service.create(name: "T", description: "", config: makeConfig())
        #expect(throws: Never.self) {
            _ = try loaded.service.settingsUpdates(templateId: template2.id, sessionId: loaded.sessionId)
        }
    }

    @Test("apply rejects other session statuses with the TS message")
    func applyRejectsStatus() throws {
        let harness = try makeTemplateHarness(sessionStatus: "indexed")
        let template = try harness.service.create(name: "T", description: "", config: makeConfig())

        #expect(throws: TemplateServiceError.invalidSessionStatus("indexed")) {
            _ = try harness.service.settingsUpdates(templateId: template.id, sessionId: harness.sessionId)
        }
        // TS: `Cannot apply template to session with status "${status}". Expected draft or photos_loaded.`
        #expect(
            String(describing: TemplateServiceError.invalidSessionStatus("indexed"))
                == "Cannot apply template to session with status \"indexed\". Expected draft or photos_loaded."
        )
    }

    @Test("apply throws TEMPLATE_NOT_FOUND and SESSION_NOT_FOUND")
    func applyNotFound() throws {
        let harness = try makeTemplateHarness()
        let template = try harness.service.create(name: "T", description: "", config: makeConfig())
        #expect(throws: TemplateServiceError.templateNotFound) {
            _ = try harness.service.settingsUpdates(templateId: "nope", sessionId: harness.sessionId)
        }
        #expect(throws: TemplateServiceError.sessionNotFound) {
            _ = try harness.service.settingsUpdates(templateId: template.id, sessionId: "nope")
        }
        #expect(String(describing: TemplateServiceError.sessionNotFound) == "SESSION_NOT_FOUND")
    }
}
