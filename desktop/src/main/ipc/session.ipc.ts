import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateStringArray, wrapHandler } from './helpers'
import { getServices } from '../bootstrap'

export function registerSessionHandlers(registry: CommandRegistry): void {
  const { sessionService } = getServices()
  registry.register(
    'session.create',
    wrapHandler(async (params) => {
      const name = validateString(params.name, 'name')
      const source = validateString(params.source ?? 'manual', 'source')
      const session = sessionService.createSession(name, source)
      if (Array.isArray(params.filepaths) && params.filepaths.length > 0) {
        const filepaths = validateStringArray(params.filepaths, 'filepaths')
        sessionService.addPhotos(session.id, filepaths, source)
        return ok(sessionService.getSession(session.id))
      }
      return ok(session)
    }),
  )

  registry.register(
    'session.list',
    wrapHandler(async () => {
      return ok(sessionService.listSessions())
    }),
  )

  registry.register(
    'session.get',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const data = sessionService.getSession(sessionId)
      if (!data) return err('Session not found')
      return ok(data)
    }),
  )

  registry.register(
    'session.delete',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const confirmed = Boolean(params.confirmed)
      sessionService.deleteSession(sessionId, confirmed)
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
      const count = sessionService.deleteSessions(ids, confirmed)
      return ok({ deletedCount: count })
    }),
  )

  registry.register(
    'session.add_photos',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const filepaths = validateStringArray(params.filepaths, 'filepaths')
      const source = typeof params.source === 'string' ? params.source : 'manual'
      return ok(sessionService.addPhotos(sessionId, filepaths, source))
    }),
  )

  registry.register(
    'session.update',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const name = validateString(params.name, 'name')
      return ok(sessionService.updateSession(sessionId, name))
    }),
  )
}
