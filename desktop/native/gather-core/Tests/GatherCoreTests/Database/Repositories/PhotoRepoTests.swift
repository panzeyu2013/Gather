// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/PhotoRepoTests.swift
// PhotoRepo 测试：会话查询/投影/键集分页、资产分组分页、addPhotos
// 去重计数、updateIndexedFile/updateChecksum/markMissing/deleteBySession。

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

private func insertAsset(_ db: DBConnection, id: String) throws {
    _ = try db.prepare("INSERT INTO assets (id, created_at, updated_at) VALUES (?, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')")
        .run([.text(id)])
}

private func insertPhoto(_ db: DBConnection, id: String, sessionId: String, filepath: String, assetId: String? = nil, checksum: String = "abc123") throws {
    _ = try db.prepare(
        "INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, width, height, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'pending', '{}', '{}', ?, 100, 200, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
    ).run([.text(id), .text(sessionId), .text(filepath), .text((filepath as NSString).lastPathComponent), .text(checksum), assetId.map { DBValue.text($0) }])
}

private func photoCount(_ db: DBConnection, sessionId: String) throws -> Int {
    let row = try db.prepare("SELECT COUNT(*) FROM photos WHERE session_id = ?").get([.text(sessionId)])
    return Int(row?[0].intValue ?? 0)
}

@Suite(.serialized)
struct PhotoRepoTests {
    @Test func getBySessionReturnsAllRowsInRowidOrder() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/one.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/two.jpg")
        try insertSession(db, id: "s2")
        try insertPhoto(db, id: "p3", sessionId: "s2", filepath: "/three.jpg")
        let repo = PhotoRepo(connection: db)

        let rows = try repo.getBySession(sessionId: "s1")
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
        #expect(try repo.getBySession(sessionId: "empty").isEmpty)
    }

    @Test func getBySessionProjectionOmitsHeavyJSONColumns() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/one.jpg")
        let repo = PhotoRepo(connection: db)

        let rows = try repo.getBySessionProjection(sessionId: "s1")
        #expect(rows.count == 1)
        #expect(rows[0].id == "p1")
        #expect(rows[0].filepath == "/one.jpg")
        #expect(rows[0].status == "pending")
        #expect(rows[0].width == 100)
        #expect(rows[0].checksum == "abc123")
    }

    @Test func countBySessionCountsOnlyThatSession() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertSession(db, id: "s2")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        try insertPhoto(db, id: "p3", sessionId: "s2", filepath: "/c.jpg")
        let repo = PhotoRepo(connection: db)

        #expect(try repo.countBySession(sessionId: "s1") == 2)
        #expect(try repo.countBySession(sessionId: "s2") == 1)
        #expect(try repo.countBySession(sessionId: "empty") == 0)
    }

    @Test func getBySessionPageUsesKeysetPagination() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        for i in 1...5 {
            try insertPhoto(db, id: "p\(i)", sessionId: "s1", filepath: "/p\(i).jpg")
        }
        let repo = PhotoRepo(connection: db)

        // 第一页（默认 limit 200 生效：全量）。
        let page1 = try repo.getBySessionPage(sessionId: "s1")
        #expect(page1.map(\.id) == ["p1", "p2", "p3", "p4", "p5"])
        #expect(page1[0].rowid == 1)
        #expect(page1[0].filename == "p1.jpg")
        #expect(page1[0].status == "pending")

        // 显式 limit 2 的键集翻页：以最后一行的 rowid 为游标。
        let first = try repo.getBySessionPage(sessionId: "s1", limit: 2)
        #expect(first.map(\.id) == ["p1", "p2"])
        let second = try repo.getBySessionPage(sessionId: "s1", afterRowId: first[1].rowid, limit: 2)
        #expect(second.map(\.id) == ["p3", "p4"])
        let third = try repo.getBySessionPage(sessionId: "s1", afterRowId: second[1].rowid, limit: 2)
        #expect(third.map(\.id) == ["p5"])
        let empty = try repo.getBySessionPage(sessionId: "s1", afterRowId: third[0].rowid, limit: 2)
        #expect(empty.isEmpty)
    }

    @Test func getAssetPageGroupsByLogicalAsset() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertAsset(db, id: "asset1")
        try insertPhoto(db, id: "raw", sessionId: "s1", filepath: "/x.nef", assetId: "asset1")
        try insertPhoto(db, id: "jpeg", sessionId: "s1", filepath: "/x.jpg", assetId: "asset1")
        try insertPhoto(db, id: "lone", sessionId: "s1", filepath: "/lone.jpg")
        let repo = PhotoRepo(connection: db)

        #expect(try repo.countAssetsBySession(sessionId: "s1") == 2)

        // limit 1（组）时 RAW/JPEG 同页不拆分。
        let page1 = try repo.getAssetPage(sessionId: "s1", limit: 1)
        #expect(page1.rows.map(\.id) == ["raw", "jpeg"])
        #expect(page1.cursor == 1)

        let page2 = try repo.getAssetPage(sessionId: "s1", afterFirstRowid: page1.cursor, limit: 1)
        #expect(page2.rows.map(\.id) == ["lone"])
        #expect(page2.cursor == 3)

        let page3 = try repo.getAssetPage(sessionId: "s1", afterFirstRowid: page2.cursor, limit: 1)
        #expect(page3.rows.isEmpty)
        #expect(page3.cursor == nil)

        // 无分组时整页返回（默认 limit 200）。
        let all = try repo.getAssetPage(sessionId: "s1")
        #expect(all.rows.map(\.id) == ["raw", "jpeg", "lone"])
        #expect(all.cursor == 3)
    }

    @Test func containsFilepathChecksGlobalPath() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/unique.jpg")
        let repo = PhotoRepo(connection: db)

        #expect(try repo.containsFilepath(filepath: "/unique.jpg"))
        #expect(try repo.containsFilepath(filepath: "/nope.jpg") == false)
    }

    @Test func addPhotosInsertsAndSkipsDuplicates() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        let repo = PhotoRepo(connection: db)

        let result = try repo.addPhotos(
            sessionId: "s1",
            filepaths: [
                PhotoAddInput(filepath: "/dir/one.jpg", width: 10, height: 20),
                PhotoAddInput(filepath: "/dir/two.NEF", width: 30, height: 40),
            ],
            "import"
        )
        #expect(result.added == 2)
        #expect(result.skipped == 0)
        #expect(result.ids.count == 2)
        #expect(result.ids[0] != "")
        #expect(result.ids[1] != "")

        // 重复路径第二次：跳过，id 为 ""。
        let again = try repo.addPhotos(
            sessionId: "s1",
            filepaths: [
                PhotoAddInput(filepath: "/dir/one.jpg", width: 10, height: 20),
                PhotoAddInput(filepath: "/dir/three.jpg", width: 5, height: 5),
            ],
            "import"
        )
        #expect(again.added == 1)
        #expect(again.skipped == 1)
        #expect(again.ids[0] == "")
        #expect(again.ids[1] != "")

        // 落库字段：filename 取路径最后一段、status pending、尺寸正确。
        let rows = try repo.getBySession(sessionId: "s1")
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

    @Test func deleteBySessionRemovesOnlyThatSession() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertSession(db, id: "s2")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s2", filepath: "/b.jpg")
        let repo = PhotoRepo(connection: db)

        try repo.deleteBySession(sessionId: "s1")
        #expect(try photoCount(db, sessionId: "s1") == 0)
        #expect(try photoCount(db, sessionId: "s2") == 1)
    }

    @Test func updateIndexedFileClearsOrKeepsChecksumByChangedFlag() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg", checksum: "abc123")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg", checksum: "keepme")
        let repo = PhotoRepo(connection: db)

        // changed=true：清空 checksum 三件套。
        try repo.updateIndexedFile(photoId: "p1", width: 640, height: 480, changed: true)
        var row = try db.prepare("SELECT width, height, status, checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p1'").get()
        #expect(row?[0].intValue == 640)
        #expect(row?[1].intValue == 480)
        #expect(row?[2].textValue == "pending")
        #expect(row?[3].textValue == "")
        #expect(row?[4].intValue == 0)
        #expect(row?[5].doubleValue == 0)

        // changed=false：保留原有 checksum（p2 从未被清过）。
        try repo.updateIndexedFile(photoId: "p2", width: 800, height: 600, changed: false)
        row = try db.prepare("SELECT width, height, checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p2'").get()
        #expect(row?[0].intValue == 800)
        #expect(row?[1].intValue == 600)
        #expect(row?[2].textValue == "keepme")

        // p1 再以 changed=false 更新：保持当前（已被清空）值，不恢复旧值。
        try repo.updateIndexedFile(photoId: "p1", width: 900, height: 700, changed: false)
        row = try db.prepare("SELECT checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p1'").get()
        #expect(row?[0].textValue == "")
        #expect(row?[1].intValue == 0)
        #expect(row?[2].doubleValue == 0)
    }

    @Test func updateChecksumPersistsValues() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg", checksum: "old")
        let repo = PhotoRepo(connection: db)

        try repo.updateChecksum(photoId: "p1", checksum: "new-checksum", fileSize: 12345, fileMtimeMs: 1700000000123.5)
        let row = try db.prepare("SELECT checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'p1'").get()
        #expect(row?[0].textValue == "new-checksum")
        #expect(row?[1].intValue == 12345)
        #expect(row?[2].doubleValue == 1700000000123.5)
    }

    @Test func markMissingUpdatesGivenIdsOnly() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/a.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/b.jpg")
        let repo = PhotoRepo(connection: db)

        try repo.markMissing(photoIds: ["p1", "ghost"])
        let statuses = try db.prepare("SELECT id, status FROM photos ORDER BY id").query()
        #expect(statuses[0][1].textValue == "missing")
        #expect(statuses[1][1].textValue == "pending")
    }
}
