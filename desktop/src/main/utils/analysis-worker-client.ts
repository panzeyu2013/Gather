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
    timer = setTimeout(() => {
      settle(() => {
        terminate()
        reject(new Error(`Analysis worker timed out after ${timeoutMs}ms`))
      })
    }, timeoutMs)
    if (typeof timer.unref === 'function') timer.unref()
    signal?.addEventListener('abort', onAbort, { once: true })
    worker.once('message', (message: { id: number; result?: T; error?: string }) => {
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
    })
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
): Promise<{ groups: string[][]; ungrouped: string[] }> {
  return runWorker({ kind: 'hash', entries, threshold, minGroupSize, mode }, signal)
}

export function clusterFacesInWorker(
  entries: EmbeddingEntry[],
  eps: number,
  minPts: number,
  signal?: AbortSignal,
): Promise<{ clusters: EmbeddingEntry[][]; noise: EmbeddingEntry[] }> {
  return runWorker({ kind: 'face', entries, eps, minPts }, signal)
}
