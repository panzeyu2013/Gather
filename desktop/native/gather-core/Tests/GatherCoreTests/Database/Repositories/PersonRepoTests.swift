// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/PersonRepoTests.swift
// PersonRepo 测试：CRUD、listWithCounts 聚合、upsertByName、merge、
// 照片桥接（addPhotos/reconcileSession）、嵌入存取（Float32 BLOB 往返）。

import Foundation
import Testing
@testable import GatherCore

private func makeDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

private func insertSession(_ db: DBConnection, id: String) throws {
    _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id)])
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String, filepath: String) throws {
    _ = try db.prepare("INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id), .text(sessionId), .text(filepath), .text((filepath as NSString).lastPathComponent)])
}

private func insertPersonPhoto(_ db: DBConnection, personId: String, photoId: String, sessionId: String, createdAt: String, faceBbox: String = "[0,0,1,1]", confidence: Double = 0.9) throws {
    _ = try db.prepare(
        "INSERT INTO person_photos (person_id, photo_id, session_id, face_bbox, confidence, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).run([.text(personId), .text(photoId), .text(sessionId), .text(faceBbox), .real(confidence), .text(createdAt)])
}

@Suite(.serialized)
struct PersonRepoTests {
    @Test func createAndGetApplyDefaults() throws {
        let db = try makeDB()
        let repo = PersonRepo(connection: db)

        let id = try repo.create(name: "Alice")
        #expect(!id.isEmpty)

        let row = try repo.get(id: id)
        #expect(row?.name == "Alice")
        #expect(row?.keywords == "[]")
        #expect(row?.thumbnailBase64 == "")
        #expect(row?.thumbnailPath == nil)
        #expect(row?.notes == "")
        #expect(row?.matchThreshold == 0.65)
        #expect(!row!.createdAt.isEmpty)
        #expect(!row!.updatedAt.isEmpty)

        #expect(try repo.get(id: "missing") == nil)
        #expect(try repo.list().map(\.id) == [id])
    }

    @Test func createStoresKeywordsAsJSON() throws {
        let db = try makeDB()
        let repo = PersonRepo(connection: db)

        let id = try repo.create(name: "Bob", keywords: ["family", "vacation"])
        #expect(try repo.get(id: id)?.keywords == "[\"family\",\"vacation\"]")
    }

    @Test func listWithCountsAggregatesPhotosAndSessions() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertSession(db, id: "s2")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/old.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/new.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s2", filepath: "/other.jpg")
        let repo = PersonRepo(connection: db)

        let alice = try repo.create(name: "Alice")
        try insertPersonPhoto(db, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")
        let bob = try repo.create(name: "Bob")

        let rows = try repo.listWithCounts()
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

    @Test func getReturnsThumbnailPathOfMostRecentPhoto() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = PersonRepo(connection: db)
        let alice = try repo.create(name: "Alice")

        try insertPersonPhoto(db, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        #expect(try repo.get(id: alice)?.thumbnailPath == "/a.jpg")
        try insertPersonPhoto(db, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        #expect(try repo.get(id: alice)?.thumbnailPath == "/b.jpg")
    }

    @Test func upsertByNameCreatesThenReuses() throws {
        let db = try makeDB()
        let repo = PersonRepo(connection: db)

        let first = try repo.upsertByName(name: "Alice", keywords: ["a"])
        let second = try repo.upsertByName(name: "Alice", keywords: ["a"])
        #expect(second == first)
        #expect(try repo.list().count == 1)

        // 新关键词合并进已有 JSON，重复关键词不重复。
        let third = try repo.upsertByName(name: "Alice", keywords: ["b", "a"])
        #expect(third == first)
        #expect(try repo.get(id: first)?.keywords == "[\"a\",\"b\"]")

        // 空关键词不触发更新。
        try repo.upsertByName(name: "Alice", keywords: [])
        #expect(try repo.get(id: first)?.keywords == "[\"a\",\"b\"]")

        // 另一名字创建新人物。
        let bob = try repo.upsertByName(name: "Bob")
        #expect(bob != first)
    }

    @Test func updatePartialFieldsAndThumbnail() throws {
        let db = try makeDB()
        let repo = PersonRepo(connection: db)
        let id = try repo.create(name: "Alice")

        try repo.update(id: id, fields: PersonUpdateFields(name: "Alice B", keywords: ["x"], notes: "note", matchThreshold: 0.8))
        var row = try repo.get(id: id)
        #expect(row?.name == "Alice B")
        #expect(row?.notes == "note")
        #expect(row?.matchThreshold == 0.8)
        #expect(row?.keywords == "[\"x\"]")

        // 部分字段更新不影响其他字段。
        try repo.update(id: id, fields: PersonUpdateFields(notes: "only-notes"))
        row = try repo.get(id: id)
        #expect(row?.name == "Alice B")
        #expect(row?.matchThreshold == 0.8)
        #expect(row?.notes == "only-notes")

        // 空字段集合是 no-op。
        let before = row
        try repo.update(id: id, fields: PersonUpdateFields())
        #expect(try repo.get(id: id) == before)
    }

    @Test func deleteRemovesPerson() throws {
        let db = try makeDB()
        let repo = PersonRepo(connection: db)
        let id = try repo.create(name: "Alice")

        try repo.delete(id: id)
        #expect(try repo.get(id: id) == nil)
        #expect(try repo.list().isEmpty)
    }

    @Test func mergeMovesEmbeddingsAndPhotosAndUnionsKeywords() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = PersonRepo(connection: db)

        let source = try repo.create(name: "Src", keywords: ["a", "b"])
        let target = try repo.create(name: "Tgt", keywords: ["b", "c"])
        try repo.addPhotos(personId: source, sessionId: "s1", photos: [
            PersonPhotoInput(photoId: "p1", faceBbox: [0, 0, 1, 1], confidence: 0.9),
        ])
        try repo.saveEmbeddings(embeddings: [
            SaveEmbeddingInput(personId: source, embedding: [1, 2, 3, 4], photoId: "p1", sessionId: "s1", faceObservationId: 7, faceBbox: [0, 0, 1, 1], quality: 0.8),
        ])

        try repo.merge(sourceId: source, targetId: target)

        // 来源删除，目标获得转移后的数据。
        #expect(try repo.get(id: source) == nil)
        #expect(try repo.countPhotos(personId: target) == 1)
        #expect(try repo.getAllEmbeddings().filter { $0.personId == target }.count == 1)
        #expect(try repo.getAllEmbeddings().filter { $0.personId == source }.isEmpty)

        // 关键词并集（去重，源在前）。
        let keywords = try repo.get(id: target)?.keywords
        #expect(keywords == "[\"a\",\"b\",\"c\"]")
    }

    @Test func addPhotosBridgeAndDedupe() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = PersonRepo(connection: db)
        let alice = try repo.create(name: "Alice")

        // 单条。
        try repo.addPhotos(personId: alice, sessionId: "s1", photos: [
            PersonPhotoInput(photoId: "p1", faceBbox: [0, 0, 1, 1], confidence: 0.9),
        ])
        let link = try repo.getPhotosWithDetails(personId: alice).photos
            .first { $0.photo.photoId == "p1" }?.photo
        #expect(link != nil)
        let faceBbox = link?.faceBbox
        #expect(faceBbox == "[0,0,1,1]")
        #expect(link?.confidence == 0.9)
        #expect(link?.sessionId == "s1")
        #expect(try repo.countPhotos(personId: alice) == 1)

        // 批量 + 重复（INSERT OR IGNORE）。
        try repo.addPhotos(personId: alice, sessionId: "s1", photos: [
            PersonPhotoInput(photoId: "p1", faceBbox: [0, 0, 1, 1], confidence: 0.5),
            PersonPhotoInput(photoId: "p2", faceBbox: [1, 1, 2, 2], confidence: 0.7),
        ])
        #expect(try repo.countPhotos(personId: alice) == 2)
        // 重复绑定未覆盖原行（confidence 保持首次 0.9）。
        let p1 = try repo.getPhotosWithDetails(personId: alice).photos
            .first { $0.photo.photoId == "p1" }?.photo
        #expect(p1?.confidence == 0.9)

        // 空批量 no-op。
        try repo.addPhotos(personId: alice, sessionId: "s1", photos: [])
        #expect(try repo.countPhotos(personId: alice) == 2)
    }

    @Test func removePhotoCleansBridgeAndEmbeddings() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        let repo = PersonRepo(connection: db)
        let alice = try repo.create(name: "Alice")

        try repo.addPhotos(personId: alice, sessionId: "s1", photos: [
            PersonPhotoInput(photoId: "p1", faceBbox: [0, 0, 1, 1], confidence: 0.9),
        ])
        try repo.saveEmbeddings(embeddings: [
            SaveEmbeddingInput(personId: alice, embedding: [1, 2], photoId: "p1", sessionId: "s1", faceObservationId: 1, faceBbox: [0, 0, 1, 1], quality: 0.9),
        ])
        #expect(try repo.getAllEmbeddings().filter { $0.personId == alice }.count == 1)

        try repo.removePhoto(personId: alice, photoId: "p1")
        #expect(try repo.countPhotos(personId: alice) == 0)
        #expect(try repo.getAllEmbeddings().filter { $0.personId == alice }.isEmpty)
    }

    @Test func saveEmbeddingsRoundTripsFloat32AndReplaceByObservation() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = PersonRepo(connection: db)
        let alice = try repo.create(name: "Alice")

        let floats: [Float] = [0.1, -0.5, 1.25, 3.5]
        try repo.saveEmbeddings(embeddings: [
            SaveEmbeddingInput(personId: alice, embedding: floats, photoId: "p1", sessionId: "s1", faceObservationId: 10, faceBbox: [0, 0, 1, 1], quality: 0.95),
            SaveEmbeddingInput(personId: alice, embedding: [7], photoId: "p2", sessionId: "s1", faceObservationId: nil, faceBbox: [0, 0, 1, 1], quality: 0.5),
        ])

        let rows = try repo.getAllEmbeddings().filter { $0.personId == alice }
        #expect(rows.count == 2)
        // Float32 BLOB 长度 = 4 字节 × 元素数。
        let row10 = try #require(rows.first { $0.faceObservationId == 10 })
        let rowNil = try #require(rows.first { $0.faceObservationId == nil })
        #expect(row10.embedding.count == 16)
        #expect(rowNil.embedding.count == 4)
        let roundTripped = row10.embedding.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(roundTripped == floats)

        // 全部向量合并视图（getAllEmbeddings）覆盖同一行数据。
        let all = try repo.getAllEmbeddings()
        #expect(all.count == 2)
        let hasEmbedding10 = all.contains { $0.personId == alice && $0.faceObservationId == 10 && $0.embedding.count == 16 }
        #expect(hasEmbedding10)

        // quality/faceBbox 仍落库（getAllEmbeddings 投影不含这两列，走原始行校验）。
        let cached = try db.prepare(
            "SELECT quality, face_bbox FROM person_embeddings WHERE person_id = ? AND face_observation_id = 10"
        ).get([.text(alice)])
        guard case .real(let quality)? = cached?[0], case .text(let faceBbox)? = cached?[1] else {
            Issue.record("person_embeddings 行缺失或类型不符")
            return
        }
        #expect(quality == 0.95)
        #expect(faceBbox == "[0,0,1,1]")

        // 相同 face_observation_id 再次保存 → INSERT OR REPLACE 覆盖（唯一索引）。
        try repo.saveEmbeddings(embeddings: [
            SaveEmbeddingInput(personId: alice, embedding: [9, 9], photoId: "p1", sessionId: "s1", faceObservationId: 10, faceBbox: [0, 0, 1, 1], quality: 0.99),
        ])
        #expect(try repo.getAllEmbeddings().filter { $0.personId == alice }.count == 2)
        let replaced = try #require(
            try repo.getAllEmbeddings().first { $0.personId == alice && $0.faceObservationId == 10 }
        )
        #expect(replaced.embedding.count == 8)
    }

    @Test func getSessionCountCountsDistinctSessions() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertSession(db, id: "s2")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s2", filepath: "/c.jpg")
        let repo = PersonRepo(connection: db)
        let alice = try repo.create(name: "Alice")

        try insertPersonPhoto(db, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")
        #expect(try repo.countPhotos(personId: alice) == 3)
        #expect(try repo.getSessionCount(personId: alice) == 2)
        #expect(try repo.getSessionCount(personId: "missing") == 0)
    }

    @Test func getPhotosWithDetailsJoinsSessionAndPhoto() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertSession(db, id: "s2")
        _ = try db.prepare("UPDATE sessions SET name = 'First' WHERE id = 's1'").run()
        _ = try db.prepare("UPDATE sessions SET name = 'Second' WHERE id = 's2'").run()
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/one.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/two.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s2", filepath: "/three.jpg")
        let repo = PersonRepo(connection: db)
        let alice = try repo.create(name: "Alice")

        try insertPersonPhoto(db, personId: alice, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: alice, photoId: "p2", sessionId: "s1", createdAt: "2026-02-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: alice, photoId: "p3", sessionId: "s2", createdAt: "2026-03-01T00:00:00.000Z")

        let result = try repo.getPhotosWithDetails(personId: alice)
        #expect(result.total == 3)
        #expect(result.photos.map(\.photo.photoId) == ["p3", "p2", "p1"])
        #expect(result.photos[0].sessionName == "Second")
        #expect(result.photos[0].filename == "three.jpg")
        #expect(result.photos[0].filepath == "/three.jpg")
        #expect(result.photos[2].sessionName == "First")

        // 会话过滤 + 分页。
        let filtered = try repo.getPhotosWithDetails(personId: alice, sessionIds: ["s1"], limit: 1, offset: 1)
        #expect(filtered.total == 2)
        #expect(filtered.photos.map(\.photo.photoId) == ["p1"])
        #expect(filtered.photos[0].filename == "one.jpg")
    }

    @Test func reconcileSessionSyncsLinksFromRoleBindings() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s1", filepath: "/c.jpg")
        let repo = PersonRepo(connection: db)

        // 角色绑定：cluster c1 绑定角色 Alice，成员 p1/p2。
        _ = try db.prepare("INSERT INTO face_clusters (id, session_id, label) VALUES (1, 's1', 'c1')").run()
        _ = try db.prepare("INSERT INTO role_bindings (cluster_id, session_id, role_name) VALUES (1, 's1', 'Alice')").run()
        _ = try db.prepare(
            "INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence) VALUES (1, 's1', 'p1', '[0,0,1,1]', 0.9), (1, 's1', 'p2', '[0,0,1,1]', 0.8)"
        ).run()

        // 已有其他会话遗留链接：Bob 链接 p1（应被清除）、Charlie 在另一会话（不受影响）。
        let bob = try repo.create(name: "Bob")
        let charlie = try repo.create(name: "Charlie")
        try insertPersonPhoto(db, personId: bob, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try insertPersonPhoto(db, personId: charlie, photoId: "p1", sessionId: "s1", createdAt: "2026-01-01T00:00:00.000Z")
        try insertSession(db, id: "other")
        try insertPhoto(db, id: "p4", sessionId: "other", filepath: "/d.jpg")
        try insertPersonPhoto(db, personId: charlie, photoId: "p4", sessionId: "other", createdAt: "2026-01-01T00:00:00.000Z")

        try repo.reconcileSession(sessionId: "s1")

        // Alice 人物被创建，p1/p2 链接按绑定数据写入。
        let alice = try repo.upsertByName(name: "Alice")
        let aliceLinks = try repo.getPhotosWithDetails(personId: alice, sessionIds: ["s1"]).photos.map(\.photo)
        #expect(aliceLinks.map(\.photoId).sorted() == ["p1", "p2"])
        #expect(aliceLinks.first { $0.photoId == "p1" }?.confidence == 0.9)
        #expect(aliceLinks.first { $0.photoId == "p1" }?.faceBbox == "[0,0,1,1]")

        // Bob 的 s1 链接被清除（角色中已无 Bob）。
        #expect(try repo.getPhotosWithDetails(personId: bob).photos.allSatisfy { $0.photo.photoId != "p1" })
        // Charlie 的 s1 链接也被清除，但其 other 会话链接不受影响。
        #expect(try repo.getPhotosWithDetails(personId: charlie).photos.allSatisfy { $0.photo.photoId != "p1" })
        #expect(try repo.getPhotosWithDetails(personId: charlie).photos.contains { $0.photo.photoId == "p4" })

        // 无任何绑定/链接时 no-op。
        try insertSession(db, id: "empty")
        try repo.reconcileSession(sessionId: "empty")
    }
}
