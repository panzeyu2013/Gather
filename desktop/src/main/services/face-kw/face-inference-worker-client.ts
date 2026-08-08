import { Worker } from 'worker_threads'
import * as path from 'path'
import { statSync } from 'node:fs'
import { CancelledError } from '@gather/shared'

export interface FaceInferenceObservation {
  bbox: [number, number, number, number]
  confidence: number
  embedding: number[]
}

export interface FaceInferenceBatchItem {
  /** Per-image failure; the rest of the batch is unaffected. */
  error?: string
  observations: FaceInferenceObservation[]
  encodingFailures: number
}

export interface FaceInferenceInitResult {
  /** Effective detector execution provider after fallback resolution. */
  provider: string
  /** True when the requested path failed and the detector was rebuilt on CPU. */
  fallbackUsed: boolean
}

export interface FaceInferenceInitConfig {
  detectorPath: string
  encoderPath: string
  provider: string
  threads: number
  encoderInputSize: number
  embeddingDim: number
  inputSizes: number[]
}

const WORKER_SCRIPT = path.join(__dirname, 'face-inference-worker.js')
// Loading the ONNX models takes seconds per worker, so instead of creating
// and tearing down a thread per analysis the pool keeps at most one idle
// worker with its sessions loaded. While it is busy a new analysis spawns a
// temporary worker (the old per-analysis behavior); an idle worker is evicted
// after 10 minutes of inactivity, on thread exit, or when the process exits.
const IDLE_WORKER_TIMEOUT_MS = 10 * 60_000
const MAX_IDLE_WORKERS = 1

interface PooledWorker {
  worker: Worker
  configKey: string
  initResult: FaceInferenceInitResult
  idleTimer: ReturnType<typeof setTimeout> | null
  onExit: () => void
}

const idleWorkers: PooledWorker[] = []
let processExitHookInstalled = false

// Sessions are tied to the exact model paths/provider settings, so a pooled
// worker may only be reused when the whole init config matches. The key is
// built from an explicit field order so it never depends on key insertion
// order of the caller's object literal.
//
// The key also folds in the size/mtime fingerprint of the model files: a
// model-downloader update replaces the files in place without an app restart,
// and the caller's persisted analysisSignature (built from the same
// size/mtime fingerprint) changes on such an update. Without the fingerprint
// the pool would reuse the old-weights session while the analysis is labeled
// with the new signature, letting stale weight outputs overwrite the new
// model's results. statSync is a synchronous stat of two local files per
// analysis init, acceptable on the main process; an unstat-able file degrades
// to the path-only key (the caller's init fails anyway).
function modelFileFingerprint(modelPath: string): string {
  try {
    const modelStat = statSync(modelPath)
    return `${modelStat.size}:${Math.round(modelStat.mtimeMs)}`
  } catch {
    return ''
  }
}

function configKeyFor(config: FaceInferenceInitConfig): string {
  return [
    config.detectorPath,
    modelFileFingerprint(config.detectorPath),
    config.encoderPath,
    modelFileFingerprint(config.encoderPath),
    config.provider,
    config.threads,
    config.encoderInputSize,
    config.embeddingDim,
    config.inputSizes.join(','),
  ].join('\u0000')
}

function installProcessExitHook(): void {
  if (processExitHookInstalled) return
  processExitHookInstalled = true
  // Workers do not get a graceful stop/shutdown call from the callers, so a
  // process-exit hook terminates any parked workers (best-effort: worker
  // threads die with the process anyway).
  process.on('exit', () => {
    for (const entry of idleWorkers.splice(0)) {
      void entry.worker.terminate()
    }
  })
}

function removeIdleWorker(entry: PooledWorker): void {
  const index = idleWorkers.indexOf(entry)
  if (index >= 0) idleWorkers.splice(index, 1)
  if (entry.idleTimer) clearTimeout(entry.idleTimer)
  entry.idleTimer = null
}

/** Take the idle pooled worker, if any, and mark it busy again. */
function takeIdleWorker(): PooledWorker | null {
  const entry = idleWorkers.pop() ?? null
  if (!entry) return null
  if (entry.idleTimer) clearTimeout(entry.idleTimer)
  entry.idleTimer = null
  entry.worker.off('exit', entry.onExit)
  entry.worker.ref?.()
  return entry
}

/**
 * Park a healthy initialized worker for reuse. Returns false when the pool is
 * already full, in which case the caller should shut the worker down.
 */
function parkIdleWorker(
  worker: Worker,
  configKey: string,
  initResult: FaceInferenceInitResult,
): boolean {
  if (idleWorkers.length >= MAX_IDLE_WORKERS) return false
  const entry: PooledWorker = {
    worker,
    configKey,
    initResult,
    idleTimer: null,
    onExit: () => removeIdleWorker(entry),
  }
  worker.once('exit', entry.onExit)
  // A parked worker must not keep the app from exiting on its own.
  worker.unref?.()
  idleWorkers.push(entry)
  const idleTimer = setTimeout(() => {
    removeIdleWorker(entry)
    void entry.worker.terminate()
  }, IDLE_WORKER_TIMEOUT_MS)
  if (typeof idleTimer.unref === 'function') idleTimer.unref()
  entry.idleTimer = idleTimer
  installProcessExitHook()
  return true
}

export class FaceInferenceWorker {
  private worker: Worker
  private nextId = 1
  private closed = false
  private configKey: string | null = null
  private initResult: FaceInferenceInitResult | null = null

  constructor() {
    const pooled = takeIdleWorker()
    this.worker = pooled?.worker ?? new Worker(WORKER_SCRIPT)
    this.configKey = pooled?.configKey ?? null
    this.initResult = pooled?.initResult ?? null
  }

  private request<T>(
    payload: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error('Face inference worker is closed'))
    if (signal?.aborted) return Promise.reject(new CancelledError('Analysis cancelled'))
    const id = this.nextId++
    return new Promise<T>((resolve, reject) => {
      const onAbort = (): void => {
        cleanup()
        this.closed = true
        void this.worker.terminate()
        reject(new CancelledError('Analysis cancelled'))
      }
      const onMessage = (message: { id: number; result?: T; error?: string }): void => {
        if (message.id !== id) return
        cleanup()
        if (message.error) reject(new Error(message.error))
        else resolve(message.result as T)
      }
      const onError = (error: Error): void => {
        cleanup()
        this.closed = true
        reject(error)
      }
      // A worker killed by OOM/SIGKILL only emits 'exit' (the same failure
      // mode analysis-worker-client.ts handles for clustering); without this
      // the pending request would hang forever.
      const onExit = (code: number): void => {
        cleanup()
        this.closed = true
        reject(new Error(`Face inference worker exited unexpectedly (code ${code})`))
      }
      const cleanup = (): void => {
        signal?.removeEventListener('abort', onAbort)
        this.worker.off('message', onMessage)
        this.worker.off('error', onError)
        this.worker.off('exit', onExit)
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      this.worker.on('message', onMessage)
      this.worker.once('error', onError)
      this.worker.once('exit', onExit)
      this.worker.postMessage({ ...payload, id })
    })
  }

  init(config: FaceInferenceInitConfig, signal?: AbortSignal): Promise<FaceInferenceInitResult> {
    const key = configKeyFor(config)
    if (!this.closed && this.initResult && this.configKey === key) {
      // A pooled worker whose sessions were loaded with the exact same
      // configuration: skip the seconds-long ONNX init entirely.
      return Promise.resolve(this.initResult)
    }
    if (this.configKey !== null && this.configKey !== key) {
      // The pooled worker holds sessions for a different model/provider
      // config; re-initializing on top of the old sessions is not supported,
      // so discard the thread and start fresh.
      this.closed = true
      void this.worker.terminate()
      this.worker = new Worker(WORKER_SCRIPT)
      this.nextId = 1
      this.closed = false
      this.configKey = null
      this.initResult = null
    }
    return this.request<FaceInferenceInitResult>({ kind: 'init', ...config }, signal)
      .then((result) => {
        this.configKey = key
        this.initResult = result
        return result
      })
  }

  analyzeBatch(
    images: Buffer[],
    config: {
      inputSizes: number[]
      confidenceThreshold: number
      nmsThreshold: number
      maxDetections: number
      embeddingDim: number
    },
    signal?: AbortSignal,
  ): Promise<FaceInferenceBatchItem[]> {
    return this.request({ kind: 'analyzeBatch', images, ...config }, signal)
  }

  async shutdown(): Promise<void> {
    if (this.closed) return
    if (this.initResult && this.configKey !== null) {
      // Healthy worker with models loaded: park it in the pool instead of
      // terminating so the next analysis with the same config reuses the
      // expensive ONNX sessions.
      if (parkIdleWorker(this.worker, this.configKey, this.initResult)) {
        this.closed = true
        return
      }
    }
    try {
      // A dead worker (crash consumed the 'error' event) would never answer
      // the shutdown request; a bounded race keeps the caller from hanging.
      // A never-initialized worker (init failed or was cancelled) is not
      // safe to reuse either, so it takes the same terminate path.
      await Promise.race([
        this.request<boolean>({ kind: 'shutdown' }),
        new Promise<void>(resolve => setTimeout(resolve, 2000)),
      ])
    } finally {
      this.closed = true
      await this.worker.terminate()
    }
  }
}
