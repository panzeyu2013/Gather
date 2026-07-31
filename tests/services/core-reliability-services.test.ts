import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  JobCancelledError,
  JobService,
} from '../../desktop/src/main/services/jobs/job.service'
import { IndexService } from '../../desktop/src/main/services/indexer/index.service'
import type {
  AnalysisJobData,
  AnalysisJobStatus,
  JobCreateParams,
  JobProgressUpdate,
} from '@gather/shared'

const services: JobService[] = []
const temporaryDirectories: string[] = []

afterEach(async () => {
  await Promise.all(services.splice(0).map(service => service.stop()))
  for (const directory of temporaryDirectories.splice(0)) {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

async function waitFor(condition: () => boolean, timeoutMs = 1_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (!condition()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for test condition')
    await new Promise(resolve => setTimeout(resolve, 5))
  }
}

class FakeJobRepository {
  private sequence = 0
  private jobs = new Map<string, AnalysisJobData>()

  create(params: JobCreateParams): AnalysisJobData {
    const timestamp = new Date().toISOString()
    const job: AnalysisJobData = {
      id: `job-${++this.sequence}`,
      type: params.type,
      scopeType: params.scopeType,
      scopeId: params.scopeId,
      dedupeKey: params.dedupeKey,
      status: 'queued',
      priority: params.priority ?? 0,
      progressCurrent: 0,
      progressTotal: 0,
      progressMessage: '',
      inputFingerprint: params.inputFingerprint ?? '',
      modelId: params.modelId ?? '',
      modelVersion: params.modelVersion ?? '',
      checkpoint: params.checkpoint ?? {},
      attemptCount: 0,
      leaseOwner: '',
      heartbeatAt: '',
      errorCode: '',
      errorMessage: '',
      createdAt: timestamp,
      startedAt: '',
      finishedAt: '',
      updatedAt: timestamp,
    }
    this.jobs.set(job.id, job)
    return { ...job }
  }

  get(id: string): AnalysisJobData | null {
    const job = this.jobs.get(id)
    return job ? { ...job } : null
  }

  list(status?: AnalysisJobStatus): AnalysisJobData[] {
    return [...this.jobs.values()]
      .filter(job => !status || job.status === status)
      .map(job => ({ ...job }))
  }

  requestCancel(id: string): boolean {
    const job = this.jobs.get(id)
    if (!job || !['queued', 'running'].includes(job.status)) return false
    job.status = job.status === 'queued' ? 'cancelled' : 'cancelling'
    return true
  }

  retry(id: string): boolean {
    const job = this.jobs.get(id)
    if (!job || !['failed', 'interrupted', 'cancelled'].includes(job.status)) return false
    job.status = 'queued'
    return true
  }

  recoverStale(): number { return 0 }
  resumeInterrupted(types: AnalysisJobData['type'][]): number {
    let resumed = 0
    for (const job of this.jobs.values()) {
      if (job.status === 'interrupted' && types.includes(job.type)) {
        job.status = 'queued'
        resumed++
      }
    }
    return resumed
  }

  claim(id: string, leaseOwner: string): boolean {
    const job = this.jobs.get(id)
    if (!job || job.status !== 'queued') return false
    job.status = 'running'
    job.leaseOwner = leaseOwner
    job.attemptCount++
    return true
  }

  heartbeat(id: string, leaseOwner: string): boolean {
    const job = this.jobs.get(id)
    return Boolean(job && job.leaseOwner === leaseOwner &&
      ['running', 'cancelling'].includes(job.status))
  }

  updateProgress(id: string, leaseOwner: string, update: JobProgressUpdate): boolean {
    const job = this.jobs.get(id)
    if (!job || job.leaseOwner !== leaseOwner) return false
    job.progressCurrent = update.current ?? job.progressCurrent
    job.progressTotal = update.total ?? job.progressTotal
    job.progressMessage = update.message ?? job.progressMessage
    return true
  }

  finish(
    id: string,
    leaseOwner: string,
    status: 'succeeded' | 'failed' | 'cancelled',
    error?: { code: string; message: string },
  ): boolean {
    const job = this.jobs.get(id)
    if (!job || job.leaseOwner !== leaseOwner) return false
    job.status = status
    job.errorCode = error?.code ?? ''
    job.errorMessage = error?.message ?? ''
    return true
  }

  interrupt(id: string, leaseOwner: string): boolean {
    const job = this.jobs.get(id)
    if (!job || job.leaseOwner !== leaseOwner || job.status !== 'running') return false
    job.status = 'interrupted'
    job.errorCode = 'application_stopped'
    return true
  }

  clearCompleted(): number { return 0 }
}

describe('core reliability services', () => {
  it('cancels running work and consumes a retried queued job', async () => {
    const repo = new FakeJobRepository()
    const jobs = new JobService(repo as never)
    services.push(jobs)
    let attempts = 0
    jobs.registerExecutor('metadata.scan', async (_job, context) => {
      attempts++
      if (attempts === 1) {
        await new Promise<void>((_resolve, reject) => {
          context.signal.addEventListener('abort', () => reject(new JobCancelledError()), {
            once: true,
          })
        })
      }
      return true
    })
    jobs.start()

    const job = jobs.create({
      type: 'metadata.scan',
      scopeType: 'session',
      scopeId: 'session',
      dedupeKey: 'scan:session',
    })
    await waitFor(() => repo.get(job.id)?.status === 'running')
    expect(jobs.cancel(job.id)).toBe(true)
    await waitFor(() => repo.get(job.id)?.status === 'cancelled')

    expect(jobs.retry(job.id)).toBe(true)
    await waitFor(() => repo.get(job.id)?.status === 'succeeded')
    expect(repo.get(job.id)?.attemptCount).toBe(2)
  })

  it('records graceful shutdown as interrupted and resumes it on the next start', async () => {
    const repo = new FakeJobRepository()
    const first = new JobService(repo as never)
    services.push(first)
    first.registerExecutor('metadata.scan', async (_job, context) => {
      await new Promise<void>((_resolve, reject) => {
        context.signal.addEventListener('abort', () => reject(new JobCancelledError()), {
          once: true,
        })
      })
    })
    first.start()
    const job = first.create({
      type: 'metadata.scan',
      scopeType: 'session',
      scopeId: 'session',
      dedupeKey: 'resume:session',
    })
    await waitFor(() => repo.get(job.id)?.status === 'running')
    await first.stop()
    expect(repo.get(job.id)?.status).toBe('interrupted')

    const restarted = new JobService(repo as never)
    services.push(restarted)
    restarted.registerExecutor('metadata.scan', async () => true)
    restarted.start()
    await waitFor(() => repo.get(job.id)?.status === 'succeeded')
    expect(repo.get(job.id)?.attemptCount).toBe(2)
  })

  it('reindexes changed files and marks disappeared files without SQL variable limits', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-index-test-'))
    temporaryDirectories.push(root)
    const changedPath = path.join(root, 'changed.jpg')
    const newPath = path.join(root, 'new.jpg')
    const missingPath = path.join(root, 'missing.jpg')
    fs.writeFileSync(changedPath, 'changed-content')
    fs.writeFileSync(newPath, 'new-content')
    const updateIndexedFile = vi.fn()
    const updateChecksum = vi.fn()
    const addPhotos = vi.fn(() => ({ added: 1, skipped: 0 }))
    const markMissing = vi.fn()
    const photos = [
      {
        id: 'changed',
        filepath: changedPath,
        asset_file_id: 'file-changed',
        status: 'pending',
      },
      {
        id: 'missing',
        filepath: missingPath,
        asset_file_id: 'file-missing',
        status: 'pending',
      },
    ]
    const indexer = new IndexService(
      {
        prepare: vi.fn(() => ({
          all: () => [
            { id: 'file-changed', file_size: 1, file_mtime_ms: 1, checksum: '' },
            { id: 'file-missing', file_size: 1, file_mtime_ms: 1, checksum: '' },
          ],
          run: vi.fn(),
        })),
        transaction: vi.fn((operation: () => void) => operation),
      } as never,
      {
        get: vi.fn(() => ({ id: 'session', source_path: root })),
        updatePhotoCount: vi.fn(),
      } as never,
      {
        getBySession: vi.fn(() => photos),
        addPhotos,
        updateIndexedFile,
        updateChecksum,
        markMissing,
        countBySession: vi.fn(() => 2),
      } as never,
      { backfillSession: vi.fn(), relinkMovedFile: vi.fn(() => null) } as never,
      { getDimensions: vi.fn(async () => ({ width: 100, height: 80 })) } as never,
      { get: vi.fn((_key: string, fallback: string) => fallback) } as never,
    )

    const result = await indexer.scanSession('session')

    expect(result.added).toBe(1)
    expect(updateIndexedFile).toHaveBeenCalledWith('changed', 100, 80, true)
    expect(markMissing).toHaveBeenCalledWith(['missing'])
    expect(addPhotos).toHaveBeenCalledWith('session', [
      expect.objectContaining({ filepath: newPath, width: 100, height: 80 }),
    ], 'index')
  })
})
