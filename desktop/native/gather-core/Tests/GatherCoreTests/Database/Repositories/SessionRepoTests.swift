// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/SessionRepoTests.swift
// SessionRepo 测试：CRUD、状态更新、index_seq、相似度数据清理。

import Foundation
import Testing
@testable import GatherCore

private func makeDB() throws -> DBConnection {
    let db = try DBConnection(path: ":memory:")
    try MigrationRunner().migrate(db)
    return db
}

private func insertSession(_ db: DBConnection, id: String, name: String, updatedAt: String) throws {
    _ = try db.prepare("INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)")
        .run([.text(id), .text(name), .text(updatedAt), .text(updatedAt)])
}

private func insertSimilarityRow(_ db: DBConnection, sessionId: String, threshold: Int) throws {
    _ = try db.prepare(
        "INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at) VALUES (?, '{}', '{}', ?, 2, '2026-01-01T00:00:00.000Z')"
    ).run([.text(sessionId), .int(Int64(threshold))])
}

private func insertSimilarityHash(_ db: DBConnection, sessionId: String, photoId: String) throws {
    _ = try db.prepare(
        "INSERT INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES (?, ?, 'abc')"
    ).run([.text(sessionId), .text(photoId)])
}

@Suite(.serialized)
struct SessionRepoTests {
    @Test func createAppliesDefaultsAndGetReturnsRow() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)

        let row = try repo.create(name: "Trip", source: "folder", sourcePath: "/tmp/photos", truncatedImport: true)

        #expect(!row.id.isEmpty)
        #expect(row.name == "Trip")
        #expect(row.status == "draft")
        #expect(row.analysisStatus == "idle")
        #expect(row.writebackStatus == "idle")
        #expect(row.importSource == "folder")
        #expect(row.sourcePath == "/tmp/photos")
        #expect(row.truncatedImport == 1)
        #expect(row.reloadAckedAt == nil)
        #expect(row.indexSeq == 0)
        #expect(row.photoCount == 0)
        #expect(row.failedWritebackCount == 0)
        #expect(!row.createdAt.isEmpty)
        #expect(!row.updatedAt.isEmpty)

        let fetched = try repo.get(id: row.id)
        #expect(fetched == row)
        #expect(try repo.get(id: "missing") == nil)
    }

    @Test func createDefaultsForOptionalArguments() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)

        let row = try repo.create(name: "Minimal", source: "import")
        #expect(row.sourcePath == "")
        #expect(row.truncatedImport == 0)
    }

    @Test func listOrdersByUpdatedAtDescending() throws {
        let db = try makeDB()
        try insertSession(db, id: "old", name: "Old", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertSession(db, id: "new", name: "New", updatedAt: "2026-03-01T00:00:00.000Z")
        let repo = SessionRepo(connection: db)

        let rows = try repo.list()
        #expect(rows.map(\.id) == ["new", "old"])
    }

    @Test func updateMethodsPersistFields() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)
        let row = try repo.create(name: "Trip", source: "folder")

        #expect(try repo.updateName(id: row.id, name: "Renamed"))
        #expect(try repo.updateSourcePath(id: row.id, sourcePath: "/new/path"))
        try repo.updateStatus(id: row.id, status: "review")
        try repo.updatePhotoCount(id: row.id, count: 42)
        try repo.updateAnalysisStatus(id: row.id, status: "done")
        try repo.updateWritebackStatus(id: row.id, status: "partial")
        try repo.updateFailedWritebackCount(id: row.id, count: 3)

        let updated = try repo.get(id: row.id)
        #expect(updated?.name == "Renamed")
        #expect(updated?.sourcePath == "/new/path")
        #expect(updated?.status == "review")
        #expect(updated?.photoCount == 42)
        #expect(updated?.analysisStatus == "done")
        #expect(updated?.writebackStatus == "partial")
        #expect(updated?.failedWritebackCount == 3)

        #expect(try repo.updateName(id: "missing", name: "X") == false)
        #expect(try repo.updateSourcePath(id: "missing", sourcePath: "/x") == false)
    }

    @Test func reloadAckedAtRoundTrip() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)
        let row = try repo.create(name: "Trip", source: "folder")

        #expect(try repo.getReloadAckedAt(sessionId: row.id) == nil)
        #expect(try repo.setReloadAckedAt(sessionId: row.id, iso: "2026-01-02T03:04:05.000Z"))
        #expect(try repo.getReloadAckedAt(sessionId: row.id) == "2026-01-02T03:04:05.000Z")
        #expect(try repo.setReloadAckedAt(sessionId: "missing", iso: "2026-01-02T03:04:05.000Z") == false)
    }

    @Test func indexSeqStartsAtZeroAndBumps() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)
        let row = try repo.create(name: "Trip", source: "folder")

        #expect(try repo.getIndexSeq(id: row.id) == 0)
        #expect(try repo.bumpIndexSeq(id: row.id) == 1)
        #expect(try repo.bumpIndexSeq(id: row.id) == 2)
        #expect(try repo.getIndexSeq(id: row.id) == 2)
        #expect(try repo.getIndexSeq(id: "missing") == 0)
    }

    @Test func deleteReturnsWhetherRowExisted() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)
        let row = try repo.create(name: "Trip", source: "folder")

        #expect(try repo.delete(id: row.id))
        #expect(try repo.get(id: row.id) == nil)
        #expect(try repo.delete(id: row.id) == false)
    }

    @Test func deleteManyDeletesAllAndReturnsCount() throws {
        let db = try makeDB()
        let repo = SessionRepo(connection: db)
        let a = try repo.create(name: "A", source: "folder")
        let b = try repo.create(name: "B", source: "folder")
        let c = try repo.create(name: "C", source: "folder")

        #expect(try repo.deleteMany(ids: [a.id, b.id]) == 2)
        #expect(try repo.get(id: a.id) == nil)
        #expect(try repo.get(id: b.id) == nil)
        #expect(try repo.get(id: c.id) != nil)
        #expect(try repo.deleteMany(ids: []) == 0)
    }

    @Test func deleteSimilarityDataBySessionClearsBothTables() throws {
        let db = try makeDB()
        try insertSession(db, id: "s1", name: "S1", updatedAt: "2026-01-01T00:00:00.000Z")
        try insertSession(db, id: "s2", name: "S2", updatedAt: "2026-01-01T00:00:00.000Z")
        // similarity_hashes.photo_id 有外键，需先有照片行。
        _ = try db.prepare("INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES ('p1', 's1', '/a.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')").run()
        _ = try db.prepare("INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES ('p2', 's2', '/b.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')").run()
        try insertSimilarityRow(db, sessionId: "s1", threshold: 10)
        try insertSimilarityRow(db, sessionId: "s2", threshold: 10)
        try insertSimilarityHash(db, sessionId: "s1", photoId: "p1")
        try insertSimilarityHash(db, sessionId: "s2", photoId: "p2")

        let repo = SessionRepo(connection: db)
        try repo.deleteSimilarityDataBySession(sessionId: "s1")

        let s1Results = try db.prepare("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's1'").get()
        #expect(s1Results?[0].intValue == 0)
        let s1Hashes = try db.prepare("SELECT COUNT(*) FROM similarity_hashes WHERE session_id = 's1'").get()
        #expect(s1Hashes?[0].intValue == 0)
        // 其他会话数据不受影响。
        let s2Results = try db.prepare("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's2'").get()
        #expect(s2Results?[0].intValue == 1)
        let s2Hashes = try db.prepare("SELECT COUNT(*) FROM similarity_hashes WHERE session_id = 's2'").get()
        #expect(s2Hashes?[0].intValue == 1)
    }
}
