import { describe, expect, it } from 'vitest'
import { batchAsync } from '../../../../desktop/src/main/utils/async'

function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

describe('batchAsync sliding window', () => {
  it('returns results in input order regardless of completion order', async () => {
    const items = ['a', 'b', 'c', 'd', 'e', 'f']
    // Later items finish faster, so completion order is reversed.
    const fn = (item: string) => delay((items.length - items.indexOf(item)) * 5)
      .then(() => item)
    const results = await batchAsync(items, fn, 3)
    expect(results).toEqual(items)
  })

  it('rejects with the first error and stops scheduling new items', async () => {
    let calls = 0
    const fn = (item: string) => {
      calls++
      if (item === 'a') return Promise.reject(new Error('boom'))
      return delay(5).then(() => item)
    }
    await expect(batchAsync(['a', 'b', 'c', 'd', 'e'], fn, 2)).rejects.toThrow('boom')
    // a fails immediately, b was already dispatched; c..e must never start.
    expect(calls).toBe(2)
  })

  it('rejects promptly while an already-dispatched item is still running', async () => {
    const calls: string[] = []
    let started = 0
    let slowFinished = false
    const fn = (item: string) => {
      started++
      calls.push(item)
      if (item === 'a') return delay(10).then(() => { throw new Error('fail-fast') })
      return delay(150).then(() => {
        slowFinished = true
        return item
      })
    }
    await expect(batchAsync(['a', 'b', 'c'], fn, 2)).rejects.toThrow('fail-fast')
    // Rejection must arrive while b is still in flight; b is allowed to
    // finish, c is never scheduled.
    expect(slowFinished).toBe(false)
    expect(started).toBe(2)
    expect(calls).toEqual(['a', 'b'])
  })

  it('never exceeds the configured concurrency and beats serial execution', async () => {
    const itemCount = 20
    const stepMs = 15
    const items = Array.from({ length: itemCount }, (_, i) => i)
    let active = 0
    let peak = 0
    let over = 0
    const fn = async (item: number) => {
      active++
      peak = Math.max(peak, active)
      if (active > 4) over++
      await delay(stepMs)
      active--
      return item
    }
    // Serial baseline on the same machine; the window must beat it by a
    // comfortable margin (4x concurrency => ~4x faster, asserting 2x).
    const serialStart = Date.now()
    for (const item of items) await delay(stepMs).then(() => item)
    const serialMs = Date.now() - serialStart
    const batchStart = Date.now()
    const results = await batchAsync(items, fn, 4)
    const batchMs = Date.now() - batchStart
    expect(results).toEqual(items)
    expect(over).toBe(0)
    expect(peak).toBeLessThanOrEqual(4)
    expect(batchMs).toBeLessThan(serialMs / 2)
  })

  it('calls every fn exactly once even under sliding scheduling', async () => {
    const callCounts = new Map<string, number>()
    const fn = (item: string) => {
      callCounts.set(item, (callCounts.get(item) ?? 0) + 1)
      return delay(5).then(() => item)
    }
    const items = ['x', 'y', 'z', 'w']
    const results = await batchAsync(items, fn, 2)
    expect(results).toEqual(items)
    for (const item of items) expect(callCounts.get(item)).toBe(1)
  })

  it('starts later items while an earlier slow item is still running', async () => {
    // The bug being fixed: the old windowed Promise.all waited for the
    // slowest item of every batch, so a slow early item blocked everything
    // after it. The sliding window must schedule item 11 (a later batch in
    // the old scheme) while the slow item 4 is still in flight.
    const startedAt: number[] = []
    const finishedAt: number[] = []
    const fn = async (item: number) => {
      startedAt[item] = Date.now()
      await delay(item === 4 ? 250 : 10)
      finishedAt[item] = Date.now()
      return item
    }
    const items = Array.from({ length: 15 }, (_, i) => i)
    const results = await batchAsync(items, fn, 5)
    expect(results).toEqual(items)
    expect(startedAt[11]).toBeLessThan(finishedAt[4])
  })

  it('handles empty input and concurrency larger than the input', async () => {
    await expect(batchAsync([], () => Promise.resolve(1))).resolves.toEqual([])
    const results = await batchAsync([1, 2, 3], async value => value * 2, 10)
    expect(results).toEqual([2, 4, 6])
  })
})
