// Tests/GatherCoreTests/Store/PurgeGeneratedCachePhotosTests.swift
// M1：PhotoStore.purgeGeneratedCachePhotos（IndexerService 内联清理事务的 Store 化）验证。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/PhotoStore purgeGeneratedCachePhotos (M1)")
struct PurgeGeneratedCachePhotosTests {
    private let now = "2026-01-01T00:00:00.000Z"

    private func makeStore() async throws -> (SQLitePhotoStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "purge")
        return (SQLitePhotoStore(database: database), database, path)
    }

    private func insertPhoto(
        _ database: SQLiteDatabase,
        id: String,
        sessionId: String,
        filepath: String,
        assetId: String,
        assetFileId: String
    ) async throws {
        try await database.run(
            """
            INSERT INTO photos
              (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id,
               asset_file_id, width, height, created_at, updated_at)
            VALUES (?, ?, ?, ?, 'abc123', 'pending', '{}', '{}', ?, ?, 100, 200, ?, ?)
            """,
            [
                .text(id), .text(sessionId), .text(filepath), .text((filepath as NSString).lastPathComponent),
                .text(assetId), .text(assetFileId), .text(now), .text(now),
            ]
        )
    }

    /// 1 session + 2 photos（目标照片带 asset_file 与 asset 成员）+ 相关 asset_files/assets/session_assets 行。
    private func seed(_ database: SQLiteDatabase) async throws {
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s1', 'S', ?, ?)",
            [.text(now), .text(now)]
        )
        for assetId in ["a-target", "a-keep"] {
            try await database.run(
                "INSERT INTO assets (id, created_at, updated_at) VALUES (?, ?, ?)",
                [.text(assetId), .text(now), .text(now)]
            )
        }
        for fileId in ["af-target", "af-keep"] {
            try await database.run(
                "INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [.text(fileId), .text("/library/\(fileId).jpg"), .text("\(fileId).jpg"), .text(now), .text(now)]
            )
        }
        for (assetId, fileId) in [("a-target", "af-target"), ("a-keep", "af-keep")] {
            try await database.run(
                "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary) VALUES (?, ?, 'primary', 1)",
                [.text(assetId), .text(fileId)]
            )
            try await database.run(
                "INSERT INTO session_assets (session_id, asset_id, display_file_id, added_at) VALUES ('s1', ?, ?, ?)",
                [.text(assetId), .text(fileId), .text(now)]
            )
        }
        try await insertPhoto(
            database, id: "p-target", sessionId: "s1",
            filepath: "/library/target.jpg", assetId: "a-target", assetFileId: "af-target"
        )
        try await insertPhoto(
            database, id: "p-other", sessionId: "s1",
            filepath: "/library/other.jpg", assetId: "a-keep", assetFileId: "af-keep"
        )
    }

    private func count(_ database: SQLiteDatabase, table: String, column: String, value: String) async throws -> Int {
        Int(try await database.scalarInt("SELECT COUNT(*) FROM \(table) WHERE \(column) = ?", [.text(value)]) ?? -1)
    }

    @Test func purgeDeletesTargetAndOrphansInOneTransaction() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await seed(database)

        let removed = try await store.purgeGeneratedCachePhotos(photoIds: ["p-target"], sessionId: "s1")
        #expect(removed == 1)

        // 目标 photo 行被删，未涉及的 photo 行保留。
        let targetPhotos = try await count(database, table: "photos", column: "id", value: "p-target")
        let otherPhotos = try await count(database, table: "photos", column: "id", value: "p-other")
        #expect(targetPhotos == 0)
        #expect(otherPhotos == 1)

        // 目标 asset_file 成孤儿被清，未涉及的 asset_file 行保留。
        let targetFiles = try await count(database, table: "asset_files", column: "id", value: "af-target")
        let keptFiles = try await count(database, table: "asset_files", column: "id", value: "af-keep")
        #expect(targetFiles == 0)
        #expect(keptFiles == 1)

        // 目标 asset 成孤儿被清（其唯一成员随 asset_files 级联删除），未涉及的 asset 行保留。
        let targetAssets = try await count(database, table: "assets", column: "id", value: "a-target")
        let keptAssets = try await count(database, table: "assets", column: "id", value: "a-keep")
        #expect(targetAssets == 0)
        #expect(keptAssets == 1)

        // session_assets 孤儿行被清，未涉及的会话-资产行保留。
        let targetLinks = try await count(database, table: "session_assets", column: "asset_id", value: "a-target")
        let keptLinks = try await count(database, table: "session_assets", column: "asset_id", value: "a-keep")
        #expect(targetLinks == 0)
        #expect(keptLinks == 1)

        // 行已删后重复调用返回 0，且不误删未涉及行。
        let removedAgain = try await store.purgeGeneratedCachePhotos(photoIds: ["p-target"], sessionId: "s1")
        #expect(removedAgain == 0)
        let otherAfter = try await count(database, table: "photos", column: "id", value: "p-other")
        let keptAssetsAfter = try await count(database, table: "assets", column: "id", value: "a-keep")
        let keptFilesAfter = try await count(database, table: "asset_files", column: "id", value: "af-keep")
        #expect(otherAfter == 1)
        #expect(keptAssetsAfter == 1)
        #expect(keptFilesAfter == 1)
        #expect(await database.currentTransactionDepth == 0)
    }
}
