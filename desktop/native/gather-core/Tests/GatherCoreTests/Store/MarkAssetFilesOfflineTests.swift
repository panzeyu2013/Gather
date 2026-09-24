// Tests/GatherCoreTests/Store/MarkAssetFilesOfflineTests.swift
// R1 / M4：markAssetFilesOffline（旧 IndexerService.swift 545-554）Store 级直测。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/MarkAssetFilesOffline (M4)")
struct MarkAssetFilesOfflineTests {
    private let originalUpdatedAt = "2026-01-01T00:00:00.000Z"

    private func makeStore() async throws -> (SQLiteAssetStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset-offline")
        return (SQLiteAssetStore(database: database), database, path)
    }

    private func insertAssetFile(_ database: SQLiteDatabase, id: String, online: Bool) async throws {
        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES (?, 'dev:1', '', ?, ?, '', 'unknown', 0, 0, '', ?, ?, ?, ?)
            """,
            [
                .text(id),
                .text("/Volumes/SSD/\(id).jpg"),
                .text("\(id).jpg"),
                .text(online ? "online" : "offline"),
                .text(originalUpdatedAt),
                .text(originalUpdatedAt),
                .text(originalUpdatedAt),
            ]
        )
    }

    private func fetch(_ database: SQLiteDatabase, id: String) async throws -> SQLiteRow? {
        try await database.queryOne(
            "SELECT online_status, updated_at FROM asset_files WHERE id = ?",
            [.text(id)]
        )
    }

    @Test func marksListedOnlineFileAndLeavesControlRowUntouched() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertAssetFile(database, id: "f1", online: true)
        try await insertAssetFile(database, id: "f2", online: false)
        let updatedAt = "2026-02-01T00:00:00.000Z"

        let affected = try await store.markAssetFilesOffline(ids: ["f1"], updatedAt: updatedAt)
        #expect(affected == 1)

        let updated = try await fetch(database, id: "f1")
        #expect(updated?.text("online_status") == "offline")
        #expect(updated?.text("updated_at") == updatedAt)

        let control = try await fetch(database, id: "f2")
        #expect(control?.text("online_status") == "offline")
        #expect(control?.text("updated_at") == originalUpdatedAt)
    }

    /// 旧 SQL 没有 online_status 过滤，SQLite changes() 统计 WHERE 命中的行数
    /// （而不是值真正发生变化的行数）：已 offline 行若列入 ids 也同样计入并刷新 updated_at。
    @Test func alreadyOfflineListedRowIsCountedAsAffected() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertAssetFile(database, id: "f1", online: true)
        try await insertAssetFile(database, id: "f2", online: false)
        let updatedAt = "2026-02-01T00:00:00.001Z"

        let affected = try await store.markAssetFilesOffline(ids: ["f1", "f2"], updatedAt: updatedAt)
        #expect(affected == 2)

        let refreshed = try await fetch(database, id: "f2")
        #expect(refreshed?.text("online_status") == "offline")
        #expect(refreshed?.text("updated_at") == updatedAt)
    }

    @Test func emptyIdsReturnsZeroWithoutWrites() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await insertAssetFile(database, id: "f1", online: true)

        let affected = try await store.markAssetFilesOffline(ids: [], updatedAt: "2026-02-01T00:00:00.002Z")
        #expect(affected == 0)

        let row = try await fetch(database, id: "f1")
        #expect(row?.text("online_status") == "online")
        #expect(row?.text("updated_at") == originalUpdatedAt)
    }
}
