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

  // Build a real v28 database: current schema minus the truncated-import
  // column, with schema_version pinned to 28.
  db.rawDb.exec(SCHEMA_SQL)
  db.rawDb.exec('ALTER TABLE sessions DROP COLUMN truncated_import')
  db.prepare('INSERT INTO schema_version (version, applied_at) VALUES (?, ?)')
    .run(28, new Date().toISOString())
})

afterEach(() => {
  db.close()
})

describe('migration 29 — truncated import marker', () => {
  it('upgrades a v28 database in place and keeps existing sessions untruncated', async () => {
    insertLegacySession('legacy')

    await runMigrations(db)

    const columns = db.rawDb.pragma('table_info(sessions)') as Array<{ name: string }>
    expect(columns.map(column => column.name)).toContain('truncated_import')
    const row = db.rawDb.prepare(
      'SELECT MAX(version) as version FROM schema_version',
    ).get() as { version: number }
    expect(row.version).toBeGreaterThanOrEqual(30)
    const legacy = db.rawDb.prepare(
      'SELECT truncated_import FROM sessions WHERE id = ?',
    ).get('legacy') as { truncated_import: number }
    expect(legacy.truncated_import).toBe(0)
  })

  it('persists the truncated flag through the session repository', async () => {
    await runMigrations(db)
    const repo = new SessionRepository(db)

    const normal = repo.create('Normal', 'local', '/photos', false)
    const truncated = repo.create('Truncated', 'local', '/huge', true)

    expect(normal.truncated_import).toBe(0)
    expect(truncated.truncated_import).toBe(1)
    expect(repo.get(truncated.id)!.truncated_import).toBe(1)
  })
})
