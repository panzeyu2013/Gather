// Tests/GatherCoreTests/Store/AssetFileStatsBySessionTests.swift
// R1：AssetStore.assetFileStatsBySession 只读基线查询测试（IndexerService 扫描基线端口）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/AssetFileStatsBySession (R1)")
struct AssetFileStatsBySessionTests {
    @Test func returnsLinkedFileBaselineAndSkipsPhotoWithoutAssetFile() async throws {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset-file-stats")
        defer { removeStoreFiles(path) }
        let store = SQLiteAssetStore(database: database)

        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES ('f1', 'dev:1', '', '/photos/p1.nef', 'p1.nef', '', 'raw',
                    123456, 1750000000123.5, 'checksum-1', 'online', '',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, asset_file_id, created_at, updated_at)
            VALUES ('p1', 's1', '/photos/p1.nef', 'p1.nef', 'pending', 'f1',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, asset_file_id, created_at, updated_at)
            VALUES ('p2', 's1', '/photos/p2.nef', 'p2.nef', 'pending', NULL,
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )

        let baselines = try await store.assetFileStatsBySession(sessionId: "s1")

        #expect(baselines.count == 1)
        // 键为 asset_files.id（= photos.asset_file_id），与旧实现 join 键一致。
        #expect(
            baselines["f1"] == AssetFileScanBaseline(
                fileSize: 123456,
                mtimeMs: 1750000000123.5,
                checksum: "checksum-1"
            )
        )
        #expect(baselines["p1"] == nil)
        #expect(baselines["p2"] == nil)
    }

    @Test func returnsEmptyDictionaryForSessionWithoutLinkedFiles() async throws {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset-file-stats-empty")
        defer { removeStoreFiles(path) }
        let store = SQLiteAssetStore(database: database)

        let baselines = try await store.assetFileStatsBySession(sessionId: "missing")

        #expect(baselines.isEmpty)
    }
}
