import { onEngineReady } from '../app'
import { toast } from '../components/toast'
import { TOAST_DURATION_ERROR } from '@gather/shared'
import type { createPollLoop } from './poll'

export interface EngineRestartHandler {
  unsub: () => void
  pollRef: { current: ReturnType<typeof createPollLoop> | null }
}

export function createEngineRestartHandler(onReset: () => void): EngineRestartHandler {
  const pollRef: EngineRestartHandler['pollRef'] = { current: null }

  const unsub = onEngineReady(() => {
    pollRef.current?.stop()
    onReset()
    window.dispatchEvent(new CustomEvent('engine-restarted'))
    toast(
      'The analysis engine restarted unexpectedly. Your analysis was interrupted. Please start again.',
      'error',
      TOAST_DURATION_ERROR,
    )
  })

  return { unsub, pollRef }
}
