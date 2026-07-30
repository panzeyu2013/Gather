import { Worker } from 'worker_threads'
import * as path from 'path'
import type { HashEntry, HashGroupingMode } from '../services/similarity/cluster-engine'
import type { EmbeddingEntry } from '../services/face-kw/face-clusterer'
import { CancelledError } from '@gather/shared'

let nextRequestId = 1

function runWorker<T>(request: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
  if (signal?.aborted) return Promise.reject(new CancelledError('Analysis cancelled'))
  const worker = new Worker(path.join(__dirname, 'analysis-worker.js'))
  const id = nextRequestId++
  return new Promise<T>((resolve, reject) => {
    const terminate = (): void => { void worker.terminate() }
    const onAbort = (): void => {
      terminate()
      reject(new CancelledError('Analysis cancelled'))
    }
    signal?.addEventListener('abort', onAbort, { once: true })
    worker.once('message', (message: { id: number; result?: T; error?: string }) => {
      signal?.removeEventListener('abort', onAbort)
      terminate()
      if (message.id !== id) {
        reject(new Error('Unexpected analysis worker response'))
      } else if (message.error) {
        reject(new Error(message.error))
      } else {
        resolve(message.result as T)
      }
    })
    worker.once('error', (error) => {
      signal?.removeEventListener('abort', onAbort)
      terminate()
      reject(error)
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
