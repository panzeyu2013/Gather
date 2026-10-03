// desktop/native/gather-core/Sources/GatherCore/Database/Migrations.swift
// 迁移执行器（1.2）：从 TS 侧 desktop/src/main/db/migrations.ts 逐条移植。
// - schema_version 表语义（SELECT MAX(version) / INSERT OR REPLACE）与 TS 一致；
// - 每个版本一个事务，版本号只在成功事务内写入（失败自动回滚）；
// - ADR-005：迁移前磁盘空间检查 → wal_checkpoint(TRUNCATE) → SQLite backup API
//   创建带版本与时间戳的备份 → 备份 integrity_check；迁移失败 → 关闭连接、
//   从备份恢复（不写 down-migration）；迁移后 foreign_key_check + 列不变量 +
//   CURRENT_SCHEMA_VERSION 校验；备份按 keep=3 淘汰（非致命）。
// - 不变量：迁移末尾无条件执行 INDEX_SQL（ADR-006）。
import Foundation
import CSQLite

public struct MigrationRunner {
    public static let currentSchemaVersion = 35

    /// 数据库文件路径（TS: app.getPath('userData')/gather.db）。为 nil 时跳过
    /// 备份/回滚（内存库或测试场景），迁移仍正常执行。
    public var databaseFilePath: String?

    /// 人脸缩略图回退目录（TS: path.join(app.getPath('userData'), FACE_THUMB_DIR)）。
    /// 为 nil 且无可用目录时，缩略图迁移延迟（与 TS「无 writable 目录」语义一致）。
    public var faceThumbnailFallbackDir: String?

    /// 测试注入点（对应 TS 的 GATHER_TEST_FAIL_MIGRATION=after-migrate）：
    /// 在迁移完成后、不变量校验前调用，抛出即触发备份回滚。
    public var afterMigrateHook: (() throws -> Void)?

    public init(
        databaseFilePath: String? = nil,
        faceThumbnailFallbackDir: String? = nil,
        afterMigrateHook: (() throws -> Void)? = nil
    ) {
        self.databaseFilePath = databaseFilePath
        self.faceThumbnailFallbackDir = faceThumbnailFallbackDir
        self.afterMigrateHook = afterMigrateHook
    }

    // ─────────────────────────────── 入口 ───────────────────────────────

    /// 执行全部迁移（幂等：已是最新版本时为空操作），按 ADR-005 备份/回滚。
    public func migrate(_ connection: DBConnection) throws {
        let previousVersion = try getSchemaVersion(connection)
        let backupPath = try createMigrationBackup(connection, currentVersion: previousVersion)
        do {
            try runMigrationsUnsafe(connection)
            try afterMigrateHook?()
            try assertMigrationInvariants(connection)
            do {
                if let databaseFilePath {
                    try pruneMigrationBackups(databaseFilePath: databaseFilePath)
                }
            } catch {
                GatherLogger.log("Unable to prune old migration backups: \(error)", level: .warn)
            }
        } catch {
            if let backupPath, let databaseFilePath {
                try restoreBackup(connection, dbPath: databaseFilePath, backupPath: backupPath)
            }
            throw error
        }
    }

    // ─────────────────────────── schema_version 语义 ───────────────────────────

    private func getSchemaVersion(_ db: DBConnection) throws -> Int {
        do {
            guard let row = try db.prepare("SELECT MAX(version) as version FROM schema_version").get() else {
                return 0
            }
            return Int(row[0].intValue ?? 0)
        } catch {
            // 首次迁移前 schema_version 表尚不存在（正常 → 0）；
            // 其余错误（库损坏等）显式抛出，由 migrate() 备份/回滚路径接管。
            if "\(error)".contains("no such table") {
                return 0
            }
            throw DBError.message("读取 schema_version 失败: \(error)")
        }
    }

    private func setSchemaVersion(_ db: DBConnection, _ version: Int) throws {
        _ = try db.prepare("INSERT OR REPLACE INTO schema_version (version, applied_at) VALUES (?, ?)")
            .run([.int(Int64(version)), .text(nowISOString())])
    }

    // ─────────────────────────────── 辅助 ───────────────────────────────

    private func columnExists(_ db: DBConnection, _ table: String, _ column: String) -> Bool {
        guard let rows = try? db.prepare("PRAGMA table_info(\(table))").query() else { return false }
        return rows.contains { $0[1].textValue == column }
    }

    private func addColumn(_ db: DBConnection, _ table: String, _ column: String, _ type: String) throws -> Bool {
        if columnExists(db, table, column) { return false }
        try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        return true
    }

    private func fillTimestamp(_ db: DBConnection, _ table: String, _ column: String) throws {
        _ = try db.prepare("UPDATE \(table) SET \(column) = ? WHERE \(column) = '' OR \(column) IS NULL")
            .run([.text(nowISOString())])
    }

    private func tableExists(_ db: DBConnection, _ table: String) -> Bool {
        (try? db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get([.text(table)])) != nil
    }

    private func assertColumns(_ db: DBConnection, _ table: String, _ columns: [String]) throws {
        for column in columns where !columnExists(db, table, column) {
            throw DBError.message("Migration invariant failed: \(table).\(column) is missing")
        }
    }

    // ─────────────────────────── 迁移内嵌 DDL 常量 ───────────────────────────

    private let createFaceClusterMembersSQL = """
      CREATE TABLE face_cluster_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        photo_id TEXT NOT NULL REFERENCES photos(id),
        bbox TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 0.0,
        observation_id INTEGER REFERENCES face_observations(id)
      )
    """

    // ─────────────────────────── 分步迁移（逐级 0→31） ───────────────────────────

    private func runMigrationsUnsafe(_ db: DBConnection) throws {
        try db.exec(SchemaSQL.schemaSQL)

        var currentVersion = try getSchemaVersion(db)

        // ── Version 1: initial migrations ──
        if currentVersion < 1 {
            try db.transaction {
                _ = try addColumn(db, "photos", "width", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "photos", "height", "INTEGER NOT NULL DEFAULT 0")
                try migrateFaceClusterMembers(db)

                let timestampColumns: [(String, String)] = [
                    ("face_observations", "created_at"),
                    ("face_clusters", "created_at"),
                    ("face_clusters", "updated_at"),
                    ("role_bindings", "created_at"),
                    ("role_bindings", "updated_at"),
                    ("culling_decisions", "created_at"),
                    ("writeback_items", "created_at"),
                    ("photo_metadata_cache", "updated_at"),
                ]
                for (table, column) in timestampColumns {
                    if try addColumn(db, table, column, "TEXT NOT NULL DEFAULT ''") {
                        try fillTimestamp(db, table, column)
                    }
                }

                _ = try addColumn(db, "face_clusters", "thumbnail_path", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "face_clusters", "thumbnail_base64", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "face_clusters", "synced_to_library", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "face_clusters", "matched_person_id", "TEXT")
                _ = try addColumn(db, "face_clusters", "match_confidence", "REAL")
                _ = try addColumn(db, "photo_metadata_cache", "keywords", "TEXT NOT NULL DEFAULT '[]'")
                _ = try addColumn(db, "writeback_items", "photo_path", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "writeback_items", "attributes_json", "TEXT NOT NULL DEFAULT '{}'")

                try assertColumns(db, "photos", ["width", "height"])
                try assertColumns(db, "face_clusters", [
                    "thumbnail_path",
                    "matched_person_id",
                    "match_confidence",
                ])
                try assertColumns(db, "writeback_items", ["photo_path", "attributes_json"])
                try setSchemaVersion(db, 1)
            }
            currentVersion = 1
        }

        // ── Version 2: enable file-backed face thumbnails ──
        if currentVersion < 2 {
            try setSchemaVersion(db, 2)
            currentVersion = 2
        }

        // ── Version 3: persist color labels in the metadata cache ──
        if currentVersion < 3 {
            try db.transaction {
                _ = try addColumn(db, "photo_metadata_cache", "label", "TEXT")
                try assertColumns(db, "photo_metadata_cache", ["label"])
                try setSchemaVersion(db, 3)
            }
            currentVersion = 3
        }

        // ── Version 4: remember the source folder used to create a session ──
        if currentVersion < 4 {
            try db.transaction {
                _ = try addColumn(db, "sessions", "source_path", "TEXT NOT NULL DEFAULT ''")
                try assertColumns(db, "sessions", ["source_path"])
                try setSchemaVersion(db, 4)
            }
            currentVersion = 4
        }

        // ── Version 5: invalidate perceptual hashes when source files change ──
        if currentVersion < 5 {
            try db.transaction {
                _ = try addColumn(db, "similarity_hashes", "file_size", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "similarity_hashes", "file_mtime_ms", "REAL NOT NULL DEFAULT 0")
                try db.exec("""
                    DELETE FROM similarity_hashes
                    WHERE id NOT IN (
                      SELECT MAX(id)
                      FROM similarity_hashes
                      GROUP BY session_id, photo_id
                    )
                    """)
                try assertColumns(db, "similarity_hashes", ["file_size", "file_mtime_ms"])
                try setSchemaVersion(db, 5)
            }
            currentVersion = 5
        }

        // ── Version 6: reuse exact checksums while source files are unchanged ──
        if currentVersion < 6 {
            try db.transaction {
                _ = try addColumn(db, "photos", "checksum_file_size", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "photos", "checksum_file_mtime_ms", "REAL NOT NULL DEFAULT 0")
                try assertColumns(db, "photos", ["checksum_file_size", "checksum_file_mtime_ms"])
                try setSchemaVersion(db, 6)
            }
            currentVersion = 6
        }

        // ── Version 7: reuse face observations while photo/model settings are unchanged ──
        if currentVersion < 7 {
            try db.transaction {
                _ = try addColumn(db, "face_observations", "source_file_size", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "face_observations", "source_file_mtime_ms", "REAL NOT NULL DEFAULT 0")
                _ = try addColumn(db, "face_observations", "analysis_signature", "TEXT NOT NULL DEFAULT ''")
                try assertColumns(db, "face_observations", [
                    "source_file_size",
                    "source_file_mtime_ms",
                    "analysis_signature",
                ])
                try setSchemaVersion(db, 7)
            }
            currentVersion = 7
        }

        // ── Version 8: cache successful zero-face analyses as well as observations ──
        if currentVersion < 8 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS face_analysis_state (
                      photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      source_file_size INTEGER NOT NULL,
                      source_file_mtime_ms REAL NOT NULL,
                      analysis_signature TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    )
                    """)
                try setSchemaVersion(db, 8)
            }
            currentVersion = 8
        }

        // ── Version 9: make culling upserts atomic and deterministic ──
        if currentVersion < 9 {
            try db.transaction {
                try db.exec("""
                    DELETE FROM culling_decisions
                    WHERE id NOT IN (
                      SELECT MAX(id)
                      FROM culling_decisions
                      GROUP BY session_id, photo_id
                    );
                    """)
                try setSchemaVersion(db, 9)
            }
            currentVersion = 9
        }

        // ── Version 10: materialize similarity membership for operational queries ──
        if currentVersion < 10 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS similarity_result_members (
                      result_id INTEGER NOT NULL REFERENCES similarity_results(id) ON DELETE CASCADE,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      group_index INTEGER NOT NULL,
                      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                      PRIMARY KEY (result_id, photo_id)
                    );
                    """)
                try setSchemaVersion(db, 10)
            }
            currentVersion = 10
        }

        // ── Version 11: persist face-clustering reuse state across restarts ──
        if currentVersion < 11 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS face_cluster_state (
                      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                      cluster_signature TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    )
                    """)
                try setSchemaVersion(db, 11)
            }
            currentVersion = 11
        }

        // ── Version 12: remove the disabled history subsystem and inert settings ──
        if currentVersion < 12 {
            try db.transaction {
                try db.exec("""
                    DROP TABLE IF EXISTS operation_log;
                    DELETE FROM app_settings
                    WHERE key IN (
                      'hash_chunk_size',
                      'poll_max_retries_sim',
                      'poll_max_retries_fkw',
                      'poll_interval_sim_ms',
                      'poll_interval_fkw_ms'
                    );
                    """)
                try setSchemaVersion(db, 12)
            }
            currentVersion = 12
        }

        // ── Version 13: durable culling state and sidecar metadata outbox ──
        if currentVersion < 13 {
            try db.transaction {
                _ = try addColumn(
                    db,
                    "culling_decisions",
                    "rating",
                    "INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5)"
                )
                _ = try addColumn(
                    db,
                    "culling_decisions",
                    "color_label",
                    "TEXT NOT NULL DEFAULT 'None' CHECK (color_label IN ('None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple'))"
                )
                _ = try addColumn(db, "culling_decisions", "revision", "INTEGER NOT NULL DEFAULT 0")
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS metadata_outbox (
                      xmp_path TEXT PRIMARY KEY,
                      owner_session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      photo_path TEXT NOT NULL,
                      patch_json TEXT NOT NULL DEFAULT '{}',
                      dirty_fields TEXT NOT NULL DEFAULT '[]',
                      revision INTEGER NOT NULL DEFAULT 0,
                      persisted_revision INTEGER NOT NULL DEFAULT 0,
                      base_fingerprint TEXT NOT NULL DEFAULT '',
                      base_values_json TEXT NOT NULL DEFAULT '{}',
                      backup_path TEXT NOT NULL DEFAULT '',
                      status TEXT NOT NULL DEFAULT 'pending' CHECK (
                        status IN ('clean', 'pending', 'writing', 'written', 'failed', 'conflict', 'synced', 'cleaned')
                      ),
                      attempt_count INTEGER NOT NULL DEFAULT 0,
                      error_message TEXT NOT NULL DEFAULT '',
                      updated_at TEXT NOT NULL
                    );
                    """)
                try assertColumns(db, "culling_decisions", ["rating", "color_label", "revision"])
                try assertColumns(db, "metadata_outbox", [
                    "xmp_path",
                    "owner_session_id",
                    "patch_json",
                    "revision",
                    "persisted_revision",
                    "status",
                ])
                try setSchemaVersion(db, 13)
            }
            currentVersion = 13
        }

        // ── Version 14: preserve imported rating/label for legacy pick decisions ──
        if currentVersion < 14 {
            try db.transaction {
                try db.exec("""
                    UPDATE culling_decisions
                    SET rating = CASE
                          WHEN (SELECT rating
                                FROM photo_metadata_cache
                                WHERE photo_id = culling_decisions.photo_id)
                               BETWEEN 0 AND 5
                          THEN (SELECT rating
                                FROM photo_metadata_cache
                                WHERE photo_id = culling_decisions.photo_id)
                          ELSE rating
                        END,
                        color_label = CASE
                          WHEN (SELECT label
                                FROM photo_metadata_cache
                                WHERE photo_id = culling_decisions.photo_id)
                               IN ('None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple')
                          THEN (SELECT label
                                FROM photo_metadata_cache
                                WHERE photo_id = culling_decisions.photo_id)
                          ELSE color_label
                        END
                    WHERE revision = 0;
                    """)
                try setSchemaVersion(db, 14)
            }
            currentVersion = 14
        }

        // ── Version 15: expand the database for global Assets without switching reads ──
        if currentVersion < 15 {
            try db.transaction {
                _ = try addColumn(db, "photos", "asset_id", "TEXT REFERENCES assets(id)")
                _ = try addColumn(db, "photos", "asset_file_id", "TEXT REFERENCES asset_files(id)")
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS assets (
                      id TEXT PRIMARY KEY,
                      capture_fingerprint TEXT NOT NULL DEFAULT '',
                      status TEXT NOT NULL DEFAULT 'active',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS asset_files (
                      id TEXT PRIMARY KEY,
                      volume_id TEXT NOT NULL DEFAULT '',
                      normalized_path TEXT NOT NULL,
                      filename TEXT NOT NULL,
                      extension TEXT NOT NULL DEFAULT '',
                      media_type TEXT NOT NULL DEFAULT 'unknown',
                      file_size INTEGER NOT NULL DEFAULT 0,
                      file_mtime_ms REAL NOT NULL DEFAULT 0,
                      checksum TEXT NOT NULL DEFAULT '',
                      online_status TEXT NOT NULL DEFAULT 'online',
                      last_seen_at TEXT NOT NULL DEFAULT '',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS asset_members (
                      asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                      file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
                      member_role TEXT NOT NULL,
                      is_primary INTEGER NOT NULL DEFAULT 0,
                      confidence REAL NOT NULL DEFAULT 1.0,
                      binding_source TEXT NOT NULL DEFAULT 'import',
                      PRIMARY KEY (asset_id, file_id),
                      UNIQUE (file_id)
                    );
                    CREATE TABLE IF NOT EXISTS asset_link_candidates (
                      id TEXT PRIMARY KEY,
                      left_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
                      right_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
                      relation_type TEXT NOT NULL,
                      confidence REAL NOT NULL,
                      evidence_json TEXT NOT NULL DEFAULT '{}',
                      status TEXT NOT NULL DEFAULT 'pending',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS session_assets (
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                      display_file_id TEXT REFERENCES asset_files(id),
                      import_order INTEGER NOT NULL DEFAULT 0,
                      added_at TEXT NOT NULL,
                      PRIMARY KEY (session_id, asset_id)
                    );
                    CREATE TABLE IF NOT EXISTS sidecar_bindings (
                      id TEXT PRIMARY KEY,
                      xmp_path TEXT NOT NULL,
                      normalized_xmp_path TEXT NOT NULL UNIQUE,
                      binding_rule TEXT NOT NULL,
                      status TEXT NOT NULL DEFAULT 'active',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS sidecar_binding_files (
                      sidecar_binding_id TEXT NOT NULL REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
                      file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
                      PRIMARY KEY (sidecar_binding_id, file_id)
                    );
                    CREATE TABLE IF NOT EXISTS asset_file_metadata (
                      file_id TEXT PRIMARY KEY REFERENCES asset_files(id) ON DELETE CASCADE,
                      date_taken TEXT,
                      camera_make TEXT,
                      camera_model TEXT,
                      lens_model TEXT,
                      focal_length REAL,
                      f_number REAL,
                      exposure_time TEXT,
                      iso INTEGER,
                      gps_latitude REAL,
                      gps_longitude REAL,
                      width INTEGER,
                      height INTEGER,
                      cached_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS sidecar_metadata_state (
                      sidecar_binding_id TEXT PRIMARY KEY REFERENCES sidecar_bindings(id) ON DELETE CASCADE,
                      rating INTEGER CHECK (rating BETWEEN 0 AND 5),
                      label TEXT,
                      keywords TEXT NOT NULL DEFAULT '[]',
                      fingerprint TEXT NOT NULL DEFAULT '',
                      updated_at TEXT NOT NULL
                    );
                    """)
                try assertColumns(db, "photos", ["asset_id", "asset_file_id"])
                try setSchemaVersion(db, 15)
            }
            currentVersion = 15
        }

        // ── Version 16: persist long-running analysis jobs ──
        if currentVersion < 16 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS analysis_jobs (
                      id TEXT PRIMARY KEY,
                      type TEXT NOT NULL,
                      scope_type TEXT NOT NULL,
                      scope_id TEXT NOT NULL,
                      dedupe_key TEXT NOT NULL,
                      status TEXT NOT NULL,
                      priority INTEGER NOT NULL DEFAULT 0,
                      progress_current INTEGER NOT NULL DEFAULT 0,
                      progress_total INTEGER NOT NULL DEFAULT 0,
                      progress_message TEXT NOT NULL DEFAULT '',
                      input_fingerprint TEXT NOT NULL DEFAULT '',
                      model_id TEXT NOT NULL DEFAULT '',
                      model_version TEXT NOT NULL DEFAULT '',
                      checkpoint_json TEXT NOT NULL DEFAULT '{}',
                      attempt_count INTEGER NOT NULL DEFAULT 0,
                      lease_owner TEXT NOT NULL DEFAULT '',
                      heartbeat_at TEXT NOT NULL DEFAULT '',
                      cancel_requested_at TEXT NOT NULL DEFAULT '',
                      error_code TEXT NOT NULL DEFAULT '',
                      error_message TEXT NOT NULL DEFAULT '',
                      created_at TEXT NOT NULL,
                      started_at TEXT NOT NULL DEFAULT '',
                      finished_at TEXT NOT NULL DEFAULT '',
                      updated_at TEXT NOT NULL
                    );
                    """)
                try setSchemaVersion(db, 16)
            }
            currentVersion = 16
        }

        // ── Version 17: versioned explainable technical quality results ──
        if currentVersion < 17 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS asset_analysis (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                      asset_file_id TEXT REFERENCES asset_files(id) ON DELETE CASCADE,
                      analysis_type TEXT NOT NULL,
                      result_json TEXT NOT NULL DEFAULT '{}',
                      warnings_json TEXT NOT NULL DEFAULT '[]',
                      model_id TEXT NOT NULL DEFAULT '',
                      model_version TEXT NOT NULL DEFAULT '',
                      input_fingerprint TEXT NOT NULL DEFAULT '',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      UNIQUE(photo_id, analysis_type, model_id, model_version, input_fingerprint)
                    );
                    """)
                try setSchemaVersion(db, 17)
            }
            currentVersion = 17
        }

        // ── Version 18: metadata outbox survives session deletion ──
        if currentVersion < 18 {
            try db.transaction {
                try db.exec("""
                    DROP TABLE IF EXISTS metadata_outbox_sessions;
                    ALTER TABLE metadata_outbox RENAME TO metadata_outbox_v17;
                    CREATE TABLE metadata_outbox (
                      xmp_path TEXT PRIMARY KEY,
                      owner_session_id TEXT,
                      created_by_session_id TEXT,
                      photo_path TEXT NOT NULL,
                      patch_json TEXT NOT NULL DEFAULT '{}',
                      dirty_fields TEXT NOT NULL DEFAULT '[]',
                      revision INTEGER NOT NULL DEFAULT 0,
                      persisted_revision INTEGER NOT NULL DEFAULT 0,
                      base_fingerprint TEXT NOT NULL DEFAULT '',
                      base_values_json TEXT NOT NULL DEFAULT '{}',
                      backup_path TEXT NOT NULL DEFAULT '',
                      status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('clean', 'pending', 'writing', 'written', 'failed', 'conflict', 'synced', 'cleaned')),
                      attempt_count INTEGER NOT NULL DEFAULT 0,
                      error_message TEXT NOT NULL DEFAULT '',
                      updated_at TEXT NOT NULL
                    );
                    INSERT INTO metadata_outbox (xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json, dirty_fields, revision, persisted_revision, base_fingerprint, base_values_json, backup_path, status, attempt_count, error_message, updated_at)
                      SELECT xmp_path, owner_session_id, owner_session_id, photo_path, patch_json, dirty_fields, revision, persisted_revision, base_fingerprint, base_values_json, backup_path, status, attempt_count, error_message, updated_at FROM metadata_outbox_v17;
                    DROP TABLE metadata_outbox_v17;
                    """)
                try setSchemaVersion(db, 18)
            }
            currentVersion = 18
        }

        // ── Version 19: persistent culling operation history ──
        if currentVersion < 19 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS culling_history (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      operation_json TEXT NOT NULL DEFAULT '[]',
                      created_at TEXT NOT NULL
                    );
                    """)
                try setSchemaVersion(db, 19)
            }
            currentVersion = 19
        }

        // ── Version 20: version smart album filter definitions ──
        if currentVersion < 20 {
            try db.transaction {
                _ = try addColumn(db, "smart_albums", "schema_version", "INTEGER NOT NULL DEFAULT 1")
                try setSchemaVersion(db, 20)
            }
            currentVersion = 20
        }

        // ── Version 21: one global XMP queue can be observed by multiple sessions ──
        if currentVersion < 21 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS metadata_outbox_sessions (
                      xmp_path TEXT NOT NULL REFERENCES metadata_outbox(xmp_path) ON DELETE CASCADE,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      confirmed_at TEXT NOT NULL DEFAULT '',
                      linked_at TEXT NOT NULL,
                      PRIMARY KEY (xmp_path, session_id)
                    );
                    INSERT OR IGNORE INTO metadata_outbox_sessions
                      (xmp_path, session_id, confirmed_at, linked_at)
                    SELECT xmp_path, owner_session_id, '', updated_at
                    FROM metadata_outbox
                    WHERE owner_session_id IS NOT NULL
                      AND owner_session_id IN (SELECT id FROM sessions);
                    """)
                try setSchemaVersion(db, 21)
            }
            currentVersion = 21
        }

        // ── Version 22: reusable analysis belongs to the physical asset file ──
        // v21 rows were per-photo and typically had asset_file_id NULL. Rows that
        // can be linked through photos.asset_file_id are backfilled (and preserved)
        // instead of dropped, so upgrading a large library does not trigger a
        // needless full re-analysis; only rows with no linkable asset file are lost.
        if currentVersion < 22 {
            try db.transaction {
                try db.exec("""
                    ALTER TABLE asset_analysis RENAME TO asset_analysis_v21;
                    CREATE TABLE asset_analysis (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
                      asset_file_id TEXT NOT NULL REFERENCES asset_files(id) ON DELETE CASCADE,
                      analysis_type TEXT NOT NULL,
                      result_json TEXT NOT NULL DEFAULT '{}',
                      warnings_json TEXT NOT NULL DEFAULT '[]',
                      model_id TEXT NOT NULL DEFAULT '',
                      model_version TEXT NOT NULL DEFAULT '',
                      input_fingerprint TEXT NOT NULL DEFAULT '',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      UNIQUE(asset_file_id, analysis_type, model_id, model_version, input_fingerprint)
                    );
                    INSERT OR IGNORE INTO asset_analysis (
                      id, photo_id, asset_file_id, analysis_type, result_json, warnings_json,
                      model_id, model_version, input_fingerprint, created_at, updated_at
                    )
                    SELECT id, photo_id, asset_file_id, analysis_type, result_json, warnings_json,
                      model_id, model_version, input_fingerprint, created_at, updated_at
                    FROM asset_analysis_v21
                    WHERE asset_file_id IS NOT NULL
                      AND asset_file_id IN (SELECT id FROM asset_files)
                    UNION ALL
                    SELECT id, photo_id,
                      (SELECT asset_file_id FROM photos WHERE photos.id = asset_analysis_v21.photo_id) AS asset_file_id,
                      analysis_type, result_json, warnings_json,
                      model_id, model_version, input_fingerprint, created_at, updated_at
                    FROM asset_analysis_v21
                    WHERE asset_file_id IS NULL
                      AND photo_id IS NOT NULL
                      AND (SELECT asset_file_id FROM photos WHERE photos.id = asset_analysis_v21.photo_id) IS NOT NULL
                    ORDER BY id;
                    DROP TABLE asset_analysis_v21;
                    """)
                try setSchemaVersion(db, 22)
            }
            currentVersion = 22
        }

        // ── Version 23: persistent Burst/Scene navigation groups ──
        if currentVersion < 23 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS navigation_groups (
                      id TEXT PRIMARY KEY,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      group_type TEXT NOT NULL CHECK (group_type IN ('burst', 'scene')),
                      photo_ids_json TEXT NOT NULL DEFAULT '[]',
                      lead_photo_id TEXT REFERENCES photos(id) ON DELETE SET NULL,
                      explanation TEXT NOT NULL DEFAULT '',
                      input_fingerprint TEXT NOT NULL DEFAULT '',
                      source TEXT NOT NULL DEFAULT 'automatic',
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    );
                    """)
                try setSchemaVersion(db, 23)
            }
            currentVersion = 23
        }

        // ── Version 24: resumable Asset backfill cursor and diagnostics ──
        if currentVersion < 24 {
            try db.transaction {
                _ = try addColumn(db, "asset_files", "file_identity", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "culling_decisions", "decision_source", "TEXT NOT NULL DEFAULT 'manual'")
                _ = try addColumn(db, "culling_history", "undone", "INTEGER NOT NULL DEFAULT 0")
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS asset_backfill_state (
                      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                      last_photo_rowid INTEGER NOT NULL DEFAULT 0,
                      total_photos INTEGER NOT NULL DEFAULT 0,
                      migrated_photos INTEGER NOT NULL DEFAULT 0,
                      offline_files INTEGER NOT NULL DEFAULT 0,
                      path_conflicts INTEGER NOT NULL DEFAULT 0,
                      sidecar_conflicts INTEGER NOT NULL DEFAULT 0,
                      candidate_links INTEGER NOT NULL DEFAULT 0,
                      automatic_merges INTEGER NOT NULL DEFAULT 0,
                      status TEXT NOT NULL DEFAULT 'running',
                      updated_at TEXT NOT NULL
                    );
                    """)
                try setSchemaVersion(db, 24)
            }
            currentVersion = 24
        }

        // ── Version 25: source ownership for safely reversible keyword writes ──
        if currentVersion < 25 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS metadata_keyword_origins (
                      xmp_path TEXT NOT NULL,
                      source TEXT NOT NULL,
                      keyword TEXT NOT NULL,
                      active INTEGER NOT NULL DEFAULT 1,
                      created_at TEXT NOT NULL,
                      updated_at TEXT NOT NULL,
                      PRIMARY KEY (xmp_path, source, keyword)
                    );
                    """)
                try setSchemaVersion(db, 25)
            }
            currentVersion = 25
        }

        // ── Version 26: drop the redundant culling index covered by the unique one ──
        if currentVersion < 26 {
            try db.transaction {
                try db.exec("""
                    DROP INDEX IF EXISTS idx_culling_photo_session;
                    """)
                try setSchemaVersion(db, 26)
            }
            currentVersion = 26
        }

        // ── Version 27: module provenance on the metadata outbox ──
        // The outbox is the single writeback state machine; writeback_items only
        // projects it for the workflow UI. `source_module` lets module isolation
        // (e.g. culling vs face-kw) be enforced from the outbox itself.
        if currentVersion < 27 {
            try db.transaction {
                _ = try addColumn(db, "metadata_outbox", "source_module", "TEXT NOT NULL DEFAULT ''")
                // json_valid guards the CASE branches: a malformed legacy patch_json must
                // not abort startup, it just falls back to 'manual'.
                try db.exec("""
                    UPDATE metadata_outbox
                    SET source_module = CASE
                      WHEN json_valid(patch_json)
                        AND json_extract(patch_json, '$.source') IN ('face-keyword', 'similarity', 'culling', 'template')
                      THEN json_extract(patch_json, '$.source')
                      ELSE 'manual'
                    END
                    WHERE source_module = ''
                    """)
                try setSchemaVersion(db, 27)
            }
            currentVersion = 27
        }

        // ── Version 28: deduplicate person_photos before the unique index lands ──
        if currentVersion < 28 {
            try db.transaction {
                // person_photos previously had no uniqueness constraint, so re-binding a
                // cluster (or binding two clusters of the same photos to one role) could
                // insert duplicate rows and inflate photo counts. Deduplicate existing
                // rows here; the unique index itself is created by INDEX_SQL afterwards,
                // which now fails cleanly only if duplicates were somehow reintroduced.
                try db.exec("""
                    DELETE FROM person_photos
                    WHERE id NOT IN (
                      SELECT MIN(id)
                      FROM person_photos
                      GROUP BY person_id, photo_id
                    );
                    """)
                try setSchemaVersion(db, 28)
            }
            currentVersion = 28
        }

        // ── Version 29: mark sessions created from a truncated initial scan ──
        if currentVersion < 29 {
            try db.transaction {
                _ = try addColumn(db, "sessions", "truncated_import", "INTEGER NOT NULL DEFAULT 0")
                try assertColumns(db, "sessions", ["truncated_import"])
                try setSchemaVersion(db, 29)
            }
            currentVersion = 29
        }

        // ── Version 30: staleness foundation — analysis run records and index sequence ──
        if currentVersion < 30 {
            try db.transaction {
                _ = try addColumn(db, "sessions", "index_seq", "INTEGER NOT NULL DEFAULT 0")
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS analysis_runs (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      kind TEXT NOT NULL,
                      photo_count INTEGER NOT NULL,
                      index_seq INTEGER NOT NULL,
                      started_at TEXT NOT NULL,
                      finished_at TEXT NOT NULL,
                      params TEXT NOT NULL,
                      status TEXT NOT NULL
                    );
                    """)
                try assertColumns(db, "sessions", ["index_seq"])
                try assertColumns(db, "analysis_runs", [
                    "session_id",
                    "kind",
                    "photo_count",
                    "index_seq",
                    "started_at",
                    "finished_at",
                    "params",
                    "status",
                ])
                try setSchemaVersion(db, 30)
            }
            currentVersion = 30
        }

        // ── Version 31: remember when Capture One last confirmed a metadata reload ──
        // Written only after reloadMetadata() succeeds, so a restart can re-derive
        // safeToCleanup from the outbox rows plus this single marker. Nullable and
        // without a default: legacy sessions never reloaded are explicitly NULL.
        if currentVersion < 31 {
            try db.transaction {
                _ = try addColumn(db, "sessions", "reload_acked_at", "TEXT")
                try assertColumns(db, "sessions", ["reload_acked_at"])
                try setSchemaVersion(db, 31)
            }
            currentVersion = 31
        }

        // ── Version 32: 查询性能表达式索引（审计 P1-性能）──
        // idx_photos_asset_group（session_id, COALESCE(NULLIF(asset_id,''),id)）
        // 服务两类查询：filterGlobally 的 asset_key 等值匹配（相关子查询
        // GROUP_CONCAT）与 Culling 首选行子查询。表达式必须与查询字面一致
        // （SQLite 表达式索引要求字面等价，NULLIF 包装否则不匹配 → 全扫）。
        // DROP+CREATE 保证表达式修正后已应用 v32 的库重跑安全。
        // 新库经 SchemaSQL.indexSQL 直接建（snapshot 已含），存量库在此补。
        if currentVersion < 32 {
            try db.exec("""
                DROP INDEX IF EXISTS idx_photos_asset_group;
                CREATE INDEX IF NOT EXISTS idx_photos_asset_group
                  ON photos(session_id, COALESCE(NULLIF(asset_id, ''), id));
                """)
            try setSchemaVersion(db, 32)
            currentVersion = 32
        }

        // ── Version 33: 增量聚类状态与簇版本（ROADMAP 1.3）──
        // similarity_cluster_state 保存每张已哈希照片的分量归属与组种子
        // （group_seed NULL = 未成组），similarity_cluster_meta 保存参数指纹
        // （阈值/组大小/分组模式）+ 版本号 + 连续增量次数（定期全局收敛计数）。
        // 新库经 SchemaSQL.schemaSQL 直接建，存量库在此补建（IF NOT EXISTS 幂等）。
        if currentVersion < 33 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS similarity_cluster_state (
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      -- 故意不加 photos 外键：照片删除后的残留行是增量 diff 的
                      -- "已移除"依据，由状态重写整体清理。
                      photo_id TEXT NOT NULL,
                      hash_hex TEXT NOT NULL,
                      component_index INTEGER NOT NULL,
                      group_seed TEXT,
                      PRIMARY KEY (session_id, photo_id)
                    );
                    CREATE TABLE IF NOT EXISTS similarity_cluster_meta (
                      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                      param_threshold INTEGER NOT NULL,
                      param_min_group_size INTEGER NOT NULL,
                      grouping_mode TEXT NOT NULL,
                      member_count INTEGER NOT NULL DEFAULT 0,
                      version INTEGER NOT NULL DEFAULT 0,
                      incremental_updates INTEGER NOT NULL DEFAULT 0,
                      updated_at TEXT NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS idx_similarity_cluster_state_component
                      ON similarity_cluster_state(session_id, component_index);
                    """)
                try assertColumns(db, "similarity_cluster_state", [
                    "session_id", "photo_id", "hash_hex", "component_index", "group_seed",
                ])
                try assertColumns(db, "similarity_cluster_meta", [
                    "session_id", "param_threshold", "param_min_group_size", "grouping_mode",
                    "member_count", "version", "incremental_updates", "updated_at",
                ])
                try setSchemaVersion(db, 33)
            }
            currentVersion = 33
        }

        // ── Version 34: 人脸质量/几何/模型版本持久化（竞品算法改造）──
        // 每条观察记录综合质量（对齐后的 [0,1]）、bbox 短边像素、滚转角，以及
        // 产生该向量的模型标识与维度，供聚类/匹配按质量与模型版本读取。
        // addColumn 自带 PRAGMA table_info 幂等 guard（与 match_confidence
        // 同一条写法）：存量 33 库只 ALTER 追加、不重建表、不触碰既有行；
        // 新库由 SchemaSQL 直接建（列已存在 → 全部 no-op）。
        if currentVersion < 34 {
            try db.transaction {
                _ = try addColumn(db, "face_observations", "quality", "REAL NOT NULL DEFAULT 0")
                _ = try addColumn(db, "face_observations", "face_size_px", "REAL NOT NULL DEFAULT 0")
                _ = try addColumn(db, "face_observations", "roll_degrees", "REAL NOT NULL DEFAULT 0")
                _ = try addColumn(db, "face_observations", "model_id", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "face_observations", "model_version", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "face_observations", "embedding_dim", "INTEGER NOT NULL DEFAULT 0")
                try assertColumns(db, "face_observations", [
                    "quality",
                    "face_size_px",
                    "roll_degrees",
                    "model_id",
                    "model_version",
                    "embedding_dim",
                ])
                try setSchemaVersion(db, 34)
            }
            currentVersion = 34
        }

        if currentVersion < 35 {
            try db.transaction {
                try db.exec("""
                    CREATE TABLE IF NOT EXISTS face_identity_feedback (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                      bbox_x REAL NOT NULL, bbox_y REAL NOT NULL, bbox_w REAL NOT NULL, bbox_h REAL NOT NULL,
                      person_id TEXT REFERENCES persons(id) ON DELETE CASCADE,
                      decision TEXT NOT NULL CHECK(decision IN ('confirmed', 'rejected')),
                      keywords TEXT NOT NULL DEFAULT '[]',
                      updated_at TEXT NOT NULL
                    );
                    """)
                try setSchemaVersion(db, 35)
            }
            currentVersion = 35
        }

        if currentVersion != Self.currentSchemaVersion {
            throw DBError.message("Unexpected schema version \(currentVersion)")
        }

        try db.exec(SchemaSQL.indexSQL)
        try ensurePhotoPathUniqueness(db)
        try migratePendingFaceThumbnails(db)
        try dropSessionsAnalysisStatus(db)
    }

    /// 删列：sessions.analysis_status（方案 A 终局）。
    ///
    /// 分析状态的唯一真相源是 analysis_jobs（SessionRepo.analysisStatus 按
    /// (type, scope_id) 派生）；列留着只会诱使调用方再写一份会漂移的状态。
    /// 幂等：只在列确实存在时执行（新库由 Schema 直接建无此列的表）；该列无
    /// 索引/视图/触发器依赖，SQLite 的 DROP COLUMN 可直接执行。
    private func dropSessionsAnalysisStatus(_ db: DBConnection) throws {
        let columns = try db.prepare("PRAGMA table_info(sessions)").query()
        let hasColumn = columns.contains { $0.count > 1 && $0[1].textValue == "analysis_status" }
        guard hasColumn else { return }
        try db.exec("ALTER TABLE sessions DROP COLUMN analysis_status")
    }

    // ─────────────────────── face_cluster_members 重建 ───────────────────────

    private func restoreFaceClusterMembers(_ db: DBConnection, oldTable: String) throws {
        let oldColumns = (try? db.prepare("PRAGMA table_info(\(oldTable))").query()) ?? []
        let hasObservationId = oldColumns.contains { $0[1].textValue == "observation_id" }
        let observationExpr = hasObservationId
            ? "CASE WHEN o.observation_id IN (SELECT id FROM face_observations) THEN o.observation_id ELSE NULL END"
            : "NULL"

        try db.exec("""
            INSERT OR IGNORE INTO face_cluster_members
              (id, cluster_id, session_id, photo_id, bbox, confidence, observation_id)
            SELECT
              o.id,
              o.cluster_id,
              o.session_id,
              o.photo_id,
              o.bbox,
              o.confidence,
              \(observationExpr)
            FROM \(oldTable) o
            JOIN face_clusters c ON c.id = o.cluster_id
            JOIN sessions s ON s.id = o.session_id
            JOIN photos p ON p.id = o.photo_id
            """)
        try db.exec("DROP TABLE \(oldTable)")
    }

    private func migrateFaceClusterMembers(_ db: DBConnection) throws {
        let oldTable = "__face_cluster_members_old"

        if tableExists(db, oldTable) {
            if !tableExists(db, "face_cluster_members") {
                try db.exec(createFaceClusterMembersSQL)
            }
            try restoreFaceClusterMembers(db, oldTable: oldTable)
        }

        if !tableExists(db, "face_cluster_members") {
            try db.exec(createFaceClusterMembersSQL)
            return
        }

        let foreignKeys = try db.prepare("PRAGMA foreign_key_list(face_cluster_members)").query()
        let hasObservationFk = foreignKeys.contains { row in
            row.count > 3 && row[2].textValue == "face_observations" && row[3].textValue == "observation_id"
        }
        if hasObservationFk { return }

        try db.exec("ALTER TABLE face_cluster_members RENAME TO \(oldTable)")
        try db.exec(createFaceClusterMembersSQL)
        try restoreFaceClusterMembers(db, oldTable: oldTable)
    }

    // ─────────────────────── 唯一照片路径索引 ───────────────────────

    /// 唯一照片路径索引是扫描期「归一化路径 → 照片行」映射的前提。历史实现发现
    /// 同会话重复 filepath 时**跳过**索引并只写日志，于是唯一索引缺失、重复行
    /// 永久留在库里（IndexerService 曾用 Dictionary(uniqueKeysWithValues:) 构造
    /// 路径表，脏数据直接 trap）。这里改为确定性收敛，收敛后必须建索引，建不出来
    /// 就抛错（由 migrate() 的备份/恢复路径回滚整个迁移），绝不降级放过。
    ///
    /// 收敛规则：同一 (session_id, filepath) 组保留 rowid 最小（最早导入）的行，
    /// 其余为重复行；重复行的全部引用改指向保留行，改指向会撞唯一约束的行随后
    /// 删除，最后删除重复行本身。
    /// 保留 rowid 最小者的理由见报告「可见影响」一节：photos.rowid 同时是导入
    /// 顺序（session_assets.import_order 与 asset_backfill_state 游标都由它派生），
    /// 保留最早的行不会让既有会话的显示顺序跳变。
    private func ensurePhotoPathUniqueness(_ db: DBConnection) throws {
        try db.transaction {
            // 廉价探针：唯一索引已存在时该 GROUP BY 走索引，干净库每次启动只付
            // 一次索引扫描；只有真的发现重复才进入合并与 PRAGMA 枚举。
            let hasDuplicates = try db.prepare("""
                SELECT 1 FROM (
                  SELECT 1 FROM photos GROUP BY session_id, filepath HAVING COUNT(*) > 1
                ) LIMIT 1
              """).get() != nil
            if hasDuplicates {
                let references = try photoReferencingColumns(db)
                let jsonColumns = try photoIdJsonColumns(db)
                let groups = try duplicatePhotoGroups(db)
                for group in groups {
                    for duplicateId in group.duplicateIds {
                        try mergeDuplicatePhoto(
                            db,
                            duplicateId: duplicateId,
                            canonicalId: group.canonicalId,
                            references: references,
                            jsonColumns: jsonColumns
                        )
                    }
                    // photo_count 是缓存计数：删行后同事务内重算，避免迁移完成后
                    // 一段时间的计数虚高（下一次扫描也会重算，但不能依赖它）。
                    _ = try db.prepare("""
                        UPDATE sessions
                        SET photo_count = (SELECT COUNT(*) FROM photos WHERE photos.session_id = sessions.id)
                        WHERE id = ?
                      """).run([.text(group.sessionId)])
                }
            }
            let remaining = Int((try db.prepare("""
                SELECT COUNT(*) FROM (
                  SELECT 1 FROM photos GROUP BY session_id, filepath HAVING COUNT(*) > 1
                )
              """).get()?[0].intValue) ?? 0)
            if remaining > 0 {
                throw DBError.message(
                    "Migration invariant failed: \(remaining) duplicate (session_id, filepath) groups remain in photos"
                )
            }
            try db.exec(SchemaSQL.uniquePhotoPathIndexSQL)
        }
    }

    /// 重复组：canonicalId = 组内 rowid 最小者，duplicateIds = 其余行（按 rowid 升序）。
    private func duplicatePhotoGroups(_ db: DBConnection) throws -> [
        (sessionId: String, canonicalId: String, duplicateIds: [String])
    ] {
        let rows = try db.prepare("""
            SELECT p.session_id, p.id, p.rowid, (
              SELECT MIN(k.rowid) FROM photos k
              WHERE k.session_id = p.session_id AND k.filepath = p.filepath
            ) AS first_rowid
            FROM photos p
            WHERE (SELECT COUNT(*) FROM photos d
                   WHERE d.session_id = p.session_id AND d.filepath = p.filepath) > 1
            ORDER BY p.session_id, p.filepath, p.rowid
          """).query()
        var groups: [(sessionId: String, canonicalId: String, duplicateIds: [String])] = []
        var currentKey: String?
        for row in rows {
            guard let sessionId = row[0].textValue, let photoId = row[1].textValue else { continue }
            let rowid = row[2].intValue ?? 0
            let firstRowid = row[3].intValue ?? 0
            let key = "\(sessionId)\u{0}\(firstRowid)"
            if key != currentKey {
                groups.append((sessionId: sessionId, canonicalId: "", duplicateIds: []))
                currentKey = key
            }
            if rowid == firstRowid {
                groups[groups.count - 1].canonicalId = photoId
            } else {
                groups[groups.count - 1].duplicateIds.append(photoId)
            }
        }
        return groups.filter { !$0.canonicalId.isEmpty && !$0.duplicateIds.isEmpty }
    }

    /// 把一行重复照片的所有引用改指向保留行，然后删除重复行本身。
    private func mergeDuplicatePhoto(
        _ db: DBConnection,
        duplicateId: String,
        canonicalId: String,
        references: [(table: String, column: String)],
        jsonColumns: [(table: String, column: String)]
    ) throws {
        for reference in references {
            // 改指向后若违反该表的唯一约束（OR IGNORE），保留行优先，重复行的
            // 副本由紧随其后的清扫删除。
            _ = try db.prepare(
                "UPDATE OR IGNORE \(reference.table) SET \(reference.column) = ? WHERE \(reference.column) = ?"
            ).run([.text(canonicalId), .text(duplicateId)])
            _ = try db.prepare(
                "DELETE FROM \(reference.table) WHERE \(reference.column) = ?"
            ).run([.text(duplicateId)])
        }
        // similarity_cluster_state 故意不声明 photos 外键（残留行是增量 diff 的
        // “已移除”依据），但它以 photo_id 为主键的一部分 → 显式改指向。
        _ = try db.prepare(
            "UPDATE OR IGNORE similarity_cluster_state SET photo_id = ? WHERE photo_id = ?"
        ).run([.text(canonicalId), .text(duplicateId)])
        _ = try db.prepare("DELETE FROM similarity_cluster_state WHERE photo_id = ?")
            .run([.text(duplicateId)])
        // 引用 photos.id 的 JSON/文本列：整词替换（两侧带引号）——photo.id 是
        // UUID，带引号边界保证 p2 不会命中 p20，也不会误伤其它字符串。
        for column in jsonColumns {
            rewritePhotoIdToken(
                db, table: column.table, column: column.column,
                from: duplicateId, to: canonicalId
            )
        }
        _ = try db.prepare("DELETE FROM photos WHERE id = ?").run([.text(duplicateId)])
    }

    /// 引用 photos.id 的 JSON/文本列：**运行时枚举**（所有 TEXT 且列名以
    /// _json / _ids 结尾的列）减去下面的显式豁免表。与 photoReferencingColumns
    /// 同一思路 —— 写死清单会随 schema 漂移，漏一列就会让合并后的库里留下
    /// 悬空 id（undo / 恢复 / 重跑分析都会指向已删除的照片行）。
    ///
    /// 默认是「重写」而不是「跳过」：新加的同名列会自动被重写，只有语义上
    /// 确认不含 photos.id 的列才需要进豁免表并写明理由。
    private func photoIdJsonColumns(_ db: DBConnection) throws -> [(table: String, column: String)] {
        let tables = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).query().compactMap { $0[0].textValue }
        var columns: [(table: String, column: String)] = []
        for table in tables {
            let tableInfo = try db.prepare("PRAGMA table_info(\(table))").query()
            for row in tableInfo {
                guard row.count > 2 else { continue }
                let name = row[1].textValue ?? ""
                let type = (row[2].textValue ?? "").uppercased()
                guard type.contains("TEXT") else { continue }
                guard name.hasSuffix("_json") || name.hasSuffix("_ids") else { continue }
                guard !Self.exemptPhotoIdJsonColumns.contains("\(table).\(name)") else { continue }
                columns.append((table, name))
            }
        }
        return columns
    }

    /// 显式豁免（列 → 理由）。每条都必须说明为什么这类列**语义上不含
    /// photos.id**，因此合并重复照片时不需要重写。
    private static let exemptPhotoIdJsonColumns: Set<String> = [
        // 关联候选证据：内容是两个 asset_files.id + basename/相机/时间，不引用照片行。
        "asset_link_candidates.evidence_json",
        // 写回条目属性：XMP 字段补丁（rating/label/keywords…），行身份由 photo_id 列承担。
        "writeback_items.attributes_json",
        // 元数据 outbox：XMP 字段补丁与基值快照，outbox 行身份由 photo_path 列承担
        // （photo_path 的重定位由 AssetRepo.relocateMetadataState 负责）。
        "metadata_outbox.patch_json",
        "metadata_outbox.base_values_json",
    ]

    /// 在单列的 JSON/文本里把 id 令牌 \"from\" 整词换成 \"to\"。
    /// 用 instr 预筛（不用 LIKE，省掉通配符转义），只改动真正含令牌的行。
    private func rewritePhotoIdToken(
        _ db: DBConnection,
        table: String,
        column: String,
        from: String,
        to: String
    ) {
        let token = "\"\(from)\""
        _ = try? db.prepare("""
            UPDATE \(table) SET \(column) = REPLACE(\(column), ?, ?)
            WHERE instr(\(column), ?) > 0
          """).run([.text(token), .text("\"\(to)\""), .text(token)])
    }

    /// 运行时发现所有声明 REFERENCES photos(id) 的子表与列（PRAGMA
    /// foreign_key_list：第 2 列 = 被引用表，第 3 列 = 本表列）。写死清单会随
    /// schema 漂移，故此处动态枚举。
    private func photoReferencingColumns(_ db: DBConnection) throws -> [(table: String, column: String)] {
        let tables = try db.prepare(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).query().compactMap { $0[0].textValue }
        var references: [(table: String, column: String)] = []
        for table in tables {
            let foreignKeys = try db.prepare("PRAGMA foreign_key_list(\(table))").query()
            for foreignKey in foreignKeys {
                guard foreignKey.count > 4,
                      foreignKey[2].textValue == "photos",
                      let column = foreignKey[3].textValue
                else { continue }
                references.append((table: table, column: column))
            }
        }
        return references
    }

    // ─────────────────────── 人脸缩略图落盘 ───────────────────────

    /// 把 Base64 缩略图原子写入磁盘（TS writeMigratedFaceThumbnail 的移植）：
    /// 独占创建临时文件 → rename 到目标；Windows 语义（EEXIST/EPERM）下先删后重试。
    public static func writeMigratedFaceThumbnail(
        thumbnailDir: String,
        clusterId: Int,
        thumbnailBase64: String
    ) throws -> String {
        guard let buffer = Data(base64Encoded: thumbnailBase64), !buffer.isEmpty else {
            throw DBError.message("Face thumbnail \(clusterId) is empty")
        }

        let fileName = "\(clusterId).jpg"
        let finalPath = thumbnailDir + "/" + fileName
        let tempName = ".\(fileName).\(ProcessInfo.processInfo.processIdentifier).\(Int(Date().timeIntervalSince1970 * 1000)).tmp"
        let tempPath = thumbnailDir + "/" + tempName
        do {
            try buffer.write(to: URL(fileURLWithPath: tempPath), options: .withoutOverwriting)
            do {
                try FileManager.default.moveItem(atPath: tempPath, toPath: finalPath)
            } catch {
                let code = (error as NSError).code
                if code != NSFileWriteFileExistsError && code != NSFileWriteNoPermissionError { throw error }
                // The thumbnail is derived data and the database still retains the Base64
                // source until this function succeeds, so a remove-and-retry is safe.
                try FileManager.default.removeItem(atPath: finalPath)
                try FileManager.default.moveItem(atPath: tempPath, toPath: finalPath)
            }
            return fileName
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    private func resolveFaceThumbnailMigrationDir(_ db: DBConnection) throws -> String? {
        var customDir = ""
        if let row = try db.prepare("SELECT value FROM app_settings WHERE key = 'face_thumbnail_dir'").get() {
            customDir = row[0].textValue ?? ""
        }
        let fallbackDir = faceThumbnailFallbackDir ?? ""
        let candidates = customDir.isEmpty ? [fallbackDir] : [customDir, fallbackDir]

        for candidate in candidates where !candidate.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
                guard FileManager.default.isWritableFile(atPath: candidate) else {
                    throw DBError.message("directory is not writable")
                }
                if !customDir.isEmpty && candidate != customDir {
                    GatherLogger.log(
                        "Face thumbnail directory is not writable; falling back to \(candidate)",
                        level: .warn
                    )
                    _ = try db.prepare("""
                        INSERT INTO app_settings (key, value)
                        VALUES ('face_thumbnail_dir', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """).run([.text(candidate)])
                }
                return candidate
            } catch {
                GatherLogger.log(
                    "Face thumbnail directory is unavailable: \(candidate)",
                    level: .warn
                )
            }
        }
        return nil
    }

    private func migratePendingFaceThumbnails(_ db: DBConnection) throws {
        // Older builds used this marker after discarding the source data. It is not
        // a valid file path, so leave those rows ready for thumbnail regeneration.
        _ = try db.prepare("""
            UPDATE face_clusters
            SET thumbnail_path = ''
            WHERE thumbnail_path = '__migration_failed__'
              AND thumbnail_base64 = ''
            """).run()

        let rows = try db.prepare("""
            SELECT id, thumbnail_base64
            FROM face_clusters
            WHERE thumbnail_base64 != ''
              AND (thumbnail_path = '' OR thumbnail_path = '__migration_failed__')
            """).query()
        if rows.isEmpty { return }

        guard let thumbnailDir = try resolveFaceThumbnailMigrationDir(db) else {
            GatherLogger.log(
                "Deferred migration of \(rows.count) face thumbnails because no writable directory is available",
                level: .warn
            )
            return
        }

        for row in rows {
            let clusterId = Int(row[0].intValue ?? 0)
            let thumbnailBase64 = row[1].textValue ?? ""
            do {
                let fileName = try Self.writeMigratedFaceThumbnail(
                    thumbnailDir: thumbnailDir,
                    clusterId: clusterId,
                    thumbnailBase64: thumbnailBase64
                )
                _ = try db.prepare("""
                    UPDATE face_clusters
                    SET thumbnail_path = ?, thumbnail_base64 = ''
                    WHERE id = ?
                    """).run([.text(fileName), .int(Int64(clusterId))])
            } catch {
                GatherLogger.log(
                    "Deferred migration of face thumbnail for cluster \(clusterId): \(error)",
                    level: .warn
                )
            }
        }
    }

    // ─────────────────────────── 备份/回滚（ADR-005） ───────────────────────────

    private func createMigrationBackup(_ connection: DBConnection, currentVersion: Int) throws -> String? {
        guard currentVersion < Self.currentSchemaVersion,
              let dbPath = databaseFilePath,
              FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let sourceSize: Int64 = [dbPath, walPath, shmPath].reduce(0) { total, path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else { return total }
            return total + size.int64Value
        }

        guard let fileSystem = statvfsFor(dbPath) else {
            throw DBError.message("无法读取磁盘空间信息用于迁移备份")
        }
        let freeBytes = fileSystem.freeBytes
        let requiredBytes = max(64 * 1024 * 1024, Int(sourceSize * 2))
        if freeBytes < requiredBytes {
            throw DBError.message(
                "Insufficient disk space for database migration backup: need \(requiredBytes) bytes, have \(freeBytes)"
            )
        }

        try dbCheckpoint(connection)
        let backupPath = "\(dbPath).pre-v\(Self.currentSchemaVersion)-\(Int(Date().timeIntervalSince1970 * 1000)).bak"
        try sqliteBackup(connection, to: backupPath)
        // SQLite may materialize the backup lazily on some runtime versions
        // combinations. The WAL has already been checkpointed, so keep a durable
        // file-level fallback before allowing migrations to mutate the database.
        if !FileManager.default.fileExists(atPath: backupPath) {
            try FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)
        }

        // 只读打开备份做 integrity_check（与 TS 的 readonly 打开一致，不改动备份）。
        guard try backupIntegrityCheckOK(backupPath) else {
            throw DBError.message("Pre-migration database backup failed integrity_check")
        }
        return backupPath
    }

    /// 只读打开备份文件，PRAGMA integrity_check 必须恰好返回一行 "ok"。
    /// 注（2026-08-10 macOS 26 实测）：SQLite 3.51 对 header 标记 WAL 的库，
    /// 只读打开要求同名 -shm 文件存在，否则 prepare 报 SQLITE_CANTOPEN
    /// （旧版 SQLite 无此行为）。备份文件由 backup API
    /// 生成，不带 -wal/-shm 伴随文件；故先创建空伴随文件以满足只读打开
    /// 协议（空 -wal 表示 checkpoint 已完整，读主文件），检查后清理。
    private func backupIntegrityCheckOK(_ path: String) throws -> Bool {
        let walPath = path + "-wal"
        let shmPath = path + "-shm"
        for companion in [walPath, shmPath] {
            if !FileManager.default.fileExists(atPath: companion) {
                FileManager.default.createFile(atPath: companion, contents: nil)
            }
        }
        defer {
            for companion in [walPath, shmPath] {
                try? FileManager.default.removeItem(atPath: companion)
            }
        }
        var backup: OpaquePointer?
        let rc = sqlite3_open_v2(path, &backup, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let backup else {
            throw DBError.message("无法打开迁移备份 \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
        defer { sqlite3_close_v2(backup) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(backup, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.message("无法编译备份完整性检查: \(String(cString: sqlite3_errmsg(backup)))")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        guard let c = sqlite3_column_text(stmt, 0) else { return false }
        let value = String(cString: c)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return value == "ok"
    }

    private func dbCheckpoint(_ db: DBConnection) throws {
        _ = try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// SQLite backup API（对应 TS 的 rawDb.backup()，非直接复制活动 db）。
    private func sqliteBackup(_ source: DBConnection, to destinationPath: String) throws {
        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(destinationPath, &destination, flags, nil) == SQLITE_OK, let destination else {
            throw DBError.message("无法创建迁移备份目标 \(destinationPath)")
        }
        defer { sqlite3_close_v2(destination) }

        guard let sourceHandle = source.rawHandle else {
            throw DBError.message("数据库已关闭，无法创建迁移备份")
        }

        let backup: OpaquePointer? = sqlite3_backup_init(destination, "main", sourceHandle, "main")
        defer {
            if let backup { sqlite3_backup_finish(backup) }
        }
        guard let backup else {
            throw DBError.message("sqlite3_backup_init 失败: \(String(cString: sqlite3_errmsg(destination)))")
        }

        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, 100)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                Thread.sleep(forTimeInterval: 0.1)
            }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        guard rc == SQLITE_DONE else {
            throw DBError.message("数据库备份失败: \(String(cString: sqlite3_errstr(rc)))")
        }
    }

    /// internal：第三轮验收测试直接驱动「恢复失败保持原库 / 成功替换」两条路径。
    func restoreBackup(_ connection: DBConnection, dbPath: String, backupPath: String) throws {
        // 问题 3（第三轮审查）：旧实现虽然先复制到临时文件，但替换时
        // 「removeItem(dbPath) 后再 moveItem」之间有窗口 —— 此间进程退出/移动失败
        // 会让活动数据库路径为空（只能手工从备份恢复）。
        // 另外 -wal/-shm 原先在替换**之前**删除：替换若失败，老库会丢掉 WAL。
        // 这里改为：完整复制到临时文件 → 同卷原子替换 → 成功后才清理旧 WAL。
        connection.close()
        let tmpPath = dbPath + ".restore-tmp"
        // 验收（问题 3）：**任何**失败路径都必须把原库重新打开——此前 copyItem
        // 抛错（备份缺失/磁盘满）落在 try/catch 之外，连接会一直处于关闭状态。
        do {
            _ = try? FileManager.default.removeItem(atPath: tmpPath)
            try FileManager.default.copyItem(atPath: backupPath, toPath: tmpPath)
            // 基本完整性校验：0 字节的临时库不应替换活库。
            let attributes = try FileManager.default.attributesOfItem(atPath: tmpPath)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                try? FileManager.default.removeItem(atPath: tmpPath)
                throw DBError.message("备份恢复失败：临时数据库为空（已保留原库）")
            }
            let dbURL = URL(fileURLWithPath: dbPath)
            let tmpURL = URL(fileURLWithPath: tmpPath)
            if FileManager.default.fileExists(atPath: dbPath) {
                // 同卷原子替换：失败时原库保持不变（不会出现「路径为空」的窗口）。
                _ = try FileManager.default.replaceItemAt(dbURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(atPath: tmpPath, toPath: dbPath)
            }
            // 只有替换成功后才清理旧库的 WAL/SHM（它们是旧库的，此时已无意义）。
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
            // 恢复失败：原库仍在（replaceItemAt 语义），重开连接并保留诊断。
            try? connection.reopen()
            throw error
        }
        try connection.reopen()
    }

    /// 备份淘汰（TS pruneMigrationBackups，keep=3）：按 mtime 保留最新 keep 个。
    internal func pruneMigrationBackups(databaseFilePath: String, keep: Int = 3) throws {
        let directory = (databaseFilePath as NSString).deletingLastPathComponent
        let base = (databaseFilePath as NSString).lastPathComponent
        let pattern = "^\(NSRegularExpression.escapedPattern(for: base))\\.pre-v\\d+-\\d+\\.bak$"
        let regex = try NSRegularExpression(pattern: pattern)

        var backups: [(path: String, mtimeMs: TimeInterval)] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
            let range = NSRange(name.startIndex..., in: name)
            guard regex.firstMatch(in: name, range: range) != nil else { continue }
            let path = directory + "/" + name
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            backups.append((path, mtime))
        }
        backups.sort { $0.mtimeMs > $1.mtimeMs }
        for stale in backups.dropFirst(keep) {
            try? FileManager.default.removeItem(atPath: stale.path)
        }
    }

    // ─────────────────────────── 迁移后不变量 ───────────────────────────

    private func assertMigrationInvariants(_ db: DBConnection) throws {
        let version = try getSchemaVersion(db)
        if version != Self.currentSchemaVersion {
            throw DBError.message("Migration ended at an unexpected schema version: \(version)")
        }
        let foreignKeyErrors = try db.prepare("PRAGMA foreign_key_check").query()
        if !foreignKeyErrors.isEmpty {
            throw DBError.message("Migration created \(foreignKeyErrors.count) foreign key violations")
        }
        for (table, columns) in [
            ("metadata_outbox", ["xmp_path", "created_by_session_id", "status", "source_module"]),
            ("metadata_outbox_sessions", ["xmp_path", "session_id", "confirmed_at"]),
            ("analysis_jobs", ["id", "status", "dedupe_key"]),
            ("culling_decisions", ["session_id", "revision", "decision_source"]),
            ("culling_history", ["session_id", "operation_json"]),
            ("asset_backfill_state", ["session_id", "last_photo_rowid", "status"]),
            ("analysis_runs", ["session_id", "kind", "index_seq", "status"]),
            ("similarity_cluster_state", ["session_id", "photo_id", "component_index", "group_seed"]),
            ("similarity_cluster_meta", ["session_id", "version", "incremental_updates"]),
        ] {
            try assertColumns(db, table, columns)
        }
    }
}

// ─────────────────────────── statvfs（磁盘空间检查） ───────────────────────────

private struct FileSystemFreeSpace {
    let freeBytes: Int64
}

private func statvfsFor(_ path: String) -> FileSystemFreeSpace? {
    #if canImport(Glibc)
    var stat = statvfs()
    guard statvfs(path, &stat) == 0 else { return nil }
    return FileSystemFreeSpace(freeBytes: Int64(stat.f_bavail) * Int64(stat.f_bsize))
    #elseif canImport(Darwin)
    var stat = statvfs()
    guard statvfs(path, &stat) == 0 else { return nil }
    return FileSystemFreeSpace(freeBytes: Int64(stat.f_bavail) * Int64(stat.f_frsize))
    #else
    return nil
    #endif
}
