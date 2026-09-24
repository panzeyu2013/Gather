// desktop/native/gather-core/Tests/GatherCoreTests/Runtime/Indexer/IndexerRuntimeTests.swift
// IndexerRuntime 行为测试（idx2c：由 Tests/GatherCoreTests/Services/
// IndexerServiceTests.swift 原 19 例迁入，被测对象切到 IndexerRuntime；
// 用例名/断言语义保持不变，覆盖 scan / checksum 回填 / 测试接缝）。
// TS 源: tests/unit/services/indexer/*（index-seq / index-lazy-checksum /
// index-ghost-photo / index-backfill-regression，用例逐一对应）。
// 差异说明：
// - TS 用 repo mock 断言调用；Swift 侧全部走真实临时 SQLite + 迁移 + 真实
//   临时文件（行为级断言：DB 状态 + 结果计数），stat 经 Dependencies.stat
//   接缝注入（TS 同款 ghost-photo 竞态测试）。
// - 并发写入竞态（backfill 与 scan 的 checksum 守卫）经 fileHasher 接缝模拟
//   并发写入者（TS 用 mock statement 的 changes=0 路径）。
// - pendingChecksums 与路由内联等价实现一致（getBySessionProjection +
//   IndexAssembler.needsChecksumBackfill）。

import Foundation
import Testing
@testable import GatherCore

private func makeTempJobStore() async throws -> any JobStore {
    let (database, _) = try await makeMigratedStoreDatabase(label: "jobs")
    return SQLiteJobStore(database: database)
}


// MARK: - 支撑

private func sha256Hex(_ content: String) -> String {
    SHA256.hash(Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
}

private struct IndexerHarness {
    let db: SQLiteDatabase
    let runtime: IndexerRuntime
    let photoStore: any PhotoStore
    let sessionStore: any SessionStore
    let sessionId: String

    /// 等价旧 IndexerService.scanSession(sessionId:)（options 仅承载 sessionId）。
    func scan() async throws -> IndexScanResult {
        try await runtime.scan(sessionId: sessionId, options: IndexScanParams(sessionId: sessionId))
    }

    /// 等价旧 IndexerService.pendingChecksums(sessionId:)（路由内联实现同款）。
    func pendingChecksumCount() async throws -> Int {
        try await photoStore.getBySessionProjection(sessionId: sessionId)
            .filter { IndexAssembler.needsChecksumBackfill(checksum: $0.checksum, status: $0.status) }
            .count
    }
}

private func makeHarness(
    root: String,
    lazyChecksum: String = "true",
    getDimensions: @escaping @Sendable (String) throws -> (width: Int, height: Int) = { _ in (100, 80) },
    stat: @escaping @Sendable (String) throws -> IndexerRuntime.FileStat = { try IndexerRuntime.defaultStat($0) },
    fileHasher: @escaping @Sendable (String) async throws -> String = { try IndexerRuntime.sha256File($0) }
) async throws -> IndexerHarness {
    // 同一临时文件库：旧连接 + Store 连接（asset 回填外键需要 sessions 行）。
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-indexer-\(UUID().uuidString).sqlite").path
    let db = try await makeMigratedStore(path: dbPath)
    let assetStore = try SQLiteAssetStore(database: try SQLiteDatabase(path: dbPath))
    let photoStore = try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath))
    let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
    let session = try await sessionStore.create(name: "Index", source: "folder", sourcePath: root)
    let runtime = IndexerRuntime(
        dependencies: IndexerRuntime.Dependencies(
            sessionStore: sessionStore,
            photoStore: photoStore,
            assetStore: assetStore,
            database: db,
            getDimensions: getDimensions,
            getSetting: { key, defaultValue in
                key == "lazy_checksum" ? lazyChecksum : defaultValue
            },
            stat: stat,
            fileHasher: fileHasher
        )
    )
    return IndexerHarness(
        db: db, runtime: runtime, photoStore: photoStore,
        sessionStore: sessionStore, sessionId: session.id
    )
}

/// asset_files 行（含 volume/identity，供 relink 按真实 inode 匹配）。
private func insertAssetFileRow(
    _ db: SQLiteDatabase,
    id: String,
    filepath: String,
    fileSize: Int64,
    fileMtimeMs: Double,
    checksum: String,
    volumeId: String = "dev:1",
    fileIdentity: String? = nil
) async throws {
    // 默认 identity 按文件路径派生（UNIQUE(volume_id, file_identity)，不同
    // 文件不得共用；TS 源为 stat().ino）。
    let identity = fileIdentity ?? "ino-\(id)"
    _ = try await db.run("""
        INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, '.jpg', 'image', ?, ?, ?, 'online', '', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """, [
        .text(id), .text(volumeId), .text(identity), .text(filepath),
        .text((filepath as NSString).lastPathComponent),
        .int(fileSize), .real(fileMtimeMs), .text(checksum),
    ])
}

/// photos 行（asset_file_id 可空）。
private func insertPhotoRow(
    _ db: SQLiteDatabase,
    id: String,
    sessionId: String,
    filepath: String,
    assetFileId: String?,
    checksum: String = "",
    status: String = "pending",
    checksumFileSize: Int = 0,
    checksumFileMtimeMs: Double = 0
) async throws {
    _ = try await db.run("""
        INSERT INTO photos (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}', '{}', NULL, ?, 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """, [
        .text(id), .text(sessionId), .text(filepath),
        .text((filepath as NSString).lastPathComponent),
        .text(checksum), .int(Int64(checksumFileSize)), .real(checksumFileMtimeMs),
        .text(status), assetFileId.map { .text($0) } ?? .null,
    ])
}

/// 完整资产链（backfill 收敛用例需要 asset_members / session_assets）。
private func insertFullAssetChain(
    _ db: SQLiteDatabase,
    assetFileId: String,
    assetId: String,
    sessionId: String,
    filepath: String,
    fileSize: Int64,
    fileMtimeMs: Double,
    checksum: String
) async throws {
    _ = try await db.run("""
        INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
        VALUES (?, '', 'active', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
      """, [.text(assetId)])
    try await insertAssetFileRow(db, id: assetFileId, filepath: filepath, fileSize: fileSize, fileMtimeMs: fileMtimeMs, checksum: checksum)
    _ = try await db.run("""
        INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source)
        VALUES (?, ?, 'camera_jpeg', 1, 'import')
      """, [.text(assetId), .text(assetFileId)])
    _ = try await db.run("""
        INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
        VALUES (?, ?, ?, 0, '2026-01-01T00:00:00.000Z')
      """, [.text(sessionId), .text(assetId), .text(assetFileId)])
}

private func photoChecksum(_ db: SQLiteDatabase, _ photoId: String) async throws -> String? {
    try await db.queryOne("SELECT checksum FROM photos WHERE id = ?", [.text(photoId)]).map { $0.values[$0.columnOrder[0]]?.textValue ?? "" }
}

private func assetFileChecksum(_ db: SQLiteDatabase, _ assetFileId: String) async throws -> String? {
    try await db.queryOne("SELECT checksum FROM asset_files WHERE id = ?", [.text(assetFileId)]).map { $0.values[$0.columnOrder[0]]?.textValue ?? "" }
}

// MARK: - index_seq 提交点（TS index-seq.test.ts 逐条对应）

@Suite("IndexerRuntime index_seq commit point")
struct IndexSeqTests {
    @Test("bumps index_seq once when the scan added a photo")
    func bumpsOnAdd() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("content".utf8).write(to: URL(fileURLWithPath: root + "/new.jpg"))
        let harness = try await makeHarness(root: root)

        let result = try await harness.scan()

        #expect(result.discovered == 1)
        #expect(result.added == 1)
        #expect(result.missing == 0)
        #expect(result.failed.isEmpty)
        // markMissing([]) 语义：无照片被标记缺失。
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE status = 'missing'") == 0)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)
        // 新照片行已入库。
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(harness.sessionId)]) == 1)
    }

    @Test("bumps index_seq when an existing photo content changed")
    func bumpsOnContentChange() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let harness = try await makeHarness(root: root)
        // 无 asset_files 行：扫描把照片自身的 checksum 基线视为不可用 → 判定变化。
        try await insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)

        let result = try await harness.scan()

        #expect(result.discovered == 1)
        #expect(result.skipped == 0)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)
    }

    @Test("bumps index_seq when a photo is relinked to a new path")
    func bumpsOnRelink() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let newPath = root + "/moved.jpg"
        let oldPath = root + "/old-name.jpg"
        let content = "relinked-content"
        try Data(content.utf8).write(to: URL(fileURLWithPath: newPath))
        let fileStat = try IndexerRuntime.defaultStat(newPath)
        let hash = sha256Hex(content)
        let harness = try await makeHarness(root: root, lazyChecksum: "false")
        // asset_files 行指向旧路径，但 volume/identity 与真实文件匹配
        // （relinkMovedFile 按 inode 找到它）。
        try await insertAssetFileRow(
            harness.db, id: "file-old", filepath: oldPath,
            fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: hash,
            volumeId: "dev:\(fileStat.dev)", fileIdentity: String(fileStat.ino)
        )
        try await insertPhotoRow(harness.db, id: "relinked", sessionId: harness.sessionId, filepath: oldPath, assetFileId: "file-old")

        let result = try await harness.scan()

        #expect(result.discovered == 1)
        #expect(result.skipped == 1)
        #expect(result.missing == 0)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)
        // 照片被重链接到新路径而非新增。
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(harness.sessionId)]) == 1)
        let row = try await harness.db.queryOne("SELECT filepath FROM photos WHERE id = 'relinked'")
        #expect(row?.text(at: 0) == newPath)
    }

    @Test("does NOT bump index_seq when the scan changed nothing")
    func noBumpWhenUnchanged() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let fileStat = try IndexerRuntime.defaultStat(photoPath)
        let harness = try await makeHarness(root: root)
        try await insertAssetFileRow(harness.db, id: "af-1", filepath: photoPath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: "checksum-1")
        try await insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: "af-1")

        let result = try await harness.scan()

        #expect(result.discovered == 1)
        #expect(result.skipped == 1)
        #expect(result.missing == 0)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 0)
    }

    @Test("bumps index_seq when a photo disappears from disk (missing reconcile)")
    func bumpsOnMissing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        // 照片行存在但文件已删除。
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        try FileManager.default.removeItem(atPath: photoPath)
        let harness = try await makeHarness(root: root)
        try await insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)

        let result = try await harness.scan()

        #expect(result.discovered == 0)
        #expect(result.missing == 1)
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE status = 'missing'") == 1)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)
    }

    @Test("does NOT bump index_seq on repeated scans when a photo has no asset_files row and the file is unchanged")
    func noBumpOnRepeatedScansWithoutAssetRow() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let harness = try await makeHarness(root: root)
        // 照片从未回填到 asset_files：扫描没有 asset_files 基线可比较。
        try await insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)

        // 首次观测提交尺寸/checksum stat，是真实变化。
        _ = try await harness.scan()
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)

        // 重扫未变化文件只重写相同值：缺失 asset_files 行不得让每次重扫
        // 都变成 content change 无限 bump。
        let second = try await harness.scan()
        #expect(second.missing == 0)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)
    }

    @Test("bumps index_seq when an unbackfilled photo content actually changes")
    func bumpsWhenUnbackfilledContentChanges() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let photoPath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: photoPath))
        let originalStat = try IndexerRuntime.defaultStat(photoPath)
        let harness = try await makeHarness(root: root)
        try await insertPhotoRow(harness.db, id: "photo-1", sessionId: harness.sessionId, filepath: photoPath, assetFileId: nil)
        // 模拟上次扫描提交的索引基线（无 asset_files 行，照片行自带基线）。
        _ = try await harness.db.run("""
            UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
            WHERE id = 'photo-1'
          """, [
            .text("hash-1"), .int(originalStat.size), .real(originalStat.mtimeMs),
        ])
        // 磁盘文件与索引基线不同。
        try Data("different-content-with-another-size".utf8).write(to: URL(fileURLWithPath: photoPath))

        let result = try await harness.scan()

        #expect(result.discovered == 1)
        #expect(try await harness.sessionStore.indexSeq(id: harness.sessionId) == 1)
    }
}

/// 第四轮审计 #3（MED）：取消/失败后 index_seq 不 bump。
/// 批次已提交但扫描中途取消时，新照片对已完成分析（sim/fkw）的可见性
/// 依赖 index_seq 游标推进；任何终态只要发生过真实变更都必须 bump。
@Suite("IndexerRuntime index_seq on cancelled scan")
struct CancelledScanIndexSeqTests {
    /// 取消闸门：fileHasher 接缝在首批哈希期间登记取消（旧用例经 getDimensions
    /// 抛取消；IndexerRuntime.scan 无 context，取消走 cancel(sessionId:) +
    /// 批间消费通道，等价 scanSession 的批间 throwIfCancelled）。
    private actor CancelGate {
        private var fire: (@Sendable (String) async -> Void)?
        func install(_ fire: @escaping @Sendable (String) async -> Void) { self.fire = fire }
        func trigger(_ sessionId: String) async { await fire?(sessionId) }
    }

    @Test("bumps index_seq when the scan is cancelled after a batch committed")
    func bumpsIndexSeqOnCancelledScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // 33 张照片（字典序：…p7、p8、p9）：首批 32 张提交时，第 32 张
        // （p8.jpg）哈希中登记取消；随后的批间检查抛取消。
        for i in 0..<33 {
            try Data("content-\(i)".utf8).write(to: URL(fileURLWithPath: root + "/p\(i).jpg"))
        }
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-indexer-cancel-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let assetStore = try SQLiteAssetStore(database: try SQLiteDatabase(path: dbPath))
        let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
        let session = try await sessionStore.create(name: "Index", source: "folder", sourcePath: root)
        // 预置已完成的 sim/fkw 分析（快照 index_seq=0）：扫描必须推进会话
        // index_seq，否则这两条已完成分析永远看不到新照片。
        _ = try await db.run("""
            INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, 'similarity', 0, 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', '{}', 'ok')
          """, [.text(session.id)])
        _ = try await db.run("""
            INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
            VALUES (?, 'face_keywording', 0, 0, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z', '{}', 'ok')
          """, [.text(session.id)])

        // 首批 32 张的末位（p8.jpg）哈希时登记取消：批仍提交；扫描在批间
        // throwIfCancelled 抛 JobCancelledError（修复前异常跳过终态块，
        // index_seq 停在 0）。
        let gate = CancelGate()
        let lastBatchPath = root + "/p8.jpg"
        let runtime = IndexerRuntime(
            dependencies: IndexerRuntime.Dependencies(
                sessionStore: sessionStore,
                photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
                assetStore: assetStore,
                database: db,
                getDimensions: { _ in (100, 80) },
                getSetting: { key, defaultValue in
                    key == "lazy_checksum" ? "false" : defaultValue
                },
                fileHasher: { path in
                    if path == lastBatchPath { await gate.trigger(session.id) }
                    return try IndexerRuntime.sha256File(path)
                }
            )
        )
        await gate.install { sessionId in await runtime.cancel(sessionId: sessionId) }

        await #expect(throws: JobCancelledError.self) {
            try await runtime.scan(sessionId: session.id, options: IndexScanParams(sessionId: session.id))
        }
        // 首批已提交（32 张入库）。
        #expect(try await rowCount(db, "SELECT COUNT(*) FROM photos WHERE session_id = ?", [.text(session.id)]) == 32)
        // 修复点：取消路径同样 bump —— 预置的已完成分析（index_seq=0）相对
        // 会话 index_seq（1）过期，新照片对分析可见。
        #expect(try await SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath)).indexSeq(id: session.id) == 1)
    }
}

// MARK: - 懒 checksum（TS index-lazy-checksum.test.ts 逐条对应）

@Suite("IndexerRuntime lazy checksum")
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

    private func seedExistingPhotos(_ harness: IndexerHarness, _ fixture: Fixture) async throws {
        let untouchedStat = try IndexerRuntime.defaultStat(fixture.untouchedPath)
        // changed 的 asset_files 行基线是假的（大小/时间错位 → 内容判定变化）。
        try await insertAssetFileRow(harness.db, id: "file-changed", filepath: fixture.changedPath, fileSize: 1, fileMtimeMs: 1, checksum: "")
        try await insertAssetFileRow(harness.db, id: "file-untouched", filepath: fixture.untouchedPath, fileSize: untouchedStat.size, fileMtimeMs: untouchedStat.mtimeMs, checksum: "")
        try await insertPhotoRow(harness.db, id: "changed", sessionId: harness.sessionId, filepath: fixture.changedPath, assetFileId: "file-changed")
        try await insertPhotoRow(harness.db, id: "untouched", sessionId: harness.sessionId, filepath: fixture.untouchedPath, assetFileId: "file-untouched")
    }

    @Test("skips hashing and records an empty checksum when lazy_checksum is enabled")
    func lazySkipsHashing() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let harness = try await makeHarness(root: fixture.root, lazyChecksum: "true")
        try await seedExistingPhotos(harness, fixture)
        let changedStat = try IndexerRuntime.defaultStat(fixture.changedPath)

        let result = try await harness.scan()

        #expect(result.discovered == 3)
        #expect(result.added == 1)
        #expect(result.missing == 0)
        // 新文件：空 checksum 入库。
        let newRow = try await harness.db.queryOne("SELECT filepath, checksum FROM photos WHERE id = (SELECT id FROM photos WHERE filepath = ?)", [.text(fixture.newPath)])
        #expect(newRow?.text(at: 1) == "")
        // 内容变化的照片：写空 checksum + 新鲜 stat。
        let changedRow = try await harness.db.queryOne("SELECT checksum, checksum_file_size, checksum_file_mtime_ms FROM photos WHERE id = 'changed'")
        #expect(changedRow?.text(at: 0) == "")
        #expect(changedRow?.int(at: 1) == changedStat.size)
        #expect(abs((changedRow?.double(at: 2) ?? 0) - changedStat.mtimeMs) < 1)
        // 未变化照片（快照 checksum 为空）：懒模式不得写入空值覆盖并发回填结果。
        let untouchedRow = try await harness.db.queryOne("SELECT checksum, checksum_file_size FROM photos WHERE id = 'untouched'")
        #expect(untouchedRow?.text(at: 0) == "")
        #expect(untouchedRow?.int(at: 1) == 0)
    }

    @Test("computes checksums synchronously when lazy_checksum is disabled")
    func nonLazyHashes() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let harness = try await makeHarness(root: fixture.root, lazyChecksum: "false")
        try await seedExistingPhotos(harness, fixture)

        let result = try await harness.scan()

        #expect(result.added == 1)
        let newRow = try await harness.db.queryOne("SELECT checksum FROM photos WHERE filepath = ?", [.text(fixture.newPath)])
        #expect(newRow?.text(at: 0) == sha256Hex(fixture.newContent))
        #expect(try await photoChecksum(harness.db, "changed") == sha256Hex(fixture.changedContent))
        #expect(try await photoChecksum(harness.db, "untouched") == sha256Hex(fixture.untouchedContent))
    }
}

// MARK: - ghost photo 竞态（TS index-ghost-photo.test.ts 逐条对应）

@Suite("IndexerRuntime incremental scan ghost photos")
struct GhostPhotoTests {
    /// 只对 ghost 路径抛错的 stat 接缝（模拟目录列举与 stat 之间的 TOCTOU 竞态）。
    private func makeStatSeam(ghostPath: String) -> @Sendable (String) throws -> IndexerRuntime.FileStat {
        let realStat = IndexerRuntime.defaultStat
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
        let harness = try await makeHarness(root: root, stat: makeStatSeam(ghostPath: ghostPath))
        let ghostStat = try IndexerRuntime.defaultStat(ghostPath)
        let okStat = try IndexerRuntime.defaultStat(okPath)
        try await insertAssetFileRow(harness.db, id: "file-ghost", filepath: ghostPath, fileSize: ghostStat.size, fileMtimeMs: ghostStat.mtimeMs, checksum: "c-ghost")
        try await insertAssetFileRow(harness.db, id: "file-ok", filepath: okPath, fileSize: okStat.size, fileMtimeMs: okStat.mtimeMs, checksum: "c-ok")
        try await insertPhotoRow(harness.db, id: "ghost", sessionId: harness.sessionId, filepath: ghostPath, assetFileId: "file-ghost")
        try await insertPhotoRow(harness.db, id: "ok", sessionId: harness.sessionId, filepath: okPath, assetFileId: "file-ok")

        let result = try await harness.scan()

        #expect(result.missing == 1)
        #expect(result.failed.isEmpty)
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'ghost' AND status = 'missing'") == 1)
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'ok' AND status = 'missing'") == 0)
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
        let harness = try await makeHarness(root: root, stat: makeStatSeam(ghostPath: ghostPath))
        let newStat = try IndexerRuntime.defaultStat(newPath)
        let ghostStat = try IndexerRuntime.defaultStat(ghostPath)
        // 旧资产行按真实 inode 匹配新路径文件（relink 依据）。
        try await insertAssetFileRow(
            harness.db, id: "file-old", filepath: oldPath,
            fileSize: newStat.size, fileMtimeMs: newStat.mtimeMs, checksum: "c-old",
            volumeId: "dev:\(newStat.dev)", fileIdentity: String(newStat.ino)
        )
        try await insertAssetFileRow(harness.db, id: "file-ghost", filepath: ghostPath, fileSize: ghostStat.size, fileMtimeMs: ghostStat.mtimeMs, checksum: "c-ghost")
        try await insertPhotoRow(harness.db, id: "relinked", sessionId: harness.sessionId, filepath: oldPath, assetFileId: "file-old")
        try await insertPhotoRow(harness.db, id: "ghost", sessionId: harness.sessionId, filepath: ghostPath, assetFileId: "file-ghost")

        let result = try await harness.scan()

        #expect(result.missing == 1)
        #expect(result.skipped == 1)
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'ghost' AND status = 'missing'") == 1)
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE id = 'relinked' AND status = 'missing'") == 0)
    }
}

// MARK: - checksum 回填（TS index-backfill-regression.test.ts 逐条对应）

@Suite("IndexerRuntime checksum backfill")
struct ChecksumBackfillTests {
    @Test("writes the backfilled checksum into asset_files so a later full scan keeps it")
    func backfillConvergesWithScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let filePath = root + "/photo.jpg"
        let content = "backfill-then-rescan"
        try Data(content.utf8).write(to: URL(fileURLWithPath: filePath))
        let fileStat = try IndexerRuntime.defaultStat(filePath)
        let checksum = sha256Hex(content)
        let harness = try await makeHarness(root: root, lazyChecksum: "true")
        // 懒首扫遗留状态：photos.checksum 空、asset_files.checksum 空。
        try await insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: filePath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: ""
        )
        _ = try await harness.db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('photo-1', ?, ?, 'photo.jpg', '', 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(harness.sessionId), .text(filePath)])

        let backfill = try await harness.runtime.backfillChecksums(sessionId: harness.sessionId)
        #expect(backfill.processed == 1)
        #expect(backfill.backfilled == 1)
        #expect(backfill.skipped == 0)
        let assetFile = try await harness.db.queryOne("SELECT checksum, file_size, file_mtime_ms FROM asset_files WHERE id = 'af-1'")
        #expect(assetFile?.text(at: 0) == checksum)
        #expect(assetFile?.int(at: 1) == fileStat.size)
        #expect(abs((assetFile?.double(at: 2) ?? 0) - fileStat.mtimeMs) < 1)

        // 第二次全量扫描必须命中 unchanged 路径：不再写 checksum，无待回填。
        let scan = try await harness.scan()
        #expect(scan.discovered == 1)
        #expect(scan.skipped == 1)
        #expect(try await photoChecksum(harness.db, "photo-1") == checksum)
        #expect(try await assetFileChecksum(harness.db, "af-1") == checksum)
        #expect(try await harness.pendingChecksumCount() == 0)
    }

    @Test("terminates when a photo cannot be read, leaving its checksum empty")
    func terminatesOnUnreadable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let goodPath = root + "/good.jpg"
        let content = "good-content"
        try Data(content.utf8).write(to: URL(fileURLWithPath: goodPath))
        let badPath = root + "/deleted.jpg"
        let harness = try await makeHarness(root: root)
        try await insertPhotoRow(harness.db, id: "good", sessionId: harness.sessionId, filepath: goodPath, assetFileId: nil)
        try await insertPhotoRow(harness.db, id: "bad", sessionId: harness.sessionId, filepath: badPath, assetFileId: nil)

        let result = try await harness.runtime.backfillChecksums(sessionId: harness.sessionId)

        // 不可读照片记入失败集、排除后续趟次，任务完成而非无限重试。
        #expect(result.processed == 2)
        #expect(result.backfilled == 1)
        #expect(result.skipped == 1)
        #expect(try await photoChecksum(harness.db, "good") == sha256Hex(content))
        #expect(try await photoChecksum(harness.db, "bad") == "")
    }

    @Test("stops after a pass with zero successes instead of spinning")
    func stopsOnZeroSuccess() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let harness = try await makeHarness(root: root)
        try await insertPhotoRow(harness.db, id: "bad-1", sessionId: harness.sessionId, filepath: root + "/gone-1.jpg", assetFileId: nil)
        try await insertPhotoRow(harness.db, id: "bad-2", sessionId: harness.sessionId, filepath: root + "/gone-2.jpg", assetFileId: nil)

        let result = try await harness.runtime.backfillChecksums(sessionId: harness.sessionId)

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
        let fileStat = try IndexerRuntime.defaultStat(filePath)
        let checksum = sha256Hex(content)
        let harness = try await makeHarness(root: root, lazyChecksum: "true")
        // 竞态状态：backfill 已提交 photos.checksum，但扫描的 asset_files 快照
        // 仍为空 checksum（文件本身未变化）。
        try await insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: filePath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: ""
        )
        _ = try await harness.db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('photo-1', ?, ?, 'photo.jpg', ?, 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(harness.sessionId), .text(filePath), .text(checksum)])

        let scan = try await harness.scan()

        // 未变化文件必须保留已回填的 checksum：不写 photos.checksum，
        // 也不碰空的 asset_files.checksum（preserve 条件写）。
        #expect(scan.missing == 0)
        #expect(try await photoChecksum(harness.db, "photo-1") == checksum)
        #expect(try await assetFileChecksum(harness.db, "af-1") == "")
        #expect(try await harness.pendingChecksumCount() == 0)
    }

    @Test("preserves the asset_files checksum via a conditional write when the snapshot lacks one")
    func conditionalAssetFileWrite() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let filePath = root + "/photo.jpg"
        try Data("content".utf8).write(to: URL(fileURLWithPath: filePath))
        let fileStat = try IndexerRuntime.defaultStat(filePath)
        let harness = try await makeHarness(root: root, lazyChecksum: "true")
        try await insertFullAssetChain(
            harness.db, assetFileId: "af-1", assetId: "asset-1", sessionId: harness.sessionId,
            filepath: filePath, fileSize: fileStat.size, fileMtimeMs: fileStat.mtimeMs, checksum: ""
        )
        // photos.checksum 已被回填，asset_files.checksum 仍为空。
        _ = try await harness.db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('photo-1', ?, ?, 'photo.jpg', 'H', 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(harness.sessionId), .text(filePath)])

        let scan = try await harness.scan()

        // SQL 层观察：existing 分支带 preserve 标志发送 —— checksum 列保留现值
        // 而非被空串覆盖。
        #expect(scan.missing == 0)
        #expect(try await photoChecksum(harness.db, "photo-1") == "H")
        #expect(try await assetFileChecksum(harness.db, "af-1") == "")
        let width = try await harness.db.queryOne("SELECT width FROM photos WHERE id = 'photo-1'")
        #expect(width?.int(at: 0) == 100)
    }

    @Test("skips the backfill write when a concurrent writer already filled the checksum")
    func concurrentWriterSkipsWrite() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let pendingPath = root + "/pending.jpg"
        try Data("race-content".utf8).write(to: URL(fileURLWithPath: pendingPath))
        // 并发写入者接缝：读取阶段（pending 已加载）之后、守卫 UPDATE 之前，
        // 另一写入者先填了 checksum —— 守卫（AND checksum = ''）必须拒绝覆盖。
        // fileHasher 需在 Runtime 构造期注入，故此处内联装配（不经 harness）。
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("gather-indexer-race-\(UUID().uuidString).sqlite").path
        let db = try await makeMigratedStore(path: dbPath)
        let assetStore = try SQLiteAssetStore(database: try SQLiteDatabase(path: dbPath))
        let sessionStore = try SQLiteSessionStore(database: try SQLiteDatabase(path: dbPath))
        let session = try await sessionStore.create(name: "Index", source: "folder", sourcePath: root)
        let runtime = IndexerRuntime(
            dependencies: IndexerRuntime.Dependencies(
                sessionStore: sessionStore,
                photoStore: try SQLitePhotoStore(database: try SQLiteDatabase(path: dbPath)),
                assetStore: assetStore,
                database: db,
                fileHasher: { path in
                    _ = try await db.run("UPDATE photos SET checksum = 'concurrent-hash' WHERE id = 'pending'")
                    return try IndexerRuntime.sha256File(path)
                }
            )
        )
        try await insertFullAssetChain(
            db, assetFileId: "af-1", assetId: "asset-1", sessionId: session.id,
            filepath: pendingPath, fileSize: 0, fileMtimeMs: 0, checksum: ""
        )
        _ = try await db.run("""
            INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
            VALUES ('pending', ?, ?, 'pending.jpg', '', 'pending', '{}', '{}', 'asset-1', 'af-1', 100, 80, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
          """, [.text(session.id), .text(pendingPath)])

        let result = try await runtime.backfillChecksums(sessionId: session.id)

        #expect(result.processed == 1)
        #expect(result.backfilled == 0)
        #expect(result.skipped == 1)
        #expect(try await photoChecksum(db, "pending") == "concurrent-hash")
        // 守卫未过：资产行写入一并跳过（photos 与 asset_files 保持一致）。
        #expect(try await assetFileChecksum(db, "af-1") == "")
    }

    @Test("supports cancellation between batches")
    func cancelsBetweenBatches() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // 首批哈希期间到达取消（signal.abort）：批仍提交，次趟循环检查抛出。
        let signal = JobAbortSignal()
        let harness = try await makeHarness(root: root, fileHasher: { path in
            signal.abort()
            return try IndexerRuntime.sha256File(path)
        })
        // 33 张照片：首批 32 张完成后仍剩 pending → 下一趟循环抛取消。
        for i in 0..<33 {
            let path = root + "/p\(i).jpg"
            try Data("content-\(i)".utf8).write(to: URL(fileURLWithPath: path))
            try await insertPhotoRow(harness.db, id: "p\(i)", sessionId: harness.sessionId, filepath: path, assetFileId: nil)
        }
        let jobStore = try await makeTempJobStore()
        let job = try await jobStore.create(JobCreateParams(
            type: .checksumBackfill, scopeType: "session", scopeId: harness.sessionId, dedupeKey: "d"
        ))
        // JobRunnerContext 直写 Store：先 claim 使进度写成功（旧 JobRunContext
        // 注入恒真 updateProgress 的等价接线）。
        _ = try await jobStore.claim(id: job.id, leaseOwner: "test")
        let context = JobRunnerContext(
            signal: signal,
            jobStore: jobStore,
            job: job,
            leaseOwner: "test",
            progressWriteIntervalMs: JobRunner.progressWriteIntervalMs,
            progressSink: nil
        )

        await #expect(throws: JobCancelledError.self) {
            try await harness.runtime.backfillChecksums(sessionId: harness.sessionId, context: context)
        }
        // 首批已提交：32 张照片被回填。
        #expect(try await rowCount(harness.db, "SELECT COUNT(*) FROM photos WHERE checksum != ''") == 32)
    }
}
