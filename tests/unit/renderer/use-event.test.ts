import { act, renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { useEvent } from '../../../desktop/src/renderer/hooks/useEvent'

const listeners = new Map<string, Set<(data: unknown) => void>>()

function mockGather(): void {
  ;(window as unknown as { gather: unknown }).gather = {
    onEvent: (type: string, callback: (data: unknown) => void) => {
      const set = listeners.get(type) ?? new Set()
      set.add(callback)
      listeners.set(type, set)
      return () => set.delete(callback)
    },
  }
}

afterEach(() => {
  listeners.clear()
  vi.restoreAllMocks()
})

describe('useEvent', () => {
  it('subscribes once and delivers latest callback updates', () => {
    mockGather()
    const onEvent = vi.spyOn(
      (window as unknown as { gather: { onEvent: unknown } }).gather,
      'onEvent',
    )
    const first = vi.fn()
    const { rerender, unmount } = renderHook(
      ({ callback }) => useEvent('progress', callback),
      { initialProps: { callback: first } },
    )

    expect(onEvent).toHaveBeenCalledTimes(1)

    const second = vi.fn()
    rerender({ callback: second })
    expect(onEvent).toHaveBeenCalledTimes(1)

    const handler = onEvent.mock.calls[0][1] as (data: unknown) => void
    act(() => handler({ current: 1 }))
    expect(first).not.toHaveBeenCalled()
    expect(second).toHaveBeenCalledWith({ current: 1 })

    unmount()
    expect(listeners.get('progress')?.size ?? 0).toBe(0)
  })

  it('does not subscribe while disabled', () => {
    mockGather()
    const onEvent = vi.spyOn(
      (window as unknown as { gather: { onEvent: unknown } }).gather,
      'onEvent',
    )
    renderHook(({ enabled }) => useEvent('jobs:progress', vi.fn(), enabled), {
      initialProps: { enabled: false },
    })
    expect(onEvent).not.toHaveBeenCalled()
  })
})
