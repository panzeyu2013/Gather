import type Database from 'better-sqlite3'
import * as path from 'path'
import * as fs from 'fs'
import { app } from 'electron'
import { SCHEMA_SQL, INDEX_SQL } from './schema'

export function runMigrations(db: Database.Database): void {
  db.exec(SCHEMA_SQL)
  db.exec(INDEX_SQL)

  function columnExists(table: string, column: string): boolean {
    const cols = db.pragma(`table_info(${table})`)
    return (cols as Array<{ name: string }>).some(c => c.name === column)
  }

  // Migration: ensure width/height columns exist on photos
  try {
    db.exec(`ALTER TABLE photos ADD COLUMN width INTEGER NOT NULL DEFAULT 0`)
  } catch { /* already exists */ }
  try {
    db.exec(`ALTER TABLE photos ADD COLUMN height INTEGER NOT NULL DEFAULT 0`)
  } catch { /* already exists */ }

  // Migration: add missing FOREIGN KEY on face_cluster_members.photo_id
  try {
    db.exec(`DELETE FROM face_cluster_members WHERE photo_id NOT IN (SELECT id FROM photos)`)
    db.exec(`ALTER TABLE face_cluster_members RENAME TO __face_cluster_members_old`)
    db.exec(`
      CREATE TABLE face_cluster_members (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cluster_id INTEGER NOT NULL REFERENCES face_clusters(id),
        session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
        photo_id TEXT NOT NULL REFERENCES photos(id),
        bbox TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 0.0,
        observation_id INTEGER
      )
    `)
    db.exec(`INSERT INTO face_cluster_members SELECT * FROM __face_cluster_members_old`)
    db.exec(`DROP TABLE __face_cluster_members_old`)
    db.exec(`CREATE INDEX IF NOT EXISTS idx_face_cluster_members_cluster ON face_cluster_members(cluster_id)`)
    db.exec(`CREATE INDEX IF NOT EXISTS idx_face_cluster_members_session ON face_cluster_members(session_id)`)
  } catch {
    // migration already applied — ignore
  }

  if (!columnExists('face_clusters', 'thumbnail_base64')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN thumbnail_base64 TEXT NOT NULL DEFAULT ''`)
  }
  if (!columnExists('face_clusters', 'synced_to_library')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN synced_to_library INTEGER NOT NULL DEFAULT 0`)
  }
  if (!columnExists('face_clusters', 'matched_person_id')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN matched_person_id TEXT`)
  }
  if (!columnExists('face_clusters', 'match_confidence')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN match_confidence REAL`)
  }

  if (!columnExists('face_observations', 'created_at')) {
    db.exec(`ALTER TABLE face_observations ADD COLUMN created_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('face_clusters', 'created_at')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN created_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('face_clusters', 'updated_at')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN updated_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('role_bindings', 'created_at')) {
    db.exec(`ALTER TABLE role_bindings ADD COLUMN created_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('role_bindings', 'updated_at')) {
    db.exec(`ALTER TABLE role_bindings ADD COLUMN updated_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('culling_decisions', 'created_at')) {
    db.exec(`ALTER TABLE culling_decisions ADD COLUMN created_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('writeback_items', 'created_at')) {
    db.exec(`ALTER TABLE writeback_items ADD COLUMN created_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }
  if (!columnExists('photo_metadata_cache', 'updated_at')) {
    db.exec(`ALTER TABLE photo_metadata_cache ADD COLUMN updated_at TEXT NOT NULL DEFAULT (datetime('now'))`)
  }

  // Migration: add thumbnail_path column and migrate base64 data to files
  if (!columnExists('face_clusters', 'thumbnail_path')) {
    db.exec(`ALTER TABLE face_clusters ADD COLUMN thumbnail_path TEXT NOT NULL DEFAULT ''`)
  }

  const pending = db.prepare("SELECT COUNT(*) as cnt FROM face_clusters WHERE thumbnail_base64 != '' AND thumbnail_path = ''").get() as { cnt: number }
  if (pending.cnt > 0) {
    const rows = db.prepare("SELECT id, thumbnail_base64 FROM face_clusters WHERE thumbnail_base64 != '' AND thumbnail_path = ''").all() as { id: number; thumbnail_base64: string }[]
    const thumbDir = path.join(app.getPath('userData'), 'face-thumbnails')
    fs.mkdirSync(thumbDir, { recursive: true })
    for (const row of rows) {
      try {
        const buffer = Buffer.from(row.thumbnail_base64, 'base64')
        const fileName = `${row.id}.jpg`
        fs.writeFileSync(path.join(thumbDir, fileName), buffer)
        db.prepare('UPDATE face_clusters SET thumbnail_path = ?, thumbnail_base64 = ? WHERE id = ?').run(fileName, '', row.id)
      } catch (e) {
        console.warn('Failed to migrate thumbnail for cluster', row.id, e)
      }
    }
  }
}
