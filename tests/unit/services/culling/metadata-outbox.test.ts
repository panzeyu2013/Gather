import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import type {
  MetadataOutboxRow,
  MetadataOutboxStatus,
} from '../../../../desktop/src/main/db/repositories/metadata-outbox.repo'
import { MetadataSyncCoordinator } from '../../../../desktop/src/main/services/metadata/metadata-sync-coordinator'

const tempDirs: string[] = []

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

class FakeOutbox {
  rows = new Map<string, MetadataOutboxRow>()

  get(path: string): MetadataOutboxRow | null {
    return this.rows.get(path) ?? null
  }

  getBySession(sessionId: string): MetadataOutboxRow[] {
    return [...this.rows.values()].filter(row => row.owner_session_id === sessionId)
  }

  claim(path: string, revision: number): boolean {
    const row = this.rows.get(path)
    if (!row || row.revision !== revision || !['pending', 'failed'].includes(row.status)) {
      return false
    }
    row.status = 'writing'
    row.attempt_count++
    return true
  }

  markWritten(
    path: string,
    revision: number,
    fingerprint: string,
    values: Record<string, unknown>,
    backupPath: string,
  ): void {
    const row = this.rows.get(path)!
    row.persisted_revision = revision
    row.base_fingerprint = fingerprint
    row.base_values_json = JSON.stringify(values)
    row.backup_path = backupPath
    row.status = row.revision === revision ? 'written' : 'pending'
  }

  markStatus(path: string, status: MetadataOutboxStatus, error = ''): void {
    const row = this.rows.get(path)!
    row.status = status
    row.error_message = error
  }

  setBackupPath(path: string, backupPath: string): void {
    const row = this.rows.get(path)!
    if (!row.backup_path) row.backup_path = backupPath
  }

  initializeBaseline(
    path: string,
    baselineFingerprint: string,
    baselineValues: Record<string, unknown>,
  ): void {
    const row = this.rows.get(path)!
    if (!row.base_fingerprint) {
      row.base_fingerprint = baselineFingerprint
      row.base_values_json = JSON.stringify(baselineValues)
    }
  }

  recoverInterrupted(): void {}
  getRecoverable(): MetadataOutboxRow[] { return [] }
  markSessionSynced(): void {}
  delete(path: string): void { this.rows.delete(path) }
  resolveConflict(
    path: string,
    patch: Record<string, unknown>,
    dirtyFields: string[],
    baselineFingerprint: string,
    baselineValues: Record<string, unknown>,
    acceptRemote: boolean,
  ): void {
    if (acceptRemote) {
      this.rows.delete(path)
      return
    }
    const current = this.rows.get(path)!
    if (current.status !== 'conflict') return
    current.patch_json = JSON.stringify(patch)
    current.dirty_fields = JSON.stringify(dirtyFields)
    current.base_fingerprint = baselineFingerprint
    current.base_values_json = JSON.stringify(baselineValues)
    current.status = 'pending'
    current.revision++
  }
}

function row(
  xmpPath: string,
  photoPath: string,
  overrides: Partial<MetadataOutboxRow> = {},
): MetadataOutboxRow {
  return {
    xmp_path: xmpPath,
    owner_session_id: 'session',
    photo_path: photoPath,
    patch_json: JSON.stringify({ rating: 5 }),
    dirty_fields: JSON.stringify(['rating']),
    revision: 2,
    persisted_revision: 0,
    base_fingerprint: '',
    base_values_json: '{}',
    backup_path: '',
    status: 'pending',
    attempt_count: 0,
    error_message: '',
    updated_at: new Date().toISOString(),
    ...overrides,
  }
}

function createCoordinator(
  repo: FakeOutbox,
  writeAttributes: (photoPath: string, tags: Record<string, unknown>) => Promise<void>,
  readAttributes: (photoPath: string) => Promise<Record<string, unknown>>,
  db: unknown = {
    prepare: () => ({ all: () => [] }),
    transaction: (fn: () => void) => fn,
  },
): MetadataSyncCoordinator {
  const writer = {
    backup: vi.fn(async () => ''),
    writeAttributes: vi.fn(writeAttributes),
    readAttributes: vi.fn(readAttributes),
    restore: vi.fn(),
  }
  return new MetadataSyncCoordinator(
    repo as never,
    {
      hasActiveForXmpPath: vi.fn(() => false),
      discardPendingByXmpPath: vi.fn(() => 0),
    } as never,
    { selectSidecar: vi.fn(() => writer) } as never,
    { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
    db as never,
  )
}

function createRealDb(
  photos: Array<{ id: string; session_id: string; filepath: string }>,
): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  db.exec(`
    CREATE TABLE photos (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, filepath TEXT NOT NULL);
    CREATE TABLE photo_metadata_cache (
      photo_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
      keywords TEXT NOT NULL DEFAULT '[]', rating INTEGER NOT NULL DEFAULT 0,
      label TEXT NOT NULL DEFAULT '', cached_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE culling_decisions (
      session_id TEXT NOT NULL, photo_id TEXT NOT NULL,
      group_id TEXT NOT NULL DEFAULT '', decision TEXT NOT NULL DEFAULT 'pending',
      rating INTEGER NOT NULL DEFAULT 0 CHECK (rating BETWEEN 0 AND 5),
      color_label TEXT NOT NULL DEFAULT 'None' CHECK (
        color_label IN ('None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple')
      ),
      revision INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT '',
      UNIQUE(session_id, photo_id)
    );
  `)
  const insertPhoto = db.prepare(
    'INSERT INTO photos (id, session_id, filepath) VALUES (?, ?, ?)',
  )
  for (const photo of photos) insertPhoto.run(photo.id, photo.session_id, photo.filepath)
  return db
}

describe('metadata outbox coordinator', () => {
  it('persists the coalesced latest revision once', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A001.NEF')
    const xmpPath = path.join(dir, 'A001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    repo.rows.set(xmpPath, row(xmpPath, photoPath))

    const write = vi.fn(async (_path: string, tags: Record<string, unknown>) => {
      fs.writeFileSync(xmpPath, JSON.stringify(tags))
    })
    const coordinator = createCoordinator(
      repo,
      write,
      async () => JSON.parse(fs.readFileSync(xmpPath, 'utf8')) as Record<string, unknown>,
    )

    const summary = await coordinator.flushSession('session')

    expect(write).toHaveBeenCalledTimes(1)
    expect(write).toHaveBeenCalledWith(photoPath, expect.objectContaining({ rating: 5 }))
    expect(summary.written).toBe(1)
    expect(repo.get(xmpPath)).toMatchObject({
      revision: 2,
      persisted_revision: 2,
      status: 'written',
    })
  })

  it('blocks a write when another application changed the same dirty field', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A001.NEF')
    const xmpPath = path.join(dir, 'A001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 3 }))
    const info = fs.statSync(xmpPath)
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      revision: 3,
      persisted_revision: 2,
      base_fingerprint: `${info.size}:${Math.round(info.mtimeMs)}:not-the-current-hash`,
      base_values_json: JSON.stringify({ rating: 5 }),
      patch_json: JSON.stringify({ rating: 4 }),
    }))

    const coordinator = createCoordinator(
      repo,
      async (_path, tags) => {
        fs.writeFileSync(xmpPath, JSON.stringify(tags))
      },
      async () => JSON.parse(fs.readFileSync(xmpPath, 'utf8')) as Record<string, unknown>,
    )
    const summary = await coordinator.flushSession('session')

    expect(summary.conflict).toBe(1)
    expect(JSON.parse(fs.readFileSync(xmpPath, 'utf8'))).toEqual({ rating: 3 })
  })

  it('captures the initial baseline before the debounce window', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A002.NEF')
    const xmpPath = path.join(dir, 'A002.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 2 }))
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      revision: 1,
      patch_json: JSON.stringify({ rating: 5 }),
    }))
    const coordinator = createCoordinator(
      repo,
      async (_path, tags) => {
        fs.writeFileSync(xmpPath, JSON.stringify(tags))
      },
      async () => JSON.parse(fs.readFileSync(xmpPath, 'utf8')) as Record<string, unknown>,
    )

    coordinator.schedule(xmpPath, 60_000)
    await new Promise(resolve => setTimeout(resolve, 10))
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 3 }))
    const summary = await coordinator.flushSession('session')
    await coordinator.shutdown()

    expect(summary.conflict).toBe(1)
    expect(JSON.parse(fs.readFileSync(xmpPath, 'utf8'))).toEqual({ rating: 3 })
  })

  it('keeps immediate flushes within the global writer concurrency limit', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    let active = 0
    let peak = 0
    const values = new Map<string, Record<string, unknown>>()
    for (let index = 0; index < 6; index++) {
      const photoPath = path.join(dir, `A00${index}.NEF`)
      const xmpPath = path.join(dir, `A00${index}.xmp`)
      fs.writeFileSync(photoPath, 'raw')
      repo.rows.set(xmpPath, row(xmpPath, photoPath, {
        revision: 1,
        patch_json: JSON.stringify({ rating: index % 6 }),
      }))
    }
    const coordinator = createCoordinator(
      repo,
      async (photoPath, tags) => {
        active++
        peak = Math.max(peak, active)
        await new Promise(resolve => setTimeout(resolve, 10))
        values.set(photoPath, tags)
        const xmpPath = photoPath.replace(/\.[^.]+$/, '.xmp')
        fs.writeFileSync(xmpPath, JSON.stringify(tags))
        active--
      },
      async photoPath => values.get(photoPath) ?? {},
    )

    await coordinator.flushSession('session')

    expect(peak).toBeLessThanOrEqual(2)
    expect(values.size).toBe(6)
  })

  it('can keep the written sidecar while deleting only the recovery backup', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A010.NEF')
    const xmpPath = path.join(dir, 'A010.xmp')
    const backupPath = path.join(dir, 'A010.xmp.gather-backup')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, 'written metadata')
    fs.writeFileSync(backupPath, 'original metadata')
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      status: 'synced',
      backup_path: backupPath,
    }))
    const coordinator = createCoordinator(repo, async () => {}, async () => ({}))

    const summary = await coordinator.finalizeSession('session')

    expect(summary.items).toHaveLength(0)
    expect(fs.readFileSync(xmpPath, 'utf8')).toBe('written metadata')
    expect(fs.existsSync(backupPath)).toBe(false)
  })

  it('never deletes an external XMP after accepting all remote conflict values', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A011.NEF')
    const xmpPath = path.join(dir, 'A011.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 3 }))
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      status: 'conflict',
      base_values_json: JSON.stringify({ rating: 2 }),
      patch_json: JSON.stringify({ rating: 5 }),
      dirty_fields: JSON.stringify(['rating']),
    }))
    const coordinator = createCoordinator(
      repo,
      async () => {},
      async () => ({ rating: 3 }),
    )

    const summary = await coordinator.resolveConflict(
      'session',
      xmpPath,
      { rating: 'use_remote' },
    )
    const cleanup = await coordinator.cleanup('session')

    expect(summary.items).toEqual([])
    expect(cleanup.deletedCount).toBe(0)
    expect(JSON.parse(fs.readFileSync(xmpPath, 'utf8'))).toEqual({ rating: 3 })
  })

  it('syncs cache and decisions when accepting remote values with no label', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A012.NEF')
    const xmpPath = path.join(dir, 'A012.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 3 }))
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      status: 'conflict',
      base_values_json: JSON.stringify({ rating: 2 }),
      patch_json: JSON.stringify({ rating: 5 }),
      dirty_fields: JSON.stringify(['rating']),
    }))
    const db = createRealDb([{ id: 'photo-1', session_id: 'session', filepath: photoPath }])
    db.prepare(
      'INSERT INTO culling_decisions (session_id, photo_id, rating, color_label) VALUES (?, ?, ?, ?)',
    ).run('session', 'photo-1', 5, 'Green')

    const coordinator = createCoordinator(
      repo,
      async () => {},
      async () => ({ rating: 3 }),
      db,
    )
    await coordinator.resolveConflict('session', xmpPath, { rating: 'use_remote' })

    const decision = db.prepare(
      'SELECT rating, color_label FROM culling_decisions WHERE photo_id = ?',
    ).get('photo-1')
    expect(decision).toEqual({ rating: 3, color_label: 'None' })
    const cache = db.prepare(
      'SELECT rating, label FROM photo_metadata_cache WHERE photo_id = ?',
    ).get('photo-1')
    expect(cache).toEqual({ rating: 3, label: 'None' })
  })

  it('sanitizes non-standard external labels instead of rolling back', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A013.NEF')
    const xmpPath = path.join(dir, 'A013.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 5, label: 'VIP' }))
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      status: 'conflict',
      base_values_json: JSON.stringify({ rating: 2, label: 'Green' }),
      patch_json: JSON.stringify({ rating: 4, label: 'Green' }),
      dirty_fields: JSON.stringify(['rating', 'label']),
    }))
    const db = createRealDb([{ id: 'photo-1', session_id: 'session', filepath: photoPath }])
    db.prepare(
      'INSERT INTO culling_decisions (session_id, photo_id, rating, color_label) VALUES (?, ?, ?, ?)',
    ).run('session', 'photo-1', 4, 'Green')

    const coordinator = createCoordinator(
      repo,
      async () => {},
      async () => ({ rating: 5, label: 'VIP' }),
      db,
    )
    await coordinator.resolveConflict('session', xmpPath, { rating: 'use_remote', label: 'use_remote' })

    const decision = db.prepare(
      'SELECT rating, color_label FROM culling_decisions WHERE photo_id = ?',
    ).get('photo-1')
    expect(decision).toEqual({ rating: 5, color_label: 'None' })
    const cache = db.prepare(
      'SELECT rating, label FROM photo_metadata_cache WHERE photo_id = ?',
    ).get('photo-1')
    expect(cache).toEqual({ rating: 5, label: 'None' })
  })

  it('does not clear cached values when the remote sidecar is corrupt', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A014.NEF')
    const xmpPath = path.join(dir, 'A014.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, 'not-valid-xml {{{')
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      status: 'conflict',
      base_values_json: JSON.stringify({ rating: 2 }),
      patch_json: JSON.stringify({ rating: 5 }),
      dirty_fields: JSON.stringify(['rating']),
    }))
    const db = createRealDb([{ id: 'photo-1', session_id: 'session', filepath: photoPath }])
    db.prepare(
      'INSERT INTO culling_decisions (session_id, photo_id, rating, color_label) VALUES (?, ?, ?, ?)',
    ).run('session', 'photo-1', 5, 'Green')
    db.prepare(
      'INSERT INTO photo_metadata_cache (photo_id, session_id, keywords, rating, label) VALUES (?, ?, ?, ?, ?)',
    ).run('photo-1', 'session', '["keep"]', 5, 'Green')

    const coordinator = createCoordinator(
      repo,
      async () => {},
      async () => ({}),
      db,
    )
    await coordinator.resolveConflict('session', xmpPath, { rating: 'use_remote' })

    const decision = db.prepare(
      'SELECT rating, color_label FROM culling_decisions WHERE photo_id = ?',
    ).get('photo-1')
    expect(decision).toEqual({ rating: 5, color_label: 'Green' })
    const cache = db.prepare(
      'SELECT keywords, rating, label FROM photo_metadata_cache WHERE photo_id = ?',
    ).get('photo-1')
    expect(cache).toEqual({ keywords: '["keep"]', rating: 5, label: 'Green' })
  })

  it('completes an interrupted write instead of reporting a false conflict', async () => {
    const repo = new FakeOutbox()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-'))
    tempDirs.push(dir)
    const photoPath = path.join(dir, 'A015.NEF')
    const xmpPath = path.join(dir, 'A015.xmp')
    fs.writeFileSync(photoPath, 'raw')
    // The file already contains exactly what the interrupted write intended.
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 5 }))
    repo.rows.set(xmpPath, row(xmpPath, photoPath, {
      base_fingerprint: 'stale-pre-write-fingerprint',
      base_values_json: JSON.stringify({ rating: 1 }),
      patch_json: JSON.stringify({ rating: 5 }),
      dirty_fields: JSON.stringify(['rating']),
      backup_path: path.join(dir, 'A015.xmp.gather-backup'),
    }))

    const write = vi.fn(async () => {})
    const coordinator = createCoordinator(
      repo,
      write,
      async () => JSON.parse(fs.readFileSync(xmpPath, 'utf8')) as Record<string, unknown>,
    )
    const summary = await coordinator.flushSession('session')

    expect(summary.conflict).toBe(0)
    expect(write).not.toHaveBeenCalled()
    expect(repo.get(xmpPath)).toMatchObject({
      status: 'written',
      persisted_revision: 2,
      base_fingerprint: expect.stringMatching(/^\d+:\d+:/),
    })
  })
})
