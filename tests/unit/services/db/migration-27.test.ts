import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-migration-'))

vi.mock('electron', () => ({
  app: {
    getPath: () => userDataDir,
  },
}))

import { Database } from '../../../../desktop/src/main/db/database'
import { runMigrations } from '../../../../desktop/src/main/db/migrations'
import { INDEX_SQL, SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'

let db: Database

function insertSession(id: string): void {
  const now = new Date().toISOString()
  db.prepare(`
    INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
    VALUES (?, '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
  `).run(id, now, now)
}

function insertLegacyOutboxRow(xmpPath: string, photoPath: string, patchJson: string): void {
  db.prepare(`
    INSERT INTO metadata_outbox (
      xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json,
      dirty_fields, revision, persisted_revision, base_fingerprint,
      base_values_json, backup_path, status, attempt_count, error_message, updated_at
    )
    VALUES (?, ?, ?, ?, ?, '[]', 1, 0, '', '{}', '', 'pending', 0, '', ?)
  `).run(xmpPath, 'legacy-session', 'legacy-session', photoPath, patchJson, new Date().toISOString())
}

beforeEach(async () => {
  for (const suffix of ['', '-wal', '-shm']) {
    fs.rmSync(path.join(userDataDir, `gather.db${suffix}`), { force: true })
  }
  db = new Database()

  // Build a real v26 database: current schema minus the module provenance
  // column and its index, with schema_version pinned to 26.
  db.rawDb.exec(SCHEMA_SQL)
  db.rawDb.exec(INDEX_SQL)
  db.rawDb.exec('DROP INDEX IF EXISTS idx_metadata_outbox_owner_module')
  db.rawDb.exec('ALTER TABLE metadata_outbox DROP COLUMN source_module')
  db.prepare('INSERT INTO schema_version (version, applied_at) VALUES (?, ?)')
    .run(26, new Date().toISOString())
})

afterEach(() => {
  db.close()
})

describe('migration 27 — outbox module provenance', () => {
  it('upgrades a v26 database in place and backfills legacy rows', async () => {
    insertSession('legacy-session')
    // Legacy rows carry the mutation source only inside patch_json.
    insertLegacyOutboxRow('/photos/valid.xmp', '/photos/valid.NEF', JSON.stringify({ source: 'culling' }))
    insertLegacyOutboxRow('/photos/face.xmp', '/photos/face.NEF', JSON.stringify({ source: 'face-keyword' }))
    // Malformed legacy JSON must not abort startup; it falls back to 'manual'.
    insertLegacyOutboxRow('/photos/corrupt.xmp', '/photos/corrupt.NEF', '{not json')
    insertLegacyOutboxRow('/photos/plain.xmp', '/photos/plain.NEF', JSON.stringify({ rating: 4 }))

    await runMigrations(db)

    const columns = db.rawDb.pragma('table_info(metadata_outbox)') as Array<{ name: string }>
    expect(columns.some(column => column.name === 'source_module')).toBe(true)

    const index = db.rawDb.pragma('index_list(metadata_outbox)') as Array<{ name: string }>
    expect(index.some(entry => entry.name === 'idx_metadata_outbox_owner_module')).toBe(true)

    const rows = db.prepare(
      'SELECT xmp_path, source_module FROM metadata_outbox ORDER BY xmp_path',
    ).all() as Array<{ xmp_path: string; source_module: string }>
    expect(rows).toEqual([
      { xmp_path: '/photos/corrupt.xmp', source_module: 'manual' },
      { xmp_path: '/photos/face.xmp', source_module: 'face-keyword' },
      { xmp_path: '/photos/plain.xmp', source_module: 'manual' },
      { xmp_path: '/photos/valid.xmp', source_module: 'culling' },
    ])

    const version = db.prepare('SELECT MAX(version) as version FROM schema_version').get() as { version: number }
    expect(version.version).toBe(28)

    const backups = fs.readdirSync(userDataDir).filter(name => /^gather\.db\.pre-v28-.*\.bak$/.test(name))
    expect(backups.length).toBe(1)
  })

  it('leaves a fresh v27+ database untouched (no column or backfill churn)', async () => {
    db.close()
    for (const suffix of ['', '-wal', '-shm']) {
      fs.rmSync(path.join(userDataDir, `gather.db${suffix}`), { force: true })
    }
    db = new Database()
    await runMigrations(db)

    const columns = db.rawDb.pragma('table_info(metadata_outbox)') as Array<{ name: string }>
    expect(columns.some(column => column.name === 'source_module')).toBe(true)

    const version = db.prepare('SELECT MAX(version) as version FROM schema_version').get() as { version: number }
    expect(version.version).toBe(28)
  })
})
