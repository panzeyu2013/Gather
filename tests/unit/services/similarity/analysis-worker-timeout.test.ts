import { describe, expect, it, vi } from 'vitest'
import type { HashEntry } from '../../../../desktop/src/main/services/similarity/cluster-engine'
import type { EmbeddingEntry } from '../../../../desktop/src/main/services/face-kw/face-clusterer'
import {
  clusterFacesInWorker,
  clusterHashesInWorker,
  estimateAnalysisTimeoutMs,
  runWorker,
} from '../../../../desktop/src/main/utils/analysis-worker-client'

// Fake worker_threads.Worker so runWorker can be driven entirely from the
// test: handlers registered with once() are stored, postMessage is recorded,
// and emit() replays a single frame (once semantics).
const fakeWorker = vi.hoisted(() => {
  type Handler = (payload: unknown) => void
  class FakeWorker {
    static instances: FakeWorker[] = []
    postMessage = vi.fn()
    terminate = vi.fn()
    private listeners = new Map<string, Handler[]>()
    constructor() {
      FakeWorker.instances.push(this)
    }
    once(event: string, handler: Handler): void {
      const list = this.listeners.get(event) ?? []
      list.push(handler)
      this.listeners.set(event, list)
    }
    emit(event: string, payload: unknown): void {
      const list = this.listeners.get(event) ?? []
      this.listeners.set(event, [])
      for (const handler of list) handler(payload)
    }
  }
  return { FakeWorker }
})

vi.mock('worker_threads', () => ({
  default: { Worker: fakeWorker.FakeWorker },
  Worker: fakeWorker.FakeWorker,
}))

type FakeWorkerInstance = InstanceType<typeof fakeWorker.FakeWorker>

const lastWorker = (): FakeWorkerInstance => {
  const worker = fakeWorker.FakeWorker.instances.at(-1)
  if (!worker) throw new Error('no fake worker was created')
  return worker
}

const lastRequestId = (): number => {
  const request = lastWorker().postMessage.mock.calls[0]?.[0] as { id: number } | undefined
  if (!request) throw new Error('no request was posted')
  return request.id
}

const hashEntries = (count: number): HashEntry[] => {
  const template: HashEntry = { photoId: 'photo-0', hash: 'aabbccdd' }
  return new Array<HashEntry>(count).fill(template)
}

const faceEntries = (count: number): EmbeddingEntry[] => {
  const template: EmbeddingEntry = { observationId: 1, photoId: 'photo-0', embedding: [] }
  return new Array<EmbeddingEntry>(count).fill(template)
}

describe('estimateAnalysisTimeoutMs', () => {
  it('floors the hash branch at 60s and caps it at 15 minutes', () => {
    expect(estimateAnalysisTimeoutMs('hash', 0)).toBe(60_000)
    expect(estimateAnalysisTimeoutMs('hash', 1)).toBe(60_000)
    expect(estimateAnalysisTimeoutMs('hash', 100_000)).toBe(900_000)
    expect(estimateAnalysisTimeoutMs('hash', 1_000_000)).toBe(900_000)
  })

  it('keeps the face branch at the 60s floor for small libraries', () => {
    expect(estimateAnalysisTimeoutMs('face', 0)).toBe(60_000)
    expect(estimateAnalysisTimeoutMs('face', 1)).toBe(60_000)
    expect(estimateAnalysisTimeoutMs('face', 5_000)).toBe(60_000)
  })

  it('scales the face branch with the square of the library size', () => {
    // 50k faces => 30s + 2.5e9 * 2.56e-4 ms ≈ 670s; 100k => ≈ 43 min.
    expect(estimateAnalysisTimeoutMs('face', 50_000)).toBe(670_000)
    expect(estimateAnalysisTimeoutMs('face', 100_000)).toBe(2_590_000)
  })

  it('clamps absurd face counts before squaring (no float overflow, 60min cap)', () => {
    expect(estimateAnalysisTimeoutMs('face', 1_000_000_000)).toBe(3_600_000)
  })

  it('honours a positive override and ignores non-positive ones', () => {
    expect(estimateAnalysisTimeoutMs('hash', 100_000, 5_000)).toBe(5_000)
    expect(estimateAnalysisTimeoutMs('face', 100_000, 123_456)).toBe(123_456)
    expect(estimateAnalysisTimeoutMs('hash', 100_000, 0)).toBe(900_000)
    expect(estimateAnalysisTimeoutMs('face', 100_000, -1)).toBe(2_590_000)
  })
})

describe('runWorker message routing', () => {
  it('routes progress frames to onProgress and resolves with the final result', async () => {
    const onProgress = vi.fn()
    const promise = clusterHashesInWorker(hashEntries(4), 16, 2, 'global', undefined, onProgress)
    const worker = lastWorker()
    const id = lastRequestId()

    worker.emit('message', { id: id + 999, kind: 'progress', current: 1, total: 4 })
    worker.emit('message', { id, kind: 'progress', current: 2, total: 4 })
    worker.emit('message', { id, result: { groups: [['photo-0', 'photo-0']], ungrouped: ['photo-0'] } })

    await expect(promise).resolves.toEqual({
      groups: [['photo-0', 'photo-0']],
      ungrouped: ['photo-0'],
    })
    // A progress frame from a different request id must not reach onProgress.
    expect(onProgress).toHaveBeenCalledTimes(1)
    expect(onProgress).toHaveBeenCalledWith(2, 4)
  })

  it('resolves with the final result even when onProgress throws', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => undefined)
    const onProgress = vi.fn(() => {
      throw new Error('progress callback boom')
    })
    const promise = clusterFacesInWorker(faceEntries(4), 0.5, 3, undefined, onProgress)
    const worker = lastWorker()
    const id = lastRequestId()

    worker.emit('message', { id, kind: 'progress', current: 1, total: 4 })
    worker.emit('message', { id, result: { clusters: [], noise: [] } })

    await expect(promise).resolves.toEqual({ clusters: [], noise: [] })
    expect(onProgress).toHaveBeenCalledTimes(1)
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('passes the estimated timeout to runWorker instead of the fixed 60s default', async () => {
    const setTimeoutSpy = vi.spyOn(globalThis, 'setTimeout')
    try {
      const promise = clusterHashesInWorker(hashEntries(100_000), 16, 2, 'global')
      const worker = lastWorker()
      const id = lastRequestId()
      worker.emit('message', { id, result: { groups: [], ungrouped: [] } })

      const delays = setTimeoutSpy.mock.calls.map(([, delay]) => delay as number)
      // 100k hashes => estimateAnalysisTimeoutMs caps at 15 minutes, not 60s.
      expect(delays).toContain(900_000)
      await expect(promise).resolves.toEqual({ groups: [], ungrouped: [] })
    } finally {
      setTimeoutSpy.mockRestore()
    }
  })

  it('passes a face timeout above the default for large face jobs', async () => {
    const setTimeoutSpy = vi.spyOn(globalThis, 'setTimeout')
    try {
      const promise = clusterFacesInWorker(faceEntries(400_000), 0.5, 3)
      const worker = lastWorker()
      const id = lastRequestId()
      worker.emit('message', { id, result: { clusters: [], noise: [] } })

      const delays = setTimeoutSpy.mock.calls.map(([, delay]) => delay as number)
      // 400k faces => n²·2.56e-4 far exceeds the cap, so the estimate is the
      // 60-minute ceiling, not the old fixed 60s.
      expect(delays).toContain(3_600_000)
      await expect(promise).resolves.toEqual({ clusters: [], noise: [] })
    } finally {
      setTimeoutSpy.mockRestore()
    }
  })

  it('re-arms the timeout on progress frames so an active worker is not killed', async () => {
    vi.useFakeTimers()
    try {
      const promise = runWorker({ kind: 'face' }, undefined, { timeoutMs: 100 })
      const worker = lastWorker()
      const id = lastRequestId()

      // Ten progress frames over 200ms: any 100ms gap without a frame would
      // time out, but the heartbeat keeps re-arming the deadline.
      for (let i = 1; i <= 10; i++) {
        vi.advanceTimersByTime(20)
        worker.emit('message', { id, kind: 'progress', current: i, total: 10 })
      }
      expect(worker.terminate).not.toHaveBeenCalled()

      worker.emit('message', { id, result: { clusters: [], noise: [] } })
      await expect(promise).resolves.toEqual({ clusters: [], noise: [] })
    } finally {
      vi.useRealTimers()
    }
  })

  it('times out once progress frames stop arriving', async () => {
    vi.useFakeTimers()
    try {
      const promise = runWorker({ kind: 'face' }, undefined, { timeoutMs: 100 })
      const worker = lastWorker()
      const id = lastRequestId()

      worker.emit('message', { id, kind: 'progress', current: 1, total: 10 })
      vi.advanceTimersByTime(40)
      worker.emit('message', { id, kind: 'progress', current: 2, total: 10 })
      expect(worker.terminate).not.toHaveBeenCalled()
      vi.advanceTimersByTime(150)

      await expect(promise).rejects.toThrow(/timed out/)
      expect(worker.terminate).toHaveBeenCalled()
    } finally {
      vi.useRealTimers()
    }
  })
})
