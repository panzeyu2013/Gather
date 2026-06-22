const toastMock = jest.fn()

jest.mock('./components/toast', () => ({
  toast: toastMock,
}))

describe('renderer api contract', () => {
  beforeEach(() => {
    toastMock.mockReset()
  })

  afterEach(() => {
    delete (window as { gather?: unknown }).gather
  })

  function setMockWindow(sendCommandResult: unknown): void {
    window.gather = {
      sendCommand: jest.fn().mockResolvedValue(sendCommandResult),
      onEvent: jest.fn(),
      onReady: jest.fn(),
      getSelectedPhotos: jest.fn(),
      reloadMetadata: jest.fn(),
      selectDirectory: jest.fn(),
      selectFiles: jest.fn(),
      getVersion: jest.fn(),
    }
  }

  const sessionRecord = {
    id: '1',
    name: 'S1',
    status: 'draft',
    event_date: '',
    analysis_status: 'idle',
    writeback_status: 'idle',
    created_at: '2026-01-01T00:00:00',
    updated_at: '2026-01-01T00:00:00',
    photo_count: 0,
  }

  it('accepts raw object responses from the main process', async () => {
    setMockWindow({ sessions: [sessionRecord] })

    const { engine } = await import('./api')
    const sessions = await engine.session.list()

    expect(sessions).toEqual([sessionRecord])
  })

  it('does not treat a raw data object with an error field as a transport failure', async () => {
    setMockWindow({ status: 'failed', error: 'domain-level failure' })

    const { engine } = await import('./api')
    const result = await engine.sim.getResult('sid')

    expect(result).toEqual({ status: 'failed', error: 'domain-level failure' })
  })

  it('rejects malformed session list responses instead of showing an empty dashboard', async () => {
    setMockWindow({ sessions: 'not-an-array' })

    const { engine } = await import('./api')

    await expect(engine.session.list()).rejects.toThrow('invalid sessions payload')
  })

  it('rejects malformed session records', async () => {
    setMockWindow({ sessions: [{ id: '1', status: 'draft' }] })

    const { engine } = await import('./api')

    await expect(engine.session.list()).rejects.toThrow('malformed session data')
  })

  it('rejects create responses without a session id', async () => {
    setMockWindow({ name: 'missing id' })

    const { engine } = await import('./api')

    await expect(engine.session.create('Bad')).rejects.toThrow('invalid session id')
  })
})
