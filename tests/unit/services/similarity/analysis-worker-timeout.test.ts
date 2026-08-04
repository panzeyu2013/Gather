import { describe, expect, it } from 'vitest'
import { runWorker, type WorkerFactory } from '../../../../desktop/src/main/utils/analysis-worker-client'
import { CancelledError } from '@gather/shared'

class FakeWorker {
  listeners = new Map<string, Array<(payload?: unknown) => void>>()
  terminated = false
  posted: { id: number } | null = null

  once(event: string, callback: (payload?: unknown) => void): void {
    this.listeners.set(event, [...(this.listeners.get(event) ?? []), callback])
  }
  postMessage(message: { id: number }): void {
    this.posted = message
  }
  terminate(): Promise<number> {
    this.terminated = true
    return Promise.resolve(0)
  }
  emit(event: string, payload?: unknown): void {
    for (const callback of this.listeners.get(event) ?? []) callback(payload)
  }
}

function createWorkerFactory(worker: FakeWorker): WorkerFactory {
  return () => worker as never
}

describe('runWorker hang protection', () => {
  it('rejects after the timeout and terminates the worker', async () => {
    const worker = new FakeWorker()
    await expect(
      runWorker({ kind: 'hash' }, undefined, {
        timeoutMs: 50,
        createWorker: createWorkerFactory(worker),
      }),
    ).rejects.toThrow(/timed out/)
    expect(worker.terminated).toBe(true)
  })

  it('rejects with CancelledError and terminates the worker on abort', async () => {
    const worker = new FakeWorker()
    const controller = new AbortController()
    const pending = runWorker({ kind: 'hash' }, controller.signal, {
      createWorker: createWorkerFactory(worker),
    })
    controller.abort()
    await expect(pending).rejects.toBeInstanceOf(CancelledError)
    expect(worker.terminated).toBe(true)
  })

  it('resolves the posted result and terminates the worker', async () => {
    const worker = new FakeWorker()
    const pending = runWorker<{ groups: string[][] }>(
      { kind: 'hash' },
      undefined,
      { createWorker: createWorkerFactory(worker) },
    )
    const id = worker.posted!.id
    worker.emit('message', { id, result: { groups: [['a']] } })
    await expect(pending).resolves.toEqual({ groups: [['a']] })
    expect(worker.terminated).toBe(true)
  })

  it('settles only once when the worker posts and exits together', async () => {
    const worker = new FakeWorker()
    const pending = runWorker<{ groups: string[][] }>(
      { kind: 'hash' },
      undefined,
      { createWorker: createWorkerFactory(worker) },
    )
    const id = worker.posted!.id
    worker.emit('message', { id, result: { groups: [] } })
    worker.emit('exit')
    await expect(pending).resolves.toEqual({ groups: [] })
  })

  it('rejects when the worker exits unexpectedly and terminates it', async () => {
    const worker = new FakeWorker()
    const pending = runWorker({ kind: 'hash' }, undefined, {
      createWorker: createWorkerFactory(worker),
    })
    worker.emit('exit')
    await expect(pending).rejects.toThrow(/exited unexpectedly/)
    expect(worker.terminated).toBe(true)
  })
})
