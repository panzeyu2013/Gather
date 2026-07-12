import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'
import { WritebackService } from '../services/writeback/writeback.service'
import { getServices } from '../bootstrap'

function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

function err(error: string): ResponseErr {
  return { ok: false, error }
}

function validateString(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error(`Invalid ${name}: must be a non-empty string`)
  }
  return value.trim()
}

function wrapHandler(handler: (params: Record<string, unknown>) => unknown) {
  return async (params: unknown) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>)
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err(message)
    }
  }
}

export function registerWritebackHandlers(registry: CommandRegistry): void {
  const { writebackService } = getServices()
}
