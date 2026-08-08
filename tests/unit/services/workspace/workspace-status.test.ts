import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { WorkspaceStatusService, OFFLINE_PHOTOS_TTL_MS } from '../../../../desktop/src/main/services/workspace/workspace-status.service'
import { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
import { AnalysisJobRepository } from '../../../../desktop/src/main/db/repositories/analysis-job.repo'
import { JobService } from '../../../../desktop/src/main/services/jobs/job.service'
import { SCHEMA_SQL, INDEX_SQL } from '../../../../desktop/src/main/db/schema'
import type { MetadataSyncSummary } from '@gather/shared'

const databases: BetterSqlite3.Database[] = []

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

function emptySummary(): MetadataSyncSummary {
  return {
    sessionId: '',
    pending: 0,
    writing: 0,
    written: 0,
    failed: 0,
    conflict: 0,
    synced: 0,
    items: [],
  }
}

interface Harness {
  db: BetterSqlite3.Database
  sessionId: string
  service: WorkspaceStatusService
  summary: MetadataSyncSummary
  setSummary: (patch: Partial<MetadataSyncSummary>) => void
}

function build(syncSummary?: Partial<MetadataSyncSummary>): Harness {
  const db = createDb()
  const sessionRepo = new SessionRepository(wrap(db))
  const session = sessionRepo.create('Workspace', 'folder')
  const summary = { ...emptySummary(), sessionId: session.id, ...syncSummary }
  const setSummary = (patch: Partial<MetadataSyncSummary>): void => {
    Object.assign(summary, patch)
  }
  const service = new WorkspaceStatusService(
    wrap(db),
    sessionRepo,
    new PhotoRepository(wrap(db)),
    { getSummary: vi.fn(() => summary) } as never,
  )
  return { db, sessionId: session.id, service, summary, setSummary }
}

function addPhoto(db: BetterSqlite3.Database, sessionId: string, id: string, status = 'pending'): void {
  const now = new Date().toISOString()
  db.prepare(`
    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, width, height, created_at, updated_at)
    VALUES (?, ?, ?, ?, '', ?, '{}', '{}', 100, 80, ?, ?)
  `).run(id, sessionId, `/tmp/${id}.jpg`, `${id}.jpg`, status, now, now)
}

function addJob(
  db: BetterSqlite3.Database,
  sessionId: string,
  options: {
    id: string
    type?: string
    status: string
    updatedAt: string
    progressCurrent?: number
    progressTotal?: number
    errorMessage?: string
    errorCode?: string
  },
): void {
  db.prepare(`
    INSERT INTO analysis_jobs (
      id, type, scope_type, scope_id, dedupe_key, status, priority,
      progress_current, progress_total, progress_message, error_message, error_code,
      input_fingerprint, model_id, model_version, checkpoint_json, attempt_count,
      lease_owner, heartbeat_at, cancel_requested_at, created_at, started_at, finished_at, updated_at
    ) VALUES (?, ?, 'session', ?, ?, ?, 0, ?, ?, '', ?, ?, '', '', '', '{}', 0, '', '', '', ?, '', ?, ?)
  `).run(
    options.id,
    options.type ?? 'metadata.scan',
    sessionId,
    `${options.type ?? 'metadata.scan'}:${sessionId}`,
    options.status,
    options.progressCurrent ?? 0,
    options.progressTotal ?? 0,
    options.errorMessage ?? '',
    options.errorCode ?? '',
    options.updatedAt,
    options.updatedAt,
    options.updatedAt,
  )
}

function addAnalysisRun(
  db: BetterSqlite3.Database,
  sessionId: string,
  options: {
    kind: 'similarity' | 'face'
    indexSeq: number
    status?: 'ok' | 'failed'
    finishedAt?: string
  },
): void {
  db.prepare(`
    INSERT INTO analysis_runs (session_id, kind, photo_count, index_seq, started_at, finished_at, params, status)
    VALUES (?, ?, 1, ?, ?, ?, '{}', ?)
  `).run(
    sessionId,
    options.kind,
    options.indexSeq,
    options.finishedAt ?? new Date().toISOString(),
    options.finishedAt ?? new Date().toISOString(),
    options.status ?? 'ok',
  )
}

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
  for (const db of databases.splice(0)) db.close()
})

describe('WorkspaceStatusService stage derivation', () => {
  it('returns null for an unknown session', () => {
    const { service } = build()
    expect(service.getStatus('missing-session')).toBeNull()
  })

  it('reports created for a session without photos', () => {
    const { service, sessionId } = build()
    expect(service.getStatus(sessionId)?.stage).toBe('created')
  })

  it('reports imported once photos exist', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    const status = service.getStatus(sessionId)!
    expect(status.stage).toBe('imported')
    expect(status.softFlags).toEqual({ culled: false, exported: false })
  })

  it('reports indexed after a succeeded metadata.scan job', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    expect(service.getStatus(sessionId)?.stage).toBe('indexed')
  })

  it('treats active index work after a succeeded scan as not indexed', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addJob(db, sessionId, { id: 'scan-2', status: 'queued', updatedAt: '2026-08-08T00:01:00.000Z' })
    expect(service.getStatus(sessionId)?.stage).toBe('imported')
  })

  it('reports analyzed for a non-stale similarity run', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    const status = service.getStatus(sessionId)!
    expect(status.stage).toBe('analyzed')
    expect(status.staleAnalyses).toEqual([])
  })

  it('falls back to indexed when the similarity run becomes stale', () => {
    const { db, service, sessionId } = build()
    const sessionRepo = new SessionRepository(wrap(db))
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    sessionRepo.bumpIndexSeq(sessionId)
    const status = service.getStatus(sessionId)!
    expect(status.stage).toBe('indexed')
    expect(status.staleAnalyses).toHaveLength(1)
    expect(status.staleAnalyses[0]?.kind).toBe('similarity')
    expect(status.staleAnalyses[0]?.lastRunAt).not.toBe('')
  })

  it('reports indexing progress from the active scan job', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, {
      id: 'scan-1',
      status: 'running',
      updatedAt: '2026-08-08T00:00:00.000Z',
      progressCurrent: 25,
      progressTotal: 100,
    })
    const status = service.getStatus(sessionId)!
    expect(status.indexing).toEqual({ total: 100, done: 25, percent: 25, status: 'active' })
    expect(status.stage).toBe('imported')
  })

  it('reports queued scans as active even with zero progress', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'queued', updatedAt: '2026-08-08T00:00:00.000Z' })
    const status = service.getStatus(sessionId)!
    expect(status.indexing).toEqual({ total: 0, done: 0, percent: 0, status: 'active' })
    expect(status.recommendedNext).toEqual({ action: 'scan_incomplete', target: 'index' })
  })

  it('reports failed scans as failed, not settled', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'failed', updatedAt: '2026-08-08T00:00:00.000Z' })
    const status = service.getStatus(sessionId)!
    expect(status.indexing).toEqual({ total: 0, done: 0, percent: 0, status: 'failed' })
    expect(status.stage).toBe('imported')
    expect(status.recommendedNext).toEqual({ action: 'scan_incomplete', target: 'index' })
  })

  it('reports zero idle indexing when no scan job is active', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    expect(service.getStatus(sessionId)?.indexing).toEqual({ total: 0, done: 0, percent: 0, status: 'idle' })
  })
})

describe('WorkspaceStatusService stale analyses', () => {
  it('lists stale similarity and face runs with their last run time', () => {
    const { db, service, sessionId } = build()
    const sessionRepo = new SessionRepository(wrap(db))
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0, finishedAt: '2026-08-08T01:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'face', indexSeq: 0, finishedAt: '2026-08-08T02:00:00.000Z' })
    sessionRepo.bumpIndexSeq(sessionId)
    const status = service.getStatus(sessionId)!
    expect(status.staleAnalyses).toEqual([
      { kind: 'similarity', lastRunAt: '2026-08-08T01:00:00.000Z' },
      { kind: 'face', lastRunAt: '2026-08-08T02:00:00.000Z' },
    ])
  })

  it('omits failed runs and non-stale runs', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0, status: 'failed' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    expect(service.getStatus(sessionId)?.staleAnalyses).toEqual([])
  })
})

describe('WorkspaceStatusService offline photos TTL', () => {
  it('caches offline photos within the TTL and re-queries after it', () => {
    vi.useFakeTimers()
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')

    expect(service.getStatus(sessionId)!.offlinePhotos).toBe(0)
    db.prepare("UPDATE photos SET status = 'missing' WHERE id = 'photo-1'").run()

    // Within the 5-minute TTL the stale cached value is served.
    vi.advanceTimersByTime(OFFLINE_PHOTOS_TTL_MS - 1)
    expect(service.getStatus(sessionId)!.offlinePhotos).toBe(0)

    // Past the TTL the count is re-queried.
    vi.advanceTimersByTime(2)
    expect(service.getStatus(sessionId)!.offlinePhotos).toBe(1)
  })
})

describe('WorkspaceStatusService recommendedNext priority', () => {
  it('scan_incomplete wins over xmp conflicts', () => {
    const { db, service, sessionId } = build({ conflict: 3 })
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'queued', updatedAt: '2026-08-08T00:00:00.000Z' })
    expect(service.getStatus(sessionId)?.recommendedNext).toEqual({
      action: 'scan_incomplete',
      target: 'index',
    })
  })

  it('xmp conflicts beat stale analyses', () => {
    const { db, service, sessionId } = build({ conflict: 1 })
    const sessionRepo = new SessionRepository(wrap(db))
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    sessionRepo.bumpIndexSeq(sessionId)
    expect(service.getStatus(sessionId)?.recommendedNext).toEqual({
      action: 'resolve_conflicts',
      target: 'metadata',
    })
  })

  it('stale analyses beat failed jobs', () => {
    const { db, service, sessionId } = build()
    const sessionRepo = new SessionRepository(wrap(db))
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    sessionRepo.bumpIndexSeq(sessionId)
    addJob(db, sessionId, {
      id: 'job-1',
      type: 'quality.score',
      status: 'failed',
      updatedAt: '2026-08-08T00:02:00.000Z',
      errorMessage: 'boom',
    })
    expect(service.getStatus(sessionId)?.recommendedNext).toEqual({
      action: 're_analyze',
      target: 'similarity',
    })
  })

  it('failed jobs surface when nothing else is pending', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    addJob(db, sessionId, {
      id: 'job-1',
      type: 'quality.score',
      status: 'failed',
      updatedAt: '2026-08-08T00:02:00.000Z',
      errorMessage: 'boom',
    })
    const status = service.getStatus(sessionId)!
    expect(status.recommendedNext).toEqual({ action: 'retry_jobs', target: 'jobs' })
    expect(status.failedJobs).toEqual([
      { id: 'job-1', type: 'quality.score', message: 'boom' },
    ])
  })

  it('progresses to culling then export when healthy', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addAnalysisRun(db, sessionId, { kind: 'similarity', indexSeq: 0 })
    expect(service.getStatus(sessionId)?.recommendedNext).toEqual({
      action: 'start_culling',
      target: 'culling',
    })

    db.prepare(`
      INSERT INTO writeback_items (photo_id, photo_path, session_id, module, keywords, attributes_json, xmp_path, backup_path, xmp_status, error_message, last_attempt_at)
      VALUES ('photo-1', '/tmp/photo-1.jpg', ?, 'culling', '[]', '{}', '/tmp/photo-1.xmp', '', 'written', '', '')
    `).run(sessionId)
    expect(service.getStatus(sessionId)?.recommendedNext).toEqual({
      action: 'export',
      target: 'export',
    })

    addJob(db, sessionId, {
      id: 'export-1',
      type: 'export.execute',
      status: 'succeeded',
      updatedAt: '2026-08-08T00:03:00.000Z',
    })
    expect(service.getStatus(sessionId)?.recommendedNext).toBeNull()
  })
})

describe('WorkspaceStatusService soft flags and counts', () => {
  it('culled is true when a culling writeback item was written back', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    db.prepare(`
      INSERT INTO writeback_items (photo_id, photo_path, session_id, module, keywords, attributes_json, xmp_path, backup_path, xmp_status, error_message, last_attempt_at)
      VALUES ('photo-1', '/tmp/photo-1.jpg', ?, 'culling', '[]', '{}', '/tmp/photo-1.xmp', '', 'written', '', '')
    `).run(sessionId)
    expect(service.getStatus(sessionId)?.softFlags.culled).toBe(true)
  })

  it('culled is true when the culling outbox reached synced', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    const now = new Date().toISOString()
    db.prepare(`
      INSERT INTO metadata_outbox (xmp_path, photo_path, patch_json, dirty_fields, source_module, revision, persisted_revision, status, updated_at)
      VALUES ('/tmp/photo-1.xmp', '/tmp/photo-1.jpg', '{}', '[]', 'culling', 1, 0, 'synced', ?)
    `).run(now)
    db.prepare(`
      INSERT INTO metadata_outbox_sessions (xmp_path, session_id, confirmed_at, linked_at)
      VALUES ('/tmp/photo-1.xmp', ?, '', ?)
    `).run(sessionId, now)
    expect(service.getStatus(sessionId)?.softFlags.culled).toBe(true)
  })

  it('exported is true after a succeeded export job', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, {
      id: 'export-1',
      type: 'export.execute',
      status: 'succeeded',
      updatedAt: '2026-08-08T00:03:00.000Z',
    })
    expect(service.getStatus(sessionId)?.softFlags.exported).toBe(true)
  })

  it('folds failed xmp rows into pending and reports conflicts', () => {
    const { service, sessionId, setSummary } = build()
    setSummary({ pending: 2, failed: 1, conflict: 4 })
    const status = service.getStatus(sessionId)!
    expect(status.xmp).toEqual({ pending: 3, conflict: 4 })
  })

  it('prefers error_message over error_code for failed job messages', () => {
    const { db, service, sessionId } = build()
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, {
      id: 'job-1',
      type: 'export.execute',
      status: 'failed',
      updatedAt: '2026-08-08T00:03:00.000Z',
      errorMessage: 'disk full',
      errorCode: 'worker_error',
    })
    addJob(db, sessionId, {
      id: 'job-2',
      type: 'thumbnail.build',
      status: 'failed',
      updatedAt: '2026-08-08T00:04:00.000Z',
      errorCode: 'worker_error',
    })
    const status = service.getStatus(sessionId)!
    expect(status.failedJobs).toEqual([
      { id: 'job-2', type: 'thumbnail.build', message: 'worker_error' },
      { id: 'job-1', type: 'export.execute', message: 'disk full' },
    ])
  })
})

describe('WorkspaceStatusService clear_completed stage-evidence protection', () => {
  it('keeps the workspace indexed after clear_completed (stage evidence survives)', () => {
    const { db, service, sessionId } = build()
    const jobs = new JobService(new AnalysisJobRepository(wrap(db)))
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'succeeded', updatedAt: '2026-08-08T00:00:00.000Z' })
    addJob(db, sessionId, {
      id: 'export-1',
      type: 'export.execute',
      status: 'succeeded',
      updatedAt: '2026-08-08T00:03:00.000Z',
    })
    // A completed non-evidence job is cleared normally.
    addJob(db, sessionId, {
      id: 'thumb-1',
      type: 'thumbnail.build',
      status: 'succeeded',
      updatedAt: '2026-08-08T00:04:00.000Z',
    })

    expect(jobs.clearCompleted()).toBe(1)

    const status = service.getStatus(sessionId)!
    // The succeeded metadata.scan row is stage evidence: it must survive so a
    // fully indexed workspace does not regress to imported / scan_incomplete.
    expect(status.stage).toBe('indexed')
    expect(status.recommendedNext?.action).not.toBe('scan_incomplete')
    expect(status.softFlags.exported).toBe(true)
  })

  it('keeps failed scan evidence so the failure signal survives clear_completed', () => {
    const { db, service, sessionId } = build()
    const jobs = new JobService(new AnalysisJobRepository(wrap(db)))
    addPhoto(db, sessionId, 'photo-1')
    addJob(db, sessionId, { id: 'scan-1', status: 'failed', updatedAt: '2026-08-08T00:00:00.000Z', errorMessage: 'io' })
    addJob(db, sessionId, {
      id: 'job-1',
      type: 'quality.score',
      status: 'failed',
      updatedAt: '2026-08-08T00:02:00.000Z',
      errorMessage: 'boom',
    })

    jobs.clearCompleted()

    const status = service.getStatus(sessionId)!
    // The metadata.scan row is the failed-signal source (the Dashboard/CC
    // "index failed" seed), so it must survive clearing and stay in failedJobs;
    // the quality row is not stage evidence and is cleared normally.
    expect(status.failedJobs).toEqual([
      { id: 'scan-1', type: 'metadata.scan', message: 'io' },
    ])
    expect(status.indexing.status).toBe('failed')
  })
})
