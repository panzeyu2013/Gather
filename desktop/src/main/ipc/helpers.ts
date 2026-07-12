import type { ResponseOk, ResponseErr } from '@gather/shared'

export function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

export function err(error: string): ResponseErr {
  return { ok: false, error }
}

export function validateString(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(`Invalid ${name}: must be a non-empty string`)
  }
  return value.trim()
}

export function validateStringArray(value: unknown, name: string): string[] {
  if (!Array.isArray(value) || value.some((v) => typeof v !== 'string')) {
    throw new Error(`Invalid ${name}: must be a string array`)
  }
  return value as string[]
}

export function validateNumber(value: unknown, name: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`Invalid ${name}: must be a finite number`)
  }
  return value
}

export type IpcHandler = (params: Record<string, unknown>, event?: Electron.IpcMainInvokeEvent) => unknown

export function wrapHandler(handler: IpcHandler) {
  return async (params: unknown, event?: Electron.IpcMainInvokeEvent) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>, event)
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err(message)
    }
  }
}
