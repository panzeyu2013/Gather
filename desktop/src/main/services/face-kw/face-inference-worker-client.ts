import { Worker } from 'worker_threads'
import * as path from 'path'
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

export class FaceInferenceWorker {
  private readonly worker = new Worker(path.join(__dirname, 'face-inference-worker.js'))
  private nextId = 1
  private closed = false

  private request<T>(
    payload: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<T> {
    if (this.closed) return Promise.reject(new Error('Face inference worker is closed'))
    if (signal?.aborted) return Promise.reject(new CancelledError('Analysis cancelled'))
    const id = this.nextId++
    return new Promise<T>((resolve, reject) => {
      const onAbort = (): void => {
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
        reject(error)
      }
      const cleanup = (): void => {
        signal?.removeEventListener('abort', onAbort)
        this.worker.off('message', onMessage)
        this.worker.off('error', onError)
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      this.worker.on('message', onMessage)
      this.worker.once('error', onError)
      this.worker.postMessage({ ...payload, id })
    })
  }

  init(config: {
    detectorPath: string
    encoderPath: string
    provider: string
    threads: number
    encoderInputSize: number
    embeddingDim: number
    inputSizes: number[]
  }, signal?: AbortSignal): Promise<FaceInferenceInitResult> {
    return this.request({ kind: 'init', ...config }, signal)
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
    try {
      await this.request<boolean>({ kind: 'shutdown' })
    } finally {
      this.closed = true
      await this.worker.terminate()
    }
  }
}
