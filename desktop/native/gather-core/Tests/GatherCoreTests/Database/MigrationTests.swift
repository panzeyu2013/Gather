// desktop/native/gather-core/Tests/GatherCoreTests/Database/MigrationTests.swift
// 迁移测试（1.2）：空库迁移后与 docs/fixtures/schema.snapshot.json 全表核对；
// 逐级 0→32 路径、备份/回滚（ADR-005）、缩略图落盘、唯一照片路径索引分支。

import Foundation
import Testing
import CSQLite
@testable import GatherCore

private struct SchemaSnapshot: Decodable {
    let schemaVersion: Int
    let tables: [String]
}

/// 从 #filePath 向上逐级查找仓库根的 docs/fixtures/schema.snapshot.json
/// （对测试文件在包内任意深度均适用）。
private func loadSnapshot() throws -> SchemaSnapshot {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var found: URL?
    while url.path != "/" {
        let candidate = url.appendingPathComponent("docs/fixtures/schema.snapshot.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            found = candidate
            break
        }
        url.deleteLastPathComponent()
    }
    guard let snapshotURL = found else {
        throw DBError.message("未找到 docs/fixtures/schema.snapshot.json（自 #filePath 向上查找失败）")
    }
    let data = try Data(contentsOf: snapshotURL)
    return try JSONDecoder().decode(SchemaSnapshot.self, from: data)
}

private func tableNames(_ db: DBConnection) throws -> [String] {
    let rows = try db.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).query()
    return rows.compactMap { $0[0].textValue }
}

private func schemaVersion(_ db: DBConnection) throws -> Int {
    // 与 MigrationRunner.getSchemaVersion 相同的容错语义：无 schema_version 表 → 0
    guard let row = try? db.prepare("SELECT MAX(version) as version FROM schema_version").get() else { return 0 }
    return Int(row[0].intValue ?? 0)
}

private func indexExists(_ db: DBConnection, _ name: String) throws -> Bool {
    try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?").get([.text(name)]) != nil
}

private func tableColumnNames(_ db: DBConnection, _ table: String) throws -> [String] {
    let rows = try db.prepare("PRAGMA table_info(\(table))").query()
    return rows.compactMap { $0[1].textValue }
}

private func tempDir() throws -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gather-migration-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

@Suite(.serialized)
struct MigrationTests {
    @Test func emptyDatabaseMatchesSnapshot() throws {
        let snapshot = try loadSnapshot()
        #expect(snapshot.schemaVersion == 33)
        #expect(snapshot.tables.count == 43)

        let db = try DBConnection(path: ":memory:")
        try MigrationRunner().migrate(db)
        defer { db.close() }

        #expect(try schemaVersion(db) == snapshot.schemaVersion)
        let actual = try tableNames(db)
        #expect(actual == snapshot.tables.sorted())
        #expect(actual.count == snapshot.tables.count)

        // 快照只记录表名；关键索引一并自检（INDEX_SQL 已执行）。
        for index in ["idx_photos_session", "idx_asset_files_volume_path", "idx_photos_session_filepath"] {
            #expect(try indexExists(db, index), "index \(index) should exist")
        }
    }

    @Test func migrateIsIdempotent() throws {
        let db = try DBConnection(path: ":memory:")
        let runner = MigrationRunner()
        try runner.migrate(db)
        try runner.migrate(db)
        defer { db.close() }

        #expect(try schemaVersion(db) == 33)
        #expect(try tableNames(db).count == loadSnapshot().tables.count)
    }

    @Test func stepwiseFromLegacyVersionZero() throws {
        // 模拟 v0 时代遗留库：face_cluster_members 无 observation_id 外键（旧形态，
        // 含一行数据），v1 应重建表并把数据搬进新形态；sessions/photos/face_clusters
        // 提供 JOIN 所需的引用行。
        let db = try DBConnection(path: ":memory:")
        try db.exec("""
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'draft',
              analysis_status TEXT NOT NULL DEFAULT 'idle', writeback_status TEXT NOT NULL DEFAULT 'idle',
              import_source TEXT NOT NULL DEFAULT 'unknown', source_path TEXT NOT NULL DEFAULT '',
              truncated_import INTEGER NOT NULL DEFAULT 0, reload_acked_at TEXT,
              index_seq INTEGER NOT NULL DEFAULT 0, photo_count INTEGER NOT NULL DEFAULT 0,
              failed_writeback_count INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE photos (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, filepath TEXT NOT NULL,
              filename TEXT NOT NULL DEFAULT '', checksum TEXT NOT NULL DEFAULT '',
              checksum_file_size INTEGER NOT NULL DEFAULT 0, checksum_file_mtime_ms REAL NOT NULL DEFAULT 0,
              status TEXT NOT NULL DEFAULT 'pending', metadata TEXT NOT NULL DEFAULT '{}', result TEXT NOT NULL DEFAULT '{}',
              asset_id TEXT, asset_file_id TEXT, width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE face_clusters (
              id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL DEFAULT '',
              label TEXT NOT NULL DEFAULT '', member_count INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL DEFAULT 'unbound', thumbnail_base64 TEXT NOT NULL DEFAULT '',
              thumbnail_path TEXT NOT NULL DEFAULT '', matched_person_id TEXT,
              synced_to_library INTEGER NOT NULL DEFAULT 0, match_confidence REAL,
              created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE face_cluster_members (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              photo_id TEXT NOT NULL REFERENCES photos(id),
              bbox TEXT NOT NULL,
              confidence REAL NOT NULL DEFAULT 0.0
            );
            INSERT INTO sessions (id, created_at, updated_at) VALUES ('s1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES ('p1', 's1', 'a.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO face_clusters (id, session_id) VALUES (1, 's1');
            INSERT INTO face_cluster_members (id, cluster_id, session_id, photo_id, bbox, confidence) VALUES (1, 1, 's1', 'p1', '[0,0,1,1]', 1.0);
            """)
        try MigrationRunner().migrate(db)
        defer { db.close() }

        #expect(try schemaVersion(db) == 33)
        #expect(try !tableExists(db, "__face_cluster_members_old"))
        let cols = try tableColumnNames(db, "face_cluster_members")
        #expect(cols.contains("observation_id"))
        let row = try db.prepare(
            "SELECT id, cluster_id, session_id, photo_id, bbox, observation_id FROM face_cluster_members"
        ).get()
        #expect(row?[0].intValue == 1)
        #expect(row?[1].intValue == 1)
        #expect(row?[2].textValue == "s1")
        #expect(row?[3].textValue == "p1")
        #expect(row?[5].intValue == nil, "旧表无 observation_id 列，应回填 NULL")    }

    @Test func midVersionJump30To33() throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec("""
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
            INSERT INTO schema_version (version, applied_at) VALUES (30, '2026-08-01T00:00:00.000Z');
            """)
        try MigrationRunner().migrate(db)
        defer { db.close() }

        #expect(try schemaVersion(db) == 33)
        #expect(try tableColumnNames(db, "sessions").contains("reload_acked_at"))
        let applied = try db.prepare("SELECT applied_at FROM schema_version WHERE version = 31").get()
        #expect(applied?[0].textValue?.isEmpty == false)
    }

    @Test func duplicatePhotoPathsSkipUniqueIndex() throws {
        let db = try DBConnection(path: ":memory:")
        // 与真实启动路径一致：先铺 SCHEMA_SQL（幂等），再灌入重复数据。
        try db.exec(StoreSchema.schemaSQL)
        try db.exec("""
            INSERT INTO sessions (id, created_at, updated_at) VALUES ('s1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES
              ('p1', 's1', 'dup.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
              ('p2', 's1', 'dup.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            """)
        try MigrationRunner().migrate(db)
        defer { db.close() }

        #expect(try schemaVersion(db) == 33)
        #expect(try !indexExists(db, "idx_photos_session_filepath"),
            "存在重复 (session_id, filepath) 时不得创建唯一索引")
    }

    @Test func pendingFaceThumbnailsAreMaterialized() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let jpegData = Data("fake-jpeg-bytes".utf8)
        let base64 = jpegData.base64EncodedString()

        let db = try DBConnection(path: ":memory:")
        try db.exec("""
            CREATE TABLE face_clusters (
              id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL DEFAULT '',
              label TEXT NOT NULL DEFAULT '', member_count INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL DEFAULT 'unbound', thumbnail_base64 TEXT NOT NULL DEFAULT '',
              thumbnail_path TEXT NOT NULL DEFAULT '', matched_person_id TEXT,
              synced_to_library INTEGER NOT NULL DEFAULT 0, match_confidence REAL,
              created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
            );
            INSERT INTO face_clusters (id, thumbnail_base64, thumbnail_path) VALUES
              (1, '\(base64)', ''),
              (2, '', '__migration_failed__');
            """)
        let runner = MigrationRunner(faceThumbnailFallbackDir: dir)
        try runner.migrate(db)
        defer { db.close() }

        // 行 1：落盘 + 清空 base64；行 2：失败标记被重置为空。
        let row1 = try db.prepare("SELECT thumbnail_path, thumbnail_base64 FROM face_clusters WHERE id = 1").get()
        #expect(row1?[0].textValue == "1.jpg")
        #expect(row1?[1].textValue == "")
        let row2 = try db.prepare("SELECT thumbnail_path FROM face_clusters WHERE id = 2").get()
        #expect(row2?[0].textValue == "")

        let fileURL = URL(fileURLWithPath: dir + "/1.jpg")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == jpegData)
    }

    @Test func backupAndRollbackOnInjectedFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dbPath = dir + "/test.db"

        let db = try DBConnection(path: dbPath)
        try db.exec("""
            CREATE TABLE marker (id INTEGER PRIMARY KEY, v TEXT);
            INSERT INTO marker (id, v) VALUES (1, 'pre');
            """)

        var runner = MigrationRunner(databaseFilePath: dbPath)
        runner.afterMigrateHook = { throw DBError.message("Injected migration failure") }
        #expect(throws: DBError.self) { try runner.migrate(db) }

        // 恢复后连接自动重开，迁移前数据完好、版本未动、v33 表不存在。
        #expect(try schemaVersion(db) == 0)
        let marker = try db.prepare("SELECT v FROM marker WHERE id = 1").get()
        #expect(marker?[0].textValue == "pre")
        #expect(try !tableExists(db, "sessions"))

        // 备份文件存在且通过 integrity_check；-wal/-shm 已清理。
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("test.db.pre-v33-") && $0.hasSuffix(".bak") }
        #expect(backups.count == 1)
        let backup = try DBConnection(path: dir + "/" + backups[0])
        defer { backup.close() }
        let integrity = try backup.prepare("PRAGMA integrity_check").query()
        #expect(integrity.count == 1 && integrity[0][0].textValue == "ok")
        // 注：恢复后连接会重开并重新进入 WAL 模式，-wal/-shm 会被重建（与 TS 侧
        // 惰性重开行为一致），故此处只核对主库文件内容，不核对 wal/shm 缺失。

        // 恢复后的库必须可重新迁移（TS：失败后下一次启动照常重跑迁移）。
        try MigrationRunner(databaseFilePath: dbPath).migrate(db)
        #expect(try schemaVersion(db) == 33)
        #expect(try tableExists(db, "sessions"))

        db.close()
    }

    @Test func migrationBackupPruningKeepsNewest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dbPath = dir + "/gather.db"

        // 预置 4 个旧备份（不同 mtime），迁移成功后应只剩最新 3 个。
        for i in 0..<4 {
            let path = dir + "/gather.db.pre-v33-\(1700000000000 + Int64(i)).bak"
            try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        }
        let db = try DBConnection(path: dbPath)
        try MigrationRunner(databaseFilePath: dbPath).migrate(db)
        defer { db.close() }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("gather.db.pre-v33-") && $0.hasSuffix(".bak") }
        #expect(remaining.count == 3, "应只保留最新 3 个备份，实际: \(remaining)")
    }
}

private func tableExists(_ db: DBConnection, _ name: String) throws -> Bool {
    try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get([.text(name)]) != nil
}
