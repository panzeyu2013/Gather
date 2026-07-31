import { Database } from './database'
import * as path from 'path'
import * as fs from 'fs'
import { app } from 'electron'
import { FACE_THUMB_DIR } from '@gather/shared'
import { SCHEMA_SQL, INDEX_SQL, UNIQUE_PHOTO_PATH_INDEX_SQL } from './schema'
import BetterSqlite3 from 'better-sqlite3'

const CURRENT_SCHEMA_VERSION = 26

const CREATE_FACE_CLUSTER_MEMBERS_SQL = `
  CREATE TABLE face_cluster_members (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
    session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    photo_id TEXT NOT NULL REFERENCES photos(id),
    bbox TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 0.0,
    observation_id INTEGER REFERENCES face_observations(id)
  )
`

function getSchemaVersion(db: BetterSqlite3.Database): number {
  try {
    const row = db.prepare('SELECT MAX(version) as version FROM schema_version').get() as { version: number | null }
    return row?.version ?? 0
  } catch {
    return 0
  }
}

function setSchemaVersion(db: BetterSqlite3.Database, version: number): void {
  db.prepare('INSERT OR REPLACE INTO schema_version (version, applied_at) VALUES (?, ?)').run(version, new Date().toISOString())
}

function columnExists(db: BetterSqlite3.Database, table: string, column: string): boolean {
  const cols = db.pragma(`table_info(${table})`)
  return (cols as Array<{ name: string }>).some(c => c.name === column)
}

function addColumn(db: BetterSqlite3.Database, table: string, column: string, type: string): boolean {
  if (columnExists(db, table, column)) return false
  db.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${type}`)
  return true
}

function fillTimestamp(db: BetterSqlite3.Database, table: string, column: string): void {
  const now = new Date().toISOString()
  db.prepare(`UPDATE ${table} SET ${column} = ? WHERE ${column} = '' OR ${column} IS NULL`).run(now)
}

function tableExists(db: BetterSqlite3.Database, table: string): boolean {
  return Boolean(
    db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table),
  )
}

function restoreFaceClusterMembers(
  db: BetterSqlite3.Database,
  oldTable: string,
): void {
  const oldColumns = db.pragma(`table_info(${oldTable})`) as Array<{ name: string }>
  const hasObservationId = oldColumns.some((column) => column.name === 'observation_id')
  const observationExpr = hasObservationId
    ? 'CASE WHEN o.observation_id IN (SELECT id FROM face_observations) THEN o.observation_id ELSE NULL END'
    : 'NULL'

  db.exec(`
    INSERT OR IGNORE INTO face_cluster_members
      (id, cluster_id, session_id, photo_id, bbox, confidence, observation_id)
    SELECT
      o.id,
      o.cluster_id,
      o.session_id,
      o.photo_id,
      o.bbox,
      o.confidence,
      ${observationExpr}
    FROM ${oldTable} o
    JOIN face_clusters c ON c.id = o.cluster_id
    JOIN sessions s ON s.id = o.session_id
    JOIN photos p ON p.id = o.photo_id
  `)
  db.exec(`DROP TABLE ${oldTable}`)
}

function migrateFaceClusterMembers(db: BetterSqlite3.Database): void {
  const oldTable = '__face_cluster_members_old'

  if (tableExists(db, oldTable)) {
    if (!tableExists(db, 'face_cluster_members')) {
      db.exec(CREATE_FACE_CLUSTER_MEMBERS_SQL)
    }
    restoreFaceClusterMembers(db, oldTable)
  }

  if (!tableExists(db, 'face_cluster_members')) {
    db.exec(CREATE_FACE_CLUSTER_MEMBERS_SQL)
    return
  }

  const foreignKeys = db.pragma('foreign_key_list(face_cluster_members)') as Array<{
    table: string
    from: string
  }>
  const hasObservationFk = foreignKeys.some(
    (foreignKey) =>
      foreignKey.table === 'face_observations' &&
      foreignKey.from === 'observation_id',
  )
  if (hasObservationFk) return

  db.exec(`ALTER TABLE face_cluster_members RENAME TO ${oldTable}`)
  db.exec(CREATE_FACE_CLUSTER_MEMBERS_SQL)
  restoreFaceClusterMembers(db, oldTable)
}

function assertColumns(
  db: BetterSqlite3.Database,
  table: string,
  columns: string[],
): void {
  for (const column of columns) {
    if (!columnExists(db, table, column)) {
      throw new Error(`Migration invariant failed: ${table}.${column} is missing`)
    }
  }
}

function ensurePhotoPathUniqueness(db: BetterSqlite3.Database): void {
  const duplicate = db.prepare(`
    SELECT session_id, filepath, COUNT(*) AS count
    FROM photos
    GROUP BY session_id, filepath
    HAVING COUNT(*) > 1
    LIMIT 1
  `).get() as { session_id: string; filepath: string; count: number } | undefined

  if (duplicate) {
    console.warn(
      `Skipping unique photo-path index: session ${duplicate.session_id} contains ${duplicate.count} rows for ${duplicate.filepath}`,
    )
    return
  }
  db.exec(UNIQUE_PHOTO_PATH_INDEX_SQL)
}

function resolveFaceThumbnailMigrationDir(
  db: BetterSqlite3.Database,
): string | null {
  const customDirRow = db
    .prepare("SELECT value FROM app_settings WHERE key = 'face_thumbnail_dir'")
    .get() as { value: string } | undefined
  const customDir = customDirRow?.value || ''
  const fallbackDir = path.join(app.getPath('userData'), FACE_THUMB_DIR)
  const candidates = customDir
    ? [customDir, fallbackDir]
    : [fallbackDir]

  for (const candidate of candidates) {
    try {
      fs.mkdirSync(candidate, { recursive: true })
      fs.accessSync(candidate, fs.constants.W_OK)
      if (customDir && candidate !== customDir) {
        console.warn(
          `Face thumbnail directory is not writable; falling back to ${candidate}`,
        )
        db.prepare(`
          INSERT INTO app_settings (key, value)
          VALUES ('face_thumbnail_dir', ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
        `).run(candidate)
      }
      return candidate
    } catch (error) {
      console.warn(
        `Face thumbnail directory is unavailable: ${candidate}`,
        error,
      )
    }
  }
  return null
}

export function writeMigratedFaceThumbnail(
  thumbnailDir: string,
  clusterId: number,
  thumbnailBase64: string,
): string {
  const buffer = Buffer.from(thumbnailBase64, 'base64')
  if (buffer.length === 0) {
    throw new Error(`Face thumbnail ${clusterId} is empty`)
  }

  const fileName = `${clusterId}.jpg`
  const finalPath = path.join(thumbnailDir, fileName)
  const tempPath = path.join(
    thumbnailDir,
    `.${fileName}.${process.pid}.${Date.now()}.tmp`,
  )
  try {
    fs.writeFileSync(tempPath, buffer, { flag: 'wx' })
    try {
      fs.renameSync(tempPath, finalPath)
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'EEXIST' && code !== 'EPERM') throw error

      // Windows cannot atomically replace an existing destination. The
      // thumbnail is derived data and the database still retains the Base64
      // source until this function succeeds, so a remove-and-retry is safe.
      fs.unlinkSync(finalPath)
      fs.renameSync(tempPath, finalPath)
    }
    return fileName
  } catch (error) {
    try {
      fs.unlinkSync(tempPath)
    } catch {
      // The temporary file may not have been created.
    }
    throw error
  }
}

function migratePendingFaceThumbnails(db: BetterSqlite3.Database): void {
  // Older builds used this marker after discarding the source data. It is not
  // a valid file path, so leave those rows ready for thumbnail regeneration.
  db.prepare(`
    UPDATE face_clusters
    SET thumbnail_path = ''
    WHERE thumbnail_path = '__migration_failed__'
      AND thumbnail_base64 = ''
  `).run()

  const rows = db.prepare(`
    SELECT id, thumbnail_base64
    FROM face_clusters
    WHERE thumbnail_base64 != ''
      AND (thumbnail_path = '' OR thumbnail_path = '__migration_failed__')
  `).all() as { id: number; thumbnail_base64: string }[]
  if (rows.length === 0) return

  const thumbnailDir = resolveFaceThumbnailMigrationDir(db)
  if (!thumbnailDir) {
    console.warn(
      `Deferred migration of ${rows.length} face thumbnails because no writable directory is available`,
    )
    return
  }

  for (const row of rows) {
    try {
      const fileName = writeMigratedFaceThumbnail(
        thumbnailDir,
        row.id,
        row.thumbnail_base64,
      )
      db.prepare(`
        UPDATE face_clusters
        SET thumbnail_path = ?, thumbnail_base64 = ''
        WHERE id = ?
      `).run(fileName, row.id)
    } catch (error) {
      console.warn(
        `Deferred migration of face thumbnail for cluster ${row.id}`,
        error,
      )
    }
  }
}

async function createMigrationBackup(database: Database, currentVersion: number): Promise<string | null> {
  const dbPath = path.join(app.getPath('userData'), 'gather.db')
  if (currentVersion >= CURRENT_SCHEMA_VERSION || !fs.existsSync(dbPath)) return null
  const walPath = `${dbPath}-wal`
  const shmPath = `${dbPath}-shm`
  const sourceSize = [dbPath, walPath, shmPath]
    .filter(filePath => fs.existsSync(filePath))
    .reduce((total, filePath) => total + fs.statSync(filePath).size, 0)
  const fileSystem = fs.statfsSync(app.getPath('userData'))
  const freeBytes = Number(fileSystem.bavail) * Number(fileSystem.bsize)
  const requiredBytes = Math.max(64 * 1024 * 1024, sourceSize * 2)
  if (freeBytes < requiredBytes) {
    throw new Error(`Insufficient disk space for database migration backup: need ${requiredBytes} bytes, have ${freeBytes}`)
  }
  dbCheckpoint(database)
  const backupPath = `${dbPath}.pre-v${CURRENT_SCHEMA_VERSION}-${Date.now()}.bak`
  await database.rawDb.backup(backupPath)
  // better-sqlite3 may materialize the backup lazily on some Electron/SQLite
  // combinations. The WAL has already been checkpointed, so keep a durable
  // file-level fallback before allowing migrations to mutate the database.
  if (!fs.existsSync(backupPath)) fs.copyFileSync(dbPath, backupPath)
  const backup = new BetterSqlite3(backupPath, { readonly: true })
  try {
    const integrity = backup.pragma('integrity_check') as Array<{ integrity_check: string }>
    if (integrity.length !== 1 || integrity[0]?.integrity_check !== 'ok') {
      throw new Error('Pre-migration database backup failed integrity_check')
    }
  } finally {
    backup.close()
  }
  return backupPath
}

function dbCheckpoint(database: Database): void {
  database.pragma('wal_checkpoint(TRUNCATE)')
}

export async function runMigrations(database: Database): Promise<void> {
  const previousVersion = getSchemaVersion(database.rawDb)
  const backupPath = await createMigrationBackup(database, previousVersion)
  try {
    runMigrationsUnsafe(database)
    if (
      process.env.NODE_ENV === 'test' &&
      process.env.GATHER_TEST_FAIL_MIGRATION === 'after-migrate'
    ) {
      throw new Error('Injected migration failure')
    }
    assertMigrationInvariants(database.rawDb)
    try {
      pruneMigrationBackups()
    } catch (error) {
      console.warn('Unable to prune old migration backups', error)
    }
  } catch (error) {
    if (backupPath) {
      const dbPath = path.join(app.getPath('userData'), 'gather.db')
      database.close()
      fs.copyFileSync(backupPath, dbPath)
      for (const suffix of ['-wal', '-shm']) {
        try { fs.rmSync(`${dbPath}${suffix}`, { force: true }) } catch { /* best effort */ }
      }
    }
    throw error
  }
}

function pruneMigrationBackups(keep = 3): void {
  const directory = app.getPath('userData')
  const backups = fs.readdirSync(directory)
    .filter(name => /^gather\.db\.pre-v\d+-\d+\.bak$/.test(name))
    .map(name => ({
      path: path.join(directory, name),
      mtimeMs: fs.statSync(path.join(directory, name)).mtimeMs,
    }))
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
  for (const backup of backups.slice(keep)) {
    fs.rmSync(backup.path, { force: true })
  }
}

function assertMigrationInvariants(db: BetterSqlite3.Database): void {
  if (getSchemaVersion(db) !== CURRENT_SCHEMA_VERSION) {
    throw new Error(`Migration ended at an unexpected schema version: ${getSchemaVersion(db)}`)
  }
  const foreignKeyErrors = db.pragma('foreign_key_check') as unknown[]
  if (foreignKeyErrors.length > 0) throw new Error(`Migration created ${foreignKeyErrors.length} foreign key violations`)
  for (const [table, columns] of [
    ['metadata_outbox', ['xmp_path', 'created_by_session_id', 'status']],
    ['metadata_outbox_sessions', ['xmp_path', 'session_id', 'confirmed_at']],
    ['analysis_jobs', ['id', 'status', 'dedupe_key']],
    ['culling_decisions', ['session_id', 'revision', 'decision_source']],
    ['culling_history', ['session_id', 'operation_json']],
    ['asset_backfill_state', ['session_id', 'last_photo_rowid', 'status']],
  ] as Array<[string, string[]]>) {
    assertColumns(db, table, columns)
  }
}

function runMigrationsUnsafe(database: Database): void {
  const db: BetterSqlite3.Database = database.rawDb
  db.exec(SCHEMA_SQL)

  let currentVersion = getSchemaVersion(db)

  // ── Version 1: initial migrations ──
  if (currentVersion < 1) {
    db.transaction(() => {
      addColumn(db, 'photos', 'width', 'INTEGER NOT NULL DEFAULT 0')
      addColumn(db, 'photos', 'height', 'INTEGER NOT NULL DEFAULT 0')
      migrateFaceClusterMembers(db)

      const timestampColumns: Array<[string, string]> = [
        ['face_observations', 'created_at'],
        ['face_clusters', 'created_at'],
        ['face_clusters', 'updated_at'],
        ['role_bindings', 'created_at'],
        ['role_bindings', 'updated_at'],
        ['culling_decisions', 'created_at'],
        ['writeback_items', 'created_at'],
        ['photo_metadata_cache', 'updated_at'],
      ]
      for (const [table, column] of timestampColumns) {
        if (addColumn(db, table, column, "TEXT NOT NULL DEFAULT ''")) {
          fillTimestamp(db, table, column)
        }
      }

      addColumn(db, 'face_clusters', 'thumbnail_path', "TEXT NOT NULL DEFAULT ''")
      addColumn(db, 'face_clusters', 'thumbnail_base64', "TEXT NOT NULL DEFAULT ''")
      addColumn(db, 'face_clusters', 'synced_to_library', 'INTEGER NOT NULL DEFAULT 0')
      addColumn(db, 'face_clusters', 'matched_person_id', 'TEXT')
      addColumn(db, 'face_clusters', 'match_confidence', 'REAL')
      addColumn(db, 'photo_metadata_cache', 'keywords', "TEXT NOT NULL DEFAULT '[]'")
      addColumn(db, 'writeback_items', 'photo_path', "TEXT NOT NULL DEFAULT ''")
      addColumn(db, 'writeback_items', 'attributes_json', "TEXT NOT NULL DEFAULT '{}'")

      assertColumns(db, 'photos', ['width', 'height'])
      assertColumns(db, 'face_clusters', [
        'thumbnail_path',
        'matched_person_id',
        'match_confidence',
      ])
      assertColumns(db, 'writeback_items', ['photo_path', 'attributes_json'])
      setSchemaVersion(db, 1)
    })()
    currentVersion = 1
  }

  // ── Version 2: enable file-backed face thumbnails ──
  if (currentVersion < 2) {
    setSchemaVersion(db, 2)
    currentVersion = 2
  }

  // ── Version 3: persist color labels in the metadata cache ──
  if (currentVersion < 3) {
    db.transaction(() => {
      addColumn(db, 'photo_metadata_cache', 'label', 'TEXT')
      assertColumns(db, 'photo_metadata_cache', ['label'])
      setSchemaVersion(db, 3)
    })()
    currentVersion = 3
  }

  // ── Version 4: remember the source folder used to create a session ──
  if (currentVersion < 4) {
    db.transaction(() => {
      addColumn(db, 'sessions', 'source_path', "TEXT NOT NULL DEFAULT ''")
      assertColumns(db, 'sessions', ['source_path'])
      setSchemaVersion(db, 4)
    })()
    currentVersion = 4
  }

  // ── Version 5: invalidate perceptual hashes when source files change ──
  if (currentVersion < 5) {
    db.transaction(() => {
      addColumn(db, 'similarity_hashes', 'file_size', 'INTEGER NOT NULL DEFAULT 0')
      addColumn(db, 'similarity_hashes', 'file_mtime_ms', 'REAL NOT NULL DEFAULT 0')
      db.exec(`
        DELETE FROM similarity_hashes
        WHERE id NOT IN (
          SELECT MAX(id)
          FROM similarity_hashes
          GROUP BY session_id, photo_id
        )
      `)
      assertColumns(db, 'similarity_hashes', ['file_size', 'file_mtime_ms'])
      setSchemaVersion(db, 5)
    })()
    currentVersion = 5
  }

  // ── Version 6: reuse exact checksums while source files are unchanged ──
  if (currentVersion < 6) {
    db.transaction(() => {
      addColumn(db, 'photos', 'checksum_file_size', 'INTEGER NOT NULL DEFAULT 0')
      addColumn(db, 'photos', 'checksum_file_mtime_ms', 'REAL NOT NULL DEFAULT 0')
      assertColumns(db, 'photos', ['checksum_file_size', 'checksum_file_mtime_ms'])
      setSchemaVersion(db, 6)
    })()
    currentVersion = 6
  }

  // ── Version 7: reuse face observations while photo/model settings are unchanged ──
  if (currentVersion < 7) {
    db.transaction(() => {
      addColumn(db, 'face_observations', 'source_file_size', 'INTEGER NOT NULL DEFAULT 0')
      addColumn(db, 'face_observations', 'source_file_mtime_ms', 'REAL NOT NULL DEFAULT 0')
      addColumn(db, 'face_observations', 'analysis_signature', "TEXT NOT NULL DEFAULT ''")
      assertColumns(db, 'face_observations', [
        'source_file_size',
        'source_file_mtime_ms',
        'analysis_signature',
      ])
      setSchemaVersion(db, 7)
    })()
    currentVersion = 7
  }

  // ── Version 8: cache successful zero-face analyses as well as observations ──
  if (currentVersion < 8) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS face_analysis_state (
          photo_id TEXT PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          source_file_size INTEGER NOT NULL,
          source_file_mtime_ms REAL NOT NULL,
          analysis_signature TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      `)
      setSchemaVersion(db, 8)
    })()
    currentVersion = 8
  }

  // ── Version 9: make culling upserts atomic and deterministic ──
  if (currentVersion < 9) {
    db.transaction(() => {
      db.exec(`
        DELETE FROM culling_decisions
        WHERE id NOT IN (
          SELECT MAX(id)
          FROM culling_decisions
          GROUP BY session_id, photo_id
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_culling_session_photo_unique
          ON culling_decisions(session_id, photo_id);
      `)
      setSchemaVersion(db, 9)
    })()
    currentVersion = 9
  }

  // ── Version 10: materialize similarity membership for operational queries ──
  if (currentVersion < 10) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS similarity_result_members (
          result_id INTEGER NOT NULL REFERENCES similarity_results(id) ON DELETE CASCADE,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          group_index INTEGER NOT NULL,
          photo_id TEXT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
          PRIMARY KEY (result_id, photo_id)
        );
        CREATE INDEX IF NOT EXISTS idx_similarity_members_session_photo
          ON similarity_result_members(session_id, photo_id);
        CREATE INDEX IF NOT EXISTS idx_similarity_members_result_group
          ON similarity_result_members(result_id, group_index);
      `)
      setSchemaVersion(db, 10)
    })()
    currentVersion = 10
  }

  // ── Version 11: persist face-clustering reuse state across restarts ──
  if (currentVersion < 11) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS face_cluster_state (
          session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
          cluster_signature TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      `)
      setSchemaVersion(db, 11)
    })()
    currentVersion = 11
  }

  // ── Version 12: remove the disabled history subsystem and inert settings ──
  if (currentVersion < 12) {
    db.transaction(() => {
      db.exec(`
        DROP TABLE IF EXISTS operation_log;
        DELETE FROM app_settings
        WHERE key IN (
          'hash_chunk_size',
          'poll_max_retries_sim',
          'poll_max_retries_fkw',
          'poll_interval_sim_ms',
          'poll_interval_fkw_ms'
        );
      `)
      setSchemaVersion(db, 12)
    })()
    currentVersion = 12
  }

  // ── Version 13: durable culling state and sidecar metadata outbox ──
  if (currentVersion < 13) {
    db.transaction(() => {
      addColumn(
        db,
        'culling_decisions',
        'rating',
        'INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5)',
      )
      addColumn(
        db,
        'culling_decisions',
        'color_label',
        "TEXT NOT NULL DEFAULT 'None' CHECK (color_label IN ('None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple'))",
      )
      addColumn(db, 'culling_decisions', 'revision', 'INTEGER NOT NULL DEFAULT 0')
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_metadata_outbox_session_status
          ON metadata_outbox(owner_session_id, status);
      `)
      assertColumns(db, 'culling_decisions', ['rating', 'color_label', 'revision'])
      assertColumns(db, 'metadata_outbox', [
        'xmp_path',
        'owner_session_id',
        'patch_json',
        'revision',
        'persisted_revision',
        'status',
      ])
      setSchemaVersion(db, 13)
    })()
    currentVersion = 13
  }

  // ── Version 14: preserve imported rating/label for legacy pick decisions ──
  if (currentVersion < 14) {
    db.transaction(() => {
      db.exec(`
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
      `)
      setSchemaVersion(db, 14)
    })()
    currentVersion = 14
  }

  // ── Version 15: expand the database for global Assets without switching reads ──
  if (currentVersion < 15) {
    db.transaction(() => {
      addColumn(db, 'photos', 'asset_id', 'TEXT REFERENCES assets(id)')
      addColumn(db, 'photos', 'asset_file_id', 'TEXT REFERENCES asset_files(id)')
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_photos_asset ON photos(asset_id);
        CREATE INDEX IF NOT EXISTS idx_photos_asset_file ON photos(asset_file_id);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_asset_files_volume_path ON asset_files(volume_id, normalized_path);
        CREATE INDEX IF NOT EXISTS idx_asset_files_checksum ON asset_files(checksum);
        CREATE INDEX IF NOT EXISTS idx_asset_members_asset ON asset_members(asset_id);
        CREATE INDEX IF NOT EXISTS idx_asset_candidates_status ON asset_link_candidates(status);
        CREATE INDEX IF NOT EXISTS idx_session_assets_asset ON session_assets(asset_id);
        CREATE INDEX IF NOT EXISTS idx_sidecar_binding_files_file ON sidecar_binding_files(file_id);
      `)
      assertColumns(db, 'photos', ['asset_id', 'asset_file_id'])
      setSchemaVersion(db, 15)
    })()
    currentVersion = 15
  }

  // ── Version 16: persist long-running analysis jobs ──
  if (currentVersion < 16) {
    db.transaction(() => {
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_analysis_jobs_status_priority
          ON analysis_jobs(status, priority, updated_at);
        CREATE INDEX IF NOT EXISTS idx_analysis_jobs_scope
          ON analysis_jobs(scope_type, scope_id);
        CREATE UNIQUE INDEX IF NOT EXISTS idx_analysis_jobs_active_dedupe
          ON analysis_jobs(dedupe_key)
          WHERE status IN ('queued', 'running', 'cancelling');
      `)
      setSchemaVersion(db, 16)
    })()
    currentVersion = 16
  }

  // ── Version 17: versioned explainable technical quality results ──
  if (currentVersion < 17) {
    db.transaction(() => {
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_asset_analysis_photo_type
          ON asset_analysis(photo_id, analysis_type);
      `)
      setSchemaVersion(db, 17)
    })()
    currentVersion = 17
  }

  // ── Version 18: metadata outbox survives session deletion ──
  if (currentVersion < 18) {
    db.transaction(() => {
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_metadata_outbox_session_status ON metadata_outbox(owner_session_id, status);
      `)
      setSchemaVersion(db, 18)
    })()
    currentVersion = 18
  }

  // ── Version 19: persistent culling operation history ──
  if (currentVersion < 19) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS culling_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
          operation_json TEXT NOT NULL DEFAULT '[]',
          created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_culling_history_session ON culling_history(session_id, id);
      `)
      setSchemaVersion(db, 19)
    })()
    currentVersion = 19
  }

  // ── Version 20: version smart album filter definitions ──
  if (currentVersion < 20) {
    db.transaction(() => {
      addColumn(db, 'smart_albums', 'schema_version', 'INTEGER NOT NULL DEFAULT 1')
      setSchemaVersion(db, 20)
    })()
    currentVersion = 20
  }

  // ── Version 21: one global XMP queue can be observed by multiple sessions ──
  if (currentVersion < 21) {
    db.transaction(() => {
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_metadata_outbox_sessions_session
          ON metadata_outbox_sessions(session_id, xmp_path);
      `)
      setSchemaVersion(db, 21)
    })()
    currentVersion = 21
  }

  // ── Version 22: reusable analysis belongs to the physical asset file ──
  if (currentVersion < 22) {
    db.transaction(() => {
      db.exec(`
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
          AND asset_file_id IN (SELECT id FROM asset_files);
        DROP TABLE asset_analysis_v21;
        CREATE INDEX idx_asset_analysis_photo_type
          ON asset_analysis(photo_id, analysis_type);
        CREATE INDEX idx_asset_analysis_file_type
          ON asset_analysis(asset_file_id, analysis_type);
      `)
      setSchemaVersion(db, 22)
    })()
    currentVersion = 22
  }

  // ── Version 23: persistent Burst/Scene navigation groups ──
  if (currentVersion < 23) {
    db.transaction(() => {
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_navigation_groups_session_type
          ON navigation_groups(session_id, group_type, updated_at);
      `)
      setSchemaVersion(db, 23)
    })()
    currentVersion = 23
  }

  // ── Version 24: resumable Asset backfill cursor and diagnostics ──
  if (currentVersion < 24) {
    db.transaction(() => {
      addColumn(db, 'asset_files', 'file_identity', "TEXT NOT NULL DEFAULT ''")
      addColumn(db, 'culling_decisions', 'decision_source', "TEXT NOT NULL DEFAULT 'manual'")
      addColumn(db, 'culling_history', 'undone', 'INTEGER NOT NULL DEFAULT 0')
      db.exec(`
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
        CREATE INDEX IF NOT EXISTS idx_asset_backfill_status
          ON asset_backfill_state(status, updated_at);
      `)
      setSchemaVersion(db, 24)
    })()
    currentVersion = 24
  }

  // ── Version 25: source ownership for safely reversible keyword writes ──
  if (currentVersion < 25) {
    db.transaction(() => {
      db.exec(`
        CREATE TABLE IF NOT EXISTS metadata_keyword_origins (
          xmp_path TEXT NOT NULL,
          source TEXT NOT NULL,
          keyword TEXT NOT NULL,
          active INTEGER NOT NULL DEFAULT 1,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          PRIMARY KEY (xmp_path, source, keyword)
        );
        CREATE INDEX IF NOT EXISTS idx_metadata_keyword_origins_source_active
          ON metadata_keyword_origins(source, active, updated_at);
      `)
      setSchemaVersion(db, 25)
    })()
    currentVersion = 25
  }

  // ── Version 26: drop the redundant culling index covered by the unique one ──
  if (currentVersion < 26) {
    db.transaction(() => {
      db.exec(`
        DROP INDEX IF EXISTS idx_culling_photo_session;
      `)
      setSchemaVersion(db, 26)
    })()
    currentVersion = 26
  }

  if (currentVersion !== CURRENT_SCHEMA_VERSION) {
    throw new Error(`Unexpected schema version ${currentVersion}`)
  }

  db.exec(INDEX_SQL)
  ensurePhotoPathUniqueness(db)
  migratePendingFaceThumbnails(db)
}
