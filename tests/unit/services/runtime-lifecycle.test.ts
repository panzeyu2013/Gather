import { describe, expect, it, vi } from 'vitest'
import {
  shutdownRuntime,
  type RuntimeLifecycle,
} from '../../../desktop/src/main/services/runtime/runtime-lifecycle'

describe('runtime lifecycle', () => {
  it('shuts down safely when startup failed before services were constructed', async () => {
    const close = vi.fn()
    await shutdownRuntime({ database: { close } }, 10)
    expect(close).toHaveBeenCalledOnce()
  })

  it('stops constructed services before closing the database', async () => {
    const calls: string[] = []
    const runtime: RuntimeLifecycle = {
      indexer: { stopWatchers: () => { calls.push('watchers') } },
      jobs: { stop: async () => { calls.push('jobs') } },
      metadataSync: { shutdown: async () => { calls.push('metadata') } },
      writerRouter: { shutdown: async () => { calls.push('writer') } },
      database: { close: () => { calls.push('database') } },
    }
    await shutdownRuntime(runtime, 100)
    expect(calls[0]).toBe('watchers')
    expect(calls.at(-1)).toBe('database')
    expect(calls).toEqual(expect.arrayContaining([
      'jobs',
      'metadata',
      'writer',
    ]))
  })
})
