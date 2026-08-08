import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import BetterSqlite3 from 'better-sqlite3'
import { MetadataSyncCoordinator } from '../../../../desktop/src/main/services/metadata/metadata-sync-coordinator'
import { MetadataOutboxRepository } from '../../../../desktop/src/main/db/repositories/metadata-outbox.repo'
import {
  aggregateSessionState,
  countOutboxStatuses,
  CaptureOneSessionState,
} from '../../../../desktop/src/main/services/capture-one/sync-state'

const tempDirs: string[] = []
const coordinators: MetadataSyncCoordinator[] = []

afterEach(async () => {
  // Sweep regardless of pass/fail: schedule() arms a 60 s write timer per
  // patch, and a failing assertion mid-test must not leak the open handle.
  await Promise.all(coordinators.splice(0).map(coordinator => coordinator.shutdown()))
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

const ACK = '2026-08-08T10:00:00.000Z'

function xmpPathOf(photoPath: string): string {
  return path.join(path.dirname(photoPath), `${path.basename(photoPath, path.extname(photoPath))}.xmp`)
}

/** Minimal real schema: sessions + the two metadata_outbox tables. */
function createRealDb(sessionId: string): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  db.exec(`
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY,
      reload_acked_at TEXT,
      updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE metadata_outbox (
      xmp_path TEXT PRIMARY KEY,
      owner_session_id TEXT NOT NULL,
      created_by_session_id TEXT,
      photo_path TEXT NOT NULL,
      patch_json TEXT NOT NULL DEFAULT '{}',
      dirty_fields TEXT NOT NULL DEFAULT '[]',
      source_module TEXT NOT NULL DEFAULT '',
      revision INTEGER NOT NULL DEFAULT 0,
      persisted_revision INTEGER NOT NULL DEFAULT 0,
      base_fingerprint TEXT NOT NULL DEFAULT '',
      base_values_json TEXT NOT NULL DEFAULT '{}',
      backup_path TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'pending',
      attempt_count INTEGER NOT NULL DEFAULT 0,
      error_message TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL
    );
    CREATE TABLE metadata_outbox_sessions (
      xmp_path TEXT NOT NULL REFERENCES metadata_outbox(xmp_path) ON DELETE CASCADE,
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      confirmed_at TEXT NOT NULL DEFAULT '',
      linked_at TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (xmp_path, session_id)
    );
  `)
  db.prepare('INSERT INTO sessions (id, reload_acked_at, updated_at) VALUES (?, NULL, ?)')
    .run(sessionId, new Date().toISOString())
  return db
}

interface Harness {
  coordinator: MetadataSyncCoordinator
  repo: MetadataOutboxRepository
  db: BetterSqlite3.Database
}

function createHarness(sessionId: string): Harness {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-reload-ack-'))
  tempDirs.push(dir)
  const db = createRealDb(sessionId)
  const repo = new MetadataOutboxRepository(db as never)
  const writer = {
    backup: vi.fn(async () => ''),
    writeAttributes: vi.fn(async (photoPath: string, tags: Record<string, unknown>) => {
      fs.writeFileSync(xmpPathOf(photoPath), JSON.stringify(tags))
    }),
    readAttributes: vi.fn(async (photoPath: string) => {
      return JSON.parse(fs.readFileSync(xmpPathOf(photoPath), 'utf8')) as Record<string, unknown>
    }),
    restore: vi.fn(),
  }
  const coordinator = new MetadataSyncCoordinator(
    repo,
    {
      hasActiveForXmpPath: vi.fn(() => false),
      discardPendingByXmpPath: vi.fn(() => 0),
    } as never,
    { selectSidecar: vi.fn(() => writer) } as never,
    { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
    db as never,
  )
  coordinators.push(coordinator)
  return { coordinator, repo, db }
}

function sessionAck(db: BetterSqlite3.Database, sessionId: string): string | null {
  const row = db.prepare('SELECT reload_acked_at FROM sessions WHERE id = ?')
    .get(sessionId) as { reload_acked_at: string | null }
  return row.reload_acked_at
}

function setAck(db: BetterSqlite3.Database, sessionId: string, iso: string): void {
  db.prepare('UPDATE sessions SET reload_acked_at = ?, updated_at = ? WHERE id = ?')
    .run(iso, new Date().toISOString(), sessionId)
}

function derivedState(db: BetterSqlite3.Database, repo: MetadataOutboxRepository, sessionId: string) {
  const rows = repo.getBySession(sessionId)
  return aggregateSessionState({
    counts: countOutboxStatuses(rows),
    reloadAckedAt: sessionAck(db, sessionId),
  })
}

/** Simulate the writeback/mutation flow: queue a patch then schedule it. */
function queuePatch(
  repo: MetadataOutboxRepository,
  coordinator: MetadataSyncCoordinator,
  sessionId: string,
  xmpPath: string,
  photoPath: string,
  patch: Record<string, unknown>,
  source: string,
): void {
  repo.mergePatch(xmpPath, sessionId, photoPath, { ...patch, source }, Object.keys(patch))
  coordinator.schedule(xmpPath, 60_000)
}

describe('reload-ack invalidation — new outbox activity must clear the session ack', () => {
  it('queuing a new row (batch2) after an ack clears the ack and the session derives c1Read', async () => {
    const sessionId = 'session'
    const { coordinator, repo, db } = createHarness(sessionId)
    const dir = path.dirname(tempDirs[tempDirs.length - 1])
    const photoPath = path.join(dir, 'A001.NEF')
    const xmpPath = path.join(dir, 'A001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 1 }))
    // Batch1 is synced and was loaded in Capture One (ack present): the
    // session was SafeToCleanup.
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 2 }, 'similarity')
    await coordinator.flushSession(sessionId)
    setAck(db, sessionId, ACK)
    coordinator.confirmSync(sessionId, 'similarity')
    expect(sessionAck(db, sessionId)).toBe(ACK)
    expect(derivedState(db, repo, sessionId)).toBe(CaptureOneSessionState.SafeToCleanup)

    // Batch2 is queued on top: the stale ack must be invalidated immediately.
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 5 }, 'similarity')
    expect(sessionAck(db, sessionId)).toBeNull()

    await coordinator.flushSession(sessionId)
    expect(repo.get(xmpPath)?.status).toBe('written')
    // Written rows mean the user has not confirmed the new generation yet.
    expect(derivedState(db, repo, sessionId)).toBe(CaptureOneSessionState.C1Read)
  })

  it('claiming a pre-existing pending row (crash window) also clears a surviving ack', async () => {
    const sessionId = 'session'
    const { coordinator, repo, db } = createHarness(sessionId)
    const dir = path.dirname(tempDirs[tempDirs.length - 1])
    const photoPath = path.join(dir, 'B001.NEF')
    const xmpPath = path.join(dir, 'B001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 1 }))
    // Row already pending while the ack somehow survived (crash between the
    // queue and the schedule hook — mergePatch without schedule): the write
    // path must clear it at claim time.
    repo.mergePatch(xmpPath, sessionId, photoPath, { rating: 3, source: 'culling' }, ['rating'])
    setAck(db, sessionId, ACK)

    await coordinator.flushSession(sessionId)

    expect(sessionAck(db, sessionId)).toBeNull()
    expect(repo.get(xmpPath)?.status).toBe('written')
  })

  it('confirm and cleanup keep the ack (no invalidation on synced/cleaned transitions)', async () => {
    const sessionId = 'session'
    const { coordinator, repo, db } = createHarness(sessionId)
    const dir = path.dirname(tempDirs[tempDirs.length - 1])
    const photoPath = path.join(dir, 'C001.NEF')
    const xmpPath = path.join(dir, 'C001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 1 }))
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 4 }, 'similarity')
    await coordinator.flushSession(sessionId)
    setAck(db, sessionId, ACK)

    const summary = coordinator.confirmSync(sessionId, 'similarity')
    expect(summary.synced).toBe(1)
    expect(sessionAck(db, sessionId)).toBe(ACK)
    const cleanup = await coordinator.cleanup(sessionId, 'similarity')
    expect(cleanup.deletedCount).toBe(1)
    expect(sessionAck(db, sessionId)).toBe(ACK)
  })
})

describe('main-side reload-ack guards', () => {
  it('confirmSync rejects with XMP_RELOAD_NOT_ACKED when the ack is missing', async () => {
    const sessionId = 'session'
    const { coordinator, repo } = createHarness(sessionId)
    const dir = path.dirname(tempDirs[tempDirs.length - 1])
    const photoPath = path.join(dir, 'D001.NEF')
    const xmpPath = path.join(dir, 'D001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 1 }))
    // All rows already synced (legacy or stale-view race), but no ack.
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 5 }, 'similarity')
    repo.markStatus(xmpPath, 'synced')

    expect(() => coordinator.confirmSync(sessionId, 'similarity'))
      .toThrow('XMP_RELOAD_NOT_ACKED')
  })

  it('cleanup rejects with XMP_RELOAD_NOT_ACKED when the ack is missing', async () => {
    const sessionId = 'session'
    const { coordinator, repo } = createHarness(sessionId)
    const dir = path.dirname(tempDirs[tempDirs.length - 1])
    const photoPath = path.join(dir, 'E001.NEF')
    const xmpPath = path.join(dir, 'E001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 1 }))
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 5 }, 'similarity')
    repo.markStatus(xmpPath, 'synced')

    await expect(coordinator.cleanup(sessionId, 'similarity'))
      .rejects.toThrow('XMP_RELOAD_NOT_ACKED')
  })

  it('cleanup with nothing to restore does not demand an ack', async () => {
    const sessionId = 'session'
    const { coordinator } = createHarness(sessionId)
    const result = await coordinator.cleanup(sessionId, 'similarity')
    expect(result).toEqual({ deletedCount: 0, errors: [] })
  })
})

describe('batch2-after-ack full sequence — SafeToCleanup unreachable without a fresh reload', () => {
  it('a stale ack can never carry the session through confirm to safeToCleanup', async () => {
    const sessionId = 'session'
    const { coordinator, repo, db } = createHarness(sessionId)
    const dir = path.dirname(tempDirs[tempDirs.length - 1])
    const photoPath = path.join(dir, 'F001.NEF')
    const xmpPath = path.join(dir, 'F001.xmp')
    fs.writeFileSync(photoPath, 'raw')
    fs.writeFileSync(xmpPath, JSON.stringify({ rating: 1 }))

    // Batch1: write → reload (ack) → confirm → synced → SafeToCleanup.
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 2 }, 'similarity')
    await coordinator.flushSession(sessionId)
    setAck(db, sessionId, ACK)
    coordinator.confirmSync(sessionId, 'similarity')
    expect(derivedState(db, repo, sessionId)).toBe(CaptureOneSessionState.SafeToCleanup)

    // Batch2 lands without a fresh reload: the ack is invalidated and the
    // renderer gate falls back to c1Read; the main-side guard refuses confirm.
    queuePatch(repo, coordinator, sessionId, xmpPath, photoPath, { rating: 5 }, 'similarity')
    expect(sessionAck(db, sessionId)).toBeNull()
    await coordinator.flushSession(sessionId)
    expect(derivedState(db, repo, sessionId)).toBe(CaptureOneSessionState.C1Read)
    expect(() => coordinator.confirmSync(sessionId, 'similarity'))
      .toThrow('XMP_RELOAD_NOT_ACKED')
    expect(derivedState(db, repo, sessionId)).toBe(CaptureOneSessionState.C1Read)

    // Only a fresh reload (a new ack) reopens the confirm path.
    setAck(db, sessionId, ACK)
    coordinator.confirmSync(sessionId, 'similarity')
    expect(derivedState(db, repo, sessionId)).toBe(CaptureOneSessionState.SafeToCleanup)
  })
})
