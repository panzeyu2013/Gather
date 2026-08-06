import { Worker } from 'worker_threads'
import * as path from 'path'
import type { HashEntry, HashGroupingMode } from '../services/similarity/cluster-engine'
import type { EmbeddingEntry } from '../services/face-kw/face-clusterer'
import { CancelledError } from '@gather/shared'

let nextRequestId = 1

export type WorkerFactory = (scriptPath: string) => Worker

export interface RunWorkerOptions {
  timeoutMs?: number
  createWorker?: WorkerFactory
  onProgress?: (current: number, total: number) => void
}

type WorkerMessage<T> = {
  id: number
  result?: T
  error?: string
  kind?: 'progress'
  current?: number
  total?: number
}

// Dynamic per-analysis timeout so large workloads (20k+ hashes, 50k+ faces)
// no longer hit the old fixed 60s cap. Callers may force their own value.
// The face branch scales with n² (exact DBSCAN: n region queries × n rows ×
// 2·dim multiply-add flops) at a conservative ~1 GFLOP/s JS worker
// throughput, doubled for safety: 20k rows × 512 dims ≈ 4.1e11 flops ≈
// 410s + 30s startup. The ANN (LSH) path is near-linear, so the formula is
// conservative there — harmless, because the timeout is a no-progress
// timeout: every 'progress' frame the worker emits re-arms it, so an active
// worker is never killed by the absolute deadline, while a stalled one (no
// progress) is still terminated.
export function estimateAnalysisTimeoutMs(
  kind: 'hash' | 'face',
  entryCount: number,
  overrideMs?: number,
): number {
  if (overrideMs !== undefined && overrideMs > 0) return overrideMs
  if (kind === 'hash') {
    return Math.min(15 * 60_000, Math.max(60_000, 30_000 + entryCount * 10))
  }
  // Clamp before squaring so absurd counts cannot overflow the float range;
  // realistic libraries (<= ~50k faces) land well under the 60-minute cap.
  const clampedCount = Math.min(entryCount, 1_000_000)
  const dim = 512
  const flops = clampedCount * clampedCount * dim
  const conservativeMs = flops / 1e9 * 1000 * 2
  return Math.min(60 * 60_000, Math.max(60_000, 30_000 + conservativeMs))
}

// A worker that silently dies (e.g. OOM/SIGKILL) only emits 'exit', which
// previously left the pending promise hanging forever and the thread alive.
// Timeout and exit handlers now settle the promise and always terminate.
export function runWorker<T>(
  request: Record<string, unknown>,
  signal?: AbortSignal,
  options: RunWorkerOptions = {},
): Promise<T> {
  if (signal?.aborted) return Promise.reject(new CancelledError('Analysis cancelled'))
  const createWorker = options.createWorker ?? ((scriptPath) => new Worker(scriptPath))
  const worker = createWorker(path.join(__dirname, 'analysis-worker.js'))
  const id = nextRequestId++
  const timeoutMs = options.timeoutMs ?? 60_000
  return new Promise<T>((resolve, reject) => {
    let settled = false
    let timer: ReturnType<typeof setTimeout> | null = null
    const terminate = (): void => { void worker.terminate() }
    const settle = (finish: () => void): void => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      finish()
    }
    const onAbort = (): void => {
      settle(() => {
        terminate()
        reject(new CancelledError('Analysis cancelled'))
      })
    }
    // No-progress timeout: armed on start and re-armed on every progress frame,
    // so a worker that keeps reporting progress is never killed, while one that
    // stalls (no progress) still hits the deadline.
    const armTimeout = (): void => {
      if (timer) clearTimeout(timer)
      timer = setTimeout(() => {
        settle(() => {
          terminate()
          reject(new Error(`Analysis worker timed out after ${timeoutMs}ms`))
        })
      }, timeoutMs)
      if (typeof timer.unref === 'function') timer.unref()
    }
    armTimeout()
    signal?.addEventListener('abort', onAbort, { once: true })
    const onMessage = (message: WorkerMessage<T>): void => {
      if (settled) return
      if (message.kind === 'progress') {
        // Re-attach before invoking the callback so a throwing progress
        // handler cannot consume the 'message' listener and drop the final
        // result frame, which would leave the promise hanging until timeout.
        worker.once('message', onMessage)
        // Progress is a heartbeat: re-arm the timeout so an active worker is
        // never killed by the deadline; settle still guards the single settle.
        armTimeout()
        if (message.id === id) {
          try {
            options.onProgress?.(message.current ?? 0, message.total ?? 0)
          } catch (error) {
            console.warn('analysis worker progress callback failed', error)
          }
        }
        return
      }
      settle(() => {
        terminate()
        if (message.id !== id) {
          reject(new Error('Unexpected analysis worker response'))
        } else if (message.error) {
          reject(new Error(message.error))
        } else {
          resolve(message.result as T)
        }
      })
    }
    worker.once('message', onMessage)
    worker.once('error', (error) => {
      settle(() => {
        terminate()
        reject(error)
      })
    })
    worker.once('exit', () => {
      settle(() => {
        terminate()
        reject(new Error('Analysis worker exited unexpectedly'))
      })
    })
    worker.postMessage({ ...request, id })
  })
}

export function clusterHashesInWorker(
  entries: HashEntry[],
  threshold: number,
  minGroupSize: number,
  mode: HashGroupingMode = 'global',
  signal?: AbortSignal,
  onProgress?: (current: number, total: number) => void,
): Promise<{ groups: string[][]; ungrouped: string[] }> {
  const timeoutMs = estimateAnalysisTimeoutMs('hash', entries.length)
  return runWorker({ kind: 'hash', entries, threshold, minGroupSize, mode }, signal, { onProgress, timeoutMs })
}

export function clusterFacesInWorker(
  entries: EmbeddingEntry[],
  eps: number,
  minPts: number,
  signal?: AbortSignal,
  onProgress?: (current: number, total: number) => void,
): Promise<{ clusters: EmbeddingEntry[][]; noise: EmbeddingEntry[] }> {
  const timeoutMs = estimateAnalysisTimeoutMs('face', entries.length)
  return runWorker({ kind: 'face', entries, eps, minPts }, signal, { onProgress, timeoutMs })
}
