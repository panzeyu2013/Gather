// Store/StoreMigrator.swift
// R1：迁移注册表与执行器（取代 Database/Migrations.swift 的 if 链）。
//
// 语义与旧执行器逐条对齐（docs/ARCHITECTURE-REWRITE-DESIGN.md §3.3）：
// - 空库：先执行 StoreSchema.schemaSQL，再按版本递增执行 steps；
// - 每个版本一个事务，版本号在事务内写入（失败自动回滚）；
// - ADR-005：磁盘空间检查 → wal_checkpoint(TRUNCATE) → SQLite backup API →
//   备份 integrity_check → 迁移失败从备份恢复（不写 down-migration）→
//   迁移后 foreign_key_check + 列不变量 + 版本校验 → 备份 keep=3 淘汰（非致命）；
// - 迁移末尾无条件执行 INDEX_SQL（ADR-006）。
//
// 迁移 SQL 与旧实现逐字一致，仅调用面改为 async actor；步骤体在
// StoreMigrator.steps 内以 isolated 闭包执行，不经过任何兼容层。
import Foundation
import CSQLite

public enum StoreMigrationError: Error, Equatable, CustomStringConvertible {
    case message(String)

    public var description: String {
        if case .message(let text) = self { return text }
        return "migration error"
    }
}

public struct MigrationStep: Sendable {
    public let version: Int
    public let description: String
    public let up: @Sendable (isolated SQLiteDatabase) throws -> Void

    public init(
        version: Int,
        description: String,
        up: @escaping @Sendable (isolated SQLiteDatabase) throws -> Void
    ) {
        self.version = version
        self.description = description
        self.up = up
    }
}

public struct StoreMigrator: Sendable {
    public static let currentSchemaVersion = StoreSchema.currentVersion

    /// 数据库文件路径（为 nil 时跳过备份/回滚：内存库或测试场景）。
    public var databaseFilePath: String?
    /// 人脸缩略图回退目录（为 nil 且无可用目录时延迟迁移，与旧语义一致）。
    public var faceThumbnailFallbackDir: String?
    /// 测试注入点：迁移完成后、不变量校验前调用，抛出即触发备份回滚。
    public var afterMigrateHook: (@Sendable () throws -> Void)?

    public init(
        databaseFilePath: String? = nil,
        faceThumbnailFallbackDir: String? = nil,
        afterMigrateHook: (@Sendable () throws -> Void)? = nil
    ) {
        self.databaseFilePath = databaseFilePath
        self.faceThumbnailFallbackDir = faceThumbnailFallbackDir
        self.afterMigrateHook = afterMigrateHook
    }

    // MARK: - 入口

    /// 幂等：已是最新版本时为空操作；失败按 ADR-005 从备份恢复。
    public func migrate(_ database: SQLiteDatabase) async throws {
        let previousVersion = try await Self.schemaVersion(of: database)
        let backupPath = try await Self.createMigrationBackup(
            database,
            currentVersion: previousVersion,
            databaseFilePath: databaseFilePath
        )
        do {
            try await Self.runSteps(database, from: previousVersion, fallbackDir: faceThumbnailFallbackDir)
            try afterMigrateHook?()
            try await Self.assertMigrationInvariants(database)
            do {
                if let databaseFilePath {
                    try Self.pruneMigrationBackups(databaseFilePath: databaseFilePath)
                }
            } catch {
                GatherLogger.log("Unable to prune old migration backups: \(error)", level: .warn)
            }
        } catch {
            if let backupPath, let databaseFilePath {
                try await Self.restoreBackup(database, dbPath: databaseFilePath, backupPath: backupPath)
            }
            throw error
        }
    }

    private static func runSteps(_ database: SQLiteDatabase, from version: Int, fallbackDir: String?) async throws {
        try await database.execute(StoreSchema.schemaSQL)
        for step in steps where step.version > version {
            try await database.transaction { db in
                try step.up(db)
            }
        }
        // 不变量（ADR-006）：迁移末尾无条件执行索引 DDL 与两个收尾迁移。
        try await database.transaction { db in
            try db.execute(StoreSchema.indexSQL)
            try ensurePhotoPathUniqueness(db)
            try migratePendingFaceThumbnails(db, fallbackDir: fallbackDir)
        }
    }

    // MARK: - schema_version 语义

    private static func schemaVersion(_ db: isolated SQLiteDatabase) throws -> Int {
        do {
            guard let row = try db.queryOne("SELECT MAX(version) AS version FROM schema_version") else {
                return 0
            }
            return Int(row.int(at: 0) ?? 0)
        } catch let failure as SQLiteFailure where failure.isMissingTable {
            return 0
        } catch {
            throw StoreMigrationError.message("读取 schema_version 失败: \(error)")
        }
    }

    private static func schemaVersion(of database: SQLiteDatabase) async throws -> Int {
        do {
            return Int(try await database.scalarInt("SELECT MAX(version) AS version FROM schema_version") ?? 0)
        } catch let failure as SQLiteFailure where failure.isMissingTable {
            return 0
        } catch {
            throw StoreMigrationError.message("读取 schema_version 失败: \(error)")
        }
    }

    private static func setSchemaVersion(_ db: isolated SQLiteDatabase, _ version: Int) throws {
        try db.run(
            "INSERT OR REPLACE INTO schema_version (version, applied_at) VALUES (?, ?)",
            [.int(Int64(version)), .text(nowISO())]
        )
    }

    private static func nowISO() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - 步骤辅助（isolated：只在步骤闭包内使用）

    private static func columnExists(_ db: isolated SQLiteDatabase, _ table: String, _ column: String) -> Bool {
        guard let rows = try? db.query("PRAGMA table_info(\(table))") else { return false }
        return rows.contains { $0.text(at: 1) == column }
    }

    private static func addColumn(
        _ db: isolated SQLiteDatabase,
        _ table: String,
        _ column: String,
        _ type: String
    ) throws -> Bool {
        if columnExists(db, table, column) { return false }
        try db.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type)")
        return true
    }

    private static func fillTimestamp(_ db: isolated SQLiteDatabase, _ table: String, _ column: String) throws {
        try db.run("UPDATE \(table) SET \(column) = ? WHERE \(column) = '' OR \(column) IS NULL", [.text(nowISO())])
    }

    private static func tableExists(_ db: isolated SQLiteDatabase, _ table: String) -> Bool {
        guard let row = try? db.queryOne(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(table)]
        ) else { return false }
        return row != nil
    }

    private static func assertColumns(_ db: isolated SQLiteDatabase, _ table: String, _ columns: [String]) throws {
        for column in columns where !columnExists(db, table, column) {
            throw StoreMigrationError.message("Migration invariant failed: \(table).\(column) is missing")
        }
    }

    // MARK: - 迁移内嵌 DDL 常量

    private static let createFaceClusterMembersSQL = """
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

    // MARK: - 步骤注册表（SQL 与旧 Migrations.swift 逐字一致）

    // swiftlint:disable:next function_body_length
    public static let steps: [MigrationStep] = [
        MigrationStep(version: 1, description: "v1") { db in

            try db.transaction { db in
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
        },
        MigrationStep(version: 2, description: "v2") { db in

            try setSchemaVersion(db, 2)
        },
        MigrationStep(version: 3, description: "v3") { db in

            try db.transaction { db in
                _ = try addColumn(db, "photo_metadata_cache", "label", "TEXT")
                try assertColumns(db, "photo_metadata_cache", ["label"])
                try setSchemaVersion(db, 3)
            }
        },
        MigrationStep(version: 4, description: "v4") { db in

            try db.transaction { db in
                _ = try addColumn(db, "sessions", "source_path", "TEXT NOT NULL DEFAULT ''")
                try assertColumns(db, "sessions", ["source_path"])
                try setSchemaVersion(db, 4)
            }
        },
        MigrationStep(version: 5, description: "v5") { db in

            try db.transaction { db in
                _ = try addColumn(db, "similarity_hashes", "file_size", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "similarity_hashes", "file_mtime_ms", "REAL NOT NULL DEFAULT 0")
                try db.execute("""
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
        },
        MigrationStep(version: 6, description: "v6") { db in

            try db.transaction { db in
                _ = try addColumn(db, "photos", "checksum_file_size", "INTEGER NOT NULL DEFAULT 0")
                _ = try addColumn(db, "photos", "checksum_file_mtime_ms", "REAL NOT NULL DEFAULT 0")
                try assertColumns(db, "photos", ["checksum_file_size", "checksum_file_mtime_ms"])
                try setSchemaVersion(db, 6)
            }
        },
        MigrationStep(version: 7, description: "v7") { db in

            try db.transaction { db in
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
        },
        MigrationStep(version: 8, description: "v8") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 9, description: "v9") { db in

            try db.transaction { db in
                try db.execute("""
                    DELETE FROM culling_decisions
                    WHERE id NOT IN (
                      SELECT MAX(id)
                      FROM culling_decisions
                      GROUP BY session_id, photo_id
                    );
                    """)
                try setSchemaVersion(db, 9)
            }
        },
        MigrationStep(version: 10, description: "v10") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 11, description: "v11") { db in

            try db.transaction { db in
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS face_cluster_state (
                      session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
                      cluster_signature TEXT NOT NULL,
                      updated_at TEXT NOT NULL
                    )
                    """)
                try setSchemaVersion(db, 11)
            }
        },
        MigrationStep(version: 12, description: "v12") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 13, description: "v13") { db in

            try db.transaction { db in
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
                try db.execute("""
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
        },
        MigrationStep(version: 14, description: "v14") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 15, description: "v15") { db in

            try db.transaction { db in
                _ = try addColumn(db, "photos", "asset_id", "TEXT REFERENCES assets(id)")
                _ = try addColumn(db, "photos", "asset_file_id", "TEXT REFERENCES asset_files(id)")
                try db.execute("""
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
        },
        MigrationStep(version: 16, description: "v16") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 17, description: "v17") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 18, description: "v18") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 19, description: "v19") { db in

            try db.transaction { db in
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS culling_history (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                      operation_json TEXT NOT NULL DEFAULT '[]',
                      created_at TEXT NOT NULL
                    );
                    """)
                try setSchemaVersion(db, 19)
            }
        },
        MigrationStep(version: 20, description: "v20") { db in

            try db.transaction { db in
                _ = try addColumn(db, "smart_albums", "schema_version", "INTEGER NOT NULL DEFAULT 1")
                try setSchemaVersion(db, 20)
            }
        },
        MigrationStep(version: 21, description: "v21") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 22, description: "v22") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 23, description: "v23") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 24, description: "v24") { db in

            try db.transaction { db in
                _ = try addColumn(db, "asset_files", "file_identity", "TEXT NOT NULL DEFAULT ''")
                _ = try addColumn(db, "culling_decisions", "decision_source", "TEXT NOT NULL DEFAULT 'manual'")
                _ = try addColumn(db, "culling_history", "undone", "INTEGER NOT NULL DEFAULT 0")
                try db.execute("""
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
        },
        MigrationStep(version: 25, description: "v25") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
        MigrationStep(version: 26, description: "v26") { db in

            try db.transaction { db in
                try db.execute("""
                    DROP INDEX IF EXISTS idx_culling_photo_session;
                    """)
                try setSchemaVersion(db, 26)
            }
        },
        MigrationStep(version: 27, description: "v27") { db in

            try db.transaction { db in
                _ = try addColumn(db, "metadata_outbox", "source_module", "TEXT NOT NULL DEFAULT ''")
                // json_valid guards the CASE branches: a malformed legacy patch_json must
                // not abort startup, it just falls back to 'manual'.
                try db.execute("""
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
        },
        MigrationStep(version: 28, description: "v28") { db in

            try db.transaction { db in
                // person_photos previously had no uniqueness constraint, so re-binding a
                // cluster (or binding two clusters of the same photos to one role) could
                // insert duplicate rows and inflate photo counts. Deduplicate existing
                // rows here; the unique index itself is created by INDEX_SQL afterwards,
                // which now fails cleanly only if duplicates were somehow reintroduced.
                try db.execute("""
                    DELETE FROM person_photos
                    WHERE id NOT IN (
                      SELECT MIN(id)
                      FROM person_photos
                      GROUP BY person_id, photo_id
                    );
                    """)
                try setSchemaVersion(db, 28)
            }
        },
        MigrationStep(version: 29, description: "v29") { db in

            try db.transaction { db in
                _ = try addColumn(db, "sessions", "truncated_import", "INTEGER NOT NULL DEFAULT 0")
                try assertColumns(db, "sessions", ["truncated_import"])
                try setSchemaVersion(db, 29)
            }
        },
        MigrationStep(version: 30, description: "v30") { db in

            try db.transaction { db in
                _ = try addColumn(db, "sessions", "index_seq", "INTEGER NOT NULL DEFAULT 0")
                try db.execute("""
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
        },
        MigrationStep(version: 31, description: "v31") { db in

            try db.transaction { db in
                _ = try addColumn(db, "sessions", "reload_acked_at", "TEXT")
                try assertColumns(db, "sessions", ["reload_acked_at"])
                try setSchemaVersion(db, 31)
            }
        },
        MigrationStep(version: 32, description: "v32") { db in

            try db.execute("""
                DROP INDEX IF EXISTS idx_photos_asset_group;
                CREATE INDEX IF NOT EXISTS idx_photos_asset_group
                  ON photos(session_id, COALESCE(NULLIF(asset_id, ''), id));
                """)
            try setSchemaVersion(db, 32)
        },
        MigrationStep(version: 33, description: "v33") { db in

            try db.transaction { db in
                try db.execute("""
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
        },
    ]

    // MARK: - face_cluster_members 重建

    private static func restoreFaceClusterMembers(_ db: isolated SQLiteDatabase, oldTable: String) throws {
        let oldColumns = (try? db.query("PRAGMA table_info(\(oldTable))")) ?? []
        let hasObservationId = oldColumns.contains { $0.text(at: 1) == "observation_id" }
        let observationExpr = hasObservationId
            ? "CASE WHEN o.observation_id IN (SELECT id FROM face_observations) THEN o.observation_id ELSE NULL END"
            : "NULL"

        try db.execute("""
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
        try db.execute("DROP TABLE \(oldTable)")
    }

    private static func migrateFaceClusterMembers(_ db: isolated SQLiteDatabase) throws {
        let oldTable = "__face_cluster_members_old"

        if tableExists(db, oldTable) {
            if !tableExists(db, "face_cluster_members") {
                try db.execute(createFaceClusterMembersSQL)
            }
            try restoreFaceClusterMembers(db, oldTable: oldTable)
        }

        if !tableExists(db, "face_cluster_members") {
            try db.execute(createFaceClusterMembersSQL)
            return
        }

        let foreignKeys = try db.query("PRAGMA foreign_key_list(face_cluster_members)")
        var hasObservationFk = false
        for row in foreignKeys {
            let hasColumns: Bool = row.columnOrder.count > 3
            if hasColumns, row.text(at: 2) == "face_observations", row.text(at: 3) == "observation_id" {
                hasObservationFk = true
                break
            }
        }
        if hasObservationFk { return }

        try db.execute("ALTER TABLE face_cluster_members RENAME TO \(oldTable)")
        try db.execute(createFaceClusterMembersSQL)
        try restoreFaceClusterMembers(db, oldTable: oldTable)
    }

    // MARK: - 唯一照片路径索引

    private static func ensurePhotoPathUniqueness(_ db: isolated SQLiteDatabase) throws {
        let duplicate = try db.queryOne("""
            SELECT session_id, filepath, COUNT(*) AS count
            FROM photos
            GROUP BY session_id, filepath
            HAVING COUNT(*) > 1
            LIMIT 1
            """)
        if let duplicate {
            let sessionId = duplicate.text(at: 0) ?? "?"
            let filepath = duplicate.text(at: 1) ?? "?"
            let count = duplicate.int(at: 2) ?? 0
            GatherLogger.log(
                "Skipping unique photo-path index: session \(sessionId) contains \(count) rows for \(filepath)",
                level: .warn
            )
            return
        }
        try db.execute(StoreSchema.uniquePhotoPathIndexSQL)
    }

    // MARK: - 人脸缩略图落盘

    /// 把 Base64 缩略图原子写入磁盘（TS writeMigratedFaceThumbnail 的移植）。
    public static func writeMigratedFaceThumbnail(
        thumbnailDir: String,
        clusterId: Int,
        thumbnailBase64: String
    ) throws -> String {
        guard let buffer = Data(base64Encoded: thumbnailBase64), !buffer.isEmpty else {
            throw StoreMigrationError.message("Face thumbnail \(clusterId) is empty")
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
                // 缩略图是派生数据，数据库仍保留 Base64 源，删除重试是安全的。
                try FileManager.default.removeItem(atPath: finalPath)
                try FileManager.default.moveItem(atPath: tempPath, toPath: finalPath)
            }
            return fileName
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw error
        }
    }

    private static func resolveFaceThumbnailMigrationDir(
        _ db: isolated SQLiteDatabase,
        fallbackDir fallback: String?
    ) throws -> String? {
        var customDir = ""
        if let row = try db.queryOne("SELECT value FROM app_settings WHERE key = 'face_thumbnail_dir'") {
            customDir = row.text(at: 0) ?? ""
        }
        let fallbackDir = fallback ?? ""
        let candidates = customDir.isEmpty ? [fallbackDir] : [customDir, fallbackDir]

        for candidate in candidates where !candidate.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: candidate, withIntermediateDirectories: true)
                guard FileManager.default.isWritableFile(atPath: candidate) else {
                    throw StoreMigrationError.message("directory is not writable")
                }
                if !customDir.isEmpty && candidate != customDir {
                    GatherLogger.log(
                        "Face thumbnail directory is not writable; falling back to \(candidate)",
                        level: .warn
                    )
                    try db.run("""
                        INSERT INTO app_settings (key, value)
                        VALUES ('face_thumbnail_dir', ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """, [.text(candidate)])
                }
                return candidate
            } catch {
                GatherLogger.log("Face thumbnail directory is unavailable: \(candidate)", level: .warn)
            }
        }
        return nil
    }

    private static func migratePendingFaceThumbnails(
        _ db: isolated SQLiteDatabase,
        fallbackDir: String?
    ) throws {
        // 旧构建在丢弃源数据后写入该标记；它不是合法路径，保留待重新生成。
        try db.run("""
            UPDATE face_clusters
            SET thumbnail_path = ''
            WHERE thumbnail_path = '__migration_failed__'
              AND thumbnail_base64 = ''
            """)

        let rows = try db.query("""
            SELECT id, thumbnail_base64
            FROM face_clusters
            WHERE thumbnail_base64 != ''
              AND (thumbnail_path = '' OR thumbnail_path = '__migration_failed__')
            """)
        if rows.isEmpty { return }

        guard let thumbnailDir = try resolveFaceThumbnailMigrationDir(db, fallbackDir: fallbackDir) else {
            GatherLogger.log(
                "Deferred migration of \(rows.count) face thumbnails because no writable directory is available",
                level: .warn
            )
            return
        }

        for row in rows {
            let clusterId = Int(row.int(at: 0) ?? 0)
            let thumbnailBase64 = row.text(at: 1) ?? ""
            do {
                let fileName = try writeMigratedFaceThumbnail(
                    thumbnailDir: thumbnailDir,
                    clusterId: clusterId,
                    thumbnailBase64: thumbnailBase64
                )
                try db.run("""
                    UPDATE face_clusters
                    SET thumbnail_path = ?, thumbnail_base64 = ''
                    WHERE id = ?
                    """, [.text(fileName), .int(Int64(clusterId))])
            } catch {
                GatherLogger.log(
                    "Deferred migration of face thumbnail for cluster \(clusterId): \(error)",
                    level: .warn
                )
            }
        }
    }

    // MARK: - 备份/回滚（ADR-005）

    private static func createMigrationBackup(
        _ database: SQLiteDatabase,
        currentVersion: Int,
        databaseFilePath: String?
    ) async throws -> String? {
        guard currentVersion < currentSchemaVersion,
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
            throw StoreMigrationError.message("无法读取磁盘空间信息用于迁移备份")
        }
        let requiredBytes: Int64 = max(64 * 1024 * 1024, sourceSize * 2)
        if fileSystem.freeBytes < requiredBytes {
            throw StoreMigrationError.message(
                "Insufficient disk space for database migration backup: need \(requiredBytes) bytes, have \(fileSystem.freeBytes)"
            )
        }

        try await database.checkpointTruncate()
        let backupPath = "\(dbPath).pre-v\(currentSchemaVersion)-\(Int(Date().timeIntervalSince1970 * 1000)).bak"
        try await database.backup(to: backupPath)
        // 部分 SQLite 组合下备份可能延迟落地；WAL 已 checkpoint，保留文件级兜底。
        if !FileManager.default.fileExists(atPath: backupPath) {
            try FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)
        }

        guard try backupIntegrityCheckOK(backupPath) else {
            throw StoreMigrationError.message("Pre-migration database backup failed integrity_check")
        }
        return backupPath
    }

    /// 只读打开备份文件，PRAGMA integrity_check 必须恰好返回一行 "ok"。
    /// 注（2026-08-10 macOS 26 实测）：SQLite 3.51 对 header 标记 WAL 的库，
    /// 只读打开要求同名 -shm 文件存在；备份由 backup API 生成、不带伴随文件，
    /// 故先创建空伴随文件，检查后清理。
    private static func backupIntegrityCheckOK(_ path: String) throws -> Bool {
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
            throw StoreMigrationError.message("无法打开迁移备份 \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
        defer { sqlite3_close_v2(backup) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(backup, "PRAGMA integrity_check", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreMigrationError.message("无法编译备份完整性检查: \(String(cString: sqlite3_errmsg(backup)))")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        guard let text = sqlite3_column_text(stmt, 0) else { return false }
        let value = String(cString: text)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        return value == "ok"
    }

    private static func restoreBackup(
        _ database: SQLiteDatabase,
        dbPath: String,
        backupPath: String
    ) async throws {
        // 先复制到临时文件再原子 rename：copyItem 失败（磁盘满等）时活动库仍完好。
        await database.close()
        let tmpPath = dbPath + ".restore-tmp"
        _ = try? FileManager.default.removeItem(atPath: tmpPath)
        try FileManager.default.copyItem(atPath: backupPath, toPath: tmpPath)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        _ = try? FileManager.default.removeItem(atPath: dbPath)
        try FileManager.default.moveItem(atPath: tmpPath, toPath: dbPath)
        try await database.reopen()
    }

    /// 备份淘汰（TS pruneMigrationBackups，keep=3）：按 mtime 保留最新 keep 个。
    internal static func pruneMigrationBackups(databaseFilePath: String, keep: Int = 3) throws {
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

    // MARK: - 迁移后不变量

    private static func assertMigrationInvariants(_ database: SQLiteDatabase) async throws {
        try await database.transaction { db in
            let version = try schemaVersion(db)
            if version != currentSchemaVersion {
                throw StoreMigrationError.message("Migration ended at an unexpected schema version: \(version)")
            }
            let foreignKeyErrors = try db.query("PRAGMA foreign_key_check")
            if !foreignKeyErrors.isEmpty {
                throw StoreMigrationError.message("Migration created \(foreignKeyErrors.count) foreign key violations")
            }
            let invariants: [(String, [String])] = [
                ("metadata_outbox", ["xmp_path", "created_by_session_id", "status", "source_module"]),
                ("metadata_outbox_sessions", ["xmp_path", "session_id", "confirmed_at"]),
                ("analysis_jobs", ["id", "status", "dedupe_key"]),
                ("culling_decisions", ["session_id", "revision", "decision_source"]),
                ("culling_history", ["session_id", "operation_json"]),
                ("asset_backfill_state", ["session_id", "last_photo_rowid", "status"]),
                ("analysis_runs", ["session_id", "kind", "index_seq", "status"]),
                ("similarity_cluster_state", ["session_id", "photo_id", "component_index", "group_seed"]),
                ("similarity_cluster_meta", ["session_id", "version", "incremental_updates"]),
            ]
            for (table, columns) in invariants {
                try assertColumns(db, table, columns)
            }
        }
    }
}

// MARK: - statvfs（磁盘空间检查）

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
