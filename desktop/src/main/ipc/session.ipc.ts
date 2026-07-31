import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateStringArray, wrapHandler } from './helpers'
import { SessionService, sanitizeSessionSourcePath } from '../services/session/session.service'

export function registerSessionHandlers(registry: CommandRegistry, sessionService: SessionService): void {
  registry.register(
    'session.create',
    wrapHandler(async (params) => {
      const name = validateString(params.name, 'name')
      const source = validateString(params.source ?? 'manual', 'source')
      const filepaths = Array.isArray(params.filepaths)
        ? validateStringArray(params.filepaths, 'filepaths')
        : []
      const sourcePath = sanitizeSessionSourcePath(
        validateString(params.sourcePath ?? '', 'sourcePath', 4096, true),
        filepaths,
      )
      const session = sessionService.createSession(name, source, sourcePath)
      if (filepaths.length > 0) {
        const result = await sessionService.addPhotos(session.id, filepaths, source)
        const sessionData = sessionService.getSession(session.id)
        return ok({ ...sessionData, failedFiles: result.failedFiles, added: result.added, skipped: result.skipped })
      }
      return ok({ ...session, failedFiles: [], added: 0, skipped: 0 })
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
      const confirmed = params.confirmed === true
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
      const confirmed = params.confirmed === true
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
      return ok(await sessionService.addPhotos(sessionId, filepaths, source))
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
