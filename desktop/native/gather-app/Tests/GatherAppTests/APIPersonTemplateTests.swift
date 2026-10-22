// desktop/native/gather-app/Tests/GatherAppTests/APIPersonTemplateTests.swift
// Cut 1 / B7a：LivePersonAPI（8 方法）与 LiveTemplateAPI（6 方法）的行为测试。
//
// 覆盖：
// - person：list/get/create 的 DTO 形状与 PERSON_NOT_FOUND；update 的 name/notes/
//   keywords/matchThreshold 与空更新；searchPhotos 的分页/会话过滤/参数边界；
//   merge / removePhoto / delete 的 Confirmed<T> 行为与投影变化；
// - template：CRUD（create 的 name trim、update 空更新、delete 幂等）与
//   TEMPLATE_NOT_FOUND；apply 的 draft/photos_loaded 白名单、SettingsService
//   写穿（阈值/eps 等）、非法会话状态 → INVALID_PARAM、缺失会话 →
//   SESSION_NOT_FOUND；
// - 错误路径：空白 id、超长 name、负数 limit/offset、NaN matchThreshold。
//
// 夹具：内存 SQLite（makeGatherTestDB）+ 真实 PersonRepo / TemplateService /
// SettingsService / SessionRepo，不触碰用户数据；破坏性入口一律显式
// Confirmed<T>（D-011，source=.test）。

import Foundation
import Testing
import GatherProtocol
import GatherPersistence
import GatherAnalysis
import GatherApplication
@testable import GatherUI
@testable import GatherHost

// MARK: - 夹具

private struct PersonTemplateFixture {
    let db: DBConnection
    let personRepo: PersonRepo
    let photoRepo: PhotoRepo
    let sessionRepo: SessionRepo
    let settingsService: SettingsService
    let templateService: TemplateService
    let personAPI: LivePersonAPI
    let templateAPI: LiveTemplateAPI

    init() throws {
        let db = try makeGatherTestDB()
        let personRepo = PersonRepo(connection: db)
        let photoRepo = PhotoRepo(connection: db)
        let sessionRepo = SessionRepo(connection: db)
        let settingsService = SettingsService(repo: SettingsRepo(connection: db))
        let templateService = TemplateService(connection: db, settings: settingsService)
        self.db = db
        self.personRepo = personRepo
        self.photoRepo = photoRepo
        self.sessionRepo = sessionRepo
        self.settingsService = settingsService
        self.templateService = templateService
        self.personAPI = LivePersonAPI(personRepo: personRepo)
        self.templateAPI = LiveTemplateAPI(templateService: templateService)
    }

    /// SessionRepo.create 默认 draft；需要其它状态时显式 updateStatus。
    func makeSession(status: String = "draft") throws -> String {
        let session = try sessionRepo.create(name: "B7a", source: "test")
        if status != "draft" {
            try sessionRepo.updateStatus(id: session.id, status: status)
        }
        return session.id
    }

    /// 照片行只落库（PhotoRepo.addPhotos 不触碰文件系统），路径无需真实存在。
    func addPhotos(_ sessionId: String, count: Int) throws -> [String] {
        let inputs = (0..<count).map { index in
            PhotoAddInput(
                filepath: "/tmp/gather-b7a-\(UUID().uuidString)-\(index).png",
                width: 100,
                height: 80
            )
        }
        return try photoRepo.addPhotos(sessionId: sessionId, filepaths: inputs, "test").ids
    }

    func addPersonPhotos(_ personId: String, sessionId: String, photoIds: [String]) throws {
        try personRepo.addPhotos(
            personId: personId,
            sessionId: sessionId,
            photos: photoIds.enumerated().map { index, photoId in
                PersonPhotoInput(
                    photoId: photoId,
                    faceBbox: [0.1, 0.2, 0.3, 0.4],
                    confidence: 0.9 - Double(index) * 0.1
                )
            }
        )
    }
}

private func makeTemplateConfig(
    threshold: Double = 10,
    minGroupSize: Int = 2,
    eps: Double = 0.65,
    minSamples: Int = 2,
    detectorConfidence: Double = 0.5
) -> WorkflowTemplateConfig {
    WorkflowTemplateConfig(
        similarity: WorkflowTemplateSimilarity(
            threshold: threshold,
            minGroupSize: minGroupSize
        ),
        face: WorkflowTemplateFace(
            eps: eps,
            minSamples: minSamples,
            detectorConfidence: detectorConfidence
        ),
        faceLibrary: WorkflowTemplateFaceLibrary(enabled: true, matchThreshold: 0.6),
        duplicate: WorkflowTemplateDuplicate(enabled: true, visualThreshold: 8),
        writeback: WorkflowTemplateWriteback(
            createAlbums: true,
            addPrefix: false,
            markUngrouped: true,
            writeIPTC: false
        )
    )
}

/// 只接受 GatherError；非 GatherError 视为失败路径断言失败（返回 nil 便于 #expect）。
private func gatherError<T>(_ body: () async throws -> T) async -> GatherError? {
    do {
        _ = try await body()
        return nil
    } catch let error as GatherError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Person

@Suite("B7a Live PersonAPI")
struct APIPersonTests {
    @Test("person.list/get/create：DTO 形状、name trim 与 PERSON_NOT_FOUND")
    func listGetCreate() async throws {
        let fixture = try PersonTemplateFixture()

        let created = try await fixture.personAPI.create(
            PersonCreateParams(name: "  Alice  ", keywords: ["lead"])
        )
        #expect(!created.id.isEmpty)

        let list = try await fixture.personAPI.list()
        #expect(list.count == 1)
        #expect(list[0].id == created.id)
        #expect(list[0].name == "Alice")
        #expect(list[0].keywords == ["lead"])
        #expect(list[0].photoCount == 0)
        #expect(list[0].sessionCount == 0)

        let detail = try await fixture.personAPI.get(created.id)
        #expect(detail.id == created.id)
        #expect(detail.name == "Alice")
        #expect(detail.notes == "")
        #expect(detail.photos.isEmpty)
        #expect(detail.totalPhotoCount == 0)

        let missing = await gatherError {
            _ = try await fixture.personAPI.get("missing")
        }
        #expect(missing?.code == .PERSON_NOT_FOUND)

        let blankId = await gatherError {
            _ = try await fixture.personAPI.get("   ")
        }
        #expect(blankId?.code == .INVALID_PARAM)
        #expect(blankId?.params["field"] == "personId")

        let blankName = await gatherError {
            _ = try await fixture.personAPI.create(PersonCreateParams(name: "   "))
        }
        #expect(blankName?.code == .INVALID_PARAM)
        #expect(blankName?.params["field"] == "name")

        let longName = await gatherError {
            _ = try await fixture.personAPI.create(
                PersonCreateParams(name: String(repeating: "a", count: 4097))
            )
        }
        #expect(longName?.code == .INVALID_PARAM)
        #expect(longName?.params["field"] == "name")
    }

    @Test("person.update/searchPhotos：字段更新、空名保留、分页与参数边界")
    func updateAndSearchPhotos() async throws {
        let fixture = try PersonTemplateFixture()
        let personId = try await fixture.personAPI.create(
            PersonCreateParams(name: "Alice")
        ).id
        let sessionId = try fixture.makeSession()
        let photoIds = try fixture.addPhotos(sessionId, count: 2)
        try fixture.addPersonPhotos(personId, sessionId: sessionId, photoIds: photoIds)

        let withPhotos = try await fixture.personAPI.get(personId)
        #expect(withPhotos.photoCount == 2)
        #expect(withPhotos.sessionCount == 1)
        #expect(withPhotos.totalPhotoCount == 2)
        #expect(withPhotos.photos.count == 2)
        #expect(withPhotos.photos.allSatisfy { $0.faceBbox.count == 4 })
        #expect(withPhotos.photos.allSatisfy { $0.sessionName == "B7a" })

        try await fixture.personAPI.update(PersonUpdateParams(
            personId: personId,
            name: "  Bob  ",
            keywords: ["k1", "k2"],
            notes: "note",
            matchThreshold: 0.8
        ))
        let updated = try await fixture.personAPI.get(personId)
        #expect(updated.name == "Bob")
        #expect(updated.keywords == ["k1", "k2"])
        #expect(updated.notes == "note")
        #expect(updated.matchThreshold == 0.8)

        // 旧命令面 语义：空名不报错，PersonRepo 保留原名（只有空白也视作不改名）。
        try await fixture.personAPI.update(PersonUpdateParams(personId: personId, name: "   "))
        #expect(try await fixture.personAPI.get(personId).name == "Bob")

        // 旧 optionalNumber 对 NaN 静默丢弃；D-012/G1 改为显式参数错误。
        let nanThreshold = await gatherError {
            try await fixture.personAPI.update(
                PersonUpdateParams(personId: personId, matchThreshold: .nan)
            )
        }
        #expect(nanThreshold?.code == .INVALID_PARAM)
        #expect(nanThreshold?.params["field"] == "matchThreshold")

        // 不存在的 person 在旧命令面是幂等 no-op（Repo 返回 .noop），不升级为错误。
        try await fixture.personAPI.update(
            PersonUpdateParams(personId: "missing", notes: "ignored")
        )

        let firstPage = try await fixture.personAPI.searchPhotos(
            PersonSearchPhotosParams(personId: personId, limit: 1)
        )
        #expect(firstPage.total == 2)
        #expect(firstPage.photos.count == 1)

        let secondPage = try await fixture.personAPI.searchPhotos(
            PersonSearchPhotosParams(personId: personId, limit: 1, offset: 1)
        )
        #expect(secondPage.total == 2)
        #expect(secondPage.photos.count == 1)
        #expect(secondPage.photos[0].photoId != firstPage.photos[0].photoId)

        let scoped = try await fixture.personAPI.searchPhotos(
            PersonSearchPhotosParams(personId: personId, sessionIds: [sessionId])
        )
        #expect(scoped.total == 2)

        let otherSession = try await fixture.personAPI.searchPhotos(
            PersonSearchPhotosParams(personId: personId, sessionIds: ["other"])
        )
        #expect(otherSession.total == 0)
        #expect(otherSession.photos.isEmpty)

        let blankSearch = await gatherError {
            _ = try await fixture.personAPI.searchPhotos(
                PersonSearchPhotosParams(personId: "  ")
            )
        }
        #expect(blankSearch?.code == .INVALID_PARAM)
        #expect(blankSearch?.params["field"] == "personId")

        let negativeLimit = await gatherError {
            _ = try await fixture.personAPI.searchPhotos(
                PersonSearchPhotosParams(personId: personId, limit: -1)
            )
        }
        #expect(negativeLimit?.code == .INVALID_PARAM)
        #expect(negativeLimit?.params["field"] == "limit")

        let negativeOffset = await gatherError {
            _ = try await fixture.personAPI.searchPhotos(
                PersonSearchPhotosParams(personId: personId, offset: -1)
            )
        }
        #expect(negativeOffset?.code == .INVALID_PARAM)
        #expect(negativeOffset?.params["field"] == "offset")
    }

    @Test("person.merge / removePhoto / delete：Confirmed<T> 的投影变化")
    func mergeRemoveDelete() async throws {
        let fixture = try PersonTemplateFixture()
        let sourceId = try await fixture.personAPI.create(
            PersonCreateParams(name: "Source")
        ).id
        let targetId = try await fixture.personAPI.create(
            PersonCreateParams(name: "Target")
        ).id
        let sessionId = try fixture.makeSession()
        let photoIds = try fixture.addPhotos(sessionId, count: 2)
        try fixture.addPersonPhotos(sourceId, sessionId: sessionId, photoIds: [photoIds[0]])
        try fixture.addPersonPhotos(targetId, sessionId: sessionId, photoIds: [photoIds[1]])

        try await fixture.personAPI.merge(
            Confirmed(
                try PersonMergeInput(sourceId: sourceId, targetId: targetId),
                source: .test
            )
        )
        #expect(try await fixture.personAPI.list().map(\.name) == ["Target"])

        let merged = try await fixture.personAPI.get(targetId)
        #expect(merged.totalPhotoCount == 2)
        #expect(Set(merged.photos.map(\.photoId)) == Set(photoIds))

        let sourceGone = await gatherError {
            _ = try await fixture.personAPI.get(sourceId)
        }
        #expect(sourceGone?.code == .PERSON_NOT_FOUND)

        try await fixture.personAPI.removePhoto(
            Confirmed(
                try PersonRemovePhotoInput(personId: targetId, photoId: photoIds[0]),
                source: .test
            )
        )
        let afterRemove = try await fixture.personAPI.get(targetId)
        #expect(afterRemove.totalPhotoCount == 1)
        #expect(afterRemove.photos.map(\.photoId) == [photoIds[1]])

        try await fixture.personAPI.delete(
            Confirmed(try PersonDeleteInput(personId: targetId), source: .test)
        )
        #expect(try await fixture.personAPI.list().isEmpty)

        // 旧命令面：删除不存在的 id 返回 {done:true}（Repo no-op），本批保持。
        try await fixture.personAPI.delete(
            Confirmed(try PersonDeleteInput(personId: "missing"), source: .test)
        )
    }
}

// MARK: - Template

@Suite("B7a Live TemplateAPI")
struct APITemplateTests {
    @Test("template CRUD：create/list/get/update/delete 与 TEMPLATE_NOT_FOUND")
    func crud() async throws {
        let fixture = try PersonTemplateFixture()
        let config = makeTemplateConfig()

        let created = try await fixture.templateAPI.create(
            TemplateCreateParams(name: "  T1  ", config: config)
        )
        #expect(created.name == "T1")
        #expect(created.description == "")
        #expect(created.config == config)

        let list = try await fixture.templateAPI.list()
        #expect(list.map(\.id) == [created.id])

        let fetched = try await fixture.templateAPI.get(created.id)
        #expect(fetched == created)

        let updatedConfig = makeTemplateConfig(threshold: 20, minGroupSize: 4)
        let updated = try await fixture.templateAPI.update(TemplateUpdateParams(
            templateId: created.id,
            name: "T2",
            description: "说明",
            config: updatedConfig
        ))
        #expect(updated.name == "T2")
        #expect(updated.description == "说明")
        #expect(updated.config == updatedConfig)

        // 空更新返回现值且不触碰 updated_at（TemplateService 语义）。
        let noOp = try await fixture.templateAPI.update(
            TemplateUpdateParams(templateId: created.id)
        )
        #expect(noOp == updated)

        try await fixture.templateAPI.delete(
            Confirmed(try TemplateReference(templateId: created.id), source: .test)
        )
        #expect(try await fixture.templateAPI.list().isEmpty)

        let missing = await gatherError {
            _ = try await fixture.templateAPI.get(created.id)
        }
        #expect(missing?.code == .TEMPLATE_NOT_FOUND)

        let blankGet = await gatherError {
            _ = try await fixture.templateAPI.get("   ")
        }
        #expect(blankGet?.code == .INVALID_PARAM)
        #expect(blankGet?.params["field"] == "templateId")

        let blankUpdate = await gatherError {
            _ = try await fixture.templateAPI.update(
                TemplateUpdateParams(templateId: "   ")
            )
        }
        #expect(blankUpdate?.code == .INVALID_PARAM)
        #expect(blankUpdate?.params["field"] == "templateId")

        let blankCreate = await gatherError {
            _ = try await fixture.templateAPI.create(
                TemplateCreateParams(name: "   ", config: config)
            )
        }
        #expect(blankCreate?.code == .INVALID_PARAM)
        #expect(blankCreate?.params["field"] == "name")

        let missingUpdate = await gatherError {
            _ = try await fixture.templateAPI.update(
                TemplateUpdateParams(templateId: "missing", name: "x")
            )
        }
        #expect(missingUpdate?.code == .TEMPLATE_NOT_FOUND)

        // 旧命令面：删除不存在的模板是幂等 no-op（DELETE 影响 0 行），本批保持。
        try await fixture.templateAPI.delete(
            Confirmed(try TemplateReference(templateId: "missing"), source: .test)
        )
    }

    @Test("template.apply：draft/photos_loaded 白名单、Settings 写穿与错误路径")
    func apply() async throws {
        let fixture = try PersonTemplateFixture()
        let config = makeTemplateConfig(
            threshold: 42,
            minGroupSize: 3,
            eps: 0.71,
            minSamples: 4,
            detectorConfidence: 0.88
        )
        let template = try await fixture.templateAPI.create(
            TemplateCreateParams(name: "Apply", description: "d", config: config)
        )
        let draftSession = try fixture.makeSession()
        let loadedSession = try fixture.makeSession(status: "photos_loaded")
        // sessions.status 的 CHECK 白名单：draft/photos_loaded/analyzing/review/completed；
        // review 不在模板 apply 的允许集合内。
        let reviewSession = try fixture.makeSession(status: "review")

        try await fixture.templateAPI.apply(
            Confirmed(
                try TemplateApplyInput(templateId: template.id, sessionId: draftSession),
                source: .test
            )
        )
        #expect(fixture.settingsService.getNumber("default_threshold", defaultValue: -1) == 42)
        #expect(fixture.settingsService.getNumber("default_min_group_size", defaultValue: -1) == 3)
        #expect(fixture.settingsService.getNumber("default_eps", defaultValue: -1) == 0.71)
        #expect(fixture.settingsService.getNumber("default_min_samples", defaultValue: -1) == 4)
        #expect(fixture.settingsService.getNumber("detect_confidence", defaultValue: -1) == 0.88)

        // 第二个允许状态：photos_loaded。
        try await fixture.templateAPI.apply(
            Confirmed(
                try TemplateApplyInput(templateId: template.id, sessionId: loadedSession),
                source: .test
            )
        )

        let invalidStatus = await gatherError {
            try await fixture.templateAPI.apply(
                Confirmed(
                    try TemplateApplyInput(templateId: template.id, sessionId: reviewSession),
                    source: .test
                )
            )
        }
        #expect(invalidStatus?.code == .INVALID_PARAM)
        #expect(invalidStatus?.params["field"] == "sessionId")

        let missingTemplate = await gatherError {
            try await fixture.templateAPI.apply(
                Confirmed(
                    try TemplateApplyInput(templateId: "missing", sessionId: draftSession),
                    source: .test
                )
            )
        }
        #expect(missingTemplate?.code == .TEMPLATE_NOT_FOUND)

        let missingSession = await gatherError {
            try await fixture.templateAPI.apply(
                Confirmed(
                    try TemplateApplyInput(templateId: template.id, sessionId: "missing"),
                    source: .test
                )
            )
        }
        #expect(missingSession?.code == .SESSION_NOT_FOUND)
    }
}
