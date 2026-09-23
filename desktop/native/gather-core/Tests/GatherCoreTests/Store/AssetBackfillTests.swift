// Tests/GatherCoreTests/Store/AssetBackfillTests.swift
// R1：AssetStore 回填路径测试（端口自 AssetRepoTests 的 backfillSession / listCandidates 用例）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/AssetStore backfill (R1)")
struct AssetBackfillTests {
    private func makeStore() async throws -> (SQLiteAssetStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset-backfill")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        return (SQLiteAssetStore(database: database), database, path)
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, filepath: String, checksum: String = "") async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, created_at, updated_at)
            VALUES (?, 's1', ?, ?, ?, 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(filepath), .text((filepath as NSString).lastPathComponent), .text(checksum)]
        )
    }

    private func backfillPair(_ store: SQLiteAssetStore, database: SQLiteDatabase, dir: String) async throws {
        let jpeg = try writeTempFile(in: dir, name: "DSC_0001.jpg")
        let nef = try writeTempFile(in: dir, name: "DSC_0001.nef")
        try await insertPhoto(database, id: "p1", filepath: jpeg)
        try await insertPhoto(database, id: "p2", filepath: nef)
        _ = try await store.backfillSession("s1")
    }

    private func count(_ database: SQLiteDatabase, _ sql: String) async throws -> Int64 {
        try await database.scalarInt(sql) ?? -1
    }

    @Test func backfillSessionMigratesPhotosAndCreatesRawJpegCandidate() async throws {
        let (store, database, path) = try await makeStore()
        let dir = try makeTempDir()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }

        let jpeg = try writeTempFile(in: dir, name: "DSC_0001.jpg")
        let nef = try writeTempFile(in: dir, name: "DSC_0001.nef")
        try await insertPhoto(database, id: "p1", filepath: jpeg, checksum: "abc")
        try await insertPhoto(database, id: "p2", filepath: nef, checksum: "def")

        let result = try await store.backfillSession("s1")
        #expect(result.migrated == 2)
        #expect(result.offline == 0)
        #expect(result.candidates == 1, "同目录同 stem 的 RAW/JPEG 生成一个候选")

        #expect(try await count(database, "SELECT COUNT(*) FROM asset_files") == 2)
        #expect(try await count(database, "SELECT COUNT(*) FROM assets") == 2)
        #expect(try await count(database, "SELECT COUNT(*) FROM asset_members") == 2)
        #expect(try await count(database, "SELECT COUNT(*) FROM session_assets") == 2)
        #expect(try await count(database, "SELECT COUNT(*) FROM sidecar_bindings") == 1, "同 stem 共享 XMP binding")
        #expect(try await count(database, "SELECT COUNT(*) FROM sidecar_binding_files") == 2)

        let jpegFile = try await database.queryOne(
            "SELECT extension, media_type, checksum, online_status FROM asset_files WHERE filename = 'DSC_0001.jpg'"
        )
        #expect(jpegFile?.text("extension") == ".jpg")
        #expect(jpegFile?.text("media_type") == "image")
        #expect(jpegFile?.text("checksum") == "abc")
        #expect(jpegFile?.text("online_status") == "online")

        let nefMember = try await database.queryOne(
            """
            SELECT member_role FROM asset_members am JOIN asset_files af ON af.id = am.file_id
            WHERE af.filename = 'DSC_0001.nef'
            """
        )
        #expect(nefMember?.text("member_role") == "raw")
        let jpegMember = try await database.queryOne(
            """
            SELECT member_role FROM asset_members am JOIN asset_files af ON af.id = am.file_id
            WHERE af.filename = 'DSC_0001.jpg'
            """
        )
        #expect(jpegMember?.text("member_role") == "camera_jpeg")

        let photoLink = try await database.queryOne("SELECT asset_id, asset_file_id FROM photos WHERE id = 'p1'")
        #expect(photoLink?.text("asset_id") != nil)
        #expect(photoLink?.text("asset_file_id") != nil)

        let state = try await database.queryOne(
            "SELECT status, migrated_photos, total_photos FROM asset_backfill_state WHERE session_id = 's1'"
        )
        #expect(state?.text("status") == "completed")
        #expect(state?.int("migrated_photos") == 2)
        #expect(state?.int("total_photos") == 2)

        let candidate = try await database.queryOne(
            "SELECT confidence, status FROM asset_link_candidates WHERE relation_type = 'raw_jpeg'"
        )
        #expect(candidate?.double("confidence") == 0.85, "唯一配对置信度 0.85")
        #expect(candidate?.text("status") == "pending")
    }

    @Test func backfillSessionOfflinePhotos() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        try await insertPhoto(database, id: "p1", filepath: "/nonexistent/1.jpg")
        try await insertPhoto(database, id: "p2", filepath: "/nonexistent/1.nef")

        let result = try await store.backfillSession("s1")
        #expect(result.migrated == 2)
        #expect(result.offline == 2)
        #expect(result.candidates == 1, "候选只依赖路径/扩展名，离线文件同样成对")

        let asset = try await database.queryOne("SELECT status FROM assets")
        #expect(asset?.text("status") == "offline_unverified")
        let volume = try await database.queryOne("SELECT volume_id FROM asset_files")
        #expect(volume?.text("volume_id")?.hasPrefix("dev:") == true, "stat 失败回退根目录 stat")
    }

    @Test func backfillSessionResumesFromCursorAndResetsWhenStuck() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }

        for index in 1...10 {
            try await insertPhoto(database, id: "p\(index)", filepath: "/gone/\(index).jpg")
        }
        try await database.run(
            """
            INSERT INTO asset_backfill_state (session_id, last_photo_rowid, total_photos, status, updated_at)
            VALUES ('s1', 10, 10, 'running', '2026-01-01T00:00:00.000Z')
            """
        )

        let result = try await store.backfillSession("s1")
        #expect(result.migrated == 10)
        let state = try await database.queryOne(
            "SELECT status, last_photo_rowid, migrated_photos FROM asset_backfill_state WHERE session_id = 's1'"
        )
        #expect(state?.text("status") == "completed")
        #expect(state?.int("last_photo_rowid") == 10)
        #expect(state?.int("migrated_photos") == 10)
    }

    @Test func listCandidatesWithAndWithoutSession() async throws {
        let (store, database, path) = try await makeStore()
        let dir = try makeTempDir()
        defer {
            removeStoreFiles(path)
            try? FileManager.default.removeItem(atPath: dir)
        }
        try await backfillPair(store, database: database, dir: dir)

        let all = try await store.listCandidates()
        #expect(all.count == 1)
        #expect(all[0].status == .pending)
        #expect(all[0].leftPath.hasSuffix(".nef"))
        #expect(all[0].rightPath.hasSuffix(".jpg"))
        #expect(all[0].confidence == 0.85)
        #expect(all[0].evidence["unambiguous"] == .bool(true))
        #expect(all[0].evidence["sameDirectory"] == .bool(true))

        #expect(try await store.listCandidates(sessionId: "s1").count == 1)
        #expect(try await store.listCandidates(sessionId: "other").isEmpty)
    }
}
