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
    await Promise.allSettled([...this.activeRuns])
    this.controllers.clear()
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
      if (wasQueued) this.completeResult(id, { error: new JobCancelledError() })
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
  clearCompleted(): number { return this.repo.clearCompleted() }
  waitForResult<T>(jobId: string): Promise<T> {
    const completed = this.completedResults.get(jobId)
    if (completed) {
      if (completed.error !== undefined) return Promise.reject(completed.error)
      return Promise.resolve(completed.value as T)
    }
    const persisted = this.repo.get(jobId)
    if (!persisted) return Promise.reject(new Error(`Analysis job not found: ${jobId}`))
    if (['failed', 'interrupted', 'cancelled'].includes(persisted.status)) {
      return Promise.reject(
        persisted.status === 'cancelled'
          ? new JobCancelledError()
          : new Error(persisted.errorMessage || `Analysis job ${persisted.status}`),
      )
    }
    return new Promise<T>((resolve, reject) => {
      const waiters = this.resultWaiters.get(jobId) ?? []
      waiters.push({
        resolve: value => resolve(value as T),
        reject,
      })
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
      throwIfCancelled: () => {
        const latest = this.repo.get(job.id)
        if (
          controller.signal.aborted ||
          latest?.status === 'cancelling' ||
          latest?.status === 'cancelled'
        ) {
          throw new JobCancelledError()
        }
      },
    }
    try {
      const result = await work(context)
      flushProgress()
      context.throwIfCancelled()
      if (!this.finish(job.id, leaseOwner, 'succeeded')) {
        throw new Error('Analysis job lost its execution lease before completion')
      }
      return result
    } catch (error) {
      flushProgress()
      const cancelled = error instanceof JobCancelledError || controller.signal.aborted
      const latest = this.repo.get(job.id)
      const interruptedByShutdown = cancelled && this.stopped && latest?.status === 'running'
      if (interruptedByShutdown) {
        this.repo.interrupt(job.id, leaseOwner)
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
      void this.drain()
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
          this.completeResult(job.id, { error })
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
