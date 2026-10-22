// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/MetadataCacheRepoTests.swift
// TS 源: desktop/src/main/db/repositories/metadata-cache.repo.ts

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

struct MetadataCacheRepoTests {
    private func makeRepo() throws -> (DBConnection, MetadataCacheRepo) {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1")
        try insertPhoto(db, id: "p2", sessionId: "s1")
        return (db, MetadataCacheRepo(connection: db))
    }

    private func input() -> MetadataCacheInput {
        MetadataCacheInput(
            sessionId: "s1",
            dateTaken: "2026-01-01T10:00:00.000Z",
            cameraMake: "Canon",
            cameraModel: "EOS R5",
            focalLength: 50.0,
            iso: 100,
            rating: 4,
            gpsLatitude: 31.23,
            width: 4000,
            keywords: ["nature", "travel"]
        )
    }

    @Test func upsertAndGet() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(try repo.get("p1") == nil)

        try repo.upsert(photoId: "p1", sessionId: "s1", data: input())
        let row = try repo.get("p1")
        #expect(row != nil)
        #expect(row?.photoId == "p1")
        #expect(row?.sessionId == "s1")
        #expect(row?.dateTaken == "2026-01-01T10:00:00.000Z")
        #expect(row?.cameraMake == "Canon")
        #expect(row?.focalLength == 50.0)
        #expect(row?.iso == 100)
        #expect(row?.rating == 4)
        #expect(row?.gpsLatitude == 31.23)
        #expect(row?.width == 4000)
        #expect(row?.keywords == ["nature", "travel"])
        #expect(row?.height == nil)
        #expect(row?.fileSize == nil)

        // JSON 存储为数组文本（TS JSON.stringify(keywords)）
        let raw = try db.prepare("SELECT keywords FROM photo_metadata_cache WHERE photo_id = 'p1'").get()
        #expect(raw?[0].textValue == "[\"nature\",\"travel\"]")
    }

    @Test func upsertOverwritesOnConflict() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(photoId: "p1", sessionId: "s1", data: input())
        var data = input()
        data.rating = 1
        data.keywords = ["city"]
        data.cameraMake = "Nikon"
        try repo.upsert(photoId: "p1", sessionId: "s1", data: data)

        let row = try repo.get("p1")
        #expect(row?.rating == 1)
        #expect(row?.keywords == ["city"])
        #expect(row?.cameraMake == "Nikon")
        #expect(row?.dateTaken == "2026-01-01T10:00:00.000Z", "ON CONFLICT 整行以 excluded 覆盖，提供过的字段保留新值")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM photo_metadata_cache") == 1)
    }

    @Test func defaultsApplyForMissingInput() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(photoId: "p1", sessionId: "s1", data: MetadataCacheInput())
        let row = try repo.get("p1")
        #expect(row?.rating == 0, "rating 默认 0")
        #expect(row?.keywords == [], "keywords 默认 []")
        #expect(row?.dateTaken == nil)
    }

    @Test func getBatchEmptyAndChunked() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        #expect(try repo.getBatch([]).isEmpty)

        var photoIds: [String] = []
        // 810 次「插 photos + upsert 缓存行」若各自自动提交，就是 1620 次写事务；
        // 本用例的断言只读最终状态（getBatch 的 810 行数量与末行 id），不依赖
        // 逐条提交对外可见的中间态，故整段包一个事务（失败仍整体回滚）。
        try db.transaction {
            for index in 0..<810 {
                let id = "bulk-\(index)"
                try insertPhoto(db, id: id, sessionId: "s1")
                photoIds.append(id)
                try repo.upsert(photoId: id, sessionId: "s1", data: MetadataCacheInput(rating: Int64(index % 5)))
            }
        }
        let rows = try repo.getBatch(photoIds)
        #expect(rows.count == 810)
        #expect(rows[809].photoId == "bulk-809")
    }

    @Test func deleteBySessionRemovesAllRows() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(photoId: "p1", sessionId: "s1", data: input())
        try repo.upsert(photoId: "p2", sessionId: "s1", data: input())

        try repo.deleteBySession("s1")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM photo_metadata_cache") == 0)
    }

    @Test func updateRatingCreatesRowFromPhoto() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.upsert(photoId: "p1", sessionId: "s1", data: input())
        try repo.updateRating(photoId: "p1", rating: 5)
        #expect(try repo.get("p1")?.rating == 5)
        #expect(try repo.get("p1")?.keywords == ["nature", "travel"], "updateRating 只改 rating/cached_at，keywords 保留")

        // 无缓存行时从 photos 生成
        try repo.updateRating(photoId: "p2", rating: 2)
        let row = try repo.get("p2")
        #expect(row?.rating == 2)
        #expect(row?.sessionId == "s1")
    }

    @Test func updateLabelAndKeywords() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try repo.updateLabel(photoId: "p1", label: "Green")
        let labeled = try repo.get("p1")
        #expect(labeled?.label == "Green")
        #expect(labeled?.rating == 0)

        try repo.updateKeywords(photoId: "p1", keywords: ["a", "b"])
        #expect(try repo.get("p1")?.keywords == ["a", "b"])

        // updateLabel 只改 label/cached_at，keywords 保留
        try repo.updateLabel(photoId: "p1", label: "Red")
        #expect(try repo.get("p1")?.keywords == ["a", "b"])
        #expect(try repo.get("p1")?.label == "Red")
    }
}
