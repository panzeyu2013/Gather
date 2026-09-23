// Tests/GatherCoreTests/Store/AssetStoreMutationTests.swift
// R1：AssetStore 变更面测试（relink* 端口自 AssetRepoTests；
// accept/reject/reconcile 为 Store 级直测，backfill 完成后再补端到端端口）。
import Foundation
import Testing
@testable import GatherCore

@Suite("Store/AssetStore mutation (R1)")
struct AssetStoreMutationTests {
    private func makeStore() async throws -> (SQLiteAssetStore, SQLiteDatabase, String) {
        let (database, path) = try await makeMigratedStoreDatabase(label: "asset-mutation")
        try await database.run(
            """
            INSERT INTO sessions (id, name, created_at, updated_at)
            VALUES ('s1', 'S', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
        return (SQLiteAssetStore(database: database), database, path)
    }

    private func insertAssetFile(_ database: SQLiteDatabase, id: String, normalizedPath: String, checksum: String = "") async throws {
        try await database.run(
            """
            INSERT INTO asset_files
              (id, volume_id, file_identity, normalized_path, filename, extension, media_type,
               file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
            VALUES (?, 'dev:1', '', ?, ?, '', 'unknown', 0, 0, ?, 'online', '',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(normalizedPath), .text((normalizedPath as NSString).lastPathComponent), .text(checksum)]
        )
    }

    private func insertPhoto(_ database: SQLiteDatabase, id: String, filepath: String) async throws {
        try await database.run(
            """
            INSERT INTO photos (id, session_id, filepath, filename, status, created_at, updated_at)
            VALUES (?, 's1', ?, ?, 'pending', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """,
            [.text(id), .text(filepath), .text((filepath as NSString).lastPathComponent)]
        )
    }

    private func insertAsset(_ database: SQLiteDatabase, id: String) async throws {
        try await database.run(
            "INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at) VALUES (?, '', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')",
            [.text(id)]
        )
    }

    /// 两个独立资产（f1 raw / f2 jpeg）+ 一条 pending 候选。
    private func makeLinkedPair(_ database: SQLiteDatabase) async throws {
        try await insertAssetFile(database, id: "f1", normalizedPath: "/photos/DSC_0001.nef", checksum: "abc")
        try await insertAssetFile(database, id: "f2", normalizedPath: "/photos/DSC_0001.jpg", checksum: "def")
        try await insertPhoto(database, id: "p1", filepath: "/photos/DSC_0001.nef")
        try await insertPhoto(database, id: "p2", filepath: "/photos/DSC_0001.jpg")
        try await insertAsset(database, id: "a1")
        try await insertAsset(database, id: "a2")
        try await database.run("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'")
        try await database.run("UPDATE photos SET asset_id = 'a2', asset_file_id = 'f2' WHERE id = 'p2'")
        try await database.run(
            "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES ('a1', 'f1', 'raw', 1, 'import')"
        )
        try await database.run(
            "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES ('a2', 'f2', 'camera_jpeg', 1, 'import')"
        )
        try await database.run(
            "INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at) VALUES ('s1', 'a1', 'f1', 1, '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            "INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at) VALUES ('s1', 'a2', 'f2', 2, '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            """
            INSERT INTO asset_link_candidates
              (id, left_file_id, right_file_id, relation_type, confidence, evidence_json, status, created_at, updated_at)
            VALUES ('c1', 'f1', 'f2', 'raw_jpeg', 0.85, '{"unambiguous":true,"sameDirectory":true}', 'pending',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
            """
        )
    }

    @Test func acceptCandidateMergesAssets() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await makeLinkedPair(database)
        try await database.run(
            "INSERT INTO asset_backfill_state (session_id, last_photo_rowid, total_photos, status, updated_at) VALUES ('s1', 0, 2, 'completed', '2026-01-01T00:00:00.000Z')"
        )

        try await store.acceptCandidate("c1")
        #expect(try await store.listCandidates(sessionId: "s1")[0].status == .accepted)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM assets") == 1, "次资产被合并删除")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM asset_members") == 2)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM session_assets") == 1)
        #expect(try await database.query("SELECT DISTINCT asset_id FROM photos").count == 1)

        await #expect(throws: AssetStoreError.candidateNotFound) {
            try await store.acceptCandidate("missing")
        }
    }

    @Test func rejectCandidateWithoutAcceptKeepsAssetsSeparate() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await makeLinkedPair(database)

        try await store.rejectCandidate("c1")
        #expect(try await store.listCandidates(sessionId: "s1")[0].status == .rejected)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM assets") == 2, "拒绝未接受的候选不拆分资产")
        await #expect(throws: AssetStoreError.candidateNotFound) {
            try await store.rejectCandidate("missing")
        }
    }

    @Test func rejectAcceptedCandidateSplitsAsset() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await makeLinkedPair(database)

        try await store.acceptCandidate("c1")
        try await store.rejectCandidate("c1")

        #expect(try await store.listCandidates(sessionId: "s1")[0].status == .rejected)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM assets") == 2, "接受后拒绝 → 右文件拆回独立资产")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM session_assets") == 2)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM asset_members WHERE is_primary = 1") == 2)
    }

    @Test func reconcileRawJpegLinksMergesFullyEvidencedCandidates() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        try await makeLinkedPair(database)
        try await database.run(
            "INSERT INTO asset_backfill_state (session_id, last_photo_rowid, total_photos, status, updated_at) VALUES ('s1', 0, 2, 'completed', '2026-01-01T00:00:00.000Z')"
        )

        // 未匹配（无拍摄时间证据）→ 不合并。
        #expect(try await store.reconcileRawJpegLinks(sessionId: "s1") == 0)
        #expect(try await store.listCandidates(sessionId: "s1")[0].status == .pending)

        try await database.run(
            """
            INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken, camera_model, keywords, cached_at)
            VALUES ('p1', 's1', '2026-01-01T10:00:00.000Z', 'canon eos r5', '[]', '2026-01-01T00:00:00.000Z'),
                   ('p2', 's1', '2026-01-01T10:00:01.500Z', 'Canon EOS R5', '[]', '2026-01-01T00:00:00.000Z')
            """
        )

        #expect(try await store.reconcileRawJpegLinks(sessionId: "s1") == 1)
        let merged = try await store.listCandidates(sessionId: "s1")[0]
        #expect(merged.status == .accepted)
        #expect(merged.confidence == 1)
        #expect(merged.evidence["automatic"] == .bool(true))
        #expect(merged.evidence["cameraModel"]?.stringValue == "canon eos r5", "evidence 保留左侧原始相机串（trim 后）")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM assets") == 1)
        #expect(try await database.scalarInt(
            "SELECT automatic_merges FROM asset_backfill_state WHERE session_id = 's1'"
        ) == 1)
    }

    @Test func relinkRootRelocatesFilesPhotosAndSession() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let oldPath = oldRoot + "/DSC_0001.jpg"
        let newPath = try writeTempFile(in: newRoot, name: "DSC_0001.jpg")

        try await insertAssetFile(database, id: "f1", normalizedPath: oldPath, checksum: "abc")
        try await insertPhoto(database, id: "p1", filepath: oldPath)
        try await insertAsset(database, id: "a1")
        try await database.run("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'")
        try await database.run(
            "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES ('a1', 'f1', 'camera_jpeg', 1, 'import')"
        )
        try await database.run(
            "INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at) VALUES ('s1', 'a1', 'f1', 1, '2026-01-01T00:00:00.000Z')"
        )
        try await database.run("UPDATE sessions SET source_path = ? WHERE id = 's1'", [.text(oldRoot)])
        try await database.run(
            "INSERT INTO similarity_results (session_id, groups_json, param_threshold, created_at) VALUES ('s1', '[]', 1, '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            "INSERT INTO navigation_groups (id, session_id, group_type, created_at, updated_at) VALUES ('ng1', 's1', 'burst', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')"
        )

        let moved = try await store.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        #expect(moved.relocatedFiles == 1)
        #expect(moved.relocatedOutboxPaths.isEmpty)

        let file = try await database.queryOne(
            "SELECT normalized_path, filename, online_status, volume_id FROM asset_files WHERE id = 'f1'"
        )
        #expect(file?.text("normalized_path") == newPath)
        #expect(file?.text("filename") == "DSC_0001.jpg")
        #expect(file?.text("online_status") == "online")
        #expect(file?.text("volume_id")?.hasPrefix("dev:") == true)

        let photo = try await database.queryOne("SELECT filepath, filename, status FROM photos WHERE id = 'p1'")
        #expect(photo?.text("filepath") == newPath)
        #expect(photo?.text("filename") == "DSC_0001.jpg")
        #expect(photo?.text("status") == "pending")

        let session = try await database.queryOne("SELECT source_path, index_seq FROM sessions WHERE id = 's1'")
        #expect(session?.text("source_path") == newRoot)
        #expect(session?.int("index_seq") == 1, "重链接使 index_seq +1（相似度结果作废）")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM similarity_results") == 0)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM navigation_groups") == 0)
    }

    @Test func relinkRootRelocatesOutboxAndCollectsPaths() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let oldPath = oldRoot + "/DSC_0001.jpg"
        let newPath = try writeTempFile(in: newRoot, name: "DSC_0001.jpg")
        try await insertAssetFile(database, id: "f1", normalizedPath: oldPath, checksum: "abc")
        try await insertPhoto(database, id: "p1", filepath: oldPath)
        try await insertAsset(database, id: "a1")
        try await database.run("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'")
        try await database.run(
            "INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES ('a1', 'f1', 'camera_jpeg', 1, 'import')"
        )
        try await database.run(
            "INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at) VALUES ('s1', 'a1', 'f1', 1, '2026-01-01T00:00:00.000Z')"
        )
        try await database.run(
            """
            INSERT INTO metadata_outbox
              (xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json, dirty_fields,
               source_module, revision, persisted_revision, base_fingerprint, base_values_json,
               backup_path, status, attempt_count, error_message, updated_at)
            VALUES (?, 's1', 's1', ?, '{}', '[]', 'manual', 1, 0, '', '{}', '', 'pending', 1, '', '2026-01-01T00:00:00.000Z')
            """,
            [.text(oldRoot + "/DSC_0001.xmp"), .text(oldPath)]
        )
        try await database.run(
            "INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at) VALUES (?, 's1', '', '2026-01-01T00:00:00.000Z')",
            [.text(oldRoot + "/DSC_0001.xmp")]
        )

        let result = try await store.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        #expect(result.relocatedFiles == 1)
        #expect(result.relocatedOutboxPaths == [newRoot + "/DSC_0001.xmp"], "迁移回调改为返回值，不再用可变 sink")

        let outbox = try await database.queryOne(
            "SELECT photo_path, status, attempt_count FROM metadata_outbox WHERE xmp_path = ?",
            [.text(newRoot + "/DSC_0001.xmp")]
        )
        #expect(outbox != nil)
        #expect(outbox?.text("photo_path") == newPath)
        #expect(outbox?.text("status") == "pending")
        #expect(outbox?.int("attempt_count") == 0, "pending 行迁移时 attempt_count 归零")
        #expect(try await database.scalarInt(
            "SELECT COUNT(*) FROM metadata_outbox WHERE xmp_path = ?",
            [.text(oldRoot + "/DSC_0001.xmp")]
        ) == 0, "旧 outbox 行已删除")
    }

    @Test func relinkMovedFileByChecksum() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let oldPath = dir + "/gone.jpg"
        let newPath = try writeTempFile(in: dir, name: "IMG_0001.NEF")
        try await insertAssetFile(database, id: "f1", normalizedPath: oldPath, checksum: "same-checksum")
        try await database.run("UPDATE asset_files SET file_size = ?, file_mtime_ms = ? WHERE id = 'f1'", [.int(19), .real(0)])
        try await insertPhoto(database, id: "p1", filepath: oldPath)
        try await insertAsset(database, id: "a1")
        try await database.run("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'")

        let result = try await store.relinkMovedFile(
            newPath: newPath,
            checksum: "same-checksum",
            fileSize: 19,
            fileMtimeMs: 0
        )
        #expect(result != nil)
        #expect(result?.fileId == "f1")
        #expect(result?.photoIds == ["p1"])
        #expect(result?.relocatedOutboxPath == nil)

        let file = try await database.queryOne(
            "SELECT normalized_path, extension, online_status, volume_id FROM asset_files WHERE id = 'f1'"
        )
        #expect(file?.text("normalized_path") == newPath)
        #expect(file?.text("extension") == ".nef", "扩展名随新路径更新")
        #expect(file?.text("online_status") == "online")
        #expect(file?.text("volume_id")?.hasPrefix("dev:") == true)
        let photo = try await database.queryOne("SELECT filepath, status FROM photos WHERE id = 'p1'")
        #expect(photo?.text("filepath") == newPath)
        #expect(photo?.text("status") == "pending")
    }

    @Test func relinkMovedFileNoMatchReturnsNil() async throws {
        let (store, database, path) = try await makeStore()
        defer { removeStoreFiles(path) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let newPath = try writeTempFile(in: dir, name: "IMG_0001.jpg")
        try await insertAssetFile(database, id: "f1", normalizedPath: dir + "/other.jpg", checksum: "other-checksum")

        #expect(try await store.relinkMovedFile(newPath: newPath, checksum: "", fileSize: 0, fileMtimeMs: 0) == nil)
        #expect(try await store.relinkMovedFile(newPath: newPath, checksum: "nope", fileSize: 0, fileMtimeMs: 0) == nil)
        #expect(try await store.relinkMovedFile(
            newPath: dir + "/missing.jpg", checksum: "other-checksum", fileSize: 0, fileMtimeMs: 0
        ) == nil)
    }
}
