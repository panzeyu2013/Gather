import type { Command, Response } from '@gather/shared'
import { CancelledError } from '@gather/shared'

export async function sendCommand<T = unknown>(
  cmd: Command['type'],
  params?: Record<string, unknown>,
): Promise<T> {
  const result = (await window.gather.sendCommand(cmd, params ?? {})) as Response<T>
  if (!result.ok) {
    if (typeof result.error === 'object' && result.error.type === 'CancelledError') {
      throw new CancelledError(result.error.message)
    }
    const errorObject = typeof result.error === 'object' ? result.error : undefined
    const errorMsg = typeof result.error === 'string' ? result.error : result.error.message
    const error = new Error(errorMsg)
    if (errorObject && typeof errorObject.params === 'object' && errorObject.params !== null) {
      ;(error as Error & { params?: Record<string, unknown> }).params = errorObject.params
    }
    throw error
  }
  return result.data
}

export function onProgress(callback: (data: unknown) => void): () => void {
  return window.gather.onEvent('progress', callback)
}

