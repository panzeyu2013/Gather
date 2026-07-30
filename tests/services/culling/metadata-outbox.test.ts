import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type {
  MetadataOutboxRow,
  MetadataOutboxStatus,
} from '../../../desktop/src/main/db/repositories/metadata-outbox.repo'
import { MetadataSyncCoordinator } from '../../../desktop/src/main/services/metadata/metadata-sync-coordinator'

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
  purgeOrphans(): void {}
  getRecoverable(): MetadataOutboxRow[] { return [] }
  markSessionSynced(): void {}
  delete(path: string): void { this.rows.delete(path) }
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
): MetadataSyncCoordinator {
  const writer = {
    backup: vi.fn(async () => ''),
    writeAttributes: vi.fn(writeAttributes),
    readAttributes: vi.fn(readAttributes),
    restore: vi.fn(),
  }
  return new MetadataSyncCoordinator(
    repo as never,
    { hasActiveForXmpPath: vi.fn(() => false) } as never,
    { selectSidecar: vi.fn(() => writer) } as never,
    { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
  )
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
})
