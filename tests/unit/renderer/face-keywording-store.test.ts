import { beforeEach, describe, expect, it } from 'vitest'
import { useFaceKwStore } from '../../../desktop/src/renderer/pages/FaceKeywording/faceKwStore'

describe('face keywording session state', () => {
  beforeEach(() => {
    useFaceKwStore.setState({
      sessionId: null,
      step: 'analyze',
      analysisStatus: 'idle',
      selectedClusterId: null,
    })
  })

  it('resets analysis state when the route session changes', () => {
    const store = useFaceKwStore.getState()
    store.setSessionId('session-a')
    useFaceKwStore.setState({
      step: 'review',
      analysisStatus: 'done',
    })

    useFaceKwStore.getState().setSessionId('session-b')

    expect(useFaceKwStore.getState()).toMatchObject({
      sessionId: 'session-b',
      step: 'analyze',
      analysisStatus: 'idle',
    })
  })

  it('ignores late analysis completion from a previous session', () => {
    useFaceKwStore.getState().setSessionId('session-b')
    useFaceKwStore.getState().finishAnalysis('session-a')

    expect(useFaceKwStore.getState()).toMatchObject({
      sessionId: 'session-b',
      step: 'analyze',
      analysisStatus: 'idle',
    })
  })

  it('ignores a late cluster selection from a previous session', () => {
    useFaceKwStore.getState().setSessionId('session-b')

    useFaceKwStore.getState().selectCluster('session-a', 42)
    expect(useFaceKwStore.getState().selectedClusterId).toBeNull()

    useFaceKwStore.getState().selectCluster('session-b', 42)
    expect(useFaceKwStore.getState().selectedClusterId).toBe(42)
  })

  it('moves to review only for the active session', () => {
    useFaceKwStore.getState().setSessionId('session-a')
    useFaceKwStore.getState().finishAnalysis('session-a')

    expect(useFaceKwStore.getState()).toMatchObject({
      step: 'review',
      analysisStatus: 'done',
    })
  })
})
