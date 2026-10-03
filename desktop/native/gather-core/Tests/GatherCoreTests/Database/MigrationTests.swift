// desktop/native/gather-core/Tests/GatherCoreTests/Database/MigrationTests.swift
// 迁移测试（1.2）：空库迁移后与 docs/fixtures/schema.snapshot.json 全表核对；
// 逐级 0→34 路径、备份/回滚（ADR-005）、缩略图落盘、重复照片路径的确定性合并与唯一索引。

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
        #expect(snapshot.schemaVersion == 35)
        #expect(snapshot.tables.count == 44)

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

        #expect(try schemaVersion(db) == 35)
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

        #expect(try schemaVersion(db) == 35)
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

    @Test func midVersionJump30To34() throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec("""
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
            INSERT INTO schema_version (version, applied_at) VALUES (30, '2026-08-01T00:00:00.000Z');
            """)
        try MigrationRunner().migrate(db)
        defer { db.close() }

        #expect(try schemaVersion(db) == 35)
        #expect(try tableColumnNames(db, "sessions").contains("reload_acked_at"))
        let applied = try db.prepare("SELECT applied_at FROM schema_version WHERE version = 31").get()
        #expect(applied?[0].textValue?.isEmpty == false)

        // v30 老库跳级到 v34：v34 的六列同样必须补齐。
        let observationColumns = try tableColumnNames(db, "face_observations")
        for column in ["quality", "face_size_px", "roll_degrees", "model_id", "model_version", "embedding_dim"] {
            #expect(observationColumns.contains(column), "v34 列 \(column) 必须存在")
        }
    }

    /// v34 升级路径：v33 存量库（face_observations 仅旧 13 列、含一行数据）经迁移
    /// 必须只 ALTER 追加新列 —— 行数与旧数据不变、新列默认值正确；升级库与新库的
    /// face_observations 列定义/列序逐项一致（ALTER 只能追加行尾，故 Schema.swift
    /// 也必须把 v34 列声明在尾部，否则 SELECT * 行映射会在两库间分叉）。
    @Test func legacyV33UpgradesFaceObservationQualityColumns() throws {
        let db = try DBConnection(path: ":memory:")
        try db.exec("""
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'draft',
              writeback_status TEXT NOT NULL DEFAULT 'idle', import_source TEXT NOT NULL DEFAULT 'unknown',
              source_path TEXT NOT NULL DEFAULT '', truncated_import INTEGER NOT NULL DEFAULT 0,
              reload_acked_at TEXT, index_seq INTEGER NOT NULL DEFAULT 0, photo_count INTEGER NOT NULL DEFAULT 0,
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
            CREATE TABLE face_observations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              photo_id TEXT NOT NULL REFERENCES photos(id),
              session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              bbox_x REAL NOT NULL, bbox_y REAL NOT NULL, bbox_w REAL NOT NULL, bbox_h REAL NOT NULL,
              embedding BLOB NOT NULL, confidence REAL NOT NULL DEFAULT 0.0,
              source_file_size INTEGER NOT NULL DEFAULT 0, source_file_mtime_ms REAL NOT NULL DEFAULT 0,
              analysis_signature TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT ''
            );
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
            INSERT INTO schema_version (version, applied_at) VALUES (33, '2026-08-10T00:00:00.000Z');
            INSERT INTO sessions (id, created_at, updated_at)
              VALUES ('s1', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at)
              VALUES ('p1', 's1', '/v/p1.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO face_observations
              (id, photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
               source_file_size, source_file_mtime_ms, analysis_signature, created_at)
              VALUES (7, 'p1', 's1', 0.1, 0.2, 0.3, 0.4, X'01020304', 0.75,
                      1234, 1700000000123.5, 'sig-legacy', '2026-01-01T00:00:00.000Z');
            """)
        defer { db.close() }

        #expect(try tableColumnNames(db, "face_observations").count == 13, "夹具必须是 v33 旧形态（13 列）")
        try MigrationRunner().migrate(db)

        #expect(try schemaVersion(db) == 35)
        let columns = try tableColumnNames(db, "face_observations")
        for column in ["quality", "face_size_px", "roll_degrees", "model_id", "model_version", "embedding_dim"] {
            #expect(columns.contains(column), "v34 列 \(column) 必须存在")
        }

        // 既有行未被重建/覆盖：行数、旧列内容、六列默认值逐项核对。
        #expect(try rowCount(db, "SELECT COUNT(*) FROM face_observations") == 1)
        let row = try db.prepare("""
            SELECT id, photo_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding, confidence,
                   source_file_size, source_file_mtime_ms, analysis_signature, created_at,
                   quality, face_size_px, roll_degrees, model_id, model_version, embedding_dim
            FROM face_observations
            """).get()
        #expect(row?[0].intValue == 7)
        #expect(row?[1].textValue == "p1")
        #expect(row?[7].doubleValue == 0.75)
        #expect(row?[8].intValue == 1234)
        #expect(row?[9].doubleValue == 1_700_000_000_123.5)
        #expect(row?[10].textValue == "sig-legacy")
        #expect(row?[11].textValue == "2026-01-01T00:00:00.000Z")
        var embeddingData = Data()
        if let cell = row?[6], case .blob(let data) = cell { embeddingData = data }
        #expect(embeddingData == Data([1, 2, 3, 4]))
        #expect(row?[12].doubleValue == 0)
        #expect(row?[13].doubleValue == 0)
        #expect(row?[14].doubleValue == 0)
        #expect(row?[15].textValue == "")
        #expect(row?[16].textValue == "")
        #expect(row?[17].intValue == 0)

        // 新库（SchemaSQL 直接建）与升级库列定义/列序逐项相等。
        let fresh = try DBConnection(path: ":memory:")
        defer { fresh.close() }
        try MigrationRunner().migrate(fresh)
        func columnShape(_ connection: DBConnection) throws -> [String] {
            try connection.prepare("PRAGMA table_info(face_observations)").query().map { info in
                "\(info[1].textValue ?? "")|\(info[2].textValue ?? "")|\(info[3].intValue ?? -1)|\(info[4].textValue ?? "")|\(info[5].intValue ?? -1)"
            }
        }
        #expect(try columnShape(db) == columnShape(fresh), "升级库与新建库的列定义/列序必须同形")

        // 幂等：再次迁移不重复加列，已写入的新值不被默认值覆盖。
        _ = try db.prepare("UPDATE face_observations SET quality = 0.8, embedding_dim = 4 WHERE id = 7").run()
        try MigrationRunner().migrate(db)
        #expect(try schemaVersion(db) == 35)
        #expect(try tableColumnNames(db, "face_observations") == columns)
        let persisted = try db.prepare("SELECT quality, embedding_dim FROM face_observations WHERE id = 7").get()
        #expect(persisted?[0].doubleValue == 0.8)
        #expect(persisted?[1].intValue == 4)
    }

    /// 历史库里的重复 filepath 必须在迁移期被确定性合并，而不是跳过唯一索引：
    /// 唯一索引缺失会让「归一化路径 → 照片行」映射退化为脏数据（扫描期 trap）。
    /// 本测试覆盖四种引用形态：
    ///   ① 无唯一约束直接改指向（face_observations / similarity_hashes / writeback_items）
    ///   ② 有唯一约束、重复行与保留行冲突 → 重复行副本被丢弃（culling_decisions /
    ///      photo_metadata_cache）
    ///   ③ 故意不声明 photos 外键的 similarity_cluster_state → 显式改指向
    ///   ④ navigation_groups 的 JSON 成员列表 + lead_photo_id 外键 → 整词改指向
    /// 并断言跨会话同名路径不受影响（唯一键是 (session_id, filepath)）。
    @Test func duplicatePhotoPathsAreMergedAndIndexed() throws {
        let db = try DBConnection(path: ":memory:")
        // 与真实启动路径一致：先铺 SCHEMA_SQL + INDEX_SQL（幂等），再灌入重复数据。
        try db.exec(SchemaSQL.schemaSQL)
        try db.exec(SchemaSQL.indexSQL)
        try db.exec("""
            INSERT INTO sessions (id, photo_count, created_at, updated_at) VALUES
              ('s1', 2, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
              ('s2', 7, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO photos (id, session_id, filepath, created_at, updated_at) VALUES
              ('p1', 's1', '/lib/dup.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
              ('p2', 's1', '/lib/dup.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'),
              ('p3', 's2', '/lib/dup.jpg', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO face_observations
              (id, photo_id, session_id, bbox_x, bbox_y, bbox_w, bbox_h, embedding)
              VALUES (1, 'p2', 's1', 0, 0, 1, 1, X'00');
            INSERT INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES ('s1', 'p2', 'deadbeef');
            INSERT INTO writeback_items (photo_id, session_id, module) VALUES ('p2', 's1', 'culling');
            INSERT INTO culling_decisions (session_id, photo_id, group_id, updated_at) VALUES
              ('s1', 'p1', 'g', '2026-01-01T00:00:00.000Z'),
              ('s1', 'p2', 'g', '2026-01-01T00:00:00.000Z');
            INSERT INTO photo_metadata_cache (photo_id, session_id, cached_at) VALUES
              ('p1', 's1', '2026-01-01T00:00:00.000Z'),
              ('p2', 's1', '2026-01-01T00:00:00.000Z');
            INSERT INTO similarity_cluster_state (session_id, photo_id, hash_hex, component_index)
              VALUES ('s1', 'p2', 'aa', 0);
            INSERT INTO navigation_groups
              (id, session_id, group_type, photo_ids_json, lead_photo_id, created_at, updated_at)
              VALUES ('g1', 's1', 'burst', '["p2","px"]', 'p2',
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            -- 引用 photos.id 的 JSON 列（无 FK 声明，必须靠运行时枚举发现）：
            INSERT INTO culling_history (session_id, operation_json, created_at)
              VALUES ('s1', '{"operations":[{"op":"rating","photoIds":["p1","p2"]}],"photoId":"p2"}',
                      '2026-01-01T00:00:00.000Z');
            INSERT INTO similarity_results
              (session_id, groups_json, stats_json, param_threshold, created_at)
              VALUES ('s1', '["p1","p2"]', '{"groupCount":1,"leadPhotoId":"p2"}', 1,
                      '2026-01-01T00:00:00.000Z');
            INSERT INTO analysis_jobs
              (id, type, scope_type, scope_id, dedupe_key, status, checkpoint_json, created_at, updated_at)
              VALUES ('j1', 'similarity', 'session', 's1', 'k', 'running',
                      '{"photoIds":["p1","p2"],"nextPhotoIndex":1}',
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO asset_files (id, normalized_path, filename, created_at, updated_at)
              VALUES ('af1', '/lib/dup.jpg', 'dup.jpg',
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            INSERT INTO asset_analysis
              (asset_file_id, analysis_type, result_json, created_at, updated_at)
              VALUES ('af1', 'quality', '{"photoId":"p2"}',
                      '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z');
            """)
        try MigrationRunner().migrate(db)
        defer { db.close() }

        // (a) 唯一索引存在且确实是 UNIQUE。
        let indexSQL = try db.prepare(
            "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_photos_session_filepath'"
        ).get()?[0].textValue ?? ""
        #expect(try indexExists(db, "idx_photos_session_filepath"),
            "重复路径合并后必须建立唯一索引，实际 sql=(indexSQL)")
        #expect(indexSQL.uppercased().contains("UNIQUE"), "索引必须是唯一的，实际 sql=(indexSQL)")

        // (b) 行数按规则收敛：保留 rowid 最小者 p1；跨会话的 p3 不受影响；
        //     sessions.photo_count 同事务内重算。
        let remaining = try db.prepare(
            "SELECT id FROM photos WHERE session_id = 's1' AND filepath = '/lib/dup.jpg' ORDER BY rowid"
        ).query().compactMap { $0[0].textValue }
        #expect(remaining == ["p1"])
        #expect(try db.prepare("SELECT COUNT(*) FROM photos").get()?[0].intValue == 2)
        #expect(try db.prepare("SELECT photo_count FROM sessions WHERE id = 's1'").get()?[0].intValue == 1,
            "被合并的会话 photo_count 必须同事务重算")
        #expect(try db.prepare("SELECT photo_count FROM sessions WHERE id = 's2'").get()?[0].intValue == 7,
            "没有重复的会话不参与重算（其缓存计数由扫描期维护）")

        // (c) 引用完整：无唯一约束的表改指向；冲突副本被丢弃；JSON/FK 同步改指向。
        #expect(try db.prepare("SELECT photo_id FROM face_observations WHERE id = 1").get()?[0].textValue == "p1")
        #expect(try db.prepare("SELECT photo_id FROM similarity_hashes WHERE session_id = 's1'").get()?[0].textValue == "p1")
        #expect(try db.prepare("SELECT photo_id FROM writeback_items WHERE session_id = 's1'").get()?[0].textValue == "p1")
        #expect(try db.prepare("SELECT COUNT(*) FROM culling_decisions").get()?[0].intValue == 1,
            "重复行的决策与保留行撞唯一键时应丢弃副本而不是留下悬空引用")
        #expect(try db.prepare("SELECT photo_id FROM culling_decisions").get()?[0].textValue == "p1")
        #expect(try db.prepare("SELECT COUNT(*) FROM photo_metadata_cache").get()?[0].intValue == 1)
        #expect(try db.prepare("SELECT COUNT(*) FROM similarity_cluster_state WHERE photo_id = 'p2'").get()?[0].intValue == 0)
        let navigation = try db.prepare(
            "SELECT photo_ids_json, lead_photo_id FROM navigation_groups WHERE id = 'g1'"
        ).get()
        #expect(navigation?[0].textValue == "[\"p1\",\"px\"]")
        #expect(navigation?[1].textValue == "p1")
        let dangling = try db.prepare("PRAGMA foreign_key_check").query()
        #expect(dangling.isEmpty, "迁移后不得有悬空外键: (dangling)")

        // (c2) JSON/文本列里的 photos.id 也必须整词重写：culling_history 的 undo
        //      操作、similarity_results 的分组、analysis_jobs 的 photoIds 断点、
        //      asset_analysis 的结果若残留已删除的 p2，恢复/续跑会指向不存在的行。
        let history = try db.prepare("SELECT operation_json FROM culling_history").get()?[0].textValue ?? ""
        #expect(history == "{\"operations\":[{\"op\":\"rating\",\"photoIds\":[\"p1\",\"p1\"]}],\"photoId\":\"p1\"}",
            "culling_history.operation_json 必须重写，实际=(history)")
        #expect(!history.contains("p2"))
        let groups = try db.prepare("SELECT groups_json FROM similarity_results").get()?[0].textValue ?? ""
        #expect(groups == "[\"p1\",\"p1\"]", "similarity_results.groups_json 必须重写，实际=(groups)")
        let stats = try db.prepare("SELECT stats_json FROM similarity_results").get()?[0].textValue ?? ""
        #expect(!stats.contains("\"p2\""), "stats_json 同样不得残留悬空 id，实际=(stats)")
        let checkpoint = try db.prepare("SELECT checkpoint_json FROM analysis_jobs WHERE id = 'j1'").get()?[0].textValue ?? ""
        #expect(checkpoint == "{\"photoIds\":[\"p1\",\"p1\"],\"nextPhotoIndex\":1}",
            "analysis_jobs.checkpoint_json 必须重写且数组长度不变（续跑游标仍有效），实际=(checkpoint)")
        let assetResult = try db.prepare("SELECT result_json FROM asset_analysis").get()?[0].textValue ?? ""
        #expect(!assetResult.contains("\"p2\""), "asset_analysis.result_json 不得残留悬空 id，实际=(assetResult)")

        // (d) 再次迁移幂等，且索引与行数不变。
        try MigrationRunner().migrate(db)
        #expect(try schemaVersion(db) == 35)
        #expect(try indexExists(db, "idx_photos_session_filepath"))
        #expect(try db.prepare("SELECT COUNT(*) FROM photos").get()?[0].intValue == 2)
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
            .filter { $0.hasPrefix("test.db.pre-v35-") && $0.hasSuffix(".bak") }
        #expect(backups.count == 1)
        let backup = try DBConnection(path: dir + "/" + backups[0])
        defer { backup.close() }
        let integrity = try backup.prepare("PRAGMA integrity_check").query()
        #expect(integrity.count == 1 && integrity[0][0].textValue == "ok")
        // 注：恢复后连接会重开并重新进入 WAL 模式，-wal/-shm 会被重建（与 TS 侧
        // 惰性重开行为一致），故此处只核对主库文件内容，不核对 wal/shm 缺失。

        // 恢复后的库必须可重新迁移（TS：失败后下一次启动照常重跑迁移）。
        try MigrationRunner(databaseFilePath: dbPath).migrate(db)
        #expect(try schemaVersion(db) == 35)
        #expect(try tableExists(db, "sessions"))

        db.close()
    }

    @Test func migrationBackupPruningKeepsNewest() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dbPath = dir + "/gather.db"

        // 预置 4 个旧备份（不同 mtime），迁移成功后应只剩最新 3 个。
        for i in 0..<4 {
            let path = dir + "/gather.db.pre-v35-\(1700000000000 + Int64(i)).bak"
            try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        }
        let db = try DBConnection(path: dbPath)
        try MigrationRunner(databaseFilePath: dbPath).migrate(db)
        defer { db.close() }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("gather.db.pre-v35-") && $0.hasSuffix(".bak") }
        #expect(remaining.count == 3, "应只保留最新 3 个备份，实际: \(remaining)")
    }
}

/// 新库（Schema 直接建表）与升级库（旧形态 + migrate）必须完全同形：
/// 逐列 name/type/notnull/dflt/pk 与逐条外键相等 —— "新库与升级库分叉"是
/// 结构性缺陷，必须在列级而不是表名级验证。
@Suite("Schema 新库与升级库同形")
struct SchemaParityTests {
    @Test func newDatabaseMatchesUpgradedDatabaseColumnForColumn() throws {
        let fresh = try DBConnection(path: ":memory:")
        try fresh.exec(SchemaSQL.schemaSQL)
        try MigrationRunner().migrate(fresh)

        // 升级库：先建新库，再把 sessions 变回旧形态（带 analysis_status），
        // 走同一条 migrate 路径删列 —— 模拟"旧库升级"。
        let upgraded = try DBConnection(path: ":memory:")
        try upgraded.exec(SchemaSQL.schemaSQL)
        try MigrationRunner().migrate(upgraded)
        try upgraded.exec("ALTER TABLE sessions ADD COLUMN analysis_status TEXT NOT NULL DEFAULT 'idle'")
        try MigrationRunner().migrate(upgraded)

        defer {
            fresh.close()
            upgraded.close()
        }

        // ① sessions 列定义逐项相等（含 analysis_status 在两侧都不存在）。
        func columns(_ db: DBConnection, _ table: String) throws -> [String] {
            try db.prepare("PRAGMA table_info(\(table))").query().map { row in
                "\(row[1].textValue ?? "")|\(row[2].textValue ?? "")|\(row[3].intValue ?? -1)|\(row[4].textValue ?? "")|\(row[5].intValue ?? -1)"
            }
        }
        #expect(try columns(fresh, "sessions") == columns(upgraded, "sessions"))
        #expect(try !columns(fresh, "sessions").contains { $0.hasPrefix("analysis_status|") },
            "新库不得再有 sessions.analysis_status 列")
        #expect(try !columns(upgraded, "sessions").contains { $0.hasPrefix("analysis_status|") },
            "升级库必须删掉 analysis_status（幂等 guard 生效）")

        // ② 外键清单逐项相等。
        func foreignKeys(_ db: DBConnection, _ table: String) throws -> [String] {
            try db.prepare("PRAGMA foreign_key_list(\(table))").query().map { row in
                "\(row[2].textValue ?? "")|\(row[3].textValue ?? "")|\(row[4].textValue ?? "")|\(row[6].textValue ?? "")"
            }.sorted()
        }
        for table in ["sessions", "photos", "analysis_jobs", "asset_files"] {
            #expect(try foreignKeys(fresh, table) == foreignKeys(upgraded, table),
                "表 \(table) 的外键必须同形")
        }

        // ③ 表名集合相等（列级之外的整体兜底）。
        func tables(_ db: DBConnection) throws -> [String] {
            try db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
                .query().compactMap { $0[0].textValue }
        }
        #expect(try tables(fresh) == tables(upgraded))
        #expect(try schemaVersion(fresh) == schemaVersion(upgraded))
    }
}

private func tableExists(_ db: DBConnection, _ name: String) throws -> Bool {
    try db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get([.text(name)]) != nil
}
