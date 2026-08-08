import BetterSqlite3 from 'better-sqlite3'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../../../desktop/src/main/services/face-kw/face-inference-worker-client', () => ({
  FaceInferenceWorker: class {
    async init() {}
    async analyzeBatch(images: unknown[]) {
      return images.map(() => ({
        observations: [
          {
            bbox: [1, 2, 3, 4],
            confidence: 0.9,
            embedding: Buffer.from(new Float32Array([0.1, 0.2]).buffer),
          },
        ],
        encodingFailures: 0,
      }))
    }
    async shutdown() {}
  },
}))

vi.mock('../../../../desktop/src/main/utils/analysis-worker-client', () => ({
  clusterFacesInWorker: vi.fn(async () => ({ clusters: [], noise: [] })),
}))

import { FaceKwService } from '../../../../desktop/src/main/services/face-kw/face-kw.service'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'

const databases: BetterSqlite3.Database[] = []
const tempDirs: string[] = []

function createDb(): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.pragma('foreign_keys = ON')
  db.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'draft',
      analysis_status TEXT NOT NULL DEFAULT 'idle',
      writeback_status TEXT NOT NULL DEFAULT 'idle',
      import_source TEXT NOT NULL DEFAULT 'unknown',
      source_path TEXT NOT NULL DEFAULT '',
      truncated_import INTEGER NOT NULL DEFAULT 0,
      index_seq INTEGER NOT NULL DEFAULT 0,
      photo_count INTEGER NOT NULL DEFAULT 0,
      failed_writeback_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE analysis_runs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      photo_count INTEGER NOT NULL,
      index_seq INTEGER NOT NULL,
      started_at TEXT NOT NULL,
      finished_at TEXT NOT NULL,
      params TEXT NOT NULL,
      status TEXT NOT NULL
    );
  `)
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
  faceRepoOverrides: Record<string, unknown> = {},
): { service: FaceKwService; sessionRepo: SessionRepository } {
  const sessionRepo = new SessionRepository(wrap(db))
  const service = new FaceKwService(
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
    {
      getObservations: vi.fn(() => []),
      getAnalysisStates: vi.fn(() => new Map()),
      reuseObservationsForAssetFile: vi.fn(() => ({ reused: false })),
      getClusterSignature: vi.fn(() => ''),
      getClusters: vi.fn(() => []),
      replaceObservationsByPhoto: vi.fn(),
      upsertAnalysisState: vi.fn(),
      deleteObservationsByPhoto: vi.fn(),
      deleteAnalysisStateByPhoto: vi.fn(),
      deleteClustersBySession: vi.fn(),
      upsertClusterSignature: vi.fn(),
      ...faceRepoOverrides,
    } as never,
    {
      getPreview: vi.fn(async () => ({
        buffer: Buffer.from('jpeg'),
        format: 'jpeg',
        width: 100,
        height: 80,
      })),
    } as never,
    {
      get: vi.fn((_key: string, fallback: string) => fallback),
      getNumber: vi.fn((_key: string, fallback: number) => fallback),
    } as never,
    {} as never,
    wrap(db),
  )
  return { service, sessionRepo }
}

function createPhotoFile(): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-face-run-'))
  tempDirs.push(root)
  const filepath = path.join(root, 'photo.jpg')
  fs.writeFileSync(filepath, 'photo-bytes')
  return filepath
}

afterEach(() => {
  vi.restoreAllMocks()
  for (const db of databases.splice(0)) db.close()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('FaceKwService analysis run records', () => {
  it('writes a face run row at entry and finalizes it to ok', async () => {
    const filepath = createPhotoFile()
    const db = createDb()
    const sessionRepo = new SessionRepository(wrap(db))
    const session = sessionRepo.create('Run', 'folder', path.dirname(filepath))
    const detectorPath = path.join(path.dirname(filepath), 'det.onnx')
    const encoderPath = path.join(path.dirname(filepath), 'enc.onnx')

    const { service } = buildService(db, filepath)
    const result = await service.analyze(session.id, detectorPath, encoderPath, 0.6, 2)

    expect(result.status).toBe('done')
    const row = db.prepare(
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
    expect(row.status).toBe('ok')
    expect(row.kind).toBe('face')
    expect(row.photo_count).toBe(1)
    expect(row.index_seq).toBe(0)
    expect(row.started_at).not.toBe('')
    expect(row.finished_at).not.toBe('')
    expect(JSON.parse(row.params)).toEqual({
      detectorPath,
      encoderPath,
      eps: 0.6,
      minPts: 2,
    })
  })

  it('finalizes the run as failed when every detection fails', async () => {
    const filepath = createPhotoFile()
    const db = createDb()
    const sessionRepo = new SessionRepository(wrap(db))
    const session = sessionRepo.create('Run', 'folder', path.dirname(filepath))
    const replace = vi.fn(() => {
      throw new Error('write failure')
    })

    const { service } = buildService(db, filepath, { replaceObservationsByPhoto: replace })
    const result = await service.analyze(
      session.id,
      path.join(path.dirname(filepath), 'det.onnx'),
      path.join(path.dirname(filepath), 'enc.onnx'),
    )

    expect(result.status).toBe('failed')
    const row = db.prepare(
      'SELECT status, finished_at FROM analysis_runs WHERE session_id = ?',
    ).get(session.id) as { status: string; finished_at: string }
    expect(row.status).toBe('failed')
    expect(row.finished_at).not.toBe('')
  })
})
