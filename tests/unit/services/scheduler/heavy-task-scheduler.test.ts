import { describe, expect, it } from 'vitest'
import { HeavyTaskScheduler } from '../../../../desktop/src/main/utils/heavy-task-scheduler'

function defer(): { promise: Promise<void>; resolve: () => void } {
  let resolve!: () => void
  const promise = new Promise<void>((r) => { resolve = r })
  return { promise, resolve }
}

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

describe('HeavyTaskScheduler weighted budget', () => {
  it('keeps two weight-2 tasks mutually exclusive under a budget of 2', async () => {
    const scheduler = new HeavyTaskScheduler(2)
    let active = 0
    let maxActive = 0
    const gateA = defer()
    const gateB = defer()
    const first = scheduler.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await gateA.promise
      active--
    }, 1, 2)
    const second = scheduler.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await gateB.promise
      active--
    }, 1, 2)

    await tick()
    expect(active).toBe(1)

    gateA.resolve()
    await first
    await tick()
    expect(active).toBe(1)

    gateB.resolve()
    await second
    expect(maxActive).toBe(1)
  })

  it('lets weight-1 tasks fill the budget in parallel', async () => {
    const scheduler = new HeavyTaskScheduler(2)
    let active = 0
    let maxActive = 0
    const gates: (() => void)[] = []
    const tasks = Array.from({ length: 4 }, () => scheduler.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await new Promise<void>((resolve) => gates.push(resolve))
      active--
    }, 1, 1))

    await tick()
    expect(active).toBe(2)

    gates.shift()!()
    await tick()
    gates.shift()!()
    await tick()
    gates.shift()!()
    await tick()
    gates.shift()!()
    await Promise.all(tasks)
    expect(maxActive).toBe(2)
  })

  it('admits queued tasks in (priority, order) order after a slot frees', async () => {
    const scheduler = new HeavyTaskScheduler(1)
    const started: string[] = []
    const gate = defer()
    const first = scheduler.run(async () => {
      started.push('first')
      await gate.promise
    }, 5, 1)

    await tick()
    const high = scheduler.run(async () => { started.push('high') }, 1, 1)
    const low = scheduler.run(async () => { started.push('low') }, 3, 1)
    await tick()

    gate.resolve()
    await Promise.all([first, high, low])
    expect(started).toEqual(['first', 'high', 'low'])
  })

  it('prefers a queued weight-2 task over a later weight-1 task when budget frees', async () => {
    const scheduler = new HeavyTaskScheduler(2)
    const started: string[] = []
    const blockerGate = defer()
    const heavyGate = defer()
    const blocker = scheduler.run(async () => {
      started.push('blocker')
      await blockerGate.promise
    }, 1, 2)

    await tick()
    const heavy = scheduler.run(async () => {
      started.push('heavy')
      await heavyGate.promise
    }, 1, 2)
    const light = scheduler.run(async () => { started.push('light') }, 2, 1)
    await tick()
    expect(started).toEqual(['blocker'])

    blockerGate.resolve()
    await blocker
    await tick()
    expect(started).toEqual(['blocker', 'heavy'])

    heavyGate.resolve()
    await heavy
    await tick()
    await light
    expect(started).toEqual(['blocker', 'heavy', 'light'])
  })

  it('clamps weights to integers of at least 1', async () => {
    const scheduler = new HeavyTaskScheduler(2)
    let active = 0
    let maxActive = 0
    const gate = defer()
    const first = scheduler.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await gate.promise
      active--
    }, 1, 0)
    const second = scheduler.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      active--
    }, 1, 2.9)

    await tick()
    expect(active).toBe(1)

    gate.resolve()
    await first
    await tick()
    await second
    expect(maxActive).toBe(1)
  })

  it('keeps two-argument calls working with weight defaulting to 1', async () => {
    const scheduler = new HeavyTaskScheduler(2)
    let active = 0
    let maxActive = 0
    const gates: (() => void)[] = []
    const tasks = Array.from({ length: 3 }, () => scheduler.run(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await new Promise<void>((resolve) => gates.push(resolve))
      active--
    }, 1))

    await tick()
    expect(active).toBe(2)

    gates.shift()!()
    await tick()
    gates.shift()!()
    await tick()
    gates.shift()!()
    await Promise.all(tasks)
    expect(maxActive).toBe(2)
  })
})
