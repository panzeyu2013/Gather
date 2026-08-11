// desktop/native/gather-core/Tests/GatherCoreTests/Services/IndexerServiceTests.swift
// IndexerService 行为测试（Phase 3.0）。
// TS 源: tests/unit/services/indexer/*（index-seq / index-lazy-checksum /
// index-ghost-photo / index-backfill-regression，用例逐一对应）。
// 差异说明：
// - TS 用 repo mock 断言调用；Swift 侧全部走真实临时 SQLite + 迁移 + 真实
//   临时文件（行为级断言：DB 状态 + 结果计数），stat 经 indexer.stat 接缝注入
//   （TS 同款 ghost-photo 竞态测试）。
// - 并发写入竞态（backfill 与 scan 的 checksum 守卫）经 fileHasher 接缝模拟
//   并发写入者（TS 用 mock statement 的 changes=0 路径）。

import Foundation
import Testing
@testable import GatherCore

// MARK: - 支撑

private func sha256Hex(_ content: String) -> String {
    SHA256.hash(Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct IndexerHarness {
    let db: DBConnection
    let indexer: IndexerService
    let sessionRepo: SessionRepo
    let sessionId: String
}

private func makeHarness(
    root: String,
    lazyChecksum: String = "true",
    getDimensions: @escaping IndexerService.DimensionsProvider = { _ in (100, 80) }
) throws -> IndexerHarness {
    let db = try makeMigratedDB()
    let sessionRepo = SessionRepo(connection: db)
    let session = try sessionRepo.create(name: "Index", source: "folder", sourcePath: root)
    let indexer = IndexerService(
        connection: db,
        sessionRepo: sessionRepo,
        photoRepo: PhotoRepo(connection: db),
        assetRepo: AssetRepo(connection: db),
        getDimensions: getDimensions,
        getSetting: { key, defaultValue in
            key == "lazy_checksum" ? lazyChecksum : defaultValue
        }
    )
    return IndexerHarness(db: db, indexer: indexer, sessionRepo: sessionRepo, sessionId: session.id)
}

/// asset_files 行（含 volume/identity，供 relink 按真实 inode 匹配）。
private func insertAssetFileRow(
    _ db: DBConnection,
    id: String,
    filepath: String,
    fileSize: Int64,
    fileMtimeMs: Double,
    checksum: String,
    volumeId: String = "dev:1",
    fileIdentity: String? = nil
) throws {
    // 默认 identity 按文件路径派生（UNIQUE(volume_id, file_identity)，不同
    // 文件不得共用；TS 源为 stat().ino）。
    let identity = fileIdentity ?? "ino-\(id)"
    _ = try db.prepare("""
        INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '.jpg', 'image', ?, ?, ?, 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(id), .text(volumeId), .text(identity), .text(filepath),
        .text((filepath as NSString).lastPathComponent),
        .int(fileSize), .real(fileMtimeMs), .text(checksum),
    ])
}

/// photos 行（asset_file_id 可空）。
private func insertPhotoRow(
    _ db: DBConnection,
    id: String,
    sessionId: String,
    filepath: String,
    assetFileId: String?,
    checksum: String = "",
    status: String = "pending",
    checksumFileSize: Int = 0,
    checksumFileMtimeMs: Double = 0
) throws {
    _ = try db.prepare("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}', '{}', NULL, ?, 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([
        .text(id), .text(sessionId), .text(filepath),
        .text((filepath as NSString).lastPathComponent),
        .text(checksum), .int(Int64(checksumFileSize)), .real(checksumFileMtimeMs),
        .text(status), assetFileId.map { .text($0) } ?? .null,
    ])
}

/// 完整资产链（backfill 收敛用例需要 asset_members / session_assets）。
private func insertFullAssetChain(
    _ db: DBConnection,
    assetFileId: String,
    assetId: String,
    sessionId: String,
    filepath: String,
    fileSize: Int64,
    fileMtimeMs: Double,
    checksum: String
) throws {
    _ = try db.prepare("""
        INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
        VALUES (?, '', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """).run([.text(assetId)])
    try insertAssetFileRow(db, id: assetFileId, filepath: filepath, fileSize: fileSize, fileMtimeMs: fileMtimeMs, checksum: checksum)
    _ = try db.prepare("""
        INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source)
        VALUES (?, ?, 'camera_jpeg', 1, 'import')
      """).run([.text(assetId), .text(assetFileId)])
    _ = try db.prepare("""
        INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
        VALUES (?, ?, ?, 0, '2026-01-01T00:00:00.000Z')
      """).run([.text(sessionId), .text(assetId), .text(assetFileId)])
}

private func photoChecksum(_ db: DBConnection, _ photoId: String) throws -> String? {
    try db.prepare("SELECT checksum FROM photos WHERE id = ?").get([.text(photoId)])?[0].textValue
}

private func assetFileChecksum(_ db: DBConnection, _ assetFileId: String) throws -> String? {
    try db.prepare("SELECT checksum FROM asset_files WHERE id = ?").get([.text(assetFileId)])?[0].textValue
}

// MARK: - index_seq 提交点（TS index-seq.test.ts 逐条对应）

@Suite("IndexService index_seq commit point")
struct IndexSeqTests {
    @Test("bumps index_seq once when the scan added a photo")
    func bumpsOnAdd() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("content".utf8).write(to: URL(fileURLWithPath: root + "/new.jpg"))
        let harness = try makeHarness(root: root)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 1)
        #expect(result.added == 1)
        #expect(result.missing == 0)
        #expect(result.failed.isEmpty)
        // markMissing([]) 语义：无照片被标记缺失。
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE status = 'missing'") == 0)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)
        // 新照片行已入库。
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(harness.sessionId)]) == 1)
    }

    @Test("bumps index_seq when an existing photo content changed")
    func bumpsOnContentChange() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let harness = try makeHarness(root: root)
        // 无 asset_files 行：扫描把照片自身的 checksum 基线视为不可用 → 判定变化。
        try insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 1)
        #expect(result.skipped == 0)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)
    }

    @Test("bumps index_seq when a photo is relinked to a new path")
    func bumpsOnRelink() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let newPath = root + "/moved.jpg"
        let oldPath = root + "/old-name.jpg"
        let content = "relinked-content"
        try Data(content.utf8).write(to: URL(fileURLWithPath: newPath))
        let fileStat = try IndexerService.defaultStat(newPath)
        let hash = sha256Hex(content)
        let harness = try makeHarness(root: root, lazyChecksum: "false")
        // asset_files 行指向旧路径，但 volume/identity 与真实文件匹配
        // （relinkMovedFile 按 inode 找到它）。
        try insertAssetFileRow(
            harness.db, id: "file-old", filepath: oldPath,
            fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: hash,
            volumeId: "dev:\(fileStat.dev)", fileIdentity: String(fileStat.ino)
        )
        try insertPhotoRow(harness.db, id: "relinked", sessionId: harness.sessionId, filepath: oldPath, assetFileId: "file-old")

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 1)
        #expect(result.skipped == 1)
        #expect(result.missing == 0)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)
        // 照片被重链接到新路径而非新增。
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(harness.sessionId)]) == 1)
        let row = try harness.db.prepare("SELECT filepath FROM photos WHERE id = 'relinked'").get()
        #expect(row?[0].textValue == newPath)
    }

    @Test("does NOT bump index_seq when the scan changed nothing")
    func noBumpWhenUnchanged() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let fileStat = try IndexerService.defaultStat(photoPath)
        let harness = try makeHarness(root: root)
        try insertAssetFileRow(harness.db, id: "af-1", filepath: photoPath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: "checksum-1")
        try insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: "af-1")

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 1)
        #expect(result.skipped == 1)
        #expect(result.missing == 0)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 0)
    }

    @Test("bumps index_seq when a photo disappears from disk (missing reconcile)")
    func bumpsOnMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        // 照片行存在但文件已删除。
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        try FileManager.default.removeItem(atPath: photoPath)
        let harness = try makeHarness(root: root)
        try insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 0)
        #expect(result.missing == 1)
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE status = 'missing'") == 1)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)
    }

    @Test("does NOT bump index_seq on repeated scans when a photo has no asset_files row and the file is unchanged")
    func noBumpOnRepeatedScansWithoutAssetRow() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let harness = try makeHarness(root: root)
        // 照片从未回填到 asset_files：扫描没有 asset_files 基线可比较。
        try insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)

        // 首次观测提交尺寸/checksum stat，是真实变化。
        _ = try await harness.indexer.scanSession(sessionId: harness.sessionId)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)

        // 重扫未变化文件只重写相同值：缺失 asset_files 行不得让每次重扫
        // 都变成 content change 无限 bump。
        let second = try await harness.indexer.scanSession(sessionId: harness.sessionId)
        #expect(second.missing == 0)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)
    }

    @Test("bumps index_seq when an unbackfilled photo content actually changes")
    func bumpsWhenUnbackfilledContentChanges() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let originalStat = try IndexerService.defaultStat(photoPath)
        let harness = try makeHarness(root: root)
        try insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)
        // 模拟上次扫描提交的索引基线（无 asset_files 行，照片行自带基线）。
        _ = try harness.db.prepare("""
            UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
            WHERE id = 'photo-1'
          """).run([
            .text("hash-1"), .int(originalStat.size), .real(originalStat.mtimeMs),
        ])
        // 磁盘文件与索引基线不同。
        try Data("different-content-with-another-size".utf8).write(to: URL(fileURLWithPath: photoPath))

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 1)
        #expect(try harness.sessionRepo.getIndexSeq(id: harness.sessionId) == 1)
    }
}

// MARK: - 懒 checksum（TS index-lazy-checksum.test.ts 逐条对应）

@Suite("IndexService lazy checksum")
struct LazyChecksumTests {
    private struct Fixture {
        let root: String
        let newPath: String
        let changedPath: String
        let untouchedPath: String
        let newContent: String
        let changedContent: String
        let untouchedContent: String
    }

    private func makeFixture() throws -> Fixture {
        let root = try makeTempDir()
        let newPath = root + "/new.jpg"
        let changedPath = root + "/changed.jpg"
        let untouchedPath = root + "/untouched.jpg"
        let newContent = "new-content"
        let changedContent = "changed-content"
        let untouchedContent = "untouched-content"
        try Data(newContent.utf8).write(to: URL(fileURLWithPath: newPath))
        try Data(changedContent.utf8).write(to: URL(fileURLWithPath: changedPath))
        try Data(untouchedContent.utf8).write(to: URL(fileURLWithPath: untouchedPath))
        return Fixture(
            root: root, newPath: newPath, changedPath: changedPath, untouchedPath: untouchedPath,
            newContent: newContent, changedContent: changedContent, untouchedContent: untouchedContent
        )
    }

    private func seedExistingPhotos(_ harness: IndexerHarness, _ fixture: Fixture) throws {
        let untouchedStat = try IndexerService.defaultStat(fixture.untouchedPath)
        // changed 的 asset_files 行基线是假的（大小/时间错位 → 内容判定变化）。
        try insertAssetFileRow(harness.db, id: "file-changed", filepath: fixture.changedPath, fileSize: 1, fileMtimeMs: 1, checksum: "")
        try insertAssetFileRow(harness.db, id: "file-untouched", filepath: fixture.untouchedPath, fileSize: untouchedStat.size, fileMtimeMs: untouchedStat.mtimeMs, checksum: "")
        try insertPhotoRow(harness.db, id: "changed", sessionId: harness.sessionId, filepath: fixture.changedPath, assetFileId: "file-changed")
        try insertPhotoRow(harness.db, id: "untouched", sessionId: harness.sessionId, filepath: fixture.untouchedPath, assetFileId: "file-untouched")
    }

    @Test("skips hashing and records an empty checksum when lazy_checksum is enabled")
    func lazySkipsHashing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let harness = try makeHarness(root: fixture.root, lazyChecksum: "true")
        try seedExistingPhotos(harness, fixture)
        let changedStat = try IndexerService.defaultStat(fixture.changedPath)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.discovered == 3)
        #expect(result.added == 1)
        #expect(result.missing == 0)
        // 新文件：空 checksum 入库。
        let newRow = try harness.db.prepare("SELECT filepath, checksum FROM photos WHERE id = (SELECT id FROM photos WHERE filepath = ?)").get([.text(fixture.newPath)])
        #expect(newRow?[1].textValue == "")
        // 内容变化的照片：写空 checksum + 新鲜 stat。
        let changedRow = try harness.db.prepare("SELECT checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'changed'").get()
        #expect(changedRow?[0].textValue == "")
        #expect(changedRow?[1].intValue == changedStat.size)
        #expect(abs((changedRow?[2].doubleValue ?? 0) - changedStat.mtimeMs) < 1)
        // 未变化照片（快照 checksum 为空）：懒模式不得写入空值覆盖并发回填结果。
        let untouchedRow = try harness.db.prepare("SELECT checksum, checksum_file_size FROM photos WHERE id = 'untouched'").get()
        #expect(untouchedRow?[0].textValue == "")
        #expect(untouchedRow?[1].intValue == 0)
    }

    @Test("computes checksums synchronously when lazy_checksum is disabled")
    func nonLazyHashes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let harness = try makeHarness(root: fixture.root, lazyChecksum: "false")
        try seedExistingPhotos(harness, fixture)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.added == 1)
        let newRow = try harness.db.prepare("SELECT checksum FROM photos WHERE filepath = ?").get([.text(fixture.newPath)])
        #expect(newRow?[0].textValue == sha256Hex(fixture.newContent))
        #expect(try photoChecksum(harness.db, "changed") == sha256Hex(fixture.changedContent))
        #expect(try photoChecksum(harness.db, "untouched") == sha256Hex(fixture.untouchedContent))
    }
}

// MARK: - ghost photo 竞态（TS index-ghost-photo.test.ts 逐条对应）

@Suite("IndexService incremental scan ghost photos")
struct GhostPhotoTests {
    /// 只对 ghost 路径抛错的 stat 接缝（模拟目录列举与 stat 之间的 TOCTOU 竞态）。
    private func makeStatSeam(ghostPath: String) -> (String) throws -> IndexerService.FileStat {
        let realStat = IndexerService.defaultStat
        return { path in
            if path == ghostPath {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }
            return try realStat(path)
        }
    }

    @Test("marks a file missing when it disappears between directory listing and stat")
    func ghostMarkedMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ghostPath = root + "/ghost.jpg"
        let okPath = root + "/ok.jpg"
        try Data("ghost-content".utf8).write(to: URL(fileURLWithPath: ghostPath))
        try Data("ok-content".utf8).write(to: URL(fileURLWithPath: okPath))
        let harness = try makeHarness(root: root)
        let ghostStat = try IndexerService.defaultStat(ghostPath)
        let okStat = try IndexerService.defaultStat(okPath)
        try insertAssetFileRow(harness.db, id: "file-ghost", filepath: ghostPath, fileSize: ghostStat.size, fileMtimeMs: ghostStat.mtimeMs, checksum: "c-ghost")
        try insertAssetFileRow(harness.db, id: "file-ok", filepath: okPath, fileSize: okStat.size, fileMtimeMs: okStat.mtimeMs, checksum: "c-ok")
        try insertPhotoRow(harness.db, id: "ghost", sessionId: harness.sessionId, filepath: ghostPath, assetFileId: "file-ghost")
        try insertPhotoRow(harness.db, id: "ok", sessionId: harness.sessionId, filepath: okPath, assetFileId: "file-ok")
        harness.indexer.stat = makeStatSeam(ghostPath: ghostPath)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.missing == 1)
        #expect(result.failed.isEmpty)
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'ghost' AND status = 'missing'") == 1)
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'ok' AND status = 'missing'") == 0)
    }

    @Test("does not mark a relinked photo as missing when it reappears at a new path")
    func relinkNotMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let newPath = root + "/moved.jpg"
        let oldPath = root + "/old-name.jpg"
        let ghostPath = root + "/ghost.jpg"
        // 文件已物理移动：磁盘上只有新路径。
        try Data("relinked-content".utf8).write(to: URL(fileURLWithPath: newPath))
        try Data("ghost-content".utf8).write(to: URL(fileURLWithPath: ghostPath))
        let harness = try makeHarness(root: root)
        let newStat = try IndexerService.defaultStat(newPath)
        let ghostStat = try IndexerService.defaultStat(ghostPath)
        // 旧资产行按真实 inode 匹配新路径文件（relink 依据）。
        try insertAssetFileRow(
            harness.db, id: "file-old", filepath: oldPath,
            fileSize: newStat.size, fileMtimeMs: newStat.mtimeMs, checksum: "c-old",
            volumeId: "dev:\(newStat.dev)", fileIdentity: String(newStat.ino)
        )
        try insertAssetFileRow(harness.db, id: "file-ghost", filepath: ghostPath, fileSize: ghostStat.size, fileMtimeMs: ghostStat.mtimeMs, checksum: "c-ghost")
        try insertPhotoRow(harness.db, id: "relinked", sessionId: harness.sessionId, filepath: oldPath, assetFileId: "file-old")
        try insertPhotoRow(harness.db, id: "ghost", sessionId: harness.sessionId, filepath: ghostPath, assetFileId: "file-ghost")
        harness.indexer.stat = makeStatSeam(ghostPath: ghostPath)

        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.missing == 1)
        #expect(result.skipped == 1)
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'ghost' AND status = 'missing'") == 1)
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'relinked' AND status = 'missing'") == 0)
    }
}

// MARK: - checksum 回填（TS index-backfill-regression.test.ts 逐条对应）

@Suite("IndexService checksum backfill")
struct ChecksumBackfillTests {
    @Test("writes the backfilled checksum into asset_files so a later full scan keeps it")
    func backfillConvergesWithScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let filePath = root + "/photo.jpg"
        let content = "backfill-then-rescan"
        try Data(content.utf8).write(to: URL(fileURLWithPath: filePath))
        let fileStat = try IndexerService.defaultStat(filePath)
        let checksum = sha256Hex(content)
        let harness = try makeHarness(root: root, lazyChecksum: "true")
        // 懒首扫遗留状态：photos.checksum 空、asset_files.checksum 空。
        try insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: filePath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: ""
        )
        _ = try harness.db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('photo-1', ?, ?, 'photo.jpg', '', 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(harness.sessionId), .text(filePath)])

        let backfill = try await harness.indexer.backfillChecksums(sessionId: harness.sessionId)
        #expect(backfill.processed == 1)
        #expect(backfill.backfilled == 1)
        #expect(backfill.skipped == 0)
        let assetFile = try harness.db.prepare(
            "SELECT checksum, file_size, file_mtime_ms FROM asset_files WHERE id = 'af-1'"
        ).get()
        #expect(assetFile?[0].textValue == checksum)
        #expect(assetFile?[1].intValue == fileStat.size)
        #expect(abs((assetFile?[2].doubleValue ?? 0) - fileStat.mtimeMs) < 1)

        // 第二次全量扫描必须命中 unchanged 路径：不再写 checksum，无待回填。
        let scan = try await harness.indexer.scanSession(sessionId: harness.sessionId)
        #expect(scan.discovered == 1)
        #expect(scan.skipped == 1)
        #expect(try photoChecksum(harness.db, "photo-1") == checksum)
        #expect(try assetFileChecksum(harness.db, "af-1") == checksum)
        #expect(try harness.indexer.pendingChecksums(sessionId: harness.sessionId) == 0)
    }

    @Test("terminates when a photo cannot be read, leaving its checksum empty")
    func terminatesOnUnreadable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let goodPath = root + "/good.jpg"
        let content = "good-content"
        try Data(content.utf8).write(to: URL(fileURLWithPath: goodPath))
        let badPath = root + "/deleted.jpg"
        let harness = try makeHarness(root: root)
        try insertPhotoRow(harness.db, id: "good", sessionId: harness.sessionId, filepath: goodPath, assetFileId: nil)
        try insertPhotoRow(harness.db, id: "bad", sessionId: harness.sessionId, filepath: badPath, assetFileId: nil)

        let result = try await harness.indexer.backfillChecksums(sessionId: harness.sessionId)

        // 不可读照片记入失败集、排除后续趟次，任务完成而非无限重试。
        #expect(result.processed == 2)
        #expect(result.backfilled == 1)
        #expect(result.skipped == 1)
        #expect(try photoChecksum(harness.db, "good") == sha256Hex(content))
        #expect(try photoChecksum(harness.db, "bad") == "")
    }

    @Test("stops after a pass with zero successes instead of spinning")
    func stopsOnZeroSuccess() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = try makeHarness(root: root)
        try insertPhotoRow(harness.db, id: "bad-1", sessionId: harness.sessionId, filepath: root + "/gone-1.jpg", assetFileId: nil)
        try insertPhotoRow(harness.db, id: "bad-2", sessionId: harness.sessionId, filepath: root + "/gone-2.jpg", assetFileId: nil)

        let result = try await harness.indexer.backfillChecksums(sessionId: harness.sessionId)

        #expect(result.processed == 2)
        #expect(result.backfilled == 0)
        #expect(result.skipped == 2)
    }

    @Test("does not clear a stored checksum when the scan snapshot is stale (lazy mode)")
    func preservesStoredChecksumOnStaleSnapshot() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let filePath = root + "/photo.jpg"
        let content = "already-hashed-content"
        try Data(content.utf8).write(to: URL(fileURLWithPath: filePath))
        let fileStat = try IndexerService.defaultStat(filePath)
        let checksum = sha256Hex(content)
        let harness = try makeHarness(root: root, lazyChecksum: "true")
        // 竞态状态：backfill 已提交 photos.checksum，但扫描的 asset_files 快照
        // 仍为空 checksum（文件本身未变化）。
        try insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: filePath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: ""
        )
        _ = try harness.db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('photo-1', ?, ?, 'photo.jpg', ?, 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(harness.sessionId), .text(filePath), .text(checksum)])

        let scan = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        // 未变化文件必须保留已回填的 checksum：不写 photos.checksum，
        // 也不碰空的 asset_files.checksum（preserve 条件写）。
        #expect(scan.missing == 0)
        #expect(try photoChecksum(harness.db, "photo-1") == checksum)
        #expect(try assetFileChecksum(harness.db, "af-1") == "")
        #expect(try harness.indexer.pendingChecksums(sessionId: harness.sessionId) == 0)
    }

    @Test("preserves the asset_files checksum via a conditional write when the snapshot lacks one")
    func conditionalAssetFileWrite() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let filePath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: filePath))
        let fileStat = try IndexerService.defaultStat(filePath)
        let harness = try makeHarness(root: root, lazyChecksum: "true")
        try insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: filePath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: ""
        )
        // photos.checksum 已被回填，asset_files.checksum 仍为空。
        _ = try harness.db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('photo-1', ?, ?, 'photo.jpg', 'H', 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(harness.sessionId), .text(filePath)])

        let scan = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        // SQL 层观察：existing 分支带 preserve 标志发送 —— checksum 列保留现值
        // 而非被空串覆盖。
        #expect(scan.missing == 0)
        #expect(try photoChecksum(harness.db, "photo-1") == "H")
        #expect(try assetFileChecksum(harness.db, "af-1") == "")
        let width = try harness.db.prepare("SELECT width FROM photos WHERE id = 'photo-1'").get()
        #expect(width?[0].intValue == 100)
    }

    @Test("skips the backfill write when a concurrent writer already filled the checksum")
    func concurrentWriterSkipsWrite() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pendingPath = root + "/pending.jpg"
        try Data("race-content".utf8).write(to: URL(fileURLWithPath: pendingPath))
        let harness = try makeHarness(root: root)
        try insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: pendingPath, fileSize: 0, fileMtimeMs: 0, checksum: ""
        )
        _ = try harness.db.prepare("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('pending', ?, ?, 'pending.jpg', '', 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """).run([.text(harness.sessionId), .text(pendingPath)])
        // 并发写入者接缝：读取阶段（pending 已加载）之后、守卫 UPDATE 之前，
        // 另一写入者先填了 checksum —— 守卫（AND checksum = ''）必须拒绝覆盖。
        harness.indexer.fileHasher = { path in
            _ = try harness.db.prepare(
                "UPDATE photos SET checksum = 'concurrent-hash' WHERE id = 'pending'"
            ).run()
            return try IndexerService.sha256File(path)
        }

        let result = try await harness.indexer.backfillChecksums(sessionId: harness.sessionId)

        #expect(result.processed == 1)
        #expect(result.backfilled == 0)
        #expect(result.skipped == 1)
        #expect(try photoChecksum(harness.db, "pending") == "concurrent-hash")
        // 守卫未过：资产行写入一并跳过（photos 与 asset_files 保持一致）。
        #expect(try assetFileChecksum(harness.db, "af-1") == "")
    }

    @Test("supports cancellation between batches")
    func cancelsBetweenBatches() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = try makeHarness(root: root)
        // 33 张照片：首批 32 张完成后仍剩 pending → 下一趟循环抛取消。
        for i in 0..<33 {
            let path = root + "/p\(i).jpg"
            try Data("content-\(i)".utf8).write(to: URL(fileURLWithPath: path))
            try insertPhotoRow(harness.db, id: "p\(i)", sessionId: harness.sessionId, filepath: path, assetFileId: nil)
        }
        let repo = AnalysisJobRepo(connection: harness.db)
        let job = try repo.create(JobCreateParams(
            type: .checksumBackfill, scopeType: "session", scopeId: harness.sessionId, dedupeKey: "d"
        ))
        let signal = JobAbortSignal()
        let context = JobRunContext(
            signal: signal,
            repo: repo,
            jobId: job.id,
            leaseOwner: "test",
            updateProgress: { _, _, _ in true },
            progressSink: nil
        )
        // 首批哈希期间到达取消（signal.abort）：批仍提交，次趟循环检查抛出。
        harness.indexer.fileHasher = { path in
            signal.abort()
            return try IndexerService.sha256File(path)
        }

        await #expect(throws: JobCancelledError.self) {
            try await harness.indexer.backfillChecksums(sessionId: harness.sessionId, context: context)
        }
        // 首批已提交：32 张照片被回填。
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE checksum != ''") == 32)
    }
}
