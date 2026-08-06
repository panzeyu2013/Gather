import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-jobs-repo-'))

vi.mock('electron', () => ({
  app: {
    getPath: () => userDataDir,
  },
}))

import { Database } from '../../../../desktop/src/main/db/database'
import { runMigrations } from '../../../../desktop/src/main/db/migrations'
import { AnalysisJobRepository } from '../../../../desktop/src/main/db/repositories/analysis-job.repo'
import type { JobCreateParams } from '@gather/shared'

let db: Database
let repo: AnalysisJobRepository

function createParams(overrides: Partial<JobCreateParams> = {}): JobCreateParams {
  return {
    type: 'metadata.scan',
    scopeType: 'session',
    scopeId: 'session-1',
    dedupeKey: 'scan:session-1',
    priority: 0,
    ...overrides,
  }
}

beforeEach(async () => {
  for (const suffix of ['', '-wal', '-shm']) {
    fs.rmSync(path.join(userDataDir, `gather.db${suffix}`), { force: true })
  }
  db = new Database()
  await runMigrations(db)
  repo = new AnalysisJobRepository(db)
})

afterEach(() => {
  db.close()
})

describe('AnalysisJobRepository state machine', () => {
  it('creates a queued job and dedupes against active work', () => {
    const created = repo.create(createParams())
    expect(created.status).toBe('queued')
    expect(created.attemptCount).toBe(0)

    // Same dedupe key while active returns the existing job instead of failing.
    const duplicate = repo.create(createParams())
    expect(duplicate.id).toBe(created.id)

    // A finished job does not block a new run with the same key.
    repo.claim(created.id, 'worker-1')
    repo.finish(created.id, 'worker-1', 'succeeded')
    const rerun = repo.create(createParams())
    expect(rerun.id).not.toBe(created.id)
  })

  it('claims, heartbeats and finishes a job under the lease owner', () => {
    const job = repo.create(createParams())
    expect(repo.claim(job.id, 'worker-1')).toBe(true)
    expect(repo.get(job.id)?.status).toBe('running')
    expect(repo.get(job.id)?.attemptCount).toBe(1)

    // A second claim while running is rejected.
    expect(repo.claim(job.id, 'worker-2')).toBe(false)
    // Heartbeat from the wrong owner is rejected.
    expect(repo.heartbeat(job.id, 'worker-2')).toBe(false)
    expect(repo.heartbeat(job.id, 'worker-1')).toBe(true)

    expect(repo.finish(job.id, 'worker-2', 'failed')).toBe(false)
    expect(repo.finish(job.id, 'worker-1', 'succeeded')).toBe(true)
    expect(repo.get(job.id)?.status).toBe('succeeded')
  })

  it('tracks progress and checkpoints on the live job', () => {
    const job = repo.create(createParams())
    repo.claim(job.id, 'worker-1')
    expect(repo.updateProgress(job.id, 'worker-1', {
      current: 3,
      total: 10,
      message: 'working',
      checkpoint: { offset: 2 },
    })).toBe(true)

    const updated = repo.get(job.id)!
    expect(updated.progressCurrent).toBe(3)
    expect(updated.progressTotal).toBe(10)
    expect(updated.progressMessage).toBe('working')
    expect(updated.checkpoint).toEqual({ offset: 2 })

    // Progress on a finished job is rejected.
    repo.finish(job.id, 'worker-1', 'succeeded')
    expect(repo.updateProgress(job.id, 'worker-1', { current: 5 })).toBe(false)
  })

  it('cancels queued and running jobs distinctly, then retries failed ones', () => {
    const queued = repo.create(createParams({ dedupeKey: 'cancel-queued' }))
    const running = repo.create(createParams({ dedupeKey: 'cancel-running' }))
    repo.claim(running.id, 'worker-1')

    expect(repo.requestCancel(queued.id)).toBe(true)
    expect(repo.get(queued.id)?.status).toBe('cancelled')
    expect(repo.requestCancel(running.id)).toBe(true)
    expect(repo.get(running.id)?.status).toBe('cancelling')

    // The worker confirms the cancellation; retry() then accepts the
    // cancelled job and resets the lease.
    expect(repo.finish(running.id, 'worker-1', 'cancelled')).toBe(true)
    expect(repo.retry(running.id)).toBe(true)
    const retried = repo.get(running.id)!
    expect(retried.status).toBe('queued')
    expect(retried.leaseOwner).toBe('')
    expect(retried.errorMessage).toBe('')
  })

  it('marks abandoned workers as interrupted via the heartbeat cutoff', () => {
    const running = repo.create(createParams({ dedupeKey: 'stale-1' }))
    const fresh = repo.create(createParams({ dedupeKey: 'stale-2' }))
    repo.claim(running.id, 'worker-1')
    repo.claim(fresh.id, 'worker-2')
    repo.heartbeat(fresh.id, 'worker-2')
    // The stale worker's last heartbeat is ancient, far beyond the lease cutoff.
    db.prepare(
      "UPDATE analysis_jobs SET heartbeat_at = '2000-01-01T00:00:00.000Z' WHERE id = ?",
    ).run(running.id)

    expect(repo.recoverStale()).toBe(1)
    const recovered = repo.get(running.id)!
    expect(recovered.status).toBe('interrupted')
    expect(recovered.errorCode).toBe('worker_lost')
    expect(repo.get(fresh.id)?.status).toBe('running')
  })

  it('resumes interrupted jobs of the selected types only', () => {
    const scan = repo.create(createParams({ dedupeKey: 'resume-scan' }))
    const face = repo.create(createParams({ type: 'face.analyze', dedupeKey: 'resume-face' }))
    for (const id of [scan.id, face.id]) {
      repo.claim(id, 'worker-1')
      repo.interrupt(id, 'worker-1')
    }
    repo.create(createParams({ dedupeKey: 'succeeded-job' }))

    const resumed = repo.resumeInterrupted(['metadata.scan'])
    expect(resumed).toBe(1)
    expect(repo.get(scan.id)?.status).toBe('queued')
    expect(repo.get(face.id)?.status).toBe('interrupted')
  })

  it('clears only completed jobs', () => {
    const done = repo.create(createParams({ dedupeKey: 'clear-done' }))
    const kept = repo.create(createParams({ dedupeKey: 'clear-kept' }))
    repo.claim(done.id, 'worker-1')
    repo.finish(done.id, 'worker-1', 'succeeded')

    expect(repo.clearCompleted()).toBe(1)
    expect(repo.get(done.id)).toBeNull()
    expect(repo.get(kept.id)).not.toBeNull()
  })
})
