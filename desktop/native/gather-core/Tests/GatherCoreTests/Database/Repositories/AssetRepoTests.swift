// desktop/native/gather-core/Tests/GatherCoreTests/Database/Repositories/AssetRepoTests.swift
// TS 源: desktop/src/main/db/repositories/asset.repo.ts

import Foundation
import Testing
import GatherTestSupport
@testable import GatherProtocol
@testable import GatherPersistence

struct AssetRepoTests {
    private func makeRepo() throws -> (DBConnection, AssetRepo) {
        let db = try makeTestDB()
        try insertSession(db, "s1")
        return (db, AssetRepo(connection: db))
    }

    // ─────────────────────────── backfillSession ───────────────────────────

    @Test func backfillSessionMigratesPhotosAndCreatesRawJpegCandidate() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        let jpeg = try writeTempFile(in: dir, name: "DSC_0001.jpg")
        let nef = try writeTempFile(in: dir, name: "DSC_0001.nef")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: jpeg, checksum: "abc")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: nef, checksum: "def")

        let result = try repo.backfillSession("s1")
        #expect(result.migrated == 2)
        #expect(result.offline == 0)
        #expect(result.candidates == 1, "同目录同 stem 的 RAW/JPEG 生成一个候选")

        // asset_files / assets / asset_members / session_assets / photos 链接
        #expect(try rowCount(db, "SELECT COUNT(*) FROM asset_files") == 2)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM assets") == 2)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM asset_members") == 2)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM session_assets") == 2)
        // RAW/JPEG 同 stem 共享同一个 XMP sidecar → 同一 binding，两条 binding_files
        #expect(try rowCount(db, "SELECT COUNT(*) FROM sidecar_bindings") == 1)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM sidecar_binding_files") == 2)

        let jpegFile = try db.prepare("SELECT extension, media_type, checksum, online_status FROM asset_files WHERE filename = 'DSC_0001.jpg'").get()
        #expect(jpegFile?[0].textValue == ".jpg")
        #expect(jpegFile?[1].textValue == "image")
        #expect(jpegFile?[2].textValue == "abc")
        #expect(jpegFile?[3].textValue == "online")
        let nefMember = try db.prepare("SELECT member_role FROM asset_members am JOIN asset_files af ON af.id = am.file_id WHERE af.filename = 'DSC_0001.nef'").get()
        #expect(nefMember?[0].textValue == "raw")
        let jpegMember = try db.prepare("SELECT member_role FROM asset_members am JOIN asset_files af ON af.id = am.file_id WHERE af.filename = 'DSC_0001.jpg'").get()
        #expect(jpegMember?[0].textValue == "camera_jpeg")

        let photoLink = try db.prepare("SELECT asset_id, asset_file_id FROM photos WHERE id = 'p1'").get()
        #expect(photoLink?[0].textValue != nil)
        #expect(photoLink?[1].textValue != nil)

        let state = try db.prepare("SELECT status, migrated_photos, total_photos FROM asset_backfill_state WHERE session_id = 's1'").get()
        #expect(state?[0].textValue == "completed")
        #expect(state?[1].intValue == 2)
        #expect(state?[2].intValue == 2)

        let candidate = try db.prepare("""
            SELECT confidence, status FROM asset_link_candidates WHERE relation_type = 'raw_jpeg'
        """).get()
        #expect(candidate?[0].doubleValue == 0.85, "唯一配对置信度 0.85")
        #expect(candidate?[1].textValue == "pending")
    }

    // 缺陷④：配对召回只认 .jpg/.jpeg，实际存在的 RAW+HEIC（新机型）与
    // RAW+TIFF（机内渲染）完全召回不到。分类必须走同一份扩展名真相源。
    @Test func backfillSessionPairsRawWithHeicAndTiffCounterparts() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }

        let nef = try writeTempFile(in: dir, name: "IMG_0001.nef")
        let heic = try writeTempFile(in: dir, name: "IMG_0001.heic")
        let tiff = try writeTempFile(in: dir, name: "IMG_0002.tif")
        let cr3 = try writeTempFile(in: dir, name: "IMG_0002.cr3")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: nef)
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: heic)
        try insertPhoto(db, id: "p3", sessionId: "s1", filepath: tiff)
        try insertPhoto(db, id: "p4", sessionId: "s1", filepath: cr3)

        let result = try repo.backfillSession("s1")
        #expect(result.candidates == 2, "RAW+HEIC 与 RAW+TIFF 都必须生成候选")

        // 角色分类：HEIC 记 camera_jpeg，TIFF 记 rendered_tiff。
        let heicRole = try db.prepare("""
            SELECT member_role FROM asset_members am
            JOIN asset_files af ON af.id = am.file_id WHERE af.filename = 'IMG_0001.heic'
        """).get()
        #expect(heicRole?[0].textValue == "camera_jpeg")
        let tiffRole = try db.prepare("""
            SELECT member_role FROM asset_members am
            JOIN asset_files af ON af.id = am.file_id WHERE af.filename = 'IMG_0002.tif'
        """).get()
        #expect(tiffRole?[0].textValue == "rendered_tiff")

        // 证据里写清具体配对侧角色（手动确认时能看到是 RAW+HEIC 还是 RAW+TIFF）。
        let roles = try db.prepare("""
            SELECT evidence_json FROM asset_link_candidates
            WHERE relation_type = 'raw_jpeg' ORDER BY confidence DESC, id
        """).query().map { $0[0].textValue ?? "" }
        #expect(roles.count == 2)
        #expect(roles.contains { $0.contains("\"rightRole\":\"camera_jpeg\"") })
        #expect(roles.contains { $0.contains("\"rightRole\":\"rendered_tiff\"") })
    }

    @Test func backfillSessionOfflinePhotos() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: "/nonexistent/1.jpg")
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: "/nonexistent/1.nef")

        let result = try repo.backfillSession("s1")
        #expect(result.migrated == 2)
        #expect(result.offline == 2)
        // TS 同语义：候选只依赖 asset_files 路径/扩展名，离线文件同样成对
        #expect(result.candidates == 1)

        let asset = try db.prepare("SELECT status FROM assets").get()
        #expect(asset?[0].textValue == "offline_unverified")
        let volume = try db.prepare("SELECT volume_id FROM asset_files").get()
        // TS 同语义：文件 stat 失败 → 回退 stat(根目录)，根目录存在则仍为 dev: 前缀
        #expect(volume?[0].textValue?.hasPrefix("dev:") == true)
    }

    @Test func backfillSessionResumesFromCursorAndResetsWhenStuck() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        for index in 1...10 {
            try insertPhoto(db, id: "p\(index)", sessionId: "s1", filepath: "/gone/\(index).jpg")
        }
        // 预置 state：cursor 已过所有行（rowid ≤ 10 均未迁移）→ 首轮查询为空但 remaining>0 → cursor 归零重扫
        _ = try db.prepare("""
            INSERT INTO asset_backfill_state (session_id, last_photo_rowid, total_photos, status, updated_at)
            VALUES ('s1', 10, 10, 'running', '2026-01-01T00:00:00.000Z')
        """).run()

        let result = try repo.backfillSession("s1")
        #expect(result.migrated == 10)
        let state = try db.prepare("SELECT status, last_photo_rowid, migrated_photos FROM asset_backfill_state WHERE session_id = 's1'").get()
        #expect(state?[0].textValue == "completed")
        #expect(state?[1].intValue == 10)
        #expect(state?[2].intValue == 10)
    }

    // ─────────────────────────── listCandidates / listVolumes ───────────────────────────

    private func backfillPair(_ db: DBConnection, repo: AssetRepo, dir: String) throws {
        let jpeg = try writeTempFile(in: dir, name: "DSC_0001.jpg")
        let nef = try writeTempFile(in: dir, name: "DSC_0001.nef")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: jpeg)
        try insertPhoto(db, id: "p2", sessionId: "s1", filepath: nef)
        _ = try repo.backfillSession("s1")
    }

    @Test func listCandidatesWithAndWithoutSession() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        try backfillPair(db, repo: repo, dir: dir)

        let all = try repo.listCandidates()
        #expect(all.count == 1)
        let candidate = all[0]
        #expect(candidate.status == .pending)
        #expect(candidate.leftPath.hasSuffix(".nef"))
        #expect(candidate.rightPath.hasSuffix(".jpg"))
        #expect(candidate.confidence == 0.85)
        #expect(candidate.evidence["unambiguous"] == .bool(true))
        #expect(candidate.evidence["sameDirectory"] == .bool(true))

        let scoped = try repo.listCandidates(sessionId: "s1")
        #expect(scoped.count == 1)
        #expect(try repo.listCandidates(sessionId: "other").isEmpty)
    }

    @Test func listVolumesGroupsByVolume() throws {
        let (db, repo) = try makeRepo()
        defer { db.close() }

        try insertAssetFile(db, id: "f1", normalizedPath: "/Volumes/SSD/a.jpg")
        try insertAssetFile(db, id: "f2", normalizedPath: "/Volumes/SSD/b.jpg")
        try insertAssetFile(db, id: "f3", normalizedPath: "/Volumes/HDD/c.jpg", volumeId: "dev:2")
        _ = try db.prepare("UPDATE asset_files SET online_status = 'offline' WHERE id = 'f3'").run()

        let volumes = try repo.listVolumes()
        #expect(volumes.count == 2)
        let ssd = volumes.first { $0.volumeId == "dev:1" }
        #expect(ssd?.roots == ["/Volumes/SSD"])
        #expect(ssd?.onlineFiles == 2)
        #expect(ssd?.offlineFiles == 0)
        let hdd = volumes.first { $0.volumeId == "dev:2" }
        #expect(hdd?.offlineFiles == 1)
    }

    // ─────────────────────────── accept / reject / reconcile ───────────────────────────

    @Test func acceptCandidateMergesAssets() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        try backfillPair(db, repo: repo, dir: dir)

        let candidate = try repo.listCandidates(sessionId: "s1")[0]
        try repo.acceptCandidate(candidate.id)

        let updated = try repo.listCandidates(sessionId: "s1")[0]
        #expect(updated.status == .accepted)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM assets") == 1, "次资产被合并删除")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM asset_members") == 2)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM session_assets") == 1)
        let photoAssets = try db.prepare("SELECT DISTINCT asset_id FROM photos").query()
        #expect(photoAssets.count == 1)

        #expect(throws: PersistenceError(code: .ASSET_LINK_CANDIDATE_NOT_FOUND)) {
            try repo.acceptCandidate("missing")
        }
    }

    @Test func rejectCandidateMarksRejected() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        try backfillPair(db, repo: repo, dir: dir)

        let candidate = try repo.listCandidates(sessionId: "s1")[0]
        try repo.rejectCandidate(candidate.id)
        #expect(try repo.listCandidates(sessionId: "s1")[0].status == .rejected)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM assets") == 2, "拒绝未接受的候选不拆分资产")
        #expect(throws: PersistenceError(code: .ASSET_LINK_CANDIDATE_NOT_FOUND)) {
            try repo.rejectCandidate("missing")
        }
    }

    @Test func rejectAcceptedCandidateSplitsAsset() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        try backfillPair(db, repo: repo, dir: dir)

        let candidate = try repo.listCandidates(sessionId: "s1")[0]
        try repo.acceptCandidate(candidate.id)
        try repo.rejectCandidate(candidate.id)

        #expect(try repo.listCandidates(sessionId: "s1")[0].status == .rejected)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM assets") == 2, "接受后拒绝 → 右文件拆回独立资产")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM session_assets") == 2)
        let members = try db.prepare("SELECT COUNT(*) FROM asset_members WHERE is_primary = 1").get()
        #expect(members?[0].intValue == 2)
    }

    @Test func reconcileRawJpegLinksMergesFullyEvidencedCandidates() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        try backfillPair(db, repo: repo, dir: dir)
        // 未匹配 → 不合并
        #expect(try repo.reconcileRawJpegLinks("s1") == 0)
        #expect(try repo.listCandidates(sessionId: "s1")[0].status == .pending)

        // 时间差 ≤ 2s 且相机一致 → 自动合并
        _ = try db.prepare("""
            INSERT INTO photo_metadata_cache (photo_id, session_id, date_taken, camera_model, keywords, cached_at)
            VALUES ('p1', 's1', '2026-01-01T10:00:00.000Z', 'Canon EOS R5', '[]', '2026-01-01T00:00:00.000Z'),
                   ('p2', 's1', '2026-01-01T10:00:01.500Z', 'canon eos r5', '[]', '2026-01-01T00:00:00.000Z')
        """).run()

        #expect(try repo.reconcileRawJpegLinks("s1") == 1)
        let merged = try repo.listCandidates(sessionId: "s1")[0]
        #expect(merged.status == .accepted)
        #expect(merged.confidence == 1)
        #expect(merged.evidence["automatic"] == .bool(true))
        #expect(merged.evidence["cameraModel"]?.stringValue == "canon eos r5", "evidence 保留左侧文件的原始相机串（trim 后）")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM assets") == 1)
        let merges = try db.prepare("SELECT automatic_merges FROM asset_backfill_state WHERE session_id = 's1'").get()
        #expect(merges?[0].intValue == 1)
    }

    // ─────────────────────────── relinkRoot / relinkMovedFile ───────────────────────────

    @Test func relinkRootRelocatesFilesPhotosAndSession() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        // 旧路径文件不存在（已移动），新路径文件真实存在；
        // 身份按新路径的真实 (dev, ino) 登记 —— 同一物理文件移动后 inode 不变。
        let oldPath = oldRoot + "/DSC_0001.jpg"
        let newPath = try writeTempFile(in: newRoot, name: "DSC_0001.jpg")

        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: newPath, checksum: "abc")
        // 用真实 photos 行：插入新照片并直接链接
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        _ = try db.prepare("INSERT INTO assets (id, status, created_at, updated_at) VALUES ('a1', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')").run()
        _ = try db.prepare("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'").run()
        _ = try db.prepare("INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES ('a1', 'f1', 'camera_jpeg', 1, 'import')").run()
        _ = try db.prepare("INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at) VALUES ('s1', 'a1', 'f1', 1, '2026-01-01T00:00:00.000Z')").run()
        _ = try db.prepare("UPDATE sessions SET source_path = ? WHERE id = 's1'").run([.text(oldRoot)])
        _ = try db.prepare("INSERT INTO similarity_results (session_id, groups_json, param_threshold, created_at) VALUES ('s1', '[]', 1, '2026-01-01T00:00:00.000Z')").run()
        _ = try db.prepare("INSERT INTO navigation_groups (id, session_id, group_type, created_at, updated_at) VALUES ('ng1', 's1', 'burst', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')").run()

        let moved = try repo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        #expect(moved == 1)

        let file = try db.prepare("SELECT normalized_path, filename, online_status, volume_id FROM asset_files WHERE id = 'f1'").get()
        #expect(file?[0].textValue == newPath)
        #expect(file?[1].textValue == "DSC_0001.jpg")
        #expect(file?[2].textValue == "online")
        #expect(file?[3].textValue?.hasPrefix("dev:") == true)

        let photo = try db.prepare("SELECT filepath, filename, status FROM photos WHERE id = 'p1'").get()
        #expect(photo?[0].textValue == newPath)
        #expect(photo?[1].textValue == "DSC_0001.jpg")
        #expect(photo?[2].textValue == "pending")

        let session = try db.prepare("SELECT source_path, index_seq FROM sessions WHERE id = 's1'").get()
        #expect(session?[0].textValue == newRoot)
        #expect(session?[1].intValue == 1, "重链接使 index_seq +1（相似度结果作废）")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM similarity_results") == 0)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM navigation_groups") == 0)
    }

    /// 统一交付模型：deliveries.xmp_path/photo_path 随 relink 迁移，delivery_items
    /// 与 delivery_sessions 按 delivery_id 保持关联（S5c-2b-3b-1）。
    @Test func relinkRootRelocatesDeliveries() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let oldPath = oldRoot + "/DSC_0001.jpg"
        let newPath = try writeTempFile(in: newRoot, name: "DSC_0001.jpg")
        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: newPath, checksum: "abc")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        _ = try db.prepare("INSERT INTO assets (id, status, created_at, updated_at) VALUES ('a1', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')").run()
        _ = try db.prepare("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'").run()
        _ = try db.prepare("INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source) VALUES ('a1', 'f1', 'camera_jpeg', 1, 'import')").run()
        _ = try db.prepare("INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at) VALUES ('s1', 'a1', 'f1', 1, '2026-01-01T00:00:00.000Z')").run()

        let oldXmp = TSPath.xmpSidecarPath(oldPath)
        let newXmp = TSPath.xmpSidecarPath(newPath)
        let now = "2026-01-01T00:00:00.000Z"
        _ = try db.prepare("""
            INSERT INTO deliveries (xmp_path, photo_path, status, revision, base_fingerprint, base_values_json, backup_path, created_at, updated_at)
            VALUES (?, ?, 'written', 2, 'fp-old', '{}', '/backup/old.xmp', ?, ?)
          """).run([.text(oldXmp), .text(oldPath), .text(now), .text(now)])
        let deliveryId = db.lastInsertRowid
        _ = try db.prepare("""
            INSERT INTO delivery_items (delivery_id, photo_id, module, keywords, status, created_at, updated_at)
            VALUES (?, 'p1', 'culling', '["keep"]', 'written', ?, ?)
          """).run([.int(deliveryId), .text(now), .text(now)])
        _ = try db.prepare("""
            INSERT INTO delivery_sessions (delivery_id, session_id, created_at) VALUES (?, 's1', ?)
          """).run([.int(deliveryId), .text(now)])
        // 未完成 intent 的 xmp_path 与 payload 都必须随交付迁移，否则 replay 会走 alreadyGone。
        let intentPayload = "{\"xmpPath\":\"\(oldXmp)\",\"photoPath\":\"\(oldPath)\"}"
        _ = try db.prepare("""
            INSERT INTO delivery_intents (kind, xmp_path, phase, payload_json, error_message, created_at, updated_at)
            VALUES ('cleanup', ?, 'prepared', ?, '', ?, ?)
          """).run([.text(oldXmp), .text(intentPayload), .text(now), .text(now)])
        let intentId = db.lastInsertRowid

        #expect(try repo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot) == 1)
        let intent = try db.prepare("SELECT xmp_path, payload_json FROM delivery_intents WHERE id = ?")
            .get([.int(intentId)])
        #expect(intent?[0].textValue == newXmp)
        let payload = (intent?[1].textValue ?? "")
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(payload.contains(newXmp))
        #expect(!payload.contains(oldXmp))

        let delivery = try db.prepare("""
            SELECT id, xmp_path, photo_path, status, revision, base_fingerprint, backup_path
            FROM deliveries WHERE id = ?
          """).get([.int(deliveryId)])
        #expect(delivery?[1].textValue == newXmp)
        #expect(delivery?[2].textValue == newPath)
        #expect(delivery?[3].textValue == "written")
        #expect(delivery?[4].intValue == 2, "迁移用同一行 UPDATE，revision/租约/基线不重置")
        #expect(delivery?[5].textValue == "fp-old")
        #expect(delivery?[6].textValue == "/backup/old.xmp")
        #expect(try db.prepare("SELECT COUNT(*) FROM deliveries WHERE xmp_path = ?").get([.text(oldXmp)])?[0].intValue == 0)

        // 交付项与确认链接不改 delivery_id。
        let item = try db.prepare("""
            SELECT delivery_id, photo_id, module, status FROM delivery_items WHERE id = ?
          """).get([.int(deliveryId)])
        #expect(item?[0].intValue == deliveryId)
        #expect(item?[1].textValue == "p1")
        #expect(item?[2].textValue == "culling")
        #expect(item?[3].textValue == "written")
        #expect(try rowCount(db, "SELECT COUNT(*) FROM delivery_sessions") == 1)
    }

    /// 目标 XMP 已有交付行：沿用旧 outbox 冲突码且在事务内整体回滚。
    @Test func relinkRootRejectsDeliveryTargetConflict() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let oldPath = oldRoot + "/DSC_0001.jpg"
        let newPath = try writeTempFile(in: newRoot, name: "DSC_0001.jpg")
        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: newPath, checksum: "abc")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        let now = "2026-01-01T00:00:00.000Z"
        let oldXmp = TSPath.xmpSidecarPath(oldPath)
        let newXmp = TSPath.xmpSidecarPath(newPath)
        for (path, photo) in [(oldXmp, oldPath), (newXmp, newPath)] {
            _ = try db.prepare("""
                INSERT INTO deliveries (xmp_path, photo_path, status, revision, created_at, updated_at)
                VALUES (?, ?, 'pending', 0, ?, ?)
              """).run([.text(path), .text(photo), .text(now), .text(now)])
        }

        var code: GatherErrorCode?
        do {
            _ = try repo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        } catch let error as PersistenceError {
            code = error.code
        }
        #expect(code == .ASSET_RELINK_OUTBOX_CONFLICT)
        #expect(try db.prepare("SELECT COUNT(*) FROM deliveries WHERE xmp_path = ?").get([.text(oldXmp)])?[0].intValue == 1, "事务回滚后旧行仍在")
        #expect(try db.prepare("SELECT COUNT(*) FROM deliveries WHERE xmp_path = ?").get([.text(newXmp)])?[0].intValue == 1)
    }

    /// 交付行在飞（writing）与旧 outbox 的 busy 语义一致。
    @Test func relinkRootRejectsWritingDelivery() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let oldPath = oldRoot + "/DSC_0001.jpg"
        let newPath = try writeTempFile(in: newRoot, name: "DSC_0001.jpg")
        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: newPath, checksum: "abc")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        let now = "2026-01-01T00:00:00.000Z"
        _ = try db.prepare("""
            INSERT INTO deliveries (xmp_path, photo_path, status, revision, created_at, updated_at)
            VALUES (?, ?, 'writing', 1, ?, ?)
          """).run([.text(TSPath.xmpSidecarPath(oldPath)), .text(oldPath), .text(now), .text(now)])

        var code: GatherErrorCode?
        do {
            _ = try repo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        } catch let error as PersistenceError {
            code = error.code
        }
        #expect(code == .ASSET_RELINK_XMP_BUSY)
    }

    @Test func relinkMovedFileByChecksum() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let oldPath = dir + "/gone.jpg"
        let newPath = try writeTempFile(in: dir, name: "IMG_0001.NEF")
        try insertAssetFile(db, id: "f1", normalizedPath: oldPath, checksum: "same-checksum", volumeId: "dev:0")
        _ = try db.prepare("UPDATE asset_files SET file_size = ?, file_mtime_ms = ? WHERE id = 'f1'").run([.int(19), .real(0)])
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        _ = try db.prepare("INSERT INTO assets (id, status, created_at, updated_at) VALUES ('a1', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')").run()
        _ = try db.prepare("UPDATE photos SET asset_id = 'a1', asset_file_id = 'f1' WHERE id = 'p1'").run()

        // 旧路径文件不存在（已移动）→ checksum 匹配唯一
        let info = try db.prepare("SELECT file_size FROM asset_files WHERE id = 'f1'").get()
        let result = try repo.relinkMovedFile(
            newPath: newPath,
            checksum: "same-checksum",
            fileSize: info?[0].intValue ?? 19,
            fileMtimeMs: 0
        )
        #expect(result != nil)
        #expect(result?.fileId == "f1")
        #expect(result?.photoIds == ["p1"])

        let file = try db.prepare("SELECT normalized_path, extension, online_status, volume_id FROM asset_files WHERE id = 'f1'").get()
        #expect(file?[0].textValue == newPath)
        #expect(file?[1].textValue == ".nef", "扩展名随新路径更新")
        #expect(file?[2].textValue == "online")
        #expect(file?[3].textValue?.hasPrefix("dev:") == true)
        let photo = try db.prepare("SELECT filepath, status FROM photos WHERE id = 'p1'").get()
        #expect(photo?[0].textValue == newPath)
        #expect(photo?[1].textValue == "pending")
    }

    @Test func relinkMovedFileNoMatchReturnsNil() throws {
        let (db, repo) = try makeRepo()
        let dir = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let newPath = try writeTempFile(in: dir, name: "IMG_0001.jpg")
        try insertAssetFile(db, id: "f1", normalizedPath: dir + "/other.jpg", checksum: "other-checksum")

        // 无 checksum 且无 identity 匹配 → nil
        #expect(try repo.relinkMovedFile(newPath: newPath, checksum: "", fileSize: 0, fileMtimeMs: 0) == nil)
        // checksum 不匹配 → nil
        #expect(try repo.relinkMovedFile(newPath: newPath, checksum: "nope", fileSize: 0, fileMtimeMs: 0) == nil)
        // 新路径文件不存在 → nil
        #expect(try repo.relinkMovedFile(newPath: dir + "/missing.jpg", checksum: "other-checksum", fileSize: 0, fileMtimeMs: 0) == nil)
    }

    // ── 重链接安全：验证不过就不许改写（旧实现无条件改写）──

    @Test func relinkRootRejectsDirectoryWithSameNamesButDifferentFiles() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let wrongRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: wrongRoot)
        }
        // 旧根的真实文件（登记身份）随后被删除。
        let oldPath = oldRoot + "/DSC_0001.jpg"
        try Data("original-content".utf8).write(to: URL(fileURLWithPath: oldPath))
        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: oldPath, checksum: "abc")
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'f1' WHERE id = 'p1'").run()
        _ = try db.prepare("INSERT INTO similarity_results (session_id, groups_json, param_threshold, created_at) VALUES ('s1', '[]', 1, '2026-01-01T00:00:00.000Z')").run()
        try FileManager.default.removeItem(atPath: oldPath)

        // 用户选错目录：同名文件，但内容/大小/mtime/inode 都不是同一个。
        _ = try writeTempFile(
            in: wrongRoot,
            name: "DSC_0001.jpg",
            content: Data("a different photo entirely with other bytes".utf8)
        )

        #expect(throws: (any Error).self) {
            _ = try repo.relinkRoot(oldRoot: oldRoot, newRoot: wrongRoot)
        }
        // 原状完全不变：路径未改写，会话分析结果未被作废。
        let file = try db.prepare("SELECT normalized_path, volume_id FROM asset_files WHERE id = 'f1'").get()
        #expect(file?[0].textValue == oldPath)
        #expect(file?[1].textValue != "dev:0")
        let photo = try db.prepare("SELECT filepath, status FROM photos WHERE id = 'p1'").get()
        #expect(photo?[0].textValue == oldPath)
        #expect(try rowCount(db, "SELECT COUNT(*) FROM similarity_results") == 1)
    }

    // ── E-02：relinkRoot 的 checksum 证据经 Persistence 的 FileHasher（原调 Domain）──

    @Test func relinkRootVerifiesMovedFileByChecksum() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let content = Data("same-bytes-0123456789".utf8)
        let oldPath = oldRoot + "/DSC_0001.jpg"
        try content.write(to: URL(fileURLWithPath: oldPath))
        // 固定旧文件 mtime：保证新位置的 mtime 一定不同，只能靠 checksum 验证。
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: oldPath
        )
        let checksum = try FileHasher.sha256File(oldPath)
        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: oldPath, checksum: checksum)
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'f1' WHERE id = 'p1'").run()

        // 移动：同内容同大小落到新根，但 inode 与 mtime 都变了 → 只有 checksum 证据成立。
        try FileManager.default.removeItem(atPath: oldPath)
        let newPath = newRoot + "/DSC_0001.jpg"
        try content.write(to: URL(fileURLWithPath: newPath))

        #expect(try repo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot) == 1)
        let file = try db.prepare("SELECT normalized_path FROM asset_files WHERE id = 'f1'").get()
        #expect(file?[0].textValue == newPath)
        let photo = try db.prepare("SELECT filepath FROM photos WHERE id = 'p1'").get()
        #expect(photo?[0].textValue == newPath)
    }

    @Test func relinkRootRejectsSameSizeDifferentChecksum() throws {
        let (db, repo) = try makeRepo()
        let oldRoot = try makeTempDir()
        let newRoot = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: oldRoot)
            try? FileManager.default.removeItem(atPath: newRoot)
        }
        let content = Data("same-bytes-0123456789".utf8)
        let oldPath = oldRoot + "/DSC_0001.jpg"
        try content.write(to: URL(fileURLWithPath: oldPath))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: oldPath
        )
        let checksum = try FileHasher.sha256File(oldPath)
        try insertTrackedFile(db, id: "f1", storedPath: oldPath, statPath: oldPath, checksum: checksum)
        try insertPhoto(db, id: "p1", sessionId: "s1", filepath: oldPath)
        _ = try db.prepare("UPDATE photos SET asset_file_id = 'f1' WHERE id = 'p1'").run()

        // 同大小、不同字节（新位置 inode/mtime 都不同）→ sha256 不匹配，必须拒绝改写。
        try FileManager.default.removeItem(atPath: oldPath)
        try Data("same-bytes-012345678X".utf8).write(
            to: URL(fileURLWithPath: newRoot + "/DSC_0001.jpg")
        )

        #expect(throws: (any Error).self) {
            _ = try repo.relinkRoot(oldRoot: oldRoot, newRoot: newRoot)
        }
        let file = try db.prepare("SELECT normalized_path FROM asset_files WHERE id = 'f1'").get()
        #expect(file?[0].textValue == oldPath, "验证不过就不许改写")
    }

    @Test func relinkRootRejectsSameRootAndNestedRoots() throws {
        let (db, repo) = try makeRepo()
        let root = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: root)
        }
        let nested = root + "/inner"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { _ = try repo.relinkRoot(oldRoot: root, newRoot: root) }
        #expect(throws: (any Error).self) { _ = try repo.relinkRoot(oldRoot: root, newRoot: nested) }
        #expect(throws: (any Error).self) { _ = try repo.relinkRoot(oldRoot: nested, newRoot: root) }
    }

    @Test func relinkRootReportsWhenNothingIsRegisteredUnderTheRoot() throws {
        let (db, repo) = try makeRepo()
        let root = try makeTempDir()
        let other = try makeTempDir()
        defer {
            db.close()
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: other)
        }
        #expect(throws: (any Error).self) { _ = try repo.relinkRoot(oldRoot: root, newRoot: other) }
    }
}
