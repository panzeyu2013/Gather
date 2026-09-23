// Tests/GatherCoreTests/Store/PersonStoreTests.swift
// R1：PersonStore 核心测试（端口自 PersonRepoTests 的 CRUD/计数/照片桥接用例）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/PersonStore (R1)")
struct PersonStoreTests {
    private func makeStore() async throws -> (SQLitePersonStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "person")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s2', 'S2', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        return (SQLitePersonStore(database: database), database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, sessionId: String, filepath: String) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text(filepath), .text((filepath as NSString).lastPathComponent)]
        )
    }

    private func insertPersonPhoto(
        _ database: SQLiteDatabase,
        personId: String,
        photoId: String,
        sessionId: String,
        createdAt: String,
        faceBbox: String = "[0,0,1,1]",
        confidence: Double = 0.9
    ) async throws {
        try await database.run(
            """
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(personId), .text(photoId), .text(sessionId), .text(faceBbox), .real(confidence), .text(createdAt)]
        )
    }

    @Test func createAndGetApplyDefaults() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let id = try await store.create(name: "Alice")
        #expect(!id.isEmpty)

        let row = try await store.get(id: id)
        #expect(row?.name == "Alice")
        #expect(row?.keywords == "[]")
        #expect(row?.thumbnailBase64 == "")
        #expect(row?.thumbnailPath == nil)
        #expect(row?.notes == "")
        #expect(row?.matchThreshold == 0.65)
        #expect(!(row?.createdAt.isEmpty ?? true))
        #expect(!(row?.updatedAt.isEmpty ?? true))

        #expect(try await store.get(id: "missing") == nil)
        #expect(try await store.list().map(\.id) == [id])
    }

    @Test func createStoresKeywordsAsJSON() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let id = try await store.create(name: "Bob", keywords: ["family", "vacation"])
        #expect(try await store.get(id: id)?.keywords == "[\"family\",\"vacation\"]")
        #expect(try await store.get(id: id)?.keywordList == ["family", "vacation"])
    }

    @Test func listWithCountsAggregatesPhotosAndSessions() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/old.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/new.jpg")
        try await insertPhoto(database, id: "p3", sessionId: "s2", filepath: "/other.jpg")

        let alice = try await store.create(name: "Alice")
        try await insertPersonPhoto(database, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")
        let bob = try await store.create(name: "Bob")

        let rows = try await store.listWithCounts()
        #expect(rows.count == 2)
        let aliceRow = rows.first { $0.person.id == alice }
        let bobRow = rows.first { $0.person.id == bob }
        #expect(aliceRow?.photoCount == 3)
        #expect(aliceRow?.sessionCount == 2)
        #expect(aliceRow?.person.thumbnailPath == "/other.jpg", "thumbnail_path 取 created_at 最新的照片")
        #expect(bobRow?.photoCount == 0)
        #expect(bobRow?.sessionCount == 0)
        #expect(bobRow?.person.thumbnailPath == nil)
    }

    @Test func getReturnsThumbnailPathOfMostRecentPhoto() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let alice = try await store.create(name: "Alice")

        try await insertPersonPhoto(database, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        #expect(try await store.get(id: alice)?.thumbnailPath == "/a.jpg")
        try await insertPersonPhoto(database, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        #expect(try await store.get(id: alice)?.thumbnailPath == "/b.jpg")
    }

    @Test func upsertByNameCreatesThenReuses() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let first = try await store.upsertByName(name: "Alice", keywords: ["a"])
        let second = try await store.upsertByName(name: "Alice", keywords: ["a"])
        #expect(second == first)
        #expect(try await store.list().count == 1)

        let third = try await store.upsertByName(name: "Alice", keywords: ["b", "a"])
        #expect(third == first)
        #expect(try await store.get(id: first)?.keywords == "[\"a\",\"b\"]", "新关键词合并、重复不重复")

        try await store.upsertByName(name: "Alice", keywords: [])
        #expect(try await store.get(id: first)?.keywords == "[\"a\",\"b\"]")

        let bob = try await store.upsertByName(name: "Bob")
        #expect(bob != first)
    }

    @Test func addPhotoAndAddPhotosBridgeAndDedupe() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let alice = try await store.create(name: "Alice")

        try await store.addPhoto(personId: alice, photoId: "p1", sessionId: "s1", faceBbox: [0, 0, 1, 1], confidence: 0.9)
        let link = try await store.getPersonPhoto(personId: alice, photoId: "p1")
        #expect(link != nil)
        #expect(link?.faceBbox == "[0,0,1,1]")
        #expect(link?.confidence == 0.9)
        #expect(link?.sessionId == "s1")
        #expect(try await store.getPersonPhoto(personId: alice, photoId: "p2") == nil)

        try await store.addPhotos(personId: alice, sessionId: "s1", photos: [
            PersonPhotoInput(photoId: "p1", faceBbox: [0, 0, 1, 1], confidence: 0.5),
            PersonPhotoInput(photoId: "p2", faceBbox: [1, 1, 2, 2], confidence: 0.7),
        ])
        #expect(try await store.countPhotos(personId: alice) == 2)
        #expect(try await store.getPersonPhoto(personId: alice, photoId: "p1")?.confidence == 0.9, "重复绑定不覆盖原行")

        try await store.addPhotos(personId: alice, sessionId: "s1", photos: [])
        #expect(try await store.countPhotos(personId: alice) == 2)
    }

    @Test func getPhotosFiltersBySessionsAndPagination() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try await insertPhoto(database, id: "p3", sessionId: "s2", filepath: "/c.jpg")
        let alice = try await store.create(name: "Alice")
        try await insertPersonPhoto(database, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")

        #expect(try await store.getPhotos(personId: alice).map(\.photoId) == ["p3", "p2", "p1"], "created_at DESC")
        #expect(try await store.getPhotos(personId: alice, sessionIds: ["s1"], limit: nil, offset: nil)
            .map(\.photoId) == ["p2", "p1"])
        #expect(try await store.getPhotos(personId: alice, sessionIds: ["s1"], limit: 1, offset: 1)
            .map(\.photoId) == ["p1"])
        #expect(try await store.getPhotos(personId: alice, sessionIds: ["other"], limit: nil, offset: nil).isEmpty)
    }

    @Test func removePhotoCleansBridgeAndCounts() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s2", filepath: "/b.jpg")
        let alice = try await store.create(name: "Alice")
        try await insertPersonPhoto(database, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p2", sessionId: "s2", createdAt: "2026-02-01T00:00:00.000Z")

        #expect(try await store.sessionCount(personId: alice) == 2)
        try await store.removePhoto(personId: alice, photoId: "p1")
        #expect(try await store.countPhotos(personId: alice) == 1)
        #expect(try await store.sessionCount(personId: alice) == 1)
        #expect(try await store.getPersonPhoto(personId: alice, photoId: "p1") == nil)
        #expect(try await store.thumbnailBase64(personId: alice) == "", "无自定义缩略图时为空串")
    }
}
