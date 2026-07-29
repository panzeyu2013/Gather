import { Database } from './database'
import * as path from 'path'
import * as fs from 'fs'
import { app } from 'electron'
import { FACE_THUMB_DIR } from '@gather/shared'
import { SCHEMA_SQL, INDEX_SQL, UNIQUE_PHOTO_PATH_INDEX_SQL } from './schema'
import type BetterSqlite3 from 'better-sqlite3'

const CURRENT_SCHEMA_VERSION = 12

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

export function runMigrations(database: Database): void {
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

  if (currentVersion !== CURRENT_SCHEMA_VERSION) {
    throw new Error(`Unexpected schema version ${currentVersion}`)
  }

  db.exec(INDEX_SQL)
  ensurePhotoPathUniqueness(db)
  migratePendingFaceThumbnails(db)
}
