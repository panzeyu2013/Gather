// Tests/GatherCoreTests/Store/MetadataStoreTests.swift
// R1：MetadataStore 测试（端口自 MetadataCacheRepoTests + MetadataKeywordOriginRepoTests）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/MetadataStore (R1)")
struct MetadataStoreTests {
    private func makeStore(photoIds: [String] = ["p1", "p2"]) async throws -> (SQLiteMetadataStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "metadata")
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        for photoId in photoIds {
            try await insertPhoto(database, id: photoId, sessionId: "s1")
        }
        return (SQLiteMetadataStore(database: database), database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, sessionId: String) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, ?, ?, 'f.jpg', 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(sessionId), .text("/\(id).jpg")]
        )
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

    private func rowCount(_ database: SQLiteDatabase, _ sql: String) async throws -> Int64 {
        try await database.scalarInt(sql) ?? -1
    }

    // MARK: photo_metadata_cache

    @Test func upsertAndGet() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        #expect(try await store.metadata(photoId: "p1") == nil)

        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: input())
        let row = try await store.metadata(photoId: "p1")
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

        let raw = try await database.queryOne("SELECT keywords FROM photo_metadata_cache WHERE photo_id = 'p1'")
        #expect(raw?.text("keywords") == "[\"nature\",\"travel\"]")
    }

    @Test func upsertOverwritesOnConflict() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: input())
        var data = input()
        data.rating = 1
        data.keywords = ["city"]
        data.cameraMake = "Nikon"
        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: data)

        let row = try await store.metadata(photoId: "p1")
        #expect(row?.rating == 1)
        #expect(row?.keywords == ["city"])
        #expect(row?.cameraMake == "Nikon")
        #expect(row?.dateTaken == "2026-01-01T10:00:00.000Z", "ON CONFLICT 以 excluded 整行覆盖")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM photo_metadata_cache") == 1)
    }

    @Test func defaultsApplyForMissingInput() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: MetadataCacheInput())
        let row = try await store.metadata(photoId: "p1")
        #expect(row?.rating == 0, "rating 默认 0")
        #expect(row?.keywords == [], "keywords 默认 []")
        #expect(row?.dateTaken == nil)
    }

    @Test func getBatchEmptyAndChunked() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        #expect(try await store.metadataBatch(photoIds: []).isEmpty)

        var photoIds: [String] = []
        for index in 0..<810 {
            let id = "bulk-\(index)"
            try await insertPhoto(database, id: id, sessionId: "s1")
            photoIds.append(id)
            try await store.upsertMetadata(
                photoId: id, sessionId: "s1",
                data: MetadataCacheInput(rating: Int64(index % 5))
            )
        }
        let rows = try await store.metadataBatch(photoIds: photoIds)
        #expect(rows.count == 810)
        #expect(rows[809].photoId == "bulk-809")
    }

    @Test func deleteBySessionAndPhoto() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: input())
        try await store.upsertMetadata(photoId: "p2", sessionId: "s1", data: input())

        try await store.deleteMetadataByPhotoId("p1")
        #expect(try await store.metadata(photoId: "p1") == nil)
        #expect(try await store.metadata(photoId: "p2") != nil)

        try await store.deleteMetadataBySession("s1")
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM photo_metadata_cache") == 0)
    }

    @Test func updateRatingCreatesRowFromPhoto() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: input())
        try await store.updateRating(photoId: "p1", rating: 5)
        #expect(try await store.metadata(photoId: "p1")?.rating == 5)
        #expect(try await store.metadata(photoId: "p1")?.keywords == ["nature", "travel"], "只改 rating/cached_at")

        try await store.updateRating(photoId: "p2", rating: 2)
        let row = try await store.metadata(photoId: "p2")
        #expect(row?.rating == 2)
        #expect(row?.sessionId == "s1")
    }

    @Test func updateLabelAndKeywords() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await store.updateLabel(photoId: "p1", label: "Green")
        #expect(try await store.metadata(photoId: "p1")?.label == "Green")
        #expect(try await store.metadata(photoId: "p1")?.rating == 0)

        try await store.updateKeywords(photoId: "p1", keywords: ["a", "b"])
        #expect(try await store.metadata(photoId: "p1")?.keywords == ["a", "b"])

        try await store.updateLabel(photoId: "p1", label: "Red")
        #expect(try await store.metadata(photoId: "p1")?.keywords == ["a", "b"])
        #expect(try await store.metadata(photoId: "p1")?.label == "Red")
    }

    // MARK: metadata_keyword_origins

    @Test func markIntroducedInsertsActiveRows() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        try await store.markKeywordIntroduced(
            xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["person-a", "person-b"]
        )
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_keyword_origins") == 2)
        let row = try await database.queryOne(
            "SELECT active FROM metadata_keyword_origins WHERE xmp_path = '/v/IMG_1.xmp' AND keyword = 'person-a'"
        )
        #expect(row?.int("active") == 1)
    }

    @Test func markIntroducedEmptyIsNoopAndDeduplicates() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        try await store.markKeywordIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: [])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_keyword_origins") == 0)

        try await store.markKeywordIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "a", "b"])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_keyword_origins") == 2)
    }

    @Test func getActiveIntroducedFilters() async throws {
        let (store, _, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        try await store.markKeywordIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b", "c"])
        try await store.markKeywordIntroduced(xmpPath: "/v/IMG_2.xmp", source: "face-keyword", keywords: ["a"])

        let active = try await store.activeIntroducedKeywords(
            xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "c", "zzz"]
        )
        #expect(active == ["a", "c"])
        #expect(try await store.activeIntroducedKeywords(
            xmpPath: "/v/IMG_2.xmp", source: "face-keyword", keywords: ["a"]
        ) == ["a"])
        #expect(try await store.activeIntroducedKeywords(
            xmpPath: "/v/IMG_1.xmp", source: "other", keywords: ["a"]
        ).isEmpty)
        #expect(try await store.activeIntroducedKeywords(
            xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: []
        ).isEmpty)
    }

    @Test func deactivateAndReactivate() async throws {
        let (store, database, path) = try await makeStore(photoIds: [])
        defer { removeStoreFiles(path) }

        try await store.markKeywordIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b"])
        try await store.deactivateKeywordOrigins(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a"])
        #expect(try await store.activeIntroducedKeywords(
            xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b"]
        ) == ["b"])
        let row = try await database.queryOne("SELECT active FROM metadata_keyword_origins WHERE keyword = 'a'")
        #expect(row?.int("active") == 0)

        try await store.deactivateKeywordOrigins(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: [])
        #expect(try await rowCount(database, "SELECT COUNT(*) FROM metadata_keyword_origins") == 2)

        try await store.markKeywordIntroduced(xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a"])
        #expect(try await store.activeIntroducedKeywords(
            xmpPath: "/v/IMG_1.xmp", source: "face-keyword", keywords: ["a", "b"]
        ) == ["a", "b"])
    }

    // MARK: W4-1c mergeMetadata / metadataBatchLite

    @Test func mergeMetadataPreservesUserFieldsWhenNil() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await store.updateRating(photoId: "p1", rating: 5)
        try await store.updateLabel(photoId: "p1", label: "Red")
        try await store.updateKeywords(photoId: "p1", keywords: ["a", "b"])

        // provider 派生字段有值，用户三列全 nil：不得清零。
        try await store.mergeMetadata(
            photoId: "p1",
            sessionId: "s1",
            data: MetadataCacheInput(
                dateTaken: "2026-02-01T00:00:00.000Z",
                cameraMake: "Nikon",
                cameraModel: "Z8",
                focalLength: 35.5,
                iso: 400,
                width: 6000,
                height: 4000
            )
        )

        let row = try #require(try await store.metadata(photoId: "p1"))
        #expect(row.rating == 5, "nil rating 不得清零用户 rating")
        #expect(row.label == "Red", "nil label 不得清零用户 label")
        #expect(row.keywords == ["a", "b"], "nil keywords 不得清零用户 keywords")
        #expect(row.cameraMake == "Nikon")
        #expect(row.cameraModel == "Z8")
        #expect(row.iso == 400)
        #expect(row.width == 6000)
        #expect(row.height == 4000)
    }

    @Test func mergeMetadataInsertsMissingRowAndNonNilOverwrites() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await store.mergeMetadata(
            photoId: "p2", sessionId: "s1", data: MetadataCacheInput(cameraMake: "Canon", keywords: ["x"])
        )
        let inserted = try #require(try await store.metadata(photoId: "p2"))
        #expect(inserted.sessionId == "s1")
        #expect(inserted.rating == 0, "缺失行以默认 rating 建行")
        #expect(inserted.cameraMake == "Canon")
        #expect(inserted.keywords == ["x"])

        // 第二个批次只带 rating：其他非 nil 列保留，nil 列不覆盖。
        try await store.mergeMetadata(photoId: "p2", sessionId: "s1", data: MetadataCacheInput(rating: 3))
        let merged = try #require(try await store.metadata(photoId: "p2"))
        #expect(merged.rating == 3, "非 nil 覆盖")
        #expect(merged.cameraMake == "Canon")
        #expect(merged.keywords == ["x"])
        #expect(merged.cameraModel == nil)
    }

    @Test func metadataBatchLiteReturnsUserColumnsAndEmptyInput() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        #expect(try await store.metadataBatchLite(photoIds: []).isEmpty, "空参 [:]")

        try await store.upsertMetadata(photoId: "p1", sessionId: "s1", data: input())
        let lite = try await store.metadataBatchLite(photoIds: ["p1", "px", "p2"])
        #expect(Set(lite.keys) == ["p1"], "仅返回已缓存行")
        #expect(lite["p1"]?.rating == 4)
        #expect(lite["p1"]?.label == nil)
        #expect(lite["p1"]?.keywords == ["nature", "travel"])
    }
}
