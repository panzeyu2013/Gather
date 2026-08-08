import BetterSqlite3 from 'better-sqlite3'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { IndexService } from '../../../../desktop/src/main/services/indexer/index.service'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
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

function addFileRow(
  sqlite: BetterSqlite3.Database,
  id: string,
  filepath: string,
  fileSize: number,
  fileMtimeMs: number,
  checksum: string,
): void {
  const now = new Date().toISOString()
  sqlite.prepare(`
    INSERT INTO asset_files (id, volume_id, file_identity, normalized_path, filename, extension, media_type, file_size, file_mtime_ms, checksum, online_status, last_seen_at, created_at, updated_at)
    VALUES (?, 'dev:1', 'ino-1', ?, ?, '.jpg', 'image', ?, ?, ?, 'online', '', ?, ?)
  `).run(id, filepath, path.basename(filepath), fileSize, fileMtimeMs, checksum, now, now)
}

function addPhotoRow(
  sqlite: BetterSqlite3.Database,
  id: string,
  sessionId: string,
  filepath: string,
  assetFileId: string | null,
): void {
  const now = new Date().toISOString()
  sqlite.prepare(`
    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, asset_file_id, width, height, created_at, updated_at)
    VALUES (?, ?, ?, ?, '', 'pending', ?, 100, 80, ?, ?)
  `).run(id, sessionId, filepath, path.basename(filepath), assetFileId, now, now)
}

function buildIndexer(
  sqlite: BetterSqlite3.Database,
  sessionRepo: SessionRepository,
  options: {
    root: string
    existingPhotos: Array<Record<string, unknown>>
    relinkResult?: unknown
  },
): { indexer: IndexService; markMissing: ReturnType<typeof vi.fn> } {
  const markMissing = vi.fn()
  const indexer = new IndexService(
    wrap(sqlite),
    sessionRepo,
    {
      getBySessionProjection: vi.fn(() => options.existingPhotos),
      addPhotos: vi.fn(() => ({ added: 1, skipped: 0, ids: ['new-1'] })),
      updateIndexedFile: vi.fn(),
      updateChecksum: vi.fn(),
      markMissing,
      countBySession: vi.fn(() => 1),
    } as never,
    {
      backfillSession: vi.fn(),
      relinkMovedFile: vi.fn(() => options.relinkResult ?? null),
    } as never,
    { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
    { get: vi.fn((_key: string, fallback: string) => fallback) } as never,
  )
  return { indexer, markMissing }
}

afterEach(() => {
  vi.restoreAllMocks()
  for (const db of databases.splice(0)) db.close()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('IndexService index_seq commit point', () => {
  it('bumps index_seq once when the scan added a photo', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    fs.writeFileSync(path.join(root, 'new.jpg'), 'content')

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    const bumpSpy = vi.spyOn(sessionRepo, 'bumpIndexSeq')
    const { indexer, markMissing } = buildIndexer(sqlite, sessionRepo, {
      root,
      existingPhotos: [],
    })

    await indexer.scanSession(session.id)

    expect(markMissing).toHaveBeenCalledWith([])
    expect(bumpSpy).toHaveBeenCalled()
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })

  it('bumps index_seq when an existing photo content changed', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    const photoPath = path.join(root, 'photo.jpg')
    fs.writeFileSync(photoPath, 'content')

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    // No asset_files row: the scan observes the file as changed.
    addPhotoRow(sqlite, 'photo-1', session.id, photoPath, null)
    const { indexer } = buildIndexer(sqlite, sessionRepo, {
      root,
      existingPhotos: [
        { id: 'photo-1', filepath: photoPath, asset_file_id: null, status: 'pending' },
      ],
    })

    await indexer.scanSession(session.id)

    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })

  it('bumps index_seq when a photo is relinked to a new path', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    const newPath = path.join(root, 'moved.jpg')
    const oldPath = path.join(root, 'old-name.jpg')
    fs.writeFileSync(newPath, 'relinked-content')

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    const fileStat = fs.statSync(newPath)
    addFileRow(sqlite, 'file-old', newPath, fileStat.size, fileStat.mtimeMs, 'checksum-1')
    addPhotoRow(sqlite, 'relinked', session.id, oldPath, 'file-old')
    const { indexer } = buildIndexer(sqlite, sessionRepo, {
      root,
      existingPhotos: [
        { id: 'relinked', filepath: oldPath, asset_file_id: 'file-old', status: 'pending' },
      ],
      relinkResult: { fileId: 'file-old', photoIds: ['relinked'] },
    })

    await indexer.scanSession(session.id)

    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })

  it('does NOT bump index_seq when the scan changed nothing', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    const photoPath = path.join(root, 'photo.jpg')
    fs.writeFileSync(photoPath, 'content')
    const fileStat = fs.statSync(photoPath)

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    addFileRow(sqlite, 'af-1', photoPath, fileStat.size, fileStat.mtimeMs, 'checksum-1')
    addPhotoRow(sqlite, 'photo-1', session.id, photoPath, 'af-1')
    const { indexer, markMissing } = buildIndexer(sqlite, sessionRepo, {
      root,
      existingPhotos: [
        { id: 'photo-1', filepath: photoPath, asset_file_id: 'af-1', status: 'pending' },
      ],
    })

    await indexer.scanSession(session.id)

    expect(markMissing).toHaveBeenCalledWith([])
    expect(sessionRepo.getIndexSeq(session.id)).toBe(0)
  })

  it('bumps index_seq when a photo disappears from disk (missing reconcile)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    const photoPath = path.join(root, 'photo.jpg')
    // The photo row exists but the file was deleted from disk before the scan.
    fs.writeFileSync(photoPath, 'content')
    fs.rmSync(photoPath)

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    addPhotoRow(sqlite, 'photo-1', session.id, photoPath, null)
    const { indexer, markMissing } = buildIndexer(sqlite, sessionRepo, {
      root,
      existingPhotos: [
        { id: 'photo-1', filepath: photoPath, asset_file_id: null, status: 'pending' },
      ],
    })

    await indexer.scanSession(session.id)

    expect(markMissing).toHaveBeenCalledWith(['photo-1'])
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })

  it('does NOT bump index_seq on repeated scans when a photo has no asset_files row and the file is unchanged', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    const photoPath = path.join(root, 'photo.jpg')
    fs.writeFileSync(photoPath, 'content')

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    // The photo was never backfilled into asset_files, so the scan has no
    // asset_files baseline to compare against.
    addPhotoRow(sqlite, 'photo-1', session.id, photoPath, null)
    const indexer = new IndexService(
      wrap(sqlite),
      sessionRepo,
      new PhotoRepository(wrap(sqlite)) as never,
      {
        backfillSession: vi.fn(),
        relinkMovedFile: vi.fn(() => null),
      } as never,
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      { get: vi.fn((_key: string, fallback: string) => fallback) } as never,
    )

    // First observation of the file commits its dimensions/checksum stat,
    // which is a real change.
    await indexer.scanSession(session.id)
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)

    // Rescanning the unchanged file re-writes identical values only: the
    // missing asset_files row must not make every rescan a "content change"
    // that bumps index_seq forever.
    await indexer.scanSession(session.id)
    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })

  it('bumps index_seq when an unbackfilled photo content actually changes', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-seq-'))
    tempDirs.push(root)
    const photoPath = path.join(root, 'photo.jpg')
    fs.writeFileSync(photoPath, 'content')
    const originalStat = fs.statSync(photoPath)

    const sqlite = createDb()
    const sessionRepo = new SessionRepository(wrap(sqlite))
    const session = sessionRepo.create('Seq', 'folder', root)
    addPhotoRow(sqlite, 'photo-1', session.id, photoPath, null)
    // Simulate a previous scan commit: the photo row itself carries the
    // indexed stat baseline (no asset_files row exists).
    sqlite.prepare(`
      UPDATE photos SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?
      WHERE id = ?
    `).run('hash-1', originalStat.size, originalStat.mtimeMs, 'photo-1')
    // The file on disk now differs from the indexed stat.
    fs.writeFileSync(photoPath, 'different-content-with-another-size')

    const indexer = new IndexService(
      wrap(sqlite),
      sessionRepo,
      new PhotoRepository(wrap(sqlite)) as never,
      {
        backfillSession: vi.fn(),
        relinkMovedFile: vi.fn(() => null),
      } as never,
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      { get: vi.fn((_key: string, fallback: string) => fallback) } as never,
    )

    await indexer.scanSession(session.id)

    expect(sessionRepo.getIndexSeq(session.id)).toBe(1)
  })
})
