import type { ResponseOk, ResponseErr } from '@gather/shared'
import { ValidationError } from '@gather/shared'

export function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

export function err(error: string | { type: string; message: string }): ResponseErr {
  return { ok: false, error }
}

export function validateString(value: unknown, name: string, maxLength = 4096): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ValidationError(`Invalid ${name}: must be a non-empty string`)
  }
  if (value.length > maxLength) {
    throw new ValidationError(`Invalid ${name}: exceeds maximum length of ${maxLength}`)
  }
  return value.trim()
}

export function validateStringArray(value: unknown, name: string, maxLength = 4096): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.some((v) => typeof v !== 'string')) {
    throw new ValidationError(`Invalid ${name}: must be a non-empty string array`)
  }
  for (const v of value as string[]) {
    if (v.length > maxLength) {
      throw new ValidationError(`Invalid ${name}: item exceeds maximum length of ${maxLength}`)
    }
  }
  return value as string[]
}

export function validateNumber(value: unknown, name: string, min?: number, max?: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new ValidationError(`Invalid ${name}: must be a finite number`)
  }
  if (min !== undefined && value < min) {
    throw new ValidationError(`Invalid ${name}: must be >= ${min}`)
  }
  if (max !== undefined && value > max) {
    throw new ValidationError(`Invalid ${name}: must be <= ${max}`)
  }
  return value
}

export type IpcHandler = (params: Record<string, unknown>, event?: Electron.IpcMainInvokeEvent) => unknown

export function wrapHandler(handler: IpcHandler) {
  return async (params: unknown, event?: Electron.IpcMainInvokeEvent) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>, event)
    } catch (e: unknown) {
      if (e instanceof ValidationError) {
        return err({ type: 'ValidationError', message: e.message })
      }
      console.error('[IPC Handler Error]', e)
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err({ type: 'RuntimeError', message })
    }
  }
}
