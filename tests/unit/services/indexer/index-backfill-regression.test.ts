import { afterEach, describe, expect, it, vi } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { SCHEMA_SQL, INDEX_SQL } from '../../../../desktop/src/main/db/schema'
import { IndexService } from '../../../../desktop/src/main/services/indexer/index.service'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
import { AssetRepository } from '../../../../desktop/src/main/db/repositories/asset.repo'

const tempDirs: string[] = []
const databases: BetterSqlite3.Database[] = []

afterEach(() => {
  vi.restoreAllMocks()
  for (const db of databases.splice(0)) db.close()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

function sha256(content: string): string {
  return createHash('sha256').update(content).digest('hex')
}

interface BackfillHarness {
  indexer: IndexService
  photosWrites: ReturnType<typeof vi.fn>
  assetFileWrites: ReturnType<typeof vi.fn>
  getBySession: ReturnType<typeof vi.fn>
  getBySessionProjection: ReturnType<typeof vi.fn>
  rows: Array<{ id: string; filepath: string; checksum: string; status: string; asset_file_id?: string | null }>
}

function buildMockBackfillHarness(
  rows: BackfillHarness['rows'],
  options: { concurrentWriter?: boolean } = {},
): BackfillHarness {
  const photosWrites = vi.fn()
  const assetFileWrites = vi.fn()
  const getBySession = vi.fn(() => rows)
  const getBySessionProjection = vi.fn(() => rows)
  const prepare = vi.fn((sql: string) => {
    if (sql.includes('UPDATE photos')) {
      return {
        // Simulates the optimistic `WHERE id = ? AND checksum = ''` guard of
        // backfillChecksums. With concurrentWriter the row is treated as
        // already filled by another writer (the changes = 0 path).
        run: (...args: unknown[]) => {
          const photoId = String(args[4])
          const checksum = String(args[0])
          photosWrites(photoId, checksum)
          const row = rows.find(photo => photo.id === photoId)
          if (!row || row.checksum !== '' || options.concurrentWriter) {
            if (row && options.concurrentWriter) row.checksum = 'concurrent-hash'
            return { changes: 0 }
          }
          row.checksum = checksum
          return { changes: 1 }
        },
      }
    }
    if (sql.includes('UPDATE asset_files')) {
      return {
        run: (...args: unknown[]) => {
          assetFileWrites(String(args[3]))
          return { changes: 1 }
        },
      }
    }
    return { all: () => [], get: () => undefined, run: () => ({ changes: 0 }) }
  })
  const indexer = new IndexService(
    { prepare, transaction: vi.fn((operation: () => void) => operation) } as never,
    { get: vi.fn(), updatePhotoCount: vi.fn() } as never,
    {
      getBySession,
      getBySessionProjection,
      updateChecksum: vi.fn(),
      countBySession: vi.fn(() => 1),
    } as never,
    { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
    { getDimensions: vi.fn() } as never,
    { get: vi.fn() } as never,
  )
  return { indexer, photosWrites, assetFileWrites, getBySession, getBySessionProjection, rows }
}

describe('IndexService checksum backfill convergence', () => {
  it('writes the backfilled checksum into asset_files so a later full scan keeps it', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-backfill-converge-'))
    tempDirs.push(root)
    const filePath = path.join(root, 'photo.jpg')
    const content = 'backfill-then-rescan'
    fs.writeFileSync(filePath, content)
    const fileStat = fs.statSync(filePath)
    const checksum = sha256(content)

    const sqlite = new BetterSqlite3(':memory:')
    databases.push(sqlite)
    sqlite.pragma('foreign_keys = ON')
    sqlite.exec(SCHEMA_SQL)
    sqlite.exec(INDEX_SQL)
    const timestamp = '2026-08-01T12:00:00.000Z'
    // State left behind by a lazy first scan: photos.checksum was backfilled
    // but asset_files.checksum is still empty, which used to make the next
    // full scan re-hash everything and clear the backfilled value again.
    sqlite.prepare(`
      INSERT INTO sessions (
        id, name, status, analysis_status, writeback_status, import_source,
        source_path, photo_count, failed_writeback_count, created_at, updated_at
      ) VALUES ('session', 'Converge', 'photos_loaded', 'idle', 'idle',
        'folder', ?, 1, 0, ?, ?)
    `).run(root, timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO asset_files (
        id, volume_id, file_identity, normalized_path, filename, extension,
        media_type, file_size, file_mtime_ms, checksum, online_status,
        last_seen_at, created_at, updated_at
      ) VALUES ('af-1', 'dev:1', 'ino-1', ?, 'photo.jpg', '.jpg', 'image',
        ?, ?, '', 'online', ?, ?, ?)
    `).run(filePath, fileStat.size, fileStat.mtimeMs, timestamp, timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
      VALUES ('asset-1', '', 'active', ?, ?)
    `).run(timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source)
      VALUES ('asset-1', 'af-1', 'camera_jpeg', 1, 'import')
    `).run()
    sqlite.prepare(`
      INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
      VALUES ('session', 'asset-1', 'af-1', 0, ?)
    `).run(timestamp)
    sqlite.prepare(`
      INSERT INTO photos (
        id, session_id, filepath, filename, checksum, status, metadata, result,
        asset_id, asset_file_id, width, height, created_at, updated_at
      ) VALUES ('photo-1', 'session', ?, 'photo.jpg', '', 'pending', '{}', '{}',
        'asset-1', 'af-1', 100, 80, ?, ?)
    `).run(filePath, timestamp, timestamp)

    const db = {
      prepare: (sql: string) => sqlite.prepare(sql),
      transaction: (operation: () => void) => sqlite.transaction(operation),
    } as never
    const photoRepo = new PhotoRepository(db)
    const updateChecksumSpy = vi.spyOn(photoRepo, 'updateChecksum')
    const indexer = new IndexService(
      db,
      new SessionRepository(db),
      photoRepo,
      new AssetRepository(db),
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      {
        get: vi.fn((key: string, fallback: string) =>
          key === 'lazy_checksum' ? 'true' : fallback),
      } as never,
    )

    const backfill = await indexer.backfillChecksums('session')
    expect(backfill).toEqual({ processed: 1, backfilled: 1, skipped: 0 })

    const assetFile = sqlite.prepare(
      'SELECT checksum, file_size, file_mtime_ms FROM asset_files WHERE id = ?',
    ).get('af-1') as { checksum: string; file_size: number; file_mtime_ms: number }
    expect(assetFile.checksum).toBe(checksum)
    expect(assetFile.file_size).toBe(fileStat.size)
    expect(assetFile.file_mtime_ms).toBe(fileStat.mtimeMs)

    // A second full scan must hit the unchanged path: no checksum write at
    // all (neither a hash nor a clear), no pending backfill work remains.
    updateChecksumSpy.mockClear()
    const scan = await indexer.scanSession('session')
    expect(scan.discovered).toBe(1)
    expect(scan.skipped).toBe(1)
    expect(updateChecksumSpy).not.toHaveBeenCalled()

    const photo = sqlite.prepare(
      'SELECT checksum FROM photos WHERE id = ?',
    ).get('photo-1') as { checksum: string }
    expect(photo.checksum).toBe(checksum)
    const afterScan = sqlite.prepare(
      'SELECT checksum FROM asset_files WHERE id = ?',
    ).get('af-1') as { checksum: string }
    expect(afterScan.checksum).toBe(checksum)
    expect(indexer.pendingChecksums('session')).toBe(0)
  })

  it('terminates when a photo cannot be read, leaving its checksum empty', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-backfill-fail-'))
    tempDirs.push(root)
    const goodPath = path.join(root, 'good.jpg')
    const content = 'good-content'
    fs.writeFileSync(goodPath, content)
    const badPath = path.join(root, 'deleted.jpg')

    const harness = buildMockBackfillHarness([
      { id: 'good', filepath: goodPath, checksum: '', status: 'pending' },
      { id: 'bad', filepath: badPath, checksum: '', status: 'pending' },
    ])

    const result = await harness.indexer.backfillChecksums('session')

    // The unreadable photo is recorded as failed, excluded from the next
    // pass, and the job completes instead of retrying forever.
    expect(result).toEqual({ processed: 2, backfilled: 1, skipped: 1 })
    expect(harness.photosWrites).toHaveBeenCalledTimes(1)
    expect(harness.photosWrites).toHaveBeenCalledWith(
      'good',
      sha256(content),
    )
    expect(harness.rows.find(row => row.id === 'good')?.checksum).toBe(sha256(content))
    expect(harness.rows.find(row => row.id === 'bad')?.checksum).toBe('')
    expect(harness.getBySessionProjection).toHaveBeenCalledTimes(2)
  })

  it('stops after a pass with zero successes instead of spinning', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-backfill-allfail-'))
    tempDirs.push(root)

    const harness = buildMockBackfillHarness([
      { id: 'bad-1', filepath: path.join(root, 'gone-1.jpg'), checksum: '', status: 'pending' },
      { id: 'bad-2', filepath: path.join(root, 'gone-2.jpg'), checksum: '', status: 'pending' },
    ])

    const result = await harness.indexer.backfillChecksums('session')

    expect(result).toEqual({ processed: 2, backfilled: 0, skipped: 2 })
    expect(harness.photosWrites).not.toHaveBeenCalled()
    expect(harness.getBySessionProjection).toHaveBeenCalledTimes(1)
  })

  it('does not clear a stored checksum when the scan snapshot is stale (lazy mode)', async () => {
    // Race state: checksum.backfill already committed photos.checksum = 'H',
    // but the scan's asset_files snapshot was taken before that commit and
    // still shows checksum = ''. The file itself is unchanged.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-scan-preserve-'))
    tempDirs.push(root)
    const filePath = path.join(root, 'photo.jpg')
    const content = 'already-hashed-content'
    fs.writeFileSync(filePath, content)
    const fileStat = fs.statSync(filePath)
    const checksum = sha256(content)

    const sqlite = new BetterSqlite3(':memory:')
    databases.push(sqlite)
    sqlite.pragma('foreign_keys = ON')
    sqlite.exec(SCHEMA_SQL)
    sqlite.exec(INDEX_SQL)
    const timestamp = '2026-08-01T12:00:00.000Z'
    sqlite.prepare(`
      INSERT INTO sessions (
        id, name, status, analysis_status, writeback_status, import_source,
        source_path, photo_count, failed_writeback_count, created_at, updated_at
      ) VALUES ('session', 'Preserve', 'photos_loaded', 'idle', 'idle',
        'folder', ?, 1, 0, ?, ?)
    `).run(root, timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO asset_files (
        id, volume_id, file_identity, normalized_path, filename, extension,
        media_type, file_size, file_mtime_ms, checksum, online_status,
        last_seen_at, created_at, updated_at
      ) VALUES ('af-1', 'dev:1', 'ino-1', ?, 'photo.jpg', '.jpg', 'image',
        ?, ?, '', 'online', ?, ?, ?)
    `).run(filePath, fileStat.size, fileStat.mtimeMs, timestamp, timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
      VALUES ('asset-1', '', 'active', ?, ?)
    `).run(timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO asset_members (asset_id, file_id, member_role, is_primary, binding_source)
      VALUES ('asset-1', 'af-1', 'camera_jpeg', 1, 'import')
    `).run()
    sqlite.prepare(`
      INSERT INTO session_assets (session_id, asset_id, display_file_id, import_order, added_at)
      VALUES ('session', 'asset-1', 'af-1', 0, ?)
    `).run(timestamp)
    sqlite.prepare(`
      INSERT INTO photos (
        id, session_id, filepath, filename, checksum, status, metadata, result,
        asset_id, asset_file_id, width, height, created_at, updated_at
      ) VALUES ('photo-1', 'session', ?, 'photo.jpg', ?, 'pending', '{}', '{}',
        'asset-1', 'af-1', 100, 80, ?, ?)
    `).run(filePath, checksum, timestamp, timestamp)

    const db = {
      prepare: (sql: string) => sqlite.prepare(sql),
      transaction: (operation: () => void) => sqlite.transaction(operation),
    } as never
    const photoRepo = new PhotoRepository(db)
    const updateChecksumSpy = vi.spyOn(photoRepo, 'updateChecksum')
    const indexer = new IndexService(
      db,
      new SessionRepository(db),
      photoRepo,
      new AssetRepository(db),
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      {
        get: vi.fn((key: string, fallback: string) =>
          key === 'lazy_checksum' ? 'true' : fallback),
      } as never,
    )

    const scan = await indexer.scanSession('session')

    // The unchanged file must keep its backfilled checksum: the scan neither
    // clears photos.checksum nor touches the empty asset_files.checksum.
    expect(scan.missing).toBe(0)
    expect(updateChecksumSpy).not.toHaveBeenCalled()

    const photo = sqlite.prepare(
      'SELECT checksum FROM photos WHERE id = ?',
    ).get('photo-1') as { checksum: string }
    expect(photo.checksum).toBe(checksum)
    const assetFile = sqlite.prepare(
      'SELECT checksum FROM asset_files WHERE id = ?',
    ).get('af-1') as { checksum: string }
    expect(assetFile.checksum).toBe('')
    expect(indexer.pendingChecksums('session')).toBe(0)
  })

  it('preserves the asset_files checksum via a conditional write when the snapshot lacks one', async () => {
    // Same stale-snapshot race, observed at the SQL level: the scan's
    // 'existing' branch must send the preserve flag instead of writing ''.
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-scan-preserve-sql-'))
    tempDirs.push(root)
    const filePath = path.join(root, 'photo.jpg')
    fs.writeFileSync(filePath, 'content')
    const fileStat = fs.statSync(filePath)
    const assetFileWrites = vi.fn()
    const updateChecksum = vi.fn()
    const updateIndexedFile = vi.fn()
    const fileStats = [{
      id: 'af-1',
      file_size: fileStat.size,
      file_mtime_ms: fileStat.mtimeMs,
      checksum: '',
    }]
    const indexer = new IndexService(
      {
        prepare: vi.fn((sql: string) => {
          if (sql.includes('UPDATE asset_files')) {
            return { run: (...args: unknown[]) => { assetFileWrites(...args) } }
          }
          if (sql.includes('af.id, af.file_size')) return { all: () => fileStats }
          return { all: () => [], get: () => undefined, run: vi.fn() }
        }),
        transaction: vi.fn((operation: () => void) => operation),
      } as never,
      {
        get: vi.fn(() => ({ id: 'session', source_path: root })),
        updatePhotoCount: vi.fn(),
      } as never,
      {
        getBySessionProjection: vi.fn(() => [
          { id: 'photo-1', filepath: filePath, asset_file_id: 'af-1', status: 'pending' },
        ]),
        addPhotos: vi.fn(() => ({ added: 0, skipped: 0 })),
        updateIndexedFile,
        updateChecksum,
        markMissing: vi.fn(),
        countBySession: vi.fn(() => 1),
      } as never,
      { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      {
        get: vi.fn((key: string, fallback: string) =>
          key === 'lazy_checksum' ? 'true' : fallback),
      } as never,
    )

    await indexer.scanSession('session')

    expect(updateChecksum).not.toHaveBeenCalled()
    expect(updateIndexedFile).toHaveBeenCalledWith('photo-1', 100, 80, false)
    const write = assetFileWrites.mock.calls[0]
    expect(write).toBeDefined()
    // (volume_id, file_identity, file_size, file_mtime_ms, preserveFlag,
    //  checksum, last_seen_at, updated_at, id): the checksum column keeps
    // its current value instead of being overwritten with ''.
    expect(write[4]).toBe(1)
    expect(write[5]).toBe('')
    expect(write[8]).toBe('af-1')
  })

  it('skips the backfill write when a concurrent writer already filled the checksum', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-backfill-race-'))
    tempDirs.push(root)
    const pendingPath = path.join(root, 'pending.jpg')
    fs.writeFileSync(pendingPath, 'race-content')

    // getBySession sees checksum = '' and picks the photo; by the time the
    // guarded UPDATE runs, another writer (the concurrent scan) has already
    // filled it, so changes = 0 and the hash must not be applied.
    const harness = buildMockBackfillHarness(
      [{ id: 'pending', filepath: pendingPath, checksum: '', status: 'pending' }],
      { concurrentWriter: true },
    )

    const result = await harness.indexer.backfillChecksums('session')

    expect(result).toEqual({ processed: 1, backfilled: 0, skipped: 1 })
    expect(harness.photosWrites).toHaveBeenCalledTimes(1)
    expect(harness.assetFileWrites).not.toHaveBeenCalled()
    expect(harness.rows[0].checksum).toBe('concurrent-hash')
  })
})
