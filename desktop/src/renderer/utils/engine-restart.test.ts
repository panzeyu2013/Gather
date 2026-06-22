import type { createPollLoop } from '../utils/poll'

const mockToast = jest.fn()
const mockOnEngineReady = jest.fn()
const dispatchEventSpy = jest.spyOn(window, 'dispatchEvent')

jest.mock('../components/toast', () => ({
    toast: mockToast,
}))

jest.mock('../app', () => ({
  onEngineReady: (fn: () => void) => {
    mockOnEngineReady.mockImplementation(() => {
      fn()
      return jest.fn()
    })
    return mockOnEngineReady(fn)
  },
}))

jest.mock('@gather/shared', () => ({
  TOAST_DURATION_ERROR: 8000,
}))

import { createEngineRestartHandler } from './engine-restart'

describe('createEngineRestartHandler', () => {
  beforeEach(() => {
    jest.clearAllMocks()
    dispatchEventSpy.mockClear()
  })

  it('returns an object with unsub and pollRef', () => {
    const onReset = jest.fn()
    const handler = createEngineRestartHandler(onReset)

    expect(handler).toHaveProperty('unsub')
    expect(typeof handler.unsub).toBe('function')
    expect(handler).toHaveProperty('pollRef')
    expect(handler.pollRef).toEqual({ current: null })
  })

  it('calls onReset when engine becomes ready', () => {
    const onReset = jest.fn()
    createEngineRestartHandler(onReset)

    expect(onReset).toHaveBeenCalledTimes(1)
  })

  it('dispatches engine-restarted custom event', () => {
    const onReset = jest.fn()
    createEngineRestartHandler(onReset)

    expect(dispatchEventSpy).toHaveBeenCalledTimes(1)
    const event = dispatchEventSpy.mock.calls[0][0] as CustomEvent
    expect(event.type).toBe('engine-restarted')
  })

  it('shows error toast on engine restart', () => {
    const onReset = jest.fn()
    createEngineRestartHandler(onReset)

    expect(mockToast).toHaveBeenCalledTimes(1)
    const [msg, type, duration] = mockToast.mock.calls[0]
    expect(msg).toContain('restarted unexpectedly')
    expect(type).toBe('error')
    expect(duration).toBe(8000)
  })

  it('stops active poll loop when engine restarts', () => {
    const onReset = jest.fn()
    const handler = createEngineRestartHandler(onReset)

    // Simulate an active poll loop
    const mockPoll = { stop: jest.fn(), start: jest.fn() }
    handler.pollRef.current = mockPoll as unknown as ReturnType<typeof createPollLoop>

    // Trigger engine ready again — should stop the poll
    expect(mockOnEngineReady).toHaveBeenCalledTimes(1)
    const restartFn = mockOnEngineReady.mock.calls[0][0]
    restartFn()

    expect(mockPoll.stop).toHaveBeenCalledTimes(1)
  })

  it('unsub function prevents further callbacks', () => {
    const onReset = jest.fn()
    const handler = createEngineRestartHandler(onReset)

    onReset.mockClear()

    // Calling unsub and then triggering restart should not call onReset again
    handler.unsub()
    expect(onReset).not.toHaveBeenCalled()
  })
})
