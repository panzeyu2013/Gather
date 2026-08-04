import { afterEach, describe, expect, it, vi } from 'vitest'
import { sendCommand, onProgress } from '../../../desktop/src/renderer/api/client'
import { CancelledError } from '../../../packages/shared/src'

function mockGather() {
  const sendCommand = vi.fn()
  const onEvent = vi.fn(() => () => undefined)
  ;(window as unknown as { gather: unknown }).gather = { sendCommand, onEvent }
  return { sendCommand, onEvent }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('api/client sendCommand', () => {
  it('returns data for a successful response', async () => {
    const { sendCommand: invoke } = mockGather()
    invoke.mockResolvedValue({ ok: true, data: { id: 's1' } })

    const data = await sendCommand<{ id: string }>('session.get', { sessionId: 's1' })

    expect(invoke).toHaveBeenCalledWith('session.get', { sessionId: 's1' })
    expect(data).toEqual({ id: 's1' })
  })

  it('throws a regular Error for a failure response', async () => {
    const { sendCommand: invoke } = mockGather()
    invoke.mockResolvedValue({ ok: false, error: 'boom' })

    await expect(sendCommand('session.get', { sessionId: 's1' }))
      .rejects.toThrow('boom')
  })

  it('throws a CancelledError for a structured cancellation response', async () => {
    const { sendCommand: invoke } = mockGather()
    invoke.mockResolvedValue({
      ok: false,
      error: { type: 'CancelledError', message: 'user cancelled' },
    })

    await expect(sendCommand('sim.analyze', { sessionId: 's1' }))
      .rejects.toBeInstanceOf(CancelledError)
  })

  it('surfaces an unexpected invoke rejection as-is', async () => {
    const { sendCommand: invoke } = mockGather()
    invoke.mockRejectedValue(new Error('ipc died'))

    await expect(sendCommand('session.list')).rejects.toThrow('ipc died')
  })
})

describe('api/client onProgress', () => {
  it('delegates to the preload event subscription and returns an unsubscribe', () => {
    const { onEvent } = mockGather()
    const callback = vi.fn()
    const unsubscribe = vi.fn()

    onEvent.mockReturnValue(unsubscribe)
    const result = onProgress(callback)

    expect(onEvent).toHaveBeenCalledWith('progress', callback)
    expect(result).toBe(unsubscribe)
  })
})
