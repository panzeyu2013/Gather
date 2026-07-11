import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'
import { WritebackService } from '../services/writeback/writeback.service'
import { WritebackRepository } from '../db/repositories/writeback.repo'
import { XmpWriter } from '../services/xmp/xmp-writer'
import { PhotoRepository } from '../db/repositories/photo.repo'
import { SessionRepository } from '../db/repositories/session.repo'

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

let service: WritebackService | null = null

function getService(): WritebackService {
  if (!service) {
    service = new WritebackService(
      new WritebackRepository(),
      new XmpWriter(),
      new PhotoRepository(),
      new SessionRepository(),
    )
  }
  return service
}

export function registerWritebackHandlers(registry: CommandRegistry): void {
}
