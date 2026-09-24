// Tests/GatherCoreTests/Store/ApplyScannedFilesTests.swift
// M2：AssetStore.applyScannedFiles 批级扫描回写（旧 IndexerService.swift 371-408）Store 级直测。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/ApplyScannedFiles (M2)")
struct ApplyScannedFilesTests {
    private let originalTimestamp = "2026-01-01T00:00:00.000Z"

    private func makeStore() async throws -> (SQLiteAssetStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "apply-scanned")
        return (SQLiteAssetStore(database: database), database, path)
    }

    /// 1 session + 1 asset_files + 1 photo（photo.asset_file_id 指向该文件）+ 1 asset_analysis 行。
    private func seed(_ database: SQLiteDatabase) async throws {
        try await database.run(
            "INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('s1', 'S', ?, ?)",
            [.text(originalTimestamp), .text(originalTimestamp)]
        )
        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES ('f1', 'dev:1', 'ino-old', '/photos/p1.jpg', 'p1.jpg', '', 'image',
                    100, 1000, 'old-checksum', 'offline', '2025-12-01T00:00:00.000Z', ?, ?)
            """,
            [.text(originalTimestamp), .text(originalTimestamp)]
        )
        try await database.run(
            """
            INSERT INTO photos
              (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms,
               status, asset_file_id, width, height, created_at, updated_at)
            VALUES ('p1', 's1', '/photos/p1.jpg', 'p1.jpg', 'old-photo-checksum', 1, 2,
                    'ready', 'f1', 10, 20, ?, ?)
            """,
            [.text(originalTimestamp), .text(originalTimestamp)]
        )
        try await database.run(
            """
            INSERT INTO asset_analysis
              (photo_id, asset_file_id, analysis_type, result_json, warnings_json,
               model_id, model_version, input_fingerprint, created_at, updated_at)
            VALUES ('p1', 'f1', 'quality', '{}', '[]', 'm1', 'v1', 'fp1', ?, ?)
            """,
            [.text(originalTimestamp), .text(originalTimestamp)]
        )
    }

    private func scanUpdate(
        assetFileId: String? = "f1",
        volumeId: String = "dev:2",
        fileIdentity: String = "ino-new",
        fileSize: Int64 = 2048,
        fileMtimeMs: Double = 1_750_000_000_999.5,
        checksum: String = "new-checksum",
        preserveChecksum: Bool = false,
        contentChanged: Bool = true,
        width: Int = 640,
        height: Int = 480
    ) -> AssetFileScanUpdate {
        AssetFileScanUpdate(
            assetFileId: assetFileId,
            volumeId: volumeId,
            fileIdentity: fileIdentity,
            fileSize: fileSize,
            fileMtimeMs: fileMtimeMs,
            checksum: checksum,
            preserveChecksum: preserveChecksum,
            contentChanged: contentChanged,
            width: width,
            height: height
        )
    }

    @Test func updatesScanFieldsRefreshesPhotoAndClearsAnalysis() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await seed(database)

        let photoIds = try await store.applyScannedFiles([scanUpdate()], sessionId: "s1")

        #expect(photoIds == ["p1"])
        let file = try await database.queryOne(
            """
            SELECT volume_id, file_identity, file_size, file_mtime_ms, checksum,
                   online_status, last_seen_at, updated_at
            FROM asset_files WHERE id = 'f1'
            """
        )
        #expect(file?.text("volume_id") == "dev:2")
        #expect(file?.text("file_identity") == "ino-new")
        #expect(file?.int("file_size") == 2048)
        #expect(file?.double("file_mtime_ms") == 1_750_000_000_999.5)
        #expect(file?.text("checksum") == "new-checksum")
        #expect(file?.text("online_status") == "online")
        let timestamp = file?.text("updated_at") ?? ""
        #expect(timestamp != originalTimestamp)
        #expect(file?.text("last_seen_at") == timestamp)

        let photo = try await database.queryOne(
            """
            SELECT checksum, checksum_file_size, checksum_file_mtime_ms, width, height, updated_at
            FROM photos WHERE id = 'p1'
            """
        )
        #expect(photo?.text("checksum") == "new-checksum")
        #expect(photo?.int("checksum_file_size") == 2048)
        #expect(photo?.double("checksum_file_mtime_ms") == 1_750_000_000_999.5)
        #expect(photo?.int("width") == 640)
        #expect(photo?.int("height") == 480)
        // 同一条 update 内 asset_files 与 photos 共用同一 timestamp（旧实现行为）。
        #expect(photo?.text("updated_at") == timestamp)

        let analysisRows = try await database.query(
            "SELECT id FROM asset_analysis WHERE asset_file_id = 'f1'"
        )
        #expect(analysisRows.isEmpty)

        let depth = await database.currentTransactionDepth
        #expect(depth == 0)
    }

    @Test func preserveChecksumAndUnchangedContentSkipPhotoRefreshAndAnalysisDelete() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await seed(database)

        let photoIds = try await store.applyScannedFiles(
            [scanUpdate(checksum: "ignored-checksum", preserveChecksum: true, contentChanged: false)],
            sessionId: "s1"
        )

        // contentChanged = false：旧实现不收集受影响照片、不刷新 photos、不清扫 analysis。
        #expect(photoIds.isEmpty)
        let file = try await database.queryOne(
            "SELECT file_size, checksum, online_status FROM asset_files WHERE id = 'f1'"
        )
        #expect(file?.int("file_size") == 2048)
        // preserveChecksum = 1：CASE WHEN 保留库内旧 checksum。
        #expect(file?.text("checksum") == "old-checksum")
        #expect(file?.text("online_status") == "online")

        let photo = try await database.queryOne(
            "SELECT checksum, width, height FROM photos WHERE id = 'p1'"
        )
        #expect(photo?.text("checksum") == "old-photo-checksum")
        #expect(photo?.int("width") == 10)
        #expect(photo?.int("height") == 20)

        let analysisRows = try await database.query(
            "SELECT id FROM asset_analysis WHERE asset_file_id = 'f1'"
        )
        #expect(analysisRows.count == 1)

        let depth = await database.currentTransactionDepth
        #expect(depth == 0)
    }

    @Test func updateWithoutAssetFileIdIsSkipped() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await seed(database)

        let photoIds = try await store.applyScannedFiles([scanUpdate(assetFileId: nil)], sessionId: "s1")

        #expect(photoIds.isEmpty)
        let file = try await database.queryOne(
            "SELECT file_size, checksum, online_status FROM asset_files WHERE id = 'f1'"
        )
        #expect(file?.int("file_size") == 100)
        #expect(file?.text("checksum") == "old-checksum")
        #expect(file?.text("online_status") == "offline")

        let photo = try await database.queryOne("SELECT width, height FROM photos WHERE id = 'p1'")
        #expect(photo?.int("width") == 10)
        #expect(photo?.int("height") == 20)

        let analysisRows = try await database.query(
            "SELECT id FROM asset_analysis WHERE asset_file_id = 'f1'"
        )
        #expect(analysisRows.count == 1)

        let depth = await database.currentTransactionDepth
        #expect(depth == 0)
    }
}
