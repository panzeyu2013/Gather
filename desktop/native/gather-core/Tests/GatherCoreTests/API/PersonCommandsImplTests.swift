// Tests/GatherCoreTests/API/PersonCommandsImplTests.swift
// R5：person 域命令实现直测（批次 B4）。
// 覆盖旧分支语义：list/get/create/update 的读写与 PERSON_NOT_FOUND、
// 三条破坏性命令的 confirmed 门控、merge 的照片与关键词迁移、
// remove_photo 的删除效果、search_photos 的过滤与分页、错误串逐字一致。
import Foundation
import Testing
@testable import GatherCore

@Suite("API/PersonCommandsImpl (R5)")
struct PersonCommandsImplTests {
    /// 目录直连 harness：PersonsAPI 与命令实现共享同一临时库。
    private func makeHarness() async throws -> (
        impl: PersonCommandsImpl, store: SQLitePersonStore, db: SQLiteDatabase, path: String
    ) {
        let path = storeTempPath("person-commands")
        let db = try await makeMigratedStore(path: path)
        let store = SQLitePersonStore(database: db)
        return (PersonCommandsImpl(persons: PersonsAPI(store: store)), store, db, path)
    }

    /// 人物照片 fixture：会话行幂等插入 + 照片行 + person_photos 行；
    /// get / search_photos 的明细查询走三表 JOIN。
    private func attachPhoto(
        _ store: SQLitePersonStore,
        _ db: SQLiteDatabase,
        personId: String,
        photoId: String,
        sessionId: String
    ) async throws {
        _ = try await db.run(
            """
            INSERT OR IGNORE INTO sessions
              (id, name, status, analysis_status, writeback_status, import_source, created_at, updated_at)
            VALUES (?, '', 'draft', 'idle', 'idle', 'unknown',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(sessionId)]
        )
        try await insertPhoto(db, id: photoId, sessionId: sessionId)
        try await store.addPhoto(
            personId: personId, photoId: photoId, sessionId: sessionId,
            faceBbox: [0, 0, 1, 1], confidence: 0.9)
    }

    @Test("create/list/get/update roundtrip keeps trimmed fields and counts")
    func crudRoundtrip() async throws {
        let (impl, store, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        let id = try await impl.create(PersonCreateParams(name: "  Alice  ", keywords: ["a"]))
        try await attachPhoto(store, db, personId: id, photoId: "p1", sessionId: "s1")

        let list = try await impl.list(PersonListParams())
        #expect(list.map(\.id) == [id])
        #expect(list[0].name == "Alice")
        #expect(list[0].keywords == ["a"])
        #expect(list[0].photoCount == 1)
        #expect(list[0].sessionCount == 1)

        let detail = try await impl.get(PersonGetParams(personId: id))
        #expect(detail.name == "Alice")
        #expect(detail.photos.map(\.photoId) == ["p1"])
        #expect(detail.photos[0].sessionId == "s1")
        #expect(detail.photoCount == 1)
        #expect(detail.totalPhotoCount == 1)

        try await impl.update(PersonUpdateParams(
            personId: id, name: "  Alice B  ", keywords: ["a", "b"], notes: "note",
            matchThreshold: 0.8))
        let updated = try await impl.get(PersonGetParams(personId: id))
        #expect(updated.name == "Alice B")
        #expect(updated.keywords == ["a", "b"])
        #expect(updated.notes == "note")
        #expect(updated.matchThreshold == 0.8)

        // 空字段集合 no-op：仅传 personId 不改变既有字段。
        try await impl.update(PersonUpdateParams(personId: id))
        #expect(try await impl.get(PersonGetParams(personId: id)).name == "Alice B")
    }

    @Test("get throws PERSON_NOT_FOUND for a missing person")
    func getMissingThrowsNotFound() async throws {
        let (impl, _, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        await #expect(throws: PersonCommandsError.notFound) {
            try await impl.get(PersonGetParams(personId: "missing"))
        }
    }

    @Test("create rejects a blank or overlong name with INVALID_PARAM:name")
    func createValidatesName() async throws {
        let (impl, _, _, path) = try await makeHarness()
        defer { removeStoreFiles(path) }

        await #expect(throws: PersonCommandsError.invalidParam("name")) {
            try await impl.create(PersonCreateParams(name: "   "))
        }
        await #expect(throws: PersonCommandsError.invalidParam("name")) {
            try await impl.create(
                PersonCreateParams(name: String(repeating: "n", count: 4097)))
        }
    }

    @Test("destructive commands reject unconfirmed params without side effects")
    func destructiveGates() async throws {
        let (impl, store, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let id = try await impl.create(PersonCreateParams(name: "Alice"))
        try await attachPhoto(store, db, personId: id, photoId: "p1", sessionId: "s1")

        await #expect(throws: PersonCommandsError.deleteConfirmRequired) {
            try await impl.delete(PersonDeleteParams(personId: id, confirmed: false))
        }
        await #expect(throws: PersonCommandsError.mergeConfirmRequired) {
            try await impl.merge(
                PersonMergeParams(sourceId: id, targetId: "other", confirmed: false))
        }
        await #expect(throws: PersonCommandsError.removePhotoConfirmRequired) {
            try await impl.removePhoto(
                PersonRemovePhotoParams(personId: id, photoId: "p1", confirmed: false))
        }

        let detail = try await impl.get(PersonGetParams(personId: id))
        #expect(detail.photos.map(\.photoId) == ["p1"])
        #expect(detail.name == "Alice")
    }

    @Test("merge moves photos and unions keywords into the target")
    func mergeMovesPhotos() async throws {
        let (impl, store, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let source = try await impl.create(
            PersonCreateParams(name: "Source", keywords: ["s"]))
        let target = try await impl.create(
            PersonCreateParams(name: "Target", keywords: ["t"]))
        try await attachPhoto(store, db, personId: source, photoId: "p1", sessionId: "s1")

        try await impl.merge(
            PersonMergeParams(sourceId: source, targetId: target, confirmed: true))

        let merged = try await impl.get(PersonGetParams(personId: target))
        #expect(merged.keywords == ["s", "t"])
        #expect(merged.photos.map(\.photoId) == ["p1"])
        #expect(merged.photoCount == 1)
        await #expect(throws: PersonCommandsError.notFound) {
            try await impl.get(PersonGetParams(personId: source))
        }
    }

    @Test("remove_photo unlinks one photo and delete removes the person")
    func removePhotoAndDelete() async throws {
        let (impl, store, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let id = try await impl.create(PersonCreateParams(name: "Alice"))
        try await attachPhoto(store, db, personId: id, photoId: "p1", sessionId: "s1")
        try await attachPhoto(store, db, personId: id, photoId: "p2", sessionId: "s2")

        try await impl.removePhoto(
            PersonRemovePhotoParams(personId: id, photoId: "p1", confirmed: true))
        let afterRemove = try await impl.get(PersonGetParams(personId: id))
        #expect(afterRemove.photos.map(\.photoId) == ["p2"])
        #expect(afterRemove.totalPhotoCount == 1)

        try await impl.delete(PersonDeleteParams(personId: id, confirmed: true))
        await #expect(throws: PersonCommandsError.notFound) {
            try await impl.get(PersonGetParams(personId: id))
        }
    }

    @Test("search_photos reports total and honors sessionIds and paging")
    func searchPhotosFiltersAndPaginates() async throws {
        let (impl, store, db, path) = try await makeHarness()
        defer { removeStoreFiles(path) }
        let id = try await impl.create(PersonCreateParams(name: "Alice"))
        try await attachPhoto(store, db, personId: id, photoId: "p1", sessionId: "s1")
        try await attachPhoto(store, db, personId: id, photoId: "p2", sessionId: "s1")
        try await attachPhoto(store, db, personId: id, photoId: "p3", sessionId: "s2")

        let all = try await impl.searchPhotos(PersonSearchPhotosParams(personId: id))
        #expect(all.total == 3)
        #expect(all.photos.count == 3)

        let sessionOne = try await impl.searchPhotos(
            PersonSearchPhotosParams(personId: id, sessionIds: ["s1"]))
        #expect(sessionOne.total == 2)
        #expect(Set(sessionOne.photos.map(\.sessionId)) == Set(["s1"]))

        let page = try await impl.searchPhotos(
            PersonSearchPhotosParams(personId: id, limit: 1, offset: 1))
        #expect(page.total == 3)
        #expect(page.photos.count == 1)

        // 空 sessionIds 与缺省同义（旧行为不过滤）。
        let emptyFilter = try await impl.searchPhotos(
            PersonSearchPhotosParams(personId: id, sessionIds: []))
        #expect(emptyFilter.total == 3)
    }

    @Test("error descriptions and gather codes match the legacy strings")
    func errorStrings() {
        #expect(PersonCommandsError.notFound.description == "PERSON_NOT_FOUND")
        #expect(PersonCommandsError.invalidParam("name").description == "INVALID_PARAM:name")
        #expect(PersonCommandsError.deleteConfirmRequired.description == "PERSON_DELETE_CONFIRM_REQUIRED")
        #expect(PersonCommandsError.mergeConfirmRequired.description == "PERSON_MERGE_CONFIRM_REQUIRED")
        #expect(PersonCommandsError.removePhotoConfirmRequired.description == "PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED")
        #expect(PersonCommandsError.notFound.gatherCode == .PERSON_NOT_FOUND)
        #expect(PersonCommandsError.deleteConfirmRequired.gatherCode == .PERSON_DELETE_CONFIRM_REQUIRED)
        #expect(PersonCommandsError.mergeConfirmRequired.gatherCode == .PERSON_MERGE_CONFIRM_REQUIRED)
        #expect(PersonCommandsError.removePhotoConfirmRequired.gatherCode == .PERSON_REMOVE_PHOTO_CONFIRM_REQUIRED)
        #expect(PersonCommandsError.invalidParam("name").gatherCode == nil)
    }
}
