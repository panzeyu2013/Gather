import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'
import { SessionService } from '../services/session/session.service'
import { SessionRepository } from '../db/repositories/session.repo'
import { PhotoRepository } from '../db/repositories/photo.repo'

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

function validateStringArray(value: unknown, name: string): string[] {
  if (!Array.isArray(value) || value.some((v) => typeof v !== 'string')) {
    throw new Error(`Invalid ${name}: must be a string array`)
  }
  return value as string[]
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

let service: SessionService | null = null

function getService(): SessionService {
  if (!service) {
    service = new SessionService(new SessionRepository(), new PhotoRepository())
  }
  return service
}

export function registerSessionHandlers(registry: CommandRegistry): void {
  registry.register(
    'session.create',
    wrapHandler(async (params) => {
      const name = validateString(params.name, 'name')
      const source = validateString(params.source ?? 'manual', 'source')
      const session = getService().createSession(name, source)
      if (Array.isArray(params.filepaths) && params.filepaths.length > 0) {
        const filepaths = validateStringArray(params.filepaths, 'filepaths')
        await getService().addPhotos(session.id, filepaths, source)
        return ok(getService().getSession(session.id))
      }
      return ok(session)
    }),
  )

  registry.register(
    'session.list',
    wrapHandler(async () => {
      return ok(getService().listSessions())
    }),
  )

  registry.register(
    'session.get',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const data = getService().getSession(sessionId)
      if (!data) return err('Session not found')
      return ok(data)
    }),
  )

  registry.register(
    'session.delete',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const confirmed = Boolean(params.confirmed)
      getService().deleteSession(sessionId, confirmed)
      return ok(true)
    }),
  )

  registry.register(
    'session.delete_many',
    wrapHandler(async (params) => {
      const ids = validateStringArray(params.sessionIds, 'sessionIds')
      if (ids.length === 0) {
        return err('No session IDs provided')
      }
      const confirmed = Boolean(params.confirmed)
      const count = getService().deleteSessions(ids, confirmed)
      return ok({ deletedCount: count })
    }),
  )

  registry.register(
    'session.add_photos',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const filepaths = validateStringArray(params.filepaths, 'filepaths')
      const source = typeof params.source === 'string' ? params.source : 'manual'
      return ok(await getService().addPhotos(sessionId, filepaths, source))
    }),
  )

  registry.register(
    'session.update',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const name = validateString(params.name, 'name')
      return ok(getService().updateSession(sessionId, name))
    }),
  )
}
