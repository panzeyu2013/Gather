import BetterSqlite3 from 'better-sqlite3'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  clusterHashesInWorker: vi.fn(async () => ({ groups: [['photo-1']], ungrouped: [] })),
  clusterHashesInWorkerMulti: vi.fn(async () =>
    Array.from({ length: 4 }, () => ({ groups: [], ungrouped: [] })),
  ),
  computeBatchDHash: vi.fn(async () => new Map([[0, 'a'.repeat(64)]])),
}))

vi.mock('../../../../desktop/src/main/utils/analysis-worker-client', () => ({
  clusterHashesInWorker: mocks.clusterHashesInWorker,
  clusterHashesInWorkerMulti: mocks.clusterHashesInWorkerMulti,
}))

vi.mock('../../../../desktop/src/main/services/similarity/hash-computer', () => ({
  computeBatchDHash: mocks.computeBatchDHash,
}))

import { SimilarityService } from '../../../../desktop/src/main/services/similarity/similarity.service'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import { SCHEMA_SQL, INDEX_SQL } from '../../../../desktop/src/main/db/schema'

const databases: BetterSqlite3.Database[] = []
const tempDirs: string[] = []

function createDb(): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.pragma('foreign_keys = ON')
  db.exec(SCHEMA_SQL)
  db.exec(INDEX_SQL)
  return db
}

function wrap(db: BetterSqlite3.Database): never {
  return {
    prepare: (sql: string) => db.prepare(sql),
    transaction: <T>(operation: () => T) => db.transaction(operation),
  } as never
}

function buildService(
  db: BetterSqlite3.Database,
  filepath: string,
  thumbnail?: () => Promise<{ buffer: Buffer }>,
): { service: SimilarityService; sessionRepo: SessionRepository } {
  const sessionRepo = new SessionRepository(wrap(db))
  const service = new SimilarityService(
    {
      getBySessionProjection: vi.fn(() => [{
        id: 'photo-1',
        session_id: 'session',
        filepath,
        filename: 'photo.jpg',
        checksum: '',
        checksum_file_size: 0,
        checksum_file_mtime_ms: 0,
        status: 'pending',
        asset_id: null,
        asset_file_id: null,
      }]),
    } as never,
    sessionRepo,
    { replace: vi.fn(), replaceForThreshold: vi.fn() } as never,
    { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
    {
      getThumbnail: thumbnail
        ? vi.fn(thumbnail)
        : vi.fn(async () => ({ buffer: Buffer.from([1]) })),
    } as never,
    wrap(db),
  )
  return { service, sessionRepo }
}

function createPhotoFile(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-sim-run-'))
  tempDirs.push(root)
  const filepath = path.join(root, 'photo.jpg')
  fs.writeFileSync(filepath, 'photo-bytes')
  return filepath
}

// The hash/observation writes reference photos(id); the photo repository is
// mocked, so the row itself is inserted directly.
function addPhotoRow(sqlite: BetterSqlite3.Database, sessionId: string, filepath: string): void {
  const now = new Date().toISOString()
  sqlite.prepare(`
    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, asset_id, asset_file_id, width, height, created_at, updated_at)
    VALUES ('photo-1', ?, ?, 'photo.jpg', '', 'pending', '{}', '{}', NULL, NULL, 100, 80, ?, ?)
  `).run(sessionId, filepath, now, now)
}

afterEach(() => {
  vi.restoreAllMocks()
  for (const mock of [mocks.clusterHashesInWorker, mocks.clusterHashesInWorkerMulti, mocks.computeBatchDHash]) {
    mock.mockClear()
  }
  for (const db of databases.splice(0)) db.close()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('SimilarityService analysis run records', () => {
  it('writes a running row at entry with the snapshot and finalizes it to ok', async () => {
    const filepath = createPhotoFile()
    const db = createDb()
    const sessionRepo = new SessionRepository(wrap(db))
    const session = sessionRepo.create('Run', 'folder', path.dirname(filepath))
    addPhotoRow(db, session.id, filepath)

    // Block the analysis on the thumbnail decode so the in-flight run row can
    // be observed before it is finalized.
    //
    // SEAM: the run row is inserted before the decode pipeline runs, and the
    // row is finalized only after the pipeline resolves. The in-window DB
    // assertions below (status === 'running', empty finished_at) are the
    // load-bearing proof — if the pipeline were ever reordered so the insert
    // happens after the decode (or finalization before it), the assertions
    // fail loudly instead of passing vacuously.
    let release!: () => void
    const gate = new Promise<void>(resolve => { release = resolve })
    const { service } = buildService(db, filepath, () =>
      gate.then(() => ({ buffer: Buffer.from([1]) })),
    )

    const run = service.analyze(session.id, {
      threshold: 10,
      minGroupSize: 2,
      groupingMode: 'global',
    })

    const running = db.prepare(
      'SELECT kind, photo_count, index_seq, params, started_at, finished_at, status FROM analysis_runs WHERE session_id = ?',
    ).get(session.id) as {
      kind: string
      photo_count: number
      index_seq: number
      params: string
      started_at: string
      finished_at: string
      status: string
    }
    expect(running.status).toBe('running')
    expect(running.kind).toBe('similarity')
    expect(running.photo_count).toBe(1)
    expect(running.index_seq).toBe(0)
    expect(running.started_at).not.toBe('')
    expect(running.finished_at).toBe('')
    expect(JSON.parse(running.params)).toEqual({
      threshold: 10,
      minGroupSize: 2,
      groupingMode: 'global',
    })

    release()
    await run

    const finalized = db.prepare(
      'SELECT status, finished_at FROM analysis_runs WHERE session_id = ?',
    ).get(session.id) as { status: string; finished_at: string }
    expect(finalized.status).toBe('ok')
    expect(finalized.finished_at).not.toBe('')
  })

  it('finalizes the run as failed and rethrows when clustering fails', async () => {
    const filepath = createPhotoFile()
    const db = createDb()
    const sessionRepo = new SessionRepository(wrap(db))
    const session = sessionRepo.create('Run', 'folder', path.dirname(filepath))
    addPhotoRow(db, session.id, filepath)
    mocks.clusterHashesInWorker.mockRejectedValueOnce(new Error('cluster boom'))

    const { service } = buildService(db, filepath)

    await expect(service.analyze(session.id)).rejects.toThrow('cluster boom')

    const row = db.prepare(
      'SELECT status, finished_at FROM analysis_runs WHERE session_id = ?',
    ).get(session.id) as { status: string; finished_at: string }
    expect(row.status).toBe('failed')
    expect(row.finished_at).not.toBe('')
  })

  it('records the index_seq snapshot from the session cursor', async () => {
    const filepath = createPhotoFile()
    const db = createDb()
    const sessionRepo = new SessionRepository(wrap(db))
    const session = sessionRepo.create('Run', 'folder', path.dirname(filepath))
    addPhotoRow(db, session.id, filepath)
    sessionRepo.bumpIndexSeq(session.id)

    const { service } = buildService(db, filepath)
    await service.analyze(session.id)

    const row = db.prepare(
      'SELECT index_seq, status FROM analysis_runs WHERE session_id = ?',
    ).get(session.id) as { index_seq: number; status: string }
    expect(row.index_seq).toBe(1)
    expect(row.status).toBe('ok')
  })
})
