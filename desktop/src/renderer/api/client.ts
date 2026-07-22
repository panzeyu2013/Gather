import type { Response } from '@gather/shared'
import { CancelledError } from '@gather/shared'

export async function sendCommand<T = unknown>(cmd: string, params?: Record<string, unknown>): Promise<T> {
  const result = (await window.gather.sendCommand(cmd, params ?? {})) as Response<T>
  if (!result.ok) {
    if (typeof result.error === 'object' && result.error.type === 'CancelledError') {
      throw new CancelledError(result.error.message)
    }
    const errorMsg = typeof result.error === 'string' ? result.error : result.error.message
    throw new Error(errorMsg)
  }
  return result.data
}

export function onProgress(callback: (data: unknown) => void): () => void {
  return window.gather.onEvent('progress', callback)
}


