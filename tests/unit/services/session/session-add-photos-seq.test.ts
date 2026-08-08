import BetterSqlite3 from 'better-sqlite3'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SessionService } from '../../../../desktop/src/main/services/session/session.service'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
import { FaceRepository } from '../../../../desktop/src/main/db/repositories/face.repo'
import { SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'

const databases: BetterSqlite3.Database[] = []
const tempDirs: string[] = []

function createDb(): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.pragma('foreign_keys = ON')
  db.exec(SCHEMA_SQL)
  return db
}

function wrap(db: BetterSqlite3.Database): never {
  return {
    prepare: (sql: string) => db.prepare(sql),
    transaction: <T>(operation: () => T) => db.transaction(operation),
  } as never
}

function buildService(db: BetterSqlite3.Database): {
  service: SessionService
  sessionRepo: SessionRepository
} {
  const sessionRepo = new SessionRepository(wrap(db))
  const settings = { getNumber: () => 8 } as never
  const service = new SessionService(
    sessionRepo,
    new PhotoRepository(wrap(db)),
    new FaceRepository(wrap(db), settings),
    settings,
    {
      getDimensions: vi.fn(async () => ({ width: 100, height: 80 })),
    } as never,
    wrap(db),
  )
  return { service, sessionRepo }
}

function addOkAnalysisRun(
  sqlite: BetterSqlite3.Database,
  sessionId: string,
  indexSeq: number,
): void {
  const timestamp = new Date().toISOString()
  sqlite.prepare(`
    INSERT INTO analysis_runs (
      session_id, kind, photo_count, index_seq, started_at, finished_at,
      params, status
    ) VALUES (?, 'similarity', 0, ?, ?, ?, '{}', 'ok')
  `).run(sessionId, indexSeq, timestamp, timestamp)
}

afterEach(() => {
  vi.restoreAllMocks()
  for (const db of databases.splice(0)) db.close()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('SessionService.addPhotos index_seq', () => {
  it('bumps index_seq when photos are added so a previous ok analysis run goes stale', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-session-add-'))
    tempDirs.push(root)
    const photoA = path.join(root, 'a.jpg')
    const photoB = path.join(root, 'b.jpg')
    fs.writeFileSync(photoA, 'a')
    fs.writeFileSync(photoB, 'b')

    const sqlite = createDb()
    const { service, sessionRepo } = buildService(sqlite)
    const session = sessionRepo.create('Add', 'folder', root)
    // A previous analysis run snapshotted the cursor before the addition.
    addOkAnalysisRun(sqlite, session.id, 0)

    const result = await service.addPhotos(session.id, [photoA, photoB], 'manual')

    expect(result.added).toBe(2)
    // 1.4.2: last_ok_run.index_seq (0) < session.index_seq (1) => stale.
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
    const lastOkRun = sqlite.prepare(`
      SELECT index_seq FROM analysis_runs
      WHERE session_id = ? AND status = 'ok' ORDER BY id DESC LIMIT 1
    `).get(session.id) as { index_seq: number }
    expect(lastOkRun.index_seq).toBeLessThan(sessionRepo.getIndexSeq(session.id))
  })

  it('does NOT bump index_seq when no photos were actually added', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-session-add-'))
    tempDirs.push(root)
    const photoA = path.join(root, 'a.jpg')
    fs.writeFileSync(photoA, 'a')

    const sqlite = createDb()
    const { service, sessionRepo } = buildService(sqlite)
    const session = sessionRepo.create('Add', 'folder', root)
    addOkAnalysisRun(sqlite, session.id, 0)

    const first = await service.addPhotos(session.id, [photoA], 'manual')
    expect(first.added).toBe(1)
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)

    // Re-adding the same path inserts nothing: the cursor must not move.
    const second = await service.addPhotos(session.id, [photoA], 'manual')
    expect(second.added).toBe(0)
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })
})
