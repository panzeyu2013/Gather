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

  // Build a real v29 database: current schema minus the reload-ack column,
  // with schema_version pinned to 29.
  db.rawDb.exec(SCHEMA_SQL)
  db.rawDb.exec('ALTER TABLE sessions DROP COLUMN reload_acked_at')
  db.prepare('INSERT INTO schema_version (version, applied_at) VALUES (?, ?)')
    .run(29, new Date().toISOString())
})

afterEach(() => {
  db.close()
})

describe('migration 31 — Capture One reload acknowledgment', () => {
  it('upgrades a v29 database in place and keeps legacy rows NULL', async () => {
    insertLegacySession('legacy')

    await runMigrations(db)

    const columns = db.rawDb.pragma('table_info(sessions)') as Array<{ name: string }>
    expect(columns.map(column => column.name)).toContain('reload_acked_at')
    const legacy = db.rawDb.prepare(
      'SELECT reload_acked_at FROM sessions WHERE id = ?',
    ).get('legacy') as { reload_acked_at: string | null }
    expect(legacy.reload_acked_at).toBeNull()
  })

  it('a fresh database gets the column and never auto-acks a reload', async () => {
    await runMigrations(db)

    const columns = db.rawDb.pragma('table_info(sessions)') as Array<{ name: string }>
    expect(columns.map(column => column.name)).toContain('reload_acked_at')

    const repo = new SessionRepository(db)
    const session = repo.create('Fresh', 'local', '/photos')
    expect(session.reload_acked_at).toBeNull()
    expect(repo.getReloadAckedAt(session.id)).toBeNull()
  })

  it('setReloadAckedAt persists the timestamp and getReloadAckedAt reads it back', async () => {
    await runMigrations(db)
    const repo = new SessionRepository(db)
    const session = repo.create('Ack', 'local', '/photos')

    expect(repo.setReloadAckedAt(session.id, '2026-08-08T10:00:00.000Z')).toBe(true)
    expect(repo.getReloadAckedAt(session.id)).toBe('2026-08-08T10:00:00.000Z')
    expect(repo.get(session.id)!.reload_acked_at).toBe('2026-08-08T10:00:00.000Z')

    expect(repo.setReloadAckedAt('missing-session', '2026-08-08T10:00:00.000Z')).toBe(false)
    expect(repo.getReloadAckedAt('missing-session')).toBeNull()
  })
})
