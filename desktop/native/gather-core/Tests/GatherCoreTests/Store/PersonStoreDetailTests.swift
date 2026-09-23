// Tests/GatherCoreTests/Store/PersonStoreDetailTests.swift
// R1：PersonStore 明细测试（端口自 PersonRepoTests 的 update/merge/embedding/reconcile 用例）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/PersonStore detail (R1)")
struct PersonStoreDetailTests {
    private func makeStore() async throws -> (SQLitePersonStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "person-detail")
        for id in ["s1", "s2"] {
            try await database.run(
                """
                INSERT INTO sessions (id, name, created_at, updated_at)
                VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """,
                [.text(id)]
            )
        }
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
        createdAt: String
    ) async throws {
        try await database.run(
            """
            INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at)
            VALUES (?, ?, ?, '[0,0,1,1]', 0.9, ?)
            """,
            [.text(personId), .text(photoId), .text(sessionId), .text(createdAt)]
        )
    }

    @Test func updatePartialFieldsAndThumbnail() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let id = try await store.create(name: "Alice")

        try await store.update(
            id: id,
            fields: PersonUpdateFields(name: "Alice B", keywords: ["x"], notes: "note", matchThreshold: 0.8)
        )
        var row = try await store.get(id: id)
        #expect(row?.name == "Alice B")
        #expect(row?.notes == "note")
        #expect(row?.matchThreshold == 0.8)
        #expect(row?.keywords == "[\"x\"]")

        try await store.update(id: id, fields: PersonUpdateFields(notes: "only-notes"))
        row = try await store.get(id: id)
        #expect(row?.name == "Alice B")
        #expect(row?.matchThreshold == 0.8)
        #expect(row?.notes == "only-notes")

        let before = row
        try await store.update(id: id, fields: PersonUpdateFields())
        #expect(try await store.get(id: id) == before, "空字段集合 no-op")

        #expect(try await store.thumbnailBase64(personId: id) == "")
        try await store.updateThumbnail(id: id, base64: "data:image/jpeg;base64,xx")
        #expect(try await store.thumbnailBase64(personId: id) == "data:image/jpeg;base64,xx")
        #expect(try await store.thumbnailBase64(personId: "missing") == "")
    }

    @Test func deleteRemovesPerson() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let id = try await store.create(name: "Alice")

        try await store.deletePerson(id: id)
        #expect(try await store.get(id: id) == nil)
        #expect(try await store.list().isEmpty)
    }

    @Test func mergeMovesEmbeddingsAndPhotosAndUnionsKeywords() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")

        let source = try await store.create(name: "Src", keywords: ["a", "b"])
        let target = try await store.create(name: "Tgt", keywords: ["b", "c"])
        try await store.addPhoto(personId: source, photoId: "p1", sessionId: "s1", faceBbox: [0, 0, 1, 1], confidence: 0.9)
        try await store.saveEmbeddings([
            SaveEmbeddingInput(
                personId: source, embedding: [1, 2, 3, 4], photoId: "p1", sessionId: "s1",
                faceObservationId: 7, faceBbox: [0, 0, 1, 1], quality: 0.8
            )
        ])

        try await store.merge(sourceId: source, targetId: target)

        #expect(try await store.get(id: source) == nil)
        #expect(try await store.countPhotos(personId: target) == 1)
        #expect(try await store.embeddings(personId: target).count == 1)
        #expect(try await store.countEmbeddings(personId: source) == 0)
        #expect(try await store.get(id: target)?.keywords == "[\"a\",\"b\",\"c\"]", "关键词并集，源在前")
    }

    @Test func saveEmbeddingsRoundTripsFloat32AndReplaceByObservation() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let alice = try await store.create(name: "Alice")

        let floats: [Float] = [0.1, -0.5, 1.25, 3.5]
        try await store.saveEmbeddings([
            SaveEmbeddingInput(personId: alice, embedding: floats, photoId: "p1", sessionId: "s1", faceObservationId: 10, faceBbox: [0, 0, 1, 1], quality: 0.95),
            SaveEmbeddingInput(personId: alice, embedding: [7], photoId: "p2", sessionId: "s1", faceObservationId: nil, faceBbox: [0, 0, 1, 1], quality: 0.5),
        ])

        let rows = try await store.embeddings(personId: alice)
        #expect(rows.count == 2)
        #expect(rows[0].id < rows[1].id, "ORDER BY id 升序")
        #expect(rows[0].personId == alice)
        #expect(rows[0].embedding.count == 16, "Float32 BLOB = 4 字节 × 元素数")
        #expect(rows[1].embedding.count == 4)
        let roundTripped = rows[0].embedding.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(roundTripped == floats)
        #expect(rows[0].faceObservationId == 10)
        #expect(rows[1].faceObservationId == nil)
        #expect(rows[0].quality == 0.95)
        #expect(rows[0].faceBbox == "[0,0,1,1]")

        #expect(try await store.countEmbeddings(personId: alice) == 2)
        let all = try await store.allEmbeddings()
        #expect(all.count == 2)
        #expect(all.contains { $0.personId == alice && $0.faceObservationId == 10 && $0.embedding.count == 16 })

        // 相同 face_observation_id 再次保存 → INSERT OR REPLACE 覆盖。
        try await store.saveEmbeddings([
            SaveEmbeddingInput(personId: alice, embedding: [9, 9], photoId: "p1", sessionId: "s1", faceObservationId: 10, faceBbox: [0, 0, 1, 1], quality: 0.99),
        ])
        #expect(try await store.countEmbeddings(personId: alice) == 2)
        let replaced = try await store.embeddings(personId: alice).first { $0.faceObservationId == 10 }
        #expect(replaced?.embedding.count == 8)
        #expect(replaced?.quality == 0.99)

        try await store.deleteEmbeddingsByObservationIds([10])
        #expect(try await store.countEmbeddings(personId: alice) == 1)
        try await store.deleteEmbeddingsByObservationIds([])
        #expect(try await store.countEmbeddings(personId: alice) == 1)

        try await store.deleteEmbeddings(personId: alice)
        #expect(try await store.countEmbeddings(personId: alice) == 0)
    }

    @Test func getSessionCountCountsDistinctSessions() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try await insertPhoto(database, id: "p3", sessionId: "s2", filepath: "/c.jpg")
        let alice = try await store.create(name: "Alice")

        try await insertPersonPhoto(database, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")
        #expect(try await store.countPhotos(personId: alice) == 3)
        #expect(try await store.sessionCount(personId: alice) == 2)
        #expect(try await store.sessionCount(personId: "missing") == 0)
    }

    @Test func getPhotosWithDetailsJoinsSessionAndPhoto() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await database.run("UPDATE sessions SET name = 'First' WHERE id = 's1'")
        try await database.run("UPDATE sessions SET name = 'Second' WHERE id = 's2'")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/one.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/two.jpg")
        try await insertPhoto(database, id: "p3", sessionId: "s2", filepath: "/three.jpg")
        let alice = try await store.create(name: "Alice")

        try await insertPersonPhoto(database, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")

        let result = try await store.getPhotosWithDetails(personId: alice, sessionIds: nil, limit: nil, offset: nil)
        #expect(result.total == 3)
        #expect(result.photos.map(\.photo.photoId) == ["p3", "p2", "p1"])
        #expect(result.photos[0].sessionName == "Second")
        #expect(result.photos[0].filename == "three.jpg")
        #expect(result.photos[0].filepath == "/three.jpg")
        #expect(result.photos[2].sessionName == "First")

        let filtered = try await store.getPhotosWithDetails(personId: alice, sessionIds: ["s1"], limit: 1, offset: 1)
        #expect(filtered.total == 2)
        #expect(filtered.photos.map(\.photo.photoId) == ["p1"])
        #expect(filtered.photos[0].filename == "one.jpg")
    }

    @Test func reconcileSessionSyncsLinksFromRoleBindings() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")

        try await database.run("INSERT INTO face_clusters (id, session_id, label) VALUES (1, 's1', 'c1')")
        try await database.run("INSERT INTO role_bindings (cluster_id, session_id, role_name) VALUES (1, 's1', 'Alice')")
        try await database.run(
            """
            INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence)
            VALUES (1, 's1', 'p1', '[0,0,1,1]', 0.9), (1, 's1', 'p2', '[0,0,1,1]', 0.8)
            """
        )

        let bob = try await store.create(name: "Bob")
        let charlie = try await store.create(name: "Charlie")
        try await insertPersonPhoto(database, personId: bob, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await insertPersonPhoto(database, personId: charlie, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('other', 'O', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await insertPhoto(database, id: "p4", sessionId: "other", filepath: "/d.jpg")
        try await insertPersonPhoto(database, personId: charlie, photoId: "p4", sessionId: "other", createdAt: "2026-01-01T00:00:00.000Z")

        try await store.reconcileSession(sessionId: "s1")

        let alice = try await store.upsertByName(name: "Alice")
        let aliceLinks = try await store.getPhotos(personId: alice, sessionIds: ["s1"], limit: nil, offset: nil)
        #expect(aliceLinks.map(\.photoId).sorted() == ["p1", "p2"])
        #expect(aliceLinks.first { $0.photoId == "p1" }?.confidence == 0.9)
        #expect(aliceLinks.first { $0.photoId == "p1" }?.faceBbox == "[0,0,1,1]")

        #expect(try await store.getPersonPhoto(personId: bob, photoId: "p1") == nil, "角色中已无 Bob → s1 链接清除")
        #expect(try await store.getPersonPhoto(personId: charlie, photoId: "p1") == nil)
        #expect(try await store.getPersonPhoto(personId: charlie, photoId: "p4") != nil, "其他会话链接不受影响")

        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('empty', 'E', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await store.reconcileSession(sessionId: "empty")
    }
}
