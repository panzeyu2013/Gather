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
import { MetadataOutboxRepository } from '../../../../desktop/src/main/db/repositories/metadata-outbox.repo'

let db: Database

function insertSession(id: string): void {
  const now = new Date().toISOString()
  db.prepare(`
    INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
    VALUES (?, '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
  `).run(id, now, now)
}

beforeEach(async () => {
  for (const suffix of ['', '-wal', '-shm']) {
    fs.rmSync(path.join(userDataDir, `gather.db${suffix}`), { force: true })
  }
  db = new Database()
  await runMigrations(db)
})

afterEach(() => {
  db.close()
})

describe('migration 27 — outbox module provenance', () => {
  it('adds source_module and the module-status index', () => {
    const columns = db.rawDb.pragma('table_info(metadata_outbox)') as Array<{ name: string }>
    expect(columns.some(column => column.name === 'source_module')).toBe(true)

    const index = db.rawDb.pragma('index_list(metadata_outbox)') as Array<{ name: string }>
    expect(index.some(entry => entry.name === 'idx_metadata_outbox_owner_module')).toBe(true)
  })

  it('persists the module on mergePatch and gates batch workflows consistently', () => {
    const repo = new MetadataOutboxRepository(db)
    const sessionId = 'session-1'
    insertSession(sessionId)

    // face_kw rows are stored under the mutation-source name 'face-keyword'.
    repo.mergePatch(
      '/photos/A001.xmp',
      sessionId,
      '/photos/A001.NEF',
      { rating: 4, source: 'face-keyword' },
      ['rating'],
    )

    const row = repo.get('/photos/A001.xmp')
    expect(row?.source_module).toBe('face-keyword')
    // Module gating only applies once the batch workflow's work is written/synced.
    repo.markStatus('/photos/A001.xmp', 'written')

    // A same-module re-writeback must NOT be blocked...
    expect(repo.hasActiveOtherModule(sessionId, 'face-keyword')).toBe(false)
    // ...while other batch workflows must be.
    expect(repo.hasActiveOtherModule(sessionId, 'similarity')).toBe(true)
    expect(repo.hasActiveOtherModule(sessionId, 'template')).toBe(true)
  })

  it('does not let interactive culling or manual edits gate a writeback', () => {
    const repo = new MetadataOutboxRepository(db)
    const sessionId = 'session-2'
    insertSession(sessionId)

    repo.mergePatch(
      '/photos/B001.xmp',
      sessionId,
      '/photos/B001.NEF',
      { rating: 4, source: 'culling' },
      ['rating'],
    )
    repo.mergePatch(
      '/photos/B002.xmp',
      sessionId,
      '/photos/B002.NEF',
      { rating: 3 },
      ['rating'],
    )
    repo.markStatus('/photos/B001.xmp', 'written')
    repo.markStatus('/photos/B002.xmp', 'written')

    // Interactive rating sync and manual edits must never block a writeback,
    // and 'manual' legacy backfill rows must not either.
    expect(repo.hasActiveOtherModule(sessionId, 'similarity')).toBe(false)
    expect(repo.hasActiveOtherModule(sessionId, 'face-keyword')).toBe(false)
  })

  it('backfills source_module from legacy patches and tolerates malformed JSON', () => {
    const now = new Date().toISOString()
    insertSession('session-3')
    const insertLegacy = db.prepare(`
      INSERT INTO metadata_outbox (
        xmp_path, owner_session_id, created_by_session_id, photo_path, patch_json,
        dirty_fields, source_module, revision, persisted_revision, base_fingerprint,
        base_values_json, backup_path, status, attempt_count, error_message, updated_at
      )
      VALUES (?, 'session-3', 'session-3', ?, ?, '[]', '', 1, 0, '', '{}', '', 'pending', 0, '', ?)
    `)
    insertLegacy.run('/photos/valid.xmp', '/photos/valid.NEF', JSON.stringify({ source: 'culling' }), now)
    insertLegacy.run('/photos/corrupt.xmp', '/photos/corrupt.NEF', '{not json', now)

    // The same backfill UPDATE migration 27 runs on upgrade.
    db.rawDb.exec(`
      UPDATE metadata_outbox
      SET source_module = CASE
        WHEN json_valid(patch_json)
          AND json_extract(patch_json, '$.source') IN ('face-keyword', 'similarity', 'culling', 'template')
        THEN json_extract(patch_json, '$.source')
        ELSE 'manual'
      END
      WHERE source_module = ''
    `)

    expect(db.prepare('SELECT source_module FROM metadata_outbox WHERE xmp_path = ?')
      .get('/photos/valid.xmp')).toEqual({ source_module: 'culling' })
    // Malformed legacy JSON must not abort startup; it falls back to manual.
    expect(db.prepare('SELECT source_module FROM metadata_outbox WHERE xmp_path = ?')
      .get('/photos/corrupt.xmp')).toEqual({ source_module: 'manual' })
  })
})
