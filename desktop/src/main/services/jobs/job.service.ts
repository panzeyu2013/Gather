import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { AnalysisJobRepository } from '../../db/repositories/analysis-job.repo'
import type { AnalysisJobStatus, JobCreateParams, JobProgressUpdate, AnalysisJobData } from '@gather/shared'

export interface JobRunContext {
  signal: AbortSignal
  updateProgress(update: JobProgressUpdate): void
  updateCheckpoint(checkpoint: Record<string, unknown>): void
  throwIfCancelled(): void
}

type JobExecutor = (job: AnalysisJobData, context: JobRunContext) => Promise<unknown>
type JobProgressSink = (job: AnalysisJobData, update: JobProgressUpdate) => void
const MAX_CONCURRENT_JOBS = 2
const PROGRESS_WRITE_INTERVAL_MS = 250

// throwIfCancelled is the hottest path in the analysis/indexing loops (once
// per photo/file), so the persisted-status check is throttled: the AbortSignal
// check stays synchronous on every call, while the DB query that catches a
// 'cancelling' status runs at most every 50 calls or every 500ms. cancel()
// aborts the controller synchronously, so the signal alone never misses an
// in-process cancel; the DB check remains as a cross-path backstop.
const CANCEL_DB_CHECK_EVERY = 50
const CANCEL_DB_CHECK_INTERVAL_MS = 500

// Job types whose terminal rows double as workspace-status stage evidence
// (workspace-status.service.ts latestScanJob / hasSuccessfulExport). They are
// excluded from jobs.clear_completed so "清理已完成" never regresses a fully
// indexed/exported workspace back to imported (design_improvements.md 1.4.3).
// Bounded growth: metadata.scan is deduplicated to one row per session and the
// export.execute rows are the only place the exported soft flag lives.
// Deriving "indexed" from sessions.index_seq instead would be unreliable: the
// seq is bumped only when a scan commits real changes, so a no-op success
// (e.g. a scan over photos already inserted at create time) leaves it at 0.
export const CLEAR_COMPLETED_STAGE_EVIDENCE_TYPES = ['metadata.scan', 'export.execute'] as const
// Large face/similarity analyses routinely exceed ten minutes, so a shorter
// default would surface spurious timeouts while the background job is still
// legitimately running. The timeout only guards against permanently-stuck
// jobs; callers may pass a smaller timeoutMs explicitly.
const WAIT_FOR_RESULT_TIMEOUT_MS = 60 * 60_000

export class JobCancelledError extends Error {
  constructor() {
    super('Analysis job was cancelled')
    this.name = 'JobCancelledError'
  }
}

@injectable()
export class JobService {
  private readonly leaseOwner = `main-${process.pid}`
  private readonly executors = new Map<AnalysisJobData['type'], JobExecutor>()
  private readonly autoResumeTypes = new Set<AnalysisJobData['type']>()
  private readonly controllers = new Map<string, AbortController>()
  private readonly activeRuns = new Set<Promise<unknown>>()
  private readonly resultWaiters = new Map<string, Array<{
    resolve: (value: unknown) => void
    reject: (error: unknown) => void
  }>>()
  private readonly completedResults = new Map<string, {
    value?: unknown
    error?: unknown
  }>()
  private watchdog: ReturnType<typeof setInterval> | null = null
  private drainScheduled = false
  private stopped = true
  private progressSink: JobProgressSink | null = null

  constructor(@inject(DI_TOKENS.ANALYSIS_JOB_REPO) private repo: AnalysisJobRepository) {}

  /** Registers a callback invoked with throttled progress for running jobs. */
  setProgressSink(sink: JobProgressSink | null): void {
    this.progressSink = sink
  }

  start(): void {
    this.stopped = false
    this.repo.recoverStale()
    this.repo.resumeInterrupted([...this.autoResumeTypes])
    this.scheduleDrain()
    if (!this.watchdog) {
      this.watchdog = setInterval(() => {
        this.repo.recoverStale()
        this.scheduleDrain()
      }, 5_000)
    }
  }

  async stop(): Promise<void> {
    this.stopped = true
    if (this.watchdog) clearInterval(this.watchdog)
    this.watchdog = null
    for (const controller of this.controllers.values()) controller.abort()
    // The controllers are no longer needed once every run has been aborted
    // (stopped=true also blocks drain), so release them before waiting: if an
    // executor never settles, the caller's bounded shutdown race still
    // completes without leaving dangling references.
    this.controllers.clear()
    await Promise.allSettled([...this.activeRuns])
  }

  registerExecutor(
    type: AnalysisJobData['type'],
    executor: JobExecutor,
    options: { autoResume?: boolean } = {},
  ): void {
    this.executors.set(type, executor)
    if (options.autoResume !== false) this.autoResumeTypes.add(type)
    else this.autoResumeTypes.delete(type)
    if (!this.stopped) {
      if (this.autoResumeTypes.has(type)) this.repo.resumeInterrupted([type])
      this.scheduleDrain()
    }
  }

  create(params: JobCreateParams) {
    const job = this.repo.create(params)
    this.scheduleDrain()
    return job
  }
  list(status?: AnalysisJobStatus) { return this.repo.list(status) }
  cancel(id: string): boolean {
    const wasQueued = this.repo.get(id)?.status === 'queued'
    const cancelled = this.repo.requestCancel(id)
    if (cancelled) {
      this.controllers.get(id)?.abort()
      if (wasQueued) {
        this.completeResult(id, { error: new JobCancelledError() })
        // A queued cancel never goes through runInternal, so it would emit no
        // terminal progress frame; clients relying on jobs:progress (header
        // progress copy, workspace status) would stay stuck at "扫描中…".
        // Match the running-cancel path and push the terminal frame here.
        this.emitTerminal(id, 'cancelled')
      }
    }
    return cancelled
  }
  cancelScope(type: AnalysisJobData['type'], scopeId: string): number {
    let cancelled = 0
    for (const job of this.repo.list()) {
      if (
        job.type === type &&
        job.scopeId === scopeId &&
        ['queued', 'running', 'cancelling'].includes(job.status) &&
        this.cancel(job.id)
      ) {
        cancelled++
      }
    }
    return cancelled
  }
  retry(id: string): boolean {
    const retried = this.repo.retry(id)
    if (retried) {
      this.completedResults.delete(id)
      this.scheduleDrain()
    }
    return retried
  }
  clearCompleted(): number {
    return this.repo.clearCompleted(CLEAR_COMPLETED_STAGE_EVIDENCE_TYPES)
  }
  waitForResult<T>(jobId: string, options: { timeoutMs?: number } = {}): Promise<T> {
    const completed = this.completedResults.get(jobId)
    if (completed) {
      if (completed.error !== undefined) return Promise.reject(completed.error)
      return Promise.resolve(completed.value as T)
    }
    const persisted = this.repo.get(jobId)
    if (!persisted) return Promise.reject(new Error(`Analysis job not found: ${jobId}`))
    if (persisted.status === 'succeeded') {
      // The in-memory completedResults entry is evicted 5 minutes after
      // completion; a late waiter must still resolve instead of hanging for
      // the full timeout. The original return value is no longer available —
      // callers of waitForResult must not depend on it for already-finished
      // jobs (the persistent job row is the durable record).
      return Promise.resolve(undefined as T)
    }
    if (['failed', 'interrupted', 'cancelled'].includes(persisted.status)) {
      return Promise.reject(
        persisted.status === 'cancelled'
          ? new JobCancelledError()
          : new Error(persisted.errorMessage || `Analysis job ${persisted.status}`),
      )
    }
    return new Promise<T>((resolve, reject) => {
      const timeoutMs = options.timeoutMs ?? WAIT_FOR_RESULT_TIMEOUT_MS
      let settled = false
      let entry: { resolve: (value: unknown) => void; reject: (error: unknown) => void }
      const timer = setTimeout(() => {
        settled = true
        const waiters = this.resultWaiters.get(jobId) ?? []
        const index = waiters.indexOf(entry)
        if (index >= 0) waiters.splice(index, 1)
        if (waiters.length === 0) this.resultWaiters.delete(jobId)
        reject(new Error(`Timed out waiting for analysis job ${jobId}`))
      }, timeoutMs)
      if (typeof timer.unref === 'function') timer.unref()
      entry = {
        resolve: (value: unknown) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          resolve(value as T)
        },
        reject: (error: unknown) => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          reject(error)
        },
      }
      const waiters = this.resultWaiters.get(jobId) ?? []
      waiters.push(entry)
      this.resultWaiters.set(jobId, waiters)
    })
  }
  claim(id: string, leaseOwner: string): boolean { return this.repo.claim(id, leaseOwner) }
  heartbeat(id: string, leaseOwner: string): boolean { return this.repo.heartbeat(id, leaseOwner) }
  updateProgress(id: string, leaseOwner: string, update: JobProgressUpdate): boolean {
    return this.repo.updateProgress(id, leaseOwner, update)
  }
  finish(id: string, leaseOwner: string, status: 'succeeded' | 'failed' | 'cancelled', error?: { code: string; message: string }): boolean {
    return this.repo.finish(id, leaseOwner, status, error)
  }

  /**
   * Push a terminal progress frame so renderer clients that recovered an
   * in-flight job on mount (and rely on events, not polling) learn that the
   * job finished. Without this, a reloaded page stays stuck in the
   * "analyzing" state forever.
   */
  private emitTerminal(jobId: string, status: 'succeeded' | 'failed' | 'cancelled' | 'interrupted'): void {
    const latest = this.repo.get(jobId)
    if (!latest) return
    this.progressSink?.(latest, {
      current: 1,
      total: 1,
      message: status,
    })
  }

  run<T>(
    job: AnalysisJobData,
    leaseOwner: string,
    work: (context: JobRunContext) => Promise<T>,
  ): Promise<T> {
    const task = this.runInternal(job, leaseOwner, work)
    this.activeRuns.add(task)
    void task.then(
      () => this.activeRuns.delete(task),
      () => this.activeRuns.delete(task),
    )
    return task
  }

  private async runInternal<T>(
    job: AnalysisJobData,
    leaseOwner: string,
    work: (context: JobRunContext) => Promise<T>,
  ): Promise<T> {
    if (!this.claim(job.id, leaseOwner)) throw new Error('Analysis job is no longer claimable')
    const controller = new AbortController()
    this.controllers.set(job.id, controller)
    const heartbeat = setInterval(() => {
      if (!this.heartbeat(job.id, leaseOwner)) controller.abort()
    }, 5_000)
    let lastProgressWriteAt = 0
    let pendingProgress: JobProgressUpdate | null = null
    let cancelCheckCalls = 0
    let lastCancelDbCheckAt = 0
    const dbStatusCancelled = (): boolean => {
      const latest = this.repo.get(job.id)
      return latest?.status === 'cancelling' || latest?.status === 'cancelled'
    }
    const throwIfCancelled = (forceDbCheck = false): void => {
      if (controller.signal.aborted) throw new JobCancelledError()
      const now = Date.now()
      if (
        !forceDbCheck &&
        ++cancelCheckCalls % CANCEL_DB_CHECK_EVERY !== 0 &&
        now - lastCancelDbCheckAt < CANCEL_DB_CHECK_INTERVAL_MS
      ) {
        return
      }
      lastCancelDbCheckAt = now
      if (dbStatusCancelled()) throw new JobCancelledError()
    }
    const flushProgress = (): void => {
      if (!pendingProgress) return
      const update = pendingProgress
      pendingProgress = null
      lastProgressWriteAt = Date.now()
      if (!this.updateProgress(job.id, leaseOwner, update)) controller.abort()
      this.progressSink?.(job, update)
    }
    const context: JobRunContext = {
      signal: controller.signal,
      updateProgress: update => {
        pendingProgress = { ...(pendingProgress ?? {}), ...update }
        const completed = typeof update.current === 'number' &&
          typeof update.total === 'number' &&
          update.total > 0 &&
          update.current >= update.total
        if (completed || Date.now() - lastProgressWriteAt >= PROGRESS_WRITE_INTERVAL_MS) {
          flushProgress()
        }
      },
      updateCheckpoint: checkpoint => {
        flushProgress()
        pendingProgress = { checkpoint }
        flushProgress()
      },
      throwIfCancelled: () => throwIfCancelled(),
    }
    try {
      const result = await work(context)
      flushProgress()
      // Force a fresh persisted-status check on the success path: work may
      // have ended on a throttled window, and a queued cancel must still
      // turn the final commit into a cancelled job.
      throwIfCancelled(true)
      if (!this.finish(job.id, leaseOwner, 'succeeded')) {
        throw new Error('Analysis job lost its execution lease before completion')
      }
      this.emitTerminal(job.id, 'succeeded')
      return result
    } catch (error) {
      flushProgress()
      const cancelled = error instanceof JobCancelledError || controller.signal.aborted
      const latest = this.repo.get(job.id)
      const interruptedByShutdown = cancelled && this.stopped && latest?.status === 'running'
      if (interruptedByShutdown) {
        this.repo.interrupt(job.id, leaseOwner)
        this.emitTerminal(job.id, 'interrupted')
      } else {
        this.finish(
          job.id,
          leaseOwner,
          cancelled ? 'cancelled' : 'failed',
          cancelled ? undefined : {
            code: 'worker_error',
            message: error instanceof Error ? error.message : String(error),
          },
        )
        this.emitTerminal(job.id, cancelled ? 'cancelled' : 'failed')
      }
      throw error
    } finally {
      clearInterval(heartbeat)
      this.controllers.delete(job.id)
    }
  }

  private scheduleDrain(): void {
    if (this.stopped || this.drainScheduled) return
    this.drainScheduled = true
    queueMicrotask(() => {
      this.drainScheduled = false
      // repo.list can throw (e.g. DB closed during shutdown); an unhandled
      // rejection would escape scheduleDrain's fire-and-forget callers.
      void this.drain().catch(error => {
        console.warn('Background job drain failed', error)
      })
    })
  }

  private async drain(): Promise<void> {
    if (this.stopped) return
    for (const job of this.repo.list('queued')) {
      if (this.controllers.size >= MAX_CONCURRENT_JOBS) break
      if (this.controllers.has(job.id)) continue
      const executor = this.executors.get(job.type)
      if (!executor) continue
      void this.run(job, this.leaseOwner, context => executor(job, context))
        .then(result => this.completeResult(job.id, { value: result }))
        .catch(error => {
          // Suppress only when a result for this job already exists (e.g. a
          // cross-process claim race where another runner completed it).
          // The executor's own failure/cancel path must still reject waiters
          // through completeResult: the DB status is already terminal by the
          // time this catch runs, so a DB-status guard would leak every
          // failed/cancelled job's waiter until the 60-minute timeout.
          if (!this.completedResults.has(job.id)) {
            this.completeResult(job.id, { error })
          }
          if (!(error instanceof JobCancelledError)) {
            console.warn(`Background job ${job.id} failed`, error)
          }
        })
        .finally(() => this.scheduleDrain())
    }
  }

  private completeResult(
    jobId: string,
    completed: { value?: unknown; error?: unknown },
  ): void {
    this.completedResults.set(jobId, completed)
    const waiters = this.resultWaiters.get(jobId) ?? []
    this.resultWaiters.delete(jobId)
    for (const waiter of waiters) {
      if (completed.error !== undefined) waiter.reject(completed.error)
      else waiter.resolve(completed.value)
    }
    const timer = setTimeout(() => this.completedResults.delete(jobId), 5 * 60_000)
    timer.unref?.()
  }
}
