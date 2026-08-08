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
import { SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'

let db: Database

function insertLegacySession(id: string): void {
  const now = new Date().toISOString()
  db.rawDb.prepare(`
    INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
    VALUES (?, '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
  `).run(id, now, now)
}

beforeEach(async () => {
  for (const suffix of ['', '-wal', '-shm']) {
    fs.rmSync(path.join(userDataDir, `gather.db${suffix}`), { force: true })
  }
  db = new Database()

  // Build a real v29 database: current schema minus the index_seq column and
  // the analysis_runs table, with schema_version pinned to 29.
  db.rawDb.exec(SCHEMA_SQL)
  db.rawDb.exec('ALTER TABLE sessions DROP COLUMN index_seq')
  db.rawDb.exec('DROP TABLE IF EXISTS analysis_runs')
  db.prepare('INSERT INTO schema_version (version, applied_at) VALUES (?, ?)')
    .run(29, new Date().toISOString())
})

afterEach(() => {
  db.close()
})

describe('migration 30 — analysis run records and index sequence', () => {
  it('upgrades a v29 database in place with a zeroed index_seq and the analysis_runs table', async () => {
    insertLegacySession('legacy')

    await runMigrations(db)

    const sessionColumns = db.rawDb.pragma('table_info(sessions)') as Array<{ name: string }>
    expect(sessionColumns.map(column => column.name)).toContain('index_seq')
    const legacy = db.rawDb.prepare(
      'SELECT index_seq FROM sessions WHERE id = ?',
    ).get('legacy') as { index_seq: number }
    expect(legacy.index_seq).toBe(0)

    const runColumns = db.rawDb.pragma('table_info(analysis_runs)') as Array<{ name: string }>
    expect(runColumns.map(column => column.name).sort()).toEqual([
      'finished_at',
      'id',
      'index_seq',
      'kind',
      'params',
      'photo_count',
      'session_id',
      'started_at',
      'status',
    ])
  })

  it('defaults new sessions to index_seq 0 and bumps it atomically', async () => {
    await runMigrations(db)
    const repo = new SessionRepository(db)

    const session = repo.create('Run', 'folder', '/photos')
    expect(session.index_seq).toBe(0)
    expect(repo.getIndexSeq(session.id)).toBe(0)

    expect(repo.bumpIndexSeq(session.id)).toBe(1)
    expect(repo.getIndexSeq(session.id)).toBe(1)
    expect(repo.bumpIndexSeq(session.id)).toBe(2)
  })

  it('cascades analysis run rows when the session is deleted', async () => {
    await runMigrations(db)
    const repo = new SessionRepository(db)
    const session = repo.create('Run', 'folder', '/photos')
    const now = new Date().toISOString()
    db.rawDb.prepare(`
      INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
      VALUES (?, 'similarity', 3, 1, ?, ?, '{}', 'ok')
    `).run(session.id, now, now)

    expect(repo.delete(session.id)).toBe(true)
    const rows = db.rawDb.prepare('SELECT COUNT(*) AS count FROM analysis_runs')
      .get() as { count: number }
    expect(rows.count).toBe(0)
  })
})
