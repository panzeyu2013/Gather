import { afterEach, describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { stat as realStat } from 'node:fs/promises'
import { IndexService } from '../../../../desktop/src/main/services/indexer/index.service'

const tempDirs: string[] = []

afterEach(() => {
  vi.restoreAllMocks()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('IndexService incremental scan ghost photos', () => {
  it('marks a file missing when it disappears between directory listing and stat', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-ghost-'))
    tempDirs.push(root)
    const ghostPath = path.join(root, 'ghost.jpg')
    const okPath = path.join(root, 'ok.jpg')
    fs.writeFileSync(ghostPath, 'ghost-content')
    fs.writeFileSync(okPath, 'ok-content')

    // Simulate the TOCTOU race: the file is listed by the walk (it exists on
    // disk) but stat() fails when scanBatch processes it. Inject a stat that
    // throws for the ghost path only.
    const stat = vi.fn(async (filepath: string) => {
      if (filepath === ghostPath) throw new Error('ENOENT')
      return realStat(filepath)
    })

    const markMissing = vi.fn()
    const indexer = new IndexService(
      {
        prepare: vi.fn(() => ({ all: () => [], run: vi.fn() })),
        transaction: vi.fn((operation: () => void) => operation),
      } as never,
      {
        get: vi.fn(() => ({ id: 'session', source_path: root })),
        updatePhotoCount: vi.fn(),
      } as never,
      {
        getBySession: vi.fn(() => [
          { id: 'ghost', filepath: ghostPath, asset_file_id: 'file-ghost', status: 'pending' },
          { id: 'ok', filepath: okPath, asset_file_id: 'file-ok', status: 'pending' },
        ]),
        addPhotos: vi.fn(() => ({ added: 0, skipped: 0 })),
        updateIndexedFile: vi.fn(),
        updateChecksum: vi.fn(),
        markMissing,
        countBySession: vi.fn(() => 2),
      } as never,
      { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      { get: vi.fn((_key: string, fallback: string) => fallback) } as never,
    )
    indexer.stat = stat

    const result = await indexer.scanSession('session')

    expect(markMissing).toHaveBeenCalledWith(['ghost'])
    expect(result.missing).toBe(1)
    expect(result.failed).toEqual([])
  })
})
