// Tests/GatherCoreTests/Store/PhotoStoreTests.swift
// R1：PhotoStore 测试（端口自 PhotoRepoTests，oracle 断言保持一致）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/PhotoStore (R1)")
struct PhotoStoreTests {
    private func makeStore() async throws -> (SQLitePhotoStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "photo")
        return (SQLitePhotoStore(database: database), database, path)
    }

    private func insertSession(_ database: SQLiteDatabase, id: String) async throws {
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')",
            [.text(id)]
        )
    }

    private func insertAsset(_ database: SQLiteDatabase, id: String) async throws {
        try await database.run(
            "INSERT INTO assets (id, created_at, updated_at) VALUES (?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')",
            [.text(id)]
        )
    }

    private func insertPhoto(
        _ database: SQLiteDatabase,
        id: String,
        sessionId: String,
        filepath: String,
        assetId: String? = nil,
        checksum: String = "abc123"
    ) async throws {
        try await database.run(
            """
            INSERT INTO photos
              (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id,
               width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 'pending', '{}', '{}', ?, 100, 200,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [
                .text(id), .text(sessionId), .text(filepath), .text((filepath as NSString).lastPathComponent),
                .text(checksum), assetId.map { SQLiteValue.text($0) } ?? .null,
            ]
        )
    }

    private func photoCount(_ database: SQLiteDatabase, sessionId: String) async throws -> Int {
        Int(try await database.scalarInt("SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(sessionId)]) ?? 0)
    }

    @Test func getBySessionReturnsAllRowsInRowidOrder() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/one.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/two.jpg")
        try await insertSession(database, id: "s2")
        try await insertPhoto(database, id: "p3", sessionId: "s2", filepath: "/three.jpg")

        let rows = try await store.getBySession(sessionId: "s1")
        #expect(rows.map(\.id) == ["p1", "p2"])
        #expect(rows[0].filepath == "/one.jpg")
        #expect(rows[0].filename == "one.jpg")
        #expect(rows[0].status == "pending")
        #expect(rows[0].checksum == "abc123")
        #expect(rows[0].width == 100)
        #expect(rows[0].height == 200)
        #expect(rows[0].metadata == "{}")
        #expect(rows[0].result == "{}")
        #expect(rows[0].assetId == nil)
        #expect(rows[0].assetFileId == nil)
        #expect(rows[0].checksumFileSize == 0)
        #expect(try await store.getBySession(sessionId: "empty").isEmpty)
    }

    @Test func getBySessionProjectionOmitsHeavyJSONColumns() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/one.jpg")

        let rows = try await store.getBySessionProjection(sessionId: "s1")
        #expect(rows.count == 1)
        #expect(rows[0].id == "p1")
        #expect(rows[0].filepath == "/one.jpg")
        #expect(rows[0].status == "pending")
        #expect(rows[0].width == 100)
        #expect(rows[0].checksum == "abc123")
    }

    @Test func countBySessionCountsOnlyThatSession() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertSession(database, id: "s2")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try await insertPhoto(database, id: "p3", sessionId: "s2", filepath: "/c.jpg")

        #expect(try await store.countBySession(sessionId: "s1") == 2)
        #expect(try await store.countBySession(sessionId: "s2") == 1)
        #expect(try await store.countBySession(sessionId: "empty") == 0)
    }

    @Test func getBySessionPageUsesKeysetPagination() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        for index in 1...5 {
            try await insertPhoto(database, id: "p\(index)", sessionId: "s1", filepath: "/p\(index).jpg")
        }

        let page1 = try await store.getBySessionPage(sessionId: "s1")
        #expect(page1.map(\.id) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(page1[0].rowid == 1)
        #expect(page1[0].filename == "p1.jpg")
        #expect(page1[0].status == "pending")

        let first = try await store.getBySessionPage(sessionId: "s1", afterRowId: nil, limit: 2)
        #expect(first.map(\.id) == ["p1", "p2"])
        let second = try await store.getBySessionPage(sessionId: "s1", afterRowId: first[1].rowid, limit: 2)
        #expect(second.map(\.id) == ["p3", "p4"])
        let third = try await store.getBySessionPage(sessionId: "s1", afterRowId: second[1].rowid, limit: 2)
        #expect(third.map(\.id) == ["p5"])
        let empty = try await store.getBySessionPage(sessionId: "s1", afterRowId: third[0].rowid, limit: 2)
        #expect(empty.isEmpty)
    }

    @Test func getAssetPageGroupsByLogicalAsset() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertAsset(database, id: "asset1")
        try await insertPhoto(database, id: "raw", sessionId: "s1", filepath: "/x.nef", assetId: "asset1")
        try await insertPhoto(database, id: "jpeg", sessionId: "s1", filepath: "/x.jpg", assetId: "asset1")
        try await insertPhoto(database, id: "lone", sessionId: "s1", filepath: "/lone.jpg")

        #expect(try await store.countAssetsBySession(sessionId: "s1") == 2)

        let page1 = try await store.getAssetPage(sessionId: "s1", afterFirstRowid: nil, limit: 1)
        #expect(page1.rows.map(\.id) == ["raw", "jpeg"])
        #expect(page1.cursor == 1)

        let page2 = try await store.getAssetPage(sessionId: "s1", afterFirstRowid: page1.cursor, limit: 1)
        #expect(page2.rows.map(\.id) == ["lone"])
        #expect(page2.cursor == 3)

        let page3 = try await store.getAssetPage(sessionId: "s1", afterFirstRowid: page2.cursor, limit: 1)
        #expect(page3.rows.isEmpty)
        #expect(page3.cursor == nil)

        let all = try await store.getAssetPage(sessionId: "s1")
        #expect(all.rows.map(\.id) == ["raw", "jpeg", "lone"])
        #expect(all.cursor == 3)
    }

    @Test func containsFilepathChecksGlobalPath() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/unique.jpg")

        #expect(try await store.containsFilepath(filepath: "/unique.jpg"))
        #expect(try await store.containsFilepath(filepath: "/nope.jpg") == false)
    }

    @Test func addPhotosInsertsAndSkipsDuplicates() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")

        let result = try await store.addPhotos(
            sessionId: "s1",
            inputs: [
                PhotoAddInput(filepath: "/dir/one.jpg", width: 10, height: 20),
                PhotoAddInput(filepath: "/dir/two.NEF", width: 30, height: 40),
            ],
            source: "import"
        )
        #expect(result.added == 2)
        #expect(result.skipped == 0)
        #expect(result.ids.count == 2)
        #expect(result.ids[0] != "")
        #expect(result.ids[1] != "")

        let again = try await store.addPhotos(
            sessionId: "s1",
            inputs: [
                PhotoAddInput(filepath: "/dir/one.jpg", width: 10, height: 20),
                PhotoAddInput(filepath: "/dir/three.jpg", width: 5, height: 5),
            ],
            source: "import"
        )
        #expect(again.added == 1)
        #expect(again.skipped == 1)
        #expect(again.ids[0] == "")
        #expect(again.ids[1] != "")

        let rows = try await store.getBySession(sessionId: "s1")
        #expect(rows.count == 3)
        let one = rows.first { $0.filepath == "/dir/one.jpg" }
        #expect(one?.filename == "one.jpg")
        #expect(one?.width == 10)
        #expect(one?.height == 20)
        #expect(one?.status == "pending")
        let two = rows.first { $0.filepath == "/dir/two.NEF" }
        #expect(two?.filename == "two.NEF")
        #expect(two?.width == 30)
    }

    @Test func deleteBySessionRemovesOnlyThatSession() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertSession(database, id: "s2")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s2", filepath: "/b.jpg")

        try await store.deleteBySession(sessionId: "s1")
        #expect(try await photoCount(database, sessionId: "s1") == 0)
        #expect(try await photoCount(database, sessionId: "s2") == 1)
    }

    @Test func updateIndexedFileClearsOrKeepsChecksumByChangedFlag() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg", checksum: "abc123")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg", checksum: "keepme")

        // changed=true：清空 checksum 三件套。
        try await store.updateIndexedFile(photoId: "p1", width: 640, height: 480, changed: true)
        var row = try await database.queryOne(
            "SELECT width, height, status, checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p1'"
        )
        #expect(row?.int("width") == 640)
        #expect(row?.int("height") == 480)
        #expect(row?.text("status") == "pending")
        #expect(row?.text("checksum") == "")
        #expect(row?.int("checksum_file_size") == 0)
        #expect(row?.double("checksum_file_mtime_ms") == 0)

        // changed=false：保留原有 checksum（p2 从未被清过）。
        try await store.updateIndexedFile(photoId: "p2", width: 800, height: 600, changed: false)
        row = try await database.queryOne(
            "SELECT width, height, checksum FROM photos WHERE id = 'p2'"
        )
        #expect(row?.int("width") == 800)
        #expect(row?.int("height") == 600)
        #expect(row?.text("checksum") == "keepme")

        // p1 再以 changed=false 更新：保持当前（已被清空）值，不恢复旧值。
        try await store.updateIndexedFile(photoId: "p1", width: 900, height: 700, changed: false)
        row = try await database.queryOne(
            "SELECT checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p1'"
        )
        #expect(row?.text("checksum") == "")
        #expect(row?.int("checksum_file_size") == 0)
        #expect(row?.double("checksum_file_mtime_ms") == 0)
    }

    @Test func updateChecksumPersistsValues() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg", checksum: "old")

        try await store.updateChecksum(photoId: "p1", checksum: "new-checksum", fileSize: 12345, fileMtimeMs: 1700000000123.5)
        let row = try await database.queryOne(
            "SELECT checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p1'"
        )
        #expect(row?.text("checksum") == "new-checksum")
        #expect(row?.int("checksum_file_size") == 12345)
        #expect(row?.double("checksum_file_mtime_ms") == 1700000000123.5)
    }

    @Test func markMissingUpdatesGivenIdsOnly() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1")
        try await insertPhoto(database, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try await insertPhoto(database, id: "p2", sessionId: "s1", filepath: "/b.jpg")

        try await store.markMissing(photoIds: ["p1", "ghost"])
        let rows = try await database.query("SELECT id, status FROM photos ORDER BY id")
        #expect(rows.count == 2)
        #expect(rows[0].text("status") == "missing")
        #expect(rows[1].text("status") == "pending")
    }
}
