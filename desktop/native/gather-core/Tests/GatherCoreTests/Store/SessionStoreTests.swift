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

    /// W4-1c：metadata_outbox 行 + metadata_outbox_sessions 边（清 reload 确认用）。
    private func insertOutbox(_ database: SQLiteDatabase, xmpPath: String, sessionId: String) async throws {
        try await database.run(
            """
            INSERT INTO metadata_outbox (xmp_path, photo_path, updated_at)
            VALUES (?, ?, '2026-01-01T00:00:00.000Z')
            """,
            [.text(xmpPath), .text(xmpPath + ".jpg")]
        )
        try await database.run(
            """
            INSERT INTO metadata_outbox_sessions (xmp_path, session_id, linked_at)
            VALUES (?, ?, '2026-01-01T00:00:00.000Z')
            """,
            [.text(xmpPath), .text(sessionId)]
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

    // MARK: W4-1c clearReloadAckedAtForXmpPaths

    @Test func clearReloadAckedAtForXmpPathsClearsOnlyLinkedSessions() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for id in ["s1", "s2", "s3"] {
            try await insertSession(database, id: id, name: "S", updatedAt: "2026-01-01T00:00:00.000Z")
            #expect(try await store.setReloadAckedAt(sessionId: id, iso: "2026-01-02T00:00:00.000Z"))
        }
        try await insertOutbox(database, xmpPath: "/v/a.xmp", sessionId: "s1")
        try await insertOutbox(database, xmpPath: "/v/b.xmp", sessionId: "s2")

        #expect(try await store.clearReloadAckedAtForXmpPaths([]) == 0, "空参 0")
        #expect(try await store.clearReloadAckedAtForXmpPaths(["/v/a.xmp"]) == 1)
        #expect(try await store.reloadAckedAt(sessionId: "s1") == nil)
        #expect(try await store.reloadAckedAt(sessionId: "s2") == "2026-01-02T00:00:00.000Z")
        #expect(try await store.reloadAckedAt(sessionId: "s3") == "2026-01-02T00:00:00.000Z")

        // 幂等：已清行不再计数；未链接路径 0。
        #expect(try await store.clearReloadAckedAtForXmpPaths(["/v/a.xmp"]) == 0)
        #expect(try await store.clearReloadAckedAtForXmpPaths(["/v/missing.xmp"]) == 0)

        // 同一会话链接多条路径：一次调用只计一次（子查询去重）。
        try await insertOutbox(database, xmpPath: "/v/c.xmp", sessionId: "s3")
        try await insertOutbox(database, xmpPath: "/v/d.xmp", sessionId: "s3")
        #expect(try await store.setReloadAckedAt(sessionId: "s3", iso: "2026-01-02T00:00:00.000Z"))
        #expect(try await store.clearReloadAckedAtForXmpPaths(["/v/c.xmp", "/v/d.xmp"]) == 1)
        #expect(try await store.reloadAckedAt(sessionId: "s3") == nil)
    }

    @Test func clearReloadAckedAtForXmpPathsRollsBackWholeBatchAcrossChunks() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        for id in ["s1", "s2"] {
            try await insertSession(database, id: id, name: "S", updatedAt: "2026-01-01T00:00:00.000Z")
            #expect(try await store.setReloadAckedAt(sessionId: id, iso: "2026-01-02T00:00:00.000Z"))
        }
        // 801 条 s1 路径跨 800 分块边界（单事务内写入）。
        var xmpPaths: [String] = []
        try await database.transaction { db in
            for index in 0..<801 {
                let xmpPath = "/v/batch_\(index).xmp"
                xmpPaths.append(xmpPath)
                try db.run(
                    "INSERT INTO metadata_outbox (xmp_path, photo_path, updated_at) VALUES (?, ?, '2026-01-01T00:00:00.000Z')",
                    [.text(xmpPath), .text(xmpPath + ".jpg")]
                )
                try db.run(
                    "INSERT INTO metadata_outbox_sessions (xmp_path, session_id, linked_at) VALUES (?, ?, '2026-01-01T00:00:00.000Z')",
                    [.text(xmpPath), .text("s1")]
                )
            }
        }
        xmpPaths.append("/v/boom.xmp")
        try await insertOutbox(database, xmpPath: "/v/boom.xmp", sessionId: "s2")
        // 末块（s2）被触发器拒绝：整批（含已更新的第 1 块）必须回滚。
        try await database.run(
            """
            CREATE TRIGGER block_clear_s2 BEFORE UPDATE OF reload_acked_at ON sessions
            WHEN OLD.id = 's2' AND NEW.reload_acked_at IS NULL
            BEGIN SELECT RAISE(ABORT, 'blocked'); END
            """
        )

        await #expect(throws: SQLiteFailure.self) {
            _ = try await store.clearReloadAckedAtForXmpPaths(xmpPaths)
        }
        #expect(try await store.reloadAckedAt(sessionId: "s1") == "2026-01-02T00:00:00.000Z", "单事务回滚")
        #expect(try await store.reloadAckedAt(sessionId: "s2") == "2026-01-02T00:00:00.000Z")
    }
}
