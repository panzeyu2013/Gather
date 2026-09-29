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
        faceRepo: FaceRepo(connection: db),
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

/// 第四轮审计 #3（MED）：取消/失败后 index_seq 不 bump。
/// 批次已提交但扫描中途取消时，新照片对已完成分析（sim/fkw）的可见性
/// 依赖 index_seq 游标推进；任何终态只要发生过真实变更都必须 bump。
@Suite("IndexService index_seq on cancelled scan")
struct CancelledScanIndexSeqTests {
    @Test("bumps index_seq when the scan is cancelled after a batch committed")
    func bumpsIndexSeqOnCancelledScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // 33 张照片（字典序：…p7、p8、p9）：首批 32 张提交时，第 32 张
        // （p8.jpg）解码中 abort；随后的 pull 循环 throwIfCancelled 抛取消。
        for i in 0..<33 {
            try Data("content-\(i)".utf8).write(to: URL(fileURLWithPath: root + "/p\(i).jpg"))
        }
        let db = try makeMigratedDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "Index", source: "folder", sourcePath: root)
        // 预置已完成的 sim/fkw 分析（快照 index_seq=0）：扫描必须推进会话
        // index_seq，否则这两条已完成分析永远看不到新照片。
        _ = try db.prepare("""
            INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, 'similarity', 0, 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', '{}', 'ok')
          """).run([.text(session.id)])
        _ = try db.prepare("""
            INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, 'face_keywording', 0, 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', '{}', 'ok')
          """).run([.text(session.id)])

        // 首批 32 张的末位（p8.jpg）解码时 abort：批仍提交；扫描在 pull 循环
        // 的 throwIfCancelled 抛 JobCancelledError（修复前异常跳过终态块，
        // index_seq 停在 0）。
        let signal = JobAbortSignal()
        let lastBatchPath = root + "/p8.jpg"
        let indexer = IndexerService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            assetRepo: AssetRepo(connection: db),
            getDimensions: { path in
                if path == lastBatchPath {
                    signal.abort()
                    throw JobCancelledError()
                }
                return (100, 80)
            },
            getSetting: { _, defaultValue in defaultValue }
        )
        let repo = AnalysisJobRepo(connection: db)
        let job = try repo.create(JobCreateParams(
            type: .metadataScan, scopeType: "session", scopeId: session.id, dedupeKey: "d"
        ))
        let context = JobRunContext(
            signal: signal,
            repo: repo,
            jobId: job.id,
            leaseOwner: "test",
            updateProgress: { _, _, _ in true },
            progressSink: nil
        )

        await #expect(throws: JobCancelledError.self) {
            try await indexer.scanSession(sessionId: session.id, context: context)
        }
        // 首批已提交（p8 转 failed，不入库）：新照片入库。
        #expect(try rowCount(db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(session.id)]) == 31)
        // 修复点：取消路径同样 bump —— 预置的已完成分析（index_seq=0）相对
        // 会话 index_seq（1）过期，新照片对分析可见。
        #expect(try sessionRepo.getIndexSeq(id: session.id) == 1)
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

// MARK: - 扫描范围（显式路径集合）与路径归一化

/// 记录预热批次（actor：预热闭包可能从后台执行）。
private actor WarmupRecorder {
    private(set) var batches: [[String]] = []
    func record(_ ids: [String]) { batches.append(ids) }
}

/// 记录设置读取（键 + 生产侧传入的默认值），用于收紧「identity 返回 default」替身。
private final class SettingsReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(key: String, defaultValue: String)] = []

    func record(_ key: String, _ defaultValue: String) {
        lock.lock()
        storage.append((key, defaultValue))
        lock.unlock()
    }

    var reads: [(key: String, defaultValue: String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

@Suite("IndexService 扫描范围与路径归一化")
struct IndexScanScopeTests {
    /// 缺陷③ 接线回归：扫描新插入的照片必须交给元数据预热（EXIF →
    /// photo_metadata_cache 的 date_taken / camera_model；RAW/JPEG 按时间自动
    /// 合并完全依赖这两列）。旧实现从无调用点 → 自动合并恒为 0。
    @Test("new photos are handed to the metadata warmup exactly once")
    func scanWarpsNewPhotoIdsForMetadata() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try writeTempFile(in: root, name: "a.jpg")
        _ = try writeTempFile(in: root, name: "b.jpg")

        let db = try makeMigratedDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "Warmup", source: "folder", sourcePath: root)
        let recorder = WarmupRecorder()
        let indexer = IndexerService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            assetRepo: AssetRepo(connection: db),
            getDimensions: { _ in (100, 80) },
            getSetting: { _, defaultValue in defaultValue },
            warmMetadata: { ids in await recorder.record(ids) }
        )

        _ = try await indexer.scanSession(sessionId: session.id)
        let batches = await recorder.batches
        #expect(batches.count == 1, "一次扫描只预热一次（按批）")
        #expect(batches.first?.count == 2, "两张新照片的 id 都必须交给预热")

        // 二次扫描没有任何新行 → 不得重复提取 EXIF。
        _ = try await indexer.scanSession(sessionId: session.id)
        #expect(await recorder.batches.count == 1)
    }

    /// 文件导入的核心回归：会话 source_path 为空（显式文件集合作用域）时，
    /// 扫描集合必须**恰好**是调用方给定的路径集合——同目录下的其它照片、
    /// 子目录里的照片都不得被顺带导入。
    @Test("explicit paths import only the requested files, never the sibling files")
    func explicitPathsDoNotWiden() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wanted = try writeTempFile(in: root, name: "wanted.jpg")
        _ = try writeTempFile(in: root, name: "sibling.jpg")
        let sub = root + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        _ = try writeTempFile(in: sub, name: "nested.jpg")

        let harness = try makeHarness(root: root)
        // 文件导入语义：source_path 留空。
        let fileScoped = try harness.sessionRepo.create(name: "Files", source: "local")
        let result = try await harness.indexer.scanSession(
            sessionId: fileScoped.id,
            requestedPaths: [wanted]
        )

        #expect(result.added == 1)
        #expect(result.discovered == 1)
        let paths = try harness.db.prepare(
            "SELECT filepath FROM photos WHERE session_id = ? ORDER BY filepath"
        ).query([.text(fileScoped.id)]).compactMap { $0[0].textValue }
        #expect(paths == [ScanPath.canonical(wanted)])
        // 同目录/子目录的未选择文件绝不入库。
        #expect(!paths.contains { $0.hasSuffix("sibling.jpg") })
        #expect(!paths.contains { $0.hasSuffix("nested.jpg") })
    }

    /// 即使会话带 source_path（目录作用域），一旦调用方给出显式路径集合，
    /// 扫描也必须服从集合而不是回退到全树——否则「重新索引」会放大范围。
    @Test("explicit paths win over the session source path (no fallback to the full tree)")
    func explicitPathsWinOverSourcePath() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wanted = try writeTempFile(in: root, name: "wanted.jpg")
        _ = try writeTempFile(in: root, name: "other.jpg")

        let harness = try makeHarness(root: root)
        let result = try await harness.indexer.scanSession(
            sessionId: harness.sessionId,
            requestedPaths: [wanted]
        )

        #expect(result.added == 1)
        let paths = try harness.db.prepare(
            "SELECT filepath FROM photos WHERE session_id = ? ORDER BY filepath"
        ).query([.text(harness.sessionId)]).compactMap { $0[0].textValue }
        #expect(paths == [ScanPath.canonical(wanted)])
    }

    /// 集合里的目录条目只在**它自己**范围内递归展开（用户显式选择了这个
    /// 目录），集合外的目录不受影响。
    @Test("a requested directory expands inside itself only")
    func requestedDirectoryExpandsWithinItself() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let picked = base + "/picked"
        let outside = base + "/outside"
        try FileManager.default.createDirectory(atPath: picked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: picked + "/nested", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        _ = try writeTempFile(in: picked, name: "a.jpg")
        _ = try writeTempFile(in: picked + "/nested", name: "b.jpg")
        _ = try writeTempFile(in: outside, name: "c.jpg")

        let harness = try makeHarness(root: base)
        let fileScoped = try harness.sessionRepo.create(name: "Dir pick", source: "local")
        let result = try await harness.indexer.scanSession(
            sessionId: fileScoped.id,
            requestedPaths: [picked]
        )

        #expect(result.added == 2)
        let paths = try harness.db.prepare(
            "SELECT filepath FROM photos WHERE session_id = ? ORDER BY filepath"
        ).query([.text(fileScoped.id)]).compactMap { $0[0].textValue }
        #expect(paths.contains { $0.hasSuffix("a.jpg") })
        #expect(paths.contains { $0.hasSuffix("b.jpg") })
        #expect(!paths.contains { $0.hasSuffix("c.jpg") })
    }

    /// 目录导入（requestedPaths == nil）仍然递归 source_path 全树——收紧范围
    /// 不能把既有的一跳目录导入一起收紧掉。
    @Test("nil requested paths keep the directory-scope full-tree scan")
    func nilPathsScanTheWholeTree() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try writeTempFile(in: root, name: "a.jpg")
        let sub = root + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        _ = try writeTempFile(in: sub, name: "b.jpg")

        let harness = try makeHarness(root: root)
        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId)

        #expect(result.added == 2)
    }

    /// 空集合是合法输入：扫描零个路径并返回零结果，不报错也不回退全树。
    @Test("an empty explicit set scans nothing and does not fall back")
    func emptyExplicitSetScansNothing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try writeTempFile(in: root, name: "a.jpg")

        let harness = try makeHarness(root: root)
        let result = try await harness.indexer.scanSession(sessionId: harness.sessionId, requestedPaths: [])

        #expect(result.discovered == 0)
        #expect(result.added == 0)
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos") == 0)
    }

    /// 文件系统根 / 主目录不得作为递归扫描根：显式失败，而不是照扫不误。
    @Test("a forbidden directory root fails explicitly instead of scanning it")
    func forbiddenRootFailsExplicitly() async throws {
        let db = try makeMigratedDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(
            name: "Forbidden", source: "local", sourcePath: NSHomeDirectory()
        )
        let indexer = IndexerService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            assetRepo: AssetRepo(connection: db)
        )

        await #expect(throws: IndexerServiceError.sourceRootForbidden) {
            try await indexer.scanSession(sessionId: session.id)
        }
        // 显式路径集合不受该守卫影响（不是递归作用域）。
        let explicit = try await indexer.scanSession(
            sessionId: session.id,
            requestedPaths: [NSHomeDirectory() + "/definitely-missing.jpg"]
        )
        #expect(explicit.added == 0)
        #expect(IndexerServiceError.sourceRootForbidden.gatherCode == .SESSION_SOURCE_ROOT_FORBIDDEN)
    }

    /// 显式集合同样不得把 home / 文件系统根当作递归根：混合选择「目录 + 文件」
    /// 时用户可能把 home 传进来，非 nil 分支也必须逐个条目显式失败。
    @Test("a forbidden entry in an explicit set fails instead of being scanned")
    func explicitForbiddenRootFails() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = try makeHarness(root: root)
        _ = try writeTempFile(in: root, name: "a.jpg")

        await #expect(throws: IndexerServiceError.sourceRootForbidden) {
            try await harness.indexer.scanSession(
                sessionId: harness.sessionId,
                requestedPaths: [root + "/a.jpg", NSHomeDirectory()]
            )
        }
        await #expect(throws: IndexerServiceError.sourceRootForbidden) {
            try await harness.indexer.scanSession(
                sessionId: harness.sessionId,
                requestedPaths: ["/"]
            )
        }
        // 抛错发生在任何写入之前：库里不应留下半次扫描的痕迹。
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos") == 0)
    }

    /// 嵌套/冗余输入（目录 + 其内部文件、或同一条目的词法变体）必须收敛成
    /// 一次扫描：祖先条目胜出，重复条目丢弃，计数不得翻倍。
    @Test("an ancestor entry covers its descendants without double counting")
    func requestedAncestorCoversDescendants() async throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let picked = base + "/picked"
        try FileManager.default.createDirectory(atPath: picked, withIntermediateDirectories: true)
        let inner = try writeTempFile(in: picked, name: "a.jpg")
        _ = try writeTempFile(in: picked, name: "b.jpg")

        let harness = try makeHarness(root: base)
        let fileScoped = try harness.sessionRepo.create(name: "Ancestor", source: "local")
        // 目录 + 目录内文件 + 同一文件的词法变体（/./ 变体归一化后同键）。
        let result = try await harness.indexer.scanSession(
            sessionId: fileScoped.id,
            requestedPaths: [inner, picked, picked + "/./a.jpg"]
        )

        #expect(result.discovered == 2, "a.jpg 只能被计入一次")
        #expect(result.added == 2)
        let paths = try harness.db.prepare(
            "SELECT filepath FROM photos WHERE session_id = ? ORDER BY filepath"
        ).query([.text(fileScoped.id)]).compactMap { $0[0].textValue }
        #expect(paths.count == 2)
        #expect(paths == paths.sorted())
    }

    /// 历史库可能留下「字符串不同、归一化后相同」的两行（唯一索引只按字符串，
    /// 拦不住 → 旧实现用唯一键字典构造路径表时直接 trap）。索引器必须确定性
    /// 收敛（首见者胜 = 最早 rowid）+ 显式上报，绝不崩溃。
    @Test("normalized duplicate paths neither trap nor get imported twice")
    func normalizedDuplicatesDoNotTrap() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = try makeHarness(root: root)
        // 同一个文件的两种词法拼写（唯一索引按字符串，拦不住）。
        try insertPhotoRow(
            harness.db, id: "p1", sessionId: harness.sessionId,
            filepath: "/tmp/gather-dup.jpg", assetFileId: nil
        )
        try insertPhotoRow(
            harness.db, id: "p2", sessionId: harness.sessionId,
            filepath: "/tmp/./gather-dup.jpg", assetFileId: nil
        )
        let key = ScanPath.canonical("/tmp/gather-dup.jpg")
        #expect(ScanPath.canonical("/tmp/./gather-dup.jpg") == key,
            "词法变体必须归一化到同一个键，否则唯一索引形同虚设")

        let result = try await harness.indexer.scanSession(
            sessionId: harness.sessionId,
            requestedPaths: ["/tmp/gather-dup.jpg"]
        )

        #expect(result.added == 0, "同一物理文件不得再插一行")
        #expect(result.failed.contains(key), "重复的归一化路径必须显式上报")
        #expect(try rowCount(harness.db, "SELECT COUNT(*) FROM photos") == 2)
    }

    /// 预热参数必须是**本批真正插入**的 photo id：
    /// - 只含本批新行（不得把已存在的行再喂一遍，也不得空批次）；
    /// - 不得退化成文件路径（旧实现无调用点，接线错误同样会让 EXIF 永不回填）。
    /// 变异「warmMetadata(insertedIds) → warmMetadata(newEntries.map(\.filepath))」可杀。
    @Test("metadata warmup receives exactly the photo ids inserted by this batch")
    func warmupReceivesInsertedPhotoIds() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try writeTempFile(in: root, name: "a.jpg")

        let db = try makeMigratedDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "WarmIds", source: "folder", sourcePath: root)
        let recorder = WarmupRecorder()
        let indexer = IndexerService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            assetRepo: AssetRepo(connection: db),
            getDimensions: { _ in (100, 80) },
            getSetting: { _, defaultValue in defaultValue },
            warmMetadata: { ids in await recorder.record(ids) }
        )

        _ = try await indexer.scanSession(sessionId: session.id)
        _ = try writeTempFile(in: root, name: "b.jpg")
        _ = try await indexer.scanSession(sessionId: session.id)

        let batches = await recorder.batches
        #expect(batches.count == 2, "两次扫描各预热一次，实际 \(batches.count)")

        let allIds = try db.prepare(
            "SELECT id FROM photos WHERE session_id = ? ORDER BY filepath"
        ).query([.text(session.id)]).compactMap { $0[0].textValue }
        #expect(allIds.count == 2, "两轮扫描后应有两行，实际 \(allIds.count)")
        #expect(batches[1].count == 1, "第二批只应携带本次插入的 1 个 id，实际 \(batches[1])")
        #expect(batches[1].allSatisfy { allIds.contains($0) },
                "预热参数必须是 photo id（真实行 id），实际 \(batches[1])")
    }

    /// ScanPath.canonical 的 /private 前缀折叠：同一条物理路径的两种拼写必须落到
    /// 同一个键（/tmp → private/tmp、/var → private/var，macOS 实测符号链接）。
    /// 变异「删掉 /private/tmp 折叠」可杀。
    @Test("canonical folds /private so both spellings of /tmp and /var agree")
    func canonicalFoldsPrivatePrefix() {
        // 独立 oracle：/tmp、/var 是指向 /private/* 的符号链接（不是实现自证）。
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")) == "private/tmp")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: "/var")) == "private/var")
        #expect(ScanPath.canonical("/private/tmp/gather-fold/photo.jpg")
                == ScanPath.canonical("/tmp/gather-fold/photo.jpg"),
                "/tmp 两种拼写必须归一到同一个键")
        #expect(ScanPath.canonical("/private/var/folders/gather-fold/photo.jpg")
                == ScanPath.canonical("/var/folders/gather-fold/photo.jpg"),
                "/var 两种拼写必须归一到同一个键")
    }

    /// 禁根判定是「home 及其祖先」，不只是 home 自身：/Users 这类祖先目录被当作
    /// 扫描根同样会退化成全盘递归。纯函数断言，不触发真实递归。
    /// 变异「isForbiddenRoot 只比较 resolved == home」可杀。
    @Test("isForbiddenRoot rejects home and its ancestors, not only home itself")
    func forbiddenRootCoversAncestorsOfHome() {
        let home = NSHomeDirectory()
        #expect(ScanPath.isForbiddenRoot(home), "home 自身必须是禁根")
        #expect(ScanPath.isForbiddenRoot("/"), "文件系统根必须是禁根")
        let parent = (home as NSString).deletingLastPathComponent
        if parent != "/" && !parent.isEmpty {
            #expect(ScanPath.isForbiddenRoot(parent), "home 的祖先 \(parent) 必须是禁根")
        }
        #expect(!ScanPath.isForbiddenRoot("/tmp/gather-not-a-forbidden-root/photo.jpg"),
                "普通目录不得被误判为禁根")
    }

    /// 设置读取的键名与默认值同样是契约：替身「identity 返回 default」会让
    /// 键名写错、默认值写错都静默通过。这里把生产调用点传的键名/默认值钉成
    /// 可审阅的字面量（不再是「替身返回什么就断言什么」）。
    @Test("settings keys and production defaults are pinned")
    func settingsKeysAndDefaultsArePinned() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try writeTempFile(in: root, name: "a.jpg")

        let db = try makeMigratedDB()
        let sessionRepo = SessionRepo(connection: db)
        let session = try sessionRepo.create(name: "Settings", source: "folder", sourcePath: root)
        let recorder = SettingsReadRecorder()
        let indexer = IndexerService(
            connection: db,
            sessionRepo: sessionRepo,
            photoRepo: PhotoRepo(connection: db),
            assetRepo: AssetRepo(connection: db),
            getDimensions: { _ in (100, 80) },
            getSetting: { key, defaultValue in
                recorder.record(key, defaultValue)
                return defaultValue
            }
        )

        _ = try await indexer.scanSession(sessionId: session.id)

        let reads = recorder.reads
        #expect(reads.contains { $0.key == "disk_cache_dir" && $0.defaultValue == "" },
                "disk_cache_dir 缺省必须为空串（未配置时不走自定义缓存目录），实际读取 \(reads)")
        #expect(reads.contains { $0.key == "lazy_checksum" && $0.defaultValue == "true" },
                "lazy_checksum 缺省必须为 true（首次扫描不算校验和），实际读取 \(reads)")
    }
}

// MARK: - 人脸派生结果失效（内容变化只命中本批照片，用户绑定不清）

/// Float32 小端 BLOB（face_observations.embedding / person_embeddings.embedding 同格式）。
private func faceEmbeddingBlob(_ values: [Float]) -> Data {
    var data = Data(count: values.count * MemoryLayout<Float>.size)
    data.withUnsafeMutableBytes { buffer in
        values.withUnsafeBytes { source in
            buffer.copyMemory(from: source)
        }
    }
    return data
}

/// 观察 + 分析状态 + 已绑定簇（含成员）+ 人物 + 一条 person_embeddings。
private func seedBoundFace(
    _ db: DBConnection,
    sessionId: String,
    clusterId: Int64,
    observationId: Int64,
    photoId: String,
    roleName: String,
    personId: String
) throws {
    let now = "2026-01-01T00:00:00.000Z"
    let embedding = faceEmbeddingBlob([1, 0, 0, 0])
    _ = try db.prepare("""
        INSERT INTO face_observations (id, photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h,
                                       embedding, confidence, source_file_size, source_file_mtime_ms,
                                       analysis_signature, created_at)
        VALUES (?, ?, ?, 1, 2, 3, 4, ?, 0.9, 10, 20, 'sig', ?)
        """).run([.int(observationId), .text(photoId), .text(sessionId), .blob(embedding), .text(now)])
    _ = try db.prepare("""
        INSERT INTO face_analysis_state (photo_id, session_id, source_file_size, source_file_mtime_ms,
                                         analysis_signature, updated_at)
        VALUES (?, ?, 10, 20, 'sig', ?)
        """).run([.text(photoId), .text(sessionId), .text(now)])
    _ = try db.prepare("""
        INSERT INTO face_clusters (id, session_id, label, member_count, status, thumbnail_base64,
                                   thumbnail_path, created_at, updated_at)
        VALUES (?, ?, ?, 1, 'bound', '', '', ?, ?)
        """).run([.int(clusterId), .text(sessionId), .text(roleName), .text(now), .text(now)])
    _ = try db.prepare("""
        INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
        VALUES (?, ?, ?, '[1,2,3,4]', 0.9, ?)
        """).run([.int(clusterId), .text(sessionId), .text(photoId), .int(observationId)])
    _ = try db.prepare("""
        INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords, created_at, updated_at)
        VALUES (?, ?, ?, '[]', ?, ?)
        """).run([.int(clusterId), .text(sessionId), .text(roleName), .text(now), .text(now)])
    _ = try db.prepare("""
        INSERT INTO persons (id, name, keywords, thumbnail_base64, notes, match_threshold, created_at, updated_at)
        VALUES (?, ?, '[]', '', '', 0.65, ?, ?)
        """).run([.text(personId), .text(roleName), .text(now), .text(now)])
    _ = try db.prepare("""
        INSERT INTO person_embeddings (person_id, embedding, photo_id, session_id, face_observation_id,
                                       face_bbox, quality, created_at)
        VALUES (?, ?, ?, ?, ?, '[1,2,3,4]', 0.9, ?)
        """).run([
            .text(personId), .blob(embedding), .text(photoId), .text(sessionId), .int(observationId), .text(now),
        ])
}

private struct InvalidationScenario {
    let harness: IndexerHarness
    let root: String
    let faceRepo: FaceRepo
}

/// changed（asset_files 基线与真实文件不符 → 判定内容变化）与 untouched
/// （基线与真实 stat + checksum 一致 → 判定不变）两张照片，各带一个已绑定簇
/// （Alice / Bob）+ 观察 + person_embeddings，然后跑一次真实 scanSession。
private func makeInvalidationScenario() async throws -> InvalidationScenario {
    let root = try makeTempDir()
    let changedPath = root + "/changed.jpg"
    let untouchedPath = root + "/untouched.jpg"
    let changedContent = "changed-content"
    let untouchedContent = "untouched-content"
    try Data(changedContent.utf8).write(to: URL(fileURLWithPath: changedPath))
    try Data(untouchedContent.utf8).write(to: URL(fileURLWithPath: untouchedPath))

    let harness = try makeHarness(root: root)
    // changed：大小/时间与真实文件不符 → contentChanged；checksum 留空是安全的
    // （判定变化后本就要重算）。
    try insertAssetFileRow(harness.db, id: "file-changed", filepath: changedPath,
                           fileSize: 1, fileMtimeMs: 1, checksum: "")
    // untouched：三项基线全部与真实文件一致 → 不进入本批失效集合。
    let untouchedStat = try IndexerService.defaultStat(untouchedPath)
    try insertAssetFileRow(harness.db, id: "file-untouched", filepath: untouchedPath,
                           fileSize: untouchedStat.size, fileMtimeMs: untouchedStat.mtimeMs,
                           checksum: sha256Hex(untouchedContent))
    try insertPhotoRow(harness.db, id: "changed", sessionId: harness.sessionId,
                       filepath: changedPath, assetFileId: "file-changed")
    try insertPhotoRow(harness.db, id: "untouched", sessionId: harness.sessionId,
                       filepath: untouchedPath, assetFileId: "file-untouched")
    try seedBoundFace(
        harness.db, sessionId: harness.sessionId, clusterId: 1, observationId: 11,
        photoId: "changed", roleName: "Alice", personId: "person-alice")
    try seedBoundFace(
        harness.db, sessionId: harness.sessionId, clusterId: 2, observationId: 12,
        photoId: "untouched", roleName: "Bob", personId: "person-bob")

    _ = try await harness.indexer.scanSession(sessionId: harness.sessionId)

    return InvalidationScenario(
        harness: harness, root: root, faceRepo: FaceRepo(connection: harness.db))
}

@Suite("Indexer face invalidation")
struct IndexerFaceInvalidationTests {
    @Test("content change invalidates only the changed photo's face members and embeddings")
    func invalidationIsPhotoScoped() async throws {
        let scenario = try await makeInvalidationScenario()
        defer { try? FileManager.default.removeItem(atPath: scenario.root) }

        // 命中照片：观察与分析状态删除；未命中照片原样保留。
        #expect(try scenario.faceRepo.getObservations(scenario.harness.sessionId).map(\.photoId) == ["untouched"])
        #expect(try rowCount(scenario.harness.db,
            "SELECT COUNT(*) FROM face_analysis_state WHERE photo_id = 'changed'") == 0)
        #expect(try rowCount(scenario.harness.db,
            "SELECT COUNT(*) FROM face_analysis_state WHERE photo_id = 'untouched'") == 1)

        // 成员行保留（绑定的照片集合不随派生数据消失），只解除对观察的引用。
        let members = try scenario.harness.db.prepare("""
            SELECT cluster_id, photo_id, observation_id FROM face_cluster_members ORDER BY cluster_id
            """).query([])
        #expect(members.count == 2)
        #expect(members[0][1].textValue == "changed")
        #expect(members[0][2].intValue == nil, "命中照片的成员必须先解除观察引用（FK 先解后删）")
        #expect(members[1][1].textValue == "untouched")
        #expect(members[1][2].intValue == 12, "未命中照片的成员不得被动")

        // person_embeddings 与观察同生命周期：残留向量会被匹配读到。
        #expect(try rowCount(scenario.harness.db,
            "SELECT COUNT(*) FROM person_embeddings WHERE face_observation_id = 11") == 0)
        #expect(try rowCount(scenario.harness.db,
            "SELECT COUNT(*) FROM person_embeddings WHERE face_observation_id = 12") == 1)
    }

    @Test("content change keeps role bindings and clusters visible")
    func bindingsSurviveContentChange() async throws {
        let scenario = try await makeInvalidationScenario()
        defer { try? FileManager.default.removeItem(atPath: scenario.root) }

        // 旧实现整会话 DELETE role_bindings/face_clusters：内容变化不得销毁用户标注。
        #expect(try rowCount(scenario.harness.db, "SELECT COUNT(*) FROM role_bindings") == 2)
        let clusters = try scenario.faceRepo.getClusters(
            scenario.harness.sessionId, includeMembers: true)
        #expect(clusters.count == 2)

        let changed = try #require(clusters.first { $0.id == 1 })
        #expect(changed.binding?.roleName == "Alice", "命中照片的绑定必须仍在（孤儿绑定仍可见）")
        // 照片行仍存在 → 成员行保留（绑定的照片集合不随派生数据消失），
        // 只解除观察引用；成员计数是成员行的实时计数，不因观察失效而归零。
        #expect(changed.memberCount == 1)
        let changedMember = try #require(changed.members?.first)
        #expect(changedMember.photoId == "changed")
        #expect(changedMember.observationId == nil)

        let untouched = try #require(clusters.first { $0.id == 2 })
        #expect(untouched.binding?.roleName == "Bob")
        #expect(untouched.memberCount == 1, "未命中照片的成员与计数不得被动")
        let untouchedMember = try #require(untouched.members?.first)
        #expect(untouchedMember.observationId == 12)
    }
}

