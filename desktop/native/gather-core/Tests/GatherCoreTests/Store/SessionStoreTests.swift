// Tests/GatherCoreTests/Store/SessionStoreTests.swift
// R1：SessionStore 测试（端口自 SessionRepoTests，oracle 断言保持一致）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/SessionStore (R1)")
struct SessionStoreTests {
    private func makeStore() async throws -> (SQLiteSessionStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "session")
        return (SQLiteSessionStore(database: database), database, path)
    }

    private func insertSession(_ database: SQLiteDatabase, id: String, name: String, updatedAt: String) async throws {
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            [.text(id), .text(name), .text(updatedAt), .text(updatedAt)]
        )
    }

    private func insertSimilarityRow(_ database: SQLiteDatabase, sessionId: String, threshold: Int) async throws {
        try await database.run(
            """
            INSERT INTO similarity_results
              (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
            VALUES (?, '{}', '{}', ?, 2, '2026-01-01T00:00:00.000Z')
            """,
            [.text(sessionId), .int(Int64(threshold))]
        )
    }

    private func insertSimilarityHash(_ database: SQLiteDatabase, sessionId: String, photoId: String) async throws {
        try await database.run(
            "INSERT INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES (?, ?, 'abc')",
            [.text(sessionId), .text(photoId)]
        )
    }

    @Test func createAppliesDefaultsAndGetReturnsRow() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let row = try await store.create(name: "Trip", source: "folder", sourcePath: "/tmp/photos", truncatedImport: true)

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

        #expect(try await store.get(id: row.id) == row)
        #expect(try await store.get(id: "missing") == nil)
    }

    @Test func createDefaultsForOptionalArguments() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        let row = try await store.create(name: "Minimal", source: "import")
        #expect(row.sourcePath == "")
        #expect(row.truncatedImport == 0)
    }

    @Test func listOrdersByUpdatedAtDescending() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "old", name: "Old", updatedAt: "2026-01-01T00:00:00.000Z")
        try await insertSession(database, id: "new", name: "New", updatedAt: "2026-03-01T00:00:00.000Z")

        #expect(try await store.list().map(\.id) == ["new", "old"])
    }

    @Test func updateMethodsPersistFields() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(name: "Trip", source: "folder")

        #expect(try await store.updateName(id: row.id, name: "Renamed"))
        #expect(try await store.updateSourcePath(id: row.id, sourcePath: "/new/path"))
        try await store.updateStatus(id: row.id, status: "review")
        try await store.updatePhotoCount(id: row.id, count: 42)
        try await store.updateAnalysisStatus(id: row.id, status: "done")
        try await store.updateWritebackStatus(id: row.id, status: "partial")
        try await store.updateFailedWritebackCount(id: row.id, count: 3)

        let updated = try await store.get(id: row.id)
        #expect(updated?.name == "Renamed")
        #expect(updated?.sourcePath == "/new/path")
        #expect(updated?.status == "review")
        #expect(updated?.photoCount == 42)
        #expect(updated?.analysisStatus == "done")
        #expect(updated?.writebackStatus == "partial")
        #expect(updated?.failedWritebackCount == 3)

        #expect(try await store.updateName(id: "missing", name: "X") == false)
        #expect(try await store.updateSourcePath(id: "missing", sourcePath: "/x") == false)
    }

    @Test func reloadAckedAtRoundTrip() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(name: "Trip", source: "folder")

        #expect(try await store.reloadAckedAt(sessionId: row.id) == nil)
        #expect(try await store.setReloadAckedAt(sessionId: row.id, iso: "2026-01-02T03:04:05.000Z"))
        #expect(try await store.reloadAckedAt(sessionId: row.id) == "2026-01-02T03:04:05.000Z")
        #expect(try await store.setReloadAckedAt(sessionId: "missing", iso: "2026-01-02T03:04:05.000Z") == false)
    }

    @Test func indexSeqStartsAtZeroAndBumps() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(name: "Trip", source: "folder")

        #expect(try await store.indexSeq(id: row.id) == 0)
        #expect(try await store.bumpIndexSeq(id: row.id) == 1)
        #expect(try await store.bumpIndexSeq(id: row.id) == 2)
        #expect(try await store.indexSeq(id: row.id) == 2)
        #expect(try await store.indexSeq(id: "missing") == 0)
    }

    @Test func deleteReturnsWhetherRowExisted() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let row = try await store.create(name: "Trip", source: "folder")

        #expect(try await store.delete(id: row.id))
        #expect(try await store.get(id: row.id) == nil)
        #expect(try await store.delete(id: row.id) == false)
    }

    @Test func deleteManyDeletesAllAndReturnsCount() async throws {
        let (store, _, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let a = try await store.create(name: "A", source: "folder")
        let b = try await store.create(name: "B", source: "folder")
        let c = try await store.create(name: "C", source: "folder")

        #expect(try await store.deleteMany(ids: [a.id, b.id]) == 2)
        #expect(try await store.get(id: a.id) == nil)
        #expect(try await store.get(id: b.id) == nil)
        #expect(try await store.get(id: c.id) != nil)
        #expect(try await store.deleteMany(ids: []) == 0)
    }

    @Test func deleteSimilarityDataBySessionClearsBothTables() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertSession(database, id: "s1", name: "S1", updatedAt: "2026-01-01T00:00:00.000Z")
        try await insertSession(database, id: "s2", name: "S2", updatedAt: "2026-01-01T00:00:00.000Z")
        // similarity_hashes.photo_id 有外键，需先有照片行。
        try await database.run(
            "INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES ('p1', 's1', '/a.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            "INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES ('p2', 's2', '/b.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        try await insertSimilarityRow(database, sessionId: "s1", threshold: 10)
        try await insertSimilarityRow(database, sessionId: "s2", threshold: 10)
        try await insertSimilarityHash(database, sessionId: "s1", photoId: "p1")
        try await insertSimilarityHash(database, sessionId: "s2", photoId: "p2")

        try await store.deleteSimilarityData(sessionId: "s1")

        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's1'") == 0)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_hashes WHERE session_id = 's1'") == 0)
        // 其他会话数据不受影响。
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_results WHERE session_id = 's2'") == 1)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_hashes WHERE session_id = 's2'") == 1)
    }
}
