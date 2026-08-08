import { afterEach, describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { IndexService } from '../../../../desktop/src/main/services/indexer/index.service'

const tempDirs: string[] = []

afterEach(() => {
  vi.restoreAllMocks()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

function sha256(content: string): string {
  return createHash('sha256').update(content).digest('hex')
}

interface Fixture {
  root: string
  newPath: string
  changedPath: string
  untouchedPath: string
  newContent: string
  changedContent: string
  untouchedContent: string
}

function createFixture(): Fixture {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-lazy-'))
  tempDirs.push(root)
  const newPath = path.join(root, 'new.jpg')
  const changedPath = path.join(root, 'changed.jpg')
  const untouchedPath = path.join(root, 'untouched.jpg')
  const newContent = 'new-content'
  const changedContent = 'changed-content'
  const untouchedContent = 'untouched-content'
  fs.writeFileSync(newPath, newContent)
  fs.writeFileSync(changedPath, changedContent)
  fs.writeFileSync(untouchedPath, untouchedContent)
  return {
    root, newPath, changedPath, untouchedPath,
    newContent, changedContent, untouchedContent,
  }
}

interface ScanHarness {
  indexer: IndexService
  addPhotos: ReturnType<typeof vi.fn>
  updateChecksum: ReturnType<typeof vi.fn>
  updateIndexedFile: ReturnType<typeof vi.fn>
  markMissing: ReturnType<typeof vi.fn>
  fileStats: Array<{ id: string; file_size: number; file_mtime_ms: number; checksum: string }>
}

function buildScanHarness(
  fixture: Fixture,
  lazyValue: string,
  fileStats: ScanHarness['fileStats'],
  existingPhotos: Array<Record<string, unknown>>,
): ScanHarness {
  const addPhotos = vi.fn(() => ({ added: 1, skipped: 0, ids: ['photo-1'] }))
  const updateChecksum = vi.fn()
  const updateIndexedFile = vi.fn()
  const markMissing = vi.fn()
  const indexer = new IndexService(
    {
      prepare: vi.fn((sql: string) => ({
        all: () => sql.includes('af.id, af.file_size') ? fileStats : [],
        get: () => undefined,
        run: vi.fn(),
      })),
      transaction: vi.fn((operation: () => void) => operation),
    } as never,
    {
      get: vi.fn(() => ({ id: 'session', source_path: fixture.root })),
      updatePhotoCount: vi.fn(),
      bumpIndexSeq: vi.fn(),
    } as never,
    {
      getBySessionProjection: vi.fn(() => existingPhotos),
      addPhotos,
      updateIndexedFile,
      updateChecksum,
      markMissing,
      countBySession: vi.fn(() => existingPhotos.length + 1),
    } as never,
    { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
    { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
    {
      get: vi.fn((key: string, fallback: string) =>
        key === 'lazy_checksum' ? lazyValue : fallback),
    } as never,
  )
  return {
    indexer,
    addPhotos,
    updateChecksum,
    updateIndexedFile,
    markMissing,
    fileStats,
  }
}

const existingPhotosFor = (fixture: Fixture) => [
  {
    id: 'changed',
    filepath: fixture.changedPath,
    asset_file_id: 'file-changed',
    status: 'pending',
  },
  {
    id: 'untouched',
    filepath: fixture.untouchedPath,
    asset_file_id: 'file-untouched',
    status: 'pending',
  },
]

describe('IndexService lazy checksum', () => {
  it('skips hashing and records an empty checksum when lazy_checksum is enabled', async () => {
    const fixture = createFixture()
    const changedStat = fs.statSync(fixture.changedPath)
    const untouchedStat = fs.statSync(fixture.untouchedPath)
    const fileStats = [
      { id: 'file-changed', file_size: 1, file_mtime_ms: 1, checksum: '' },
      {
        id: 'file-untouched',
        file_size: untouchedStat.size,
        file_mtime_ms: untouchedStat.mtimeMs,
        checksum: '',
      },
    ]
    const harness = buildScanHarness(fixture, 'true', fileStats, existingPhotosFor(fixture))

    await harness.indexer.scanSession('session')

    expect(harness.addPhotos).toHaveBeenCalledWith('session', [
      expect.objectContaining({ filepath: fixture.newPath, checksum: '' }),
    ], 'index')
    expect(harness.updateChecksum).toHaveBeenCalledWith(
      'changed',
      '',
      changedStat.size,
      changedStat.mtimeMs,
    )
    // An unchanged file with an empty (possibly stale) snapshot checksum must
    // not be written at all in lazy mode: writing '' would clear a checksum a
    // concurrent backfill may have just committed. Non-lazy mode hashes it
    // below; a genuinely changed file is still cleared here.
    expect(harness.updateChecksum).not.toHaveBeenCalledWith(
      'untouched',
      '',
      untouchedStat.size,
      untouchedStat.mtimeMs,
    )
    expect(harness.updateIndexedFile).toHaveBeenCalledWith('untouched', 100, 80, false)
  })

  it('computes checksums synchronously when lazy_checksum is disabled', async () => {
    const fixture = createFixture()
    const changedStat = fs.statSync(fixture.changedPath)
    const untouchedStat = fs.statSync(fixture.untouchedPath)
    const fileStats = [
      { id: 'file-changed', file_size: 1, file_mtime_ms: 1, checksum: '' },
      {
        id: 'file-untouched',
        file_size: untouchedStat.size,
        file_mtime_ms: untouchedStat.mtimeMs,
        checksum: '',
      },
    ]
    const harness = buildScanHarness(fixture, 'false', fileStats, existingPhotosFor(fixture))

    await harness.indexer.scanSession('session')

    expect(harness.addPhotos).toHaveBeenCalledWith('session', [
      expect.objectContaining({
        filepath: fixture.newPath,
        checksum: sha256(fixture.newContent),
      }),
    ], 'index')
    expect(harness.updateChecksum).toHaveBeenCalledWith(
      'changed',
      sha256(fixture.changedContent),
      changedStat.size,
      changedStat.mtimeMs,
    )
    expect(harness.updateChecksum).toHaveBeenCalledWith(
      'untouched',
      sha256(fixture.untouchedContent),
      untouchedStat.size,
      untouchedStat.mtimeMs,
    )
  })
})

describe('IndexService checksum backfill', () => {
  it('fills empty checksums with fresh size/mtime and skips missing or already-hashed photos', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-backfill-'))
    tempDirs.push(root)
    const pendingPath = path.join(root, 'pending.jpg')
    const content = 'backfill-content'
    fs.writeFileSync(pendingPath, content)
    const rows = [
      { id: 'pending', filepath: pendingPath, checksum: '', status: 'pending' },
      { id: 'missing', filepath: path.join(root, 'gone.jpg'), checksum: '', status: 'missing' },
      { id: 'done', filepath: pendingPath, checksum: 'existing-hash', status: 'pending' },
    ]
    const updateChecksum = vi.fn()
    const indexer = new IndexService(
      {
        // backfillChecksums writes through the guarded `AND checksum = ''`
        // UPDATE statements; simulate them here.
        prepare: vi.fn((sql: string) => {
          if (sql.includes('UPDATE photos')) {
            return {
              run: (...args: unknown[]) => {
                const row = rows.find(photo => photo.id === args[4])
                if (!row || row.checksum !== '') return { changes: 0 }
                row.checksum = String(args[0])
                return { changes: 1 }
              },
            }
          }
          if (sql.includes('UPDATE asset_files')) {
            return { run: () => ({ changes: 1 }) }
          }
          return { all: () => [], get: () => undefined, run: vi.fn() }
        }),
        transaction: vi.fn((operation: () => void) => operation),
      } as never,
      {
        get: vi.fn(),
        updatePhotoCount: vi.fn(),
      } as never,
      {
        getBySessionProjection: vi.fn(() => rows),
        updateChecksum,
        countBySession: vi.fn(() => 1),
      } as never,
      { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
      { getDimensions: vi.fn() } as never,
      { get: vi.fn() } as never,
    )

    const result = await indexer.backfillChecksums('session')

    // The optimistic photos write fills the empty row; the checksum is no
    // longer written via photoRepo.updateChecksum.
    expect(updateChecksum).not.toHaveBeenCalled()
    expect(rows.find(row => row.id === 'pending')?.checksum).toBe(sha256(content))
    expect(result).toEqual({ processed: 1, backfilled: 1, skipped: 0 })
  })

  it('supports cancellation between batches', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-backfill-cancel-'))
    tempDirs.push(root)
    const pendingPath = path.join(root, 'pending.jpg')
    fs.writeFileSync(pendingPath, 'content')
    const indexer = new IndexService(
      {
        prepare: vi.fn(() => ({ all: () => [], get: () => undefined, run: () => ({ changes: 0 }) })),
        transaction: vi.fn((operation: () => void) => operation),
      } as never,
      { get: vi.fn(), updatePhotoCount: vi.fn() } as never,
      {
        getBySessionProjection: vi.fn(() => [
          { id: 'pending', filepath: pendingPath, checksum: '', status: 'pending' },
        ]),
        updateChecksum: vi.fn(),
        countBySession: vi.fn(() => 1),
      } as never,
      { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
      { getDimensions: vi.fn() } as never,
      { get: vi.fn() } as never,
    )
    let calls = 0
    const context = {
      throwIfCancelled: vi.fn(() => {
        if (++calls >= 2) throw new Error('cancelled')
      }),
      updateProgress: vi.fn(),
    }

    await expect(indexer.backfillChecksums('session', context as never))
      .rejects.toThrow('cancelled')
  })
})
