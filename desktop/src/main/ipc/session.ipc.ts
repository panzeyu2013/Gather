import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateStringArray, wrapHandler } from './helpers'
import { SessionService, sanitizeSessionSourcePath } from '../services/session/session.service'
import type { JobService } from '../services/jobs/job.service'

export function registerSessionHandlers(
  registry: CommandRegistry,
  sessionService: SessionService,
  jobs: JobService,
): void {
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
      const truncatedImport = params.truncatedImport === true
      const session = sessionService.createSession(name, source, sourcePath, truncatedImport)
      if (filepaths.length > 0) {
        const result = await sessionService.addPhotos(session.id, filepaths, source)
        const sessionData = sessionService.getSession(session.id)
        return ok({ ...sessionData, failedFiles: result.failedFiles, added: result.added, skipped: result.skipped })
      }
      return ok({ ...session, failedFiles: [], added: 0, skipped: 0 })
    }),
  )

  // One-hop local import: the renderer sends only a source path — never a file
  // array. The session row is created here and the existing `metadata.scan`
  // job (the indexer's streaming walk) is enqueued immediately with the same
  // dedupeKey the renderer-side `index.scan` trigger uses, so a duplicate
  // request from SessionDetail collapses onto this job.
  registry.register(
    'session.create_from_directory',
    wrapHandler(async (params) => {
      const name = validateString(params.name ?? '', 'name', 4096, true)
      const sourcePath = validateString(params.sourcePath, 'sourcePath', 4096)
      const session = await sessionService.createFromDirectory(name, sourcePath)
      try {
        jobs.create({
          type: 'metadata.scan',
          scopeType: 'session',
          scopeId: session.id,
          dedupeKey: `metadata.scan:${session.id}`,
        })
      } catch (error) {
        // Enqueue failure would leave an orphaned session row whose photos
        // never get indexed; roll the row back before rethrowing so the
        // workspace list never surfaces a half-created session.
        try {
          sessionService.deleteSession(session.id, true)
        } catch {
          // Best-effort cleanup; the session row may already be gone.
        }
        throw error
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
      if (!data) return err('SESSION_NOT_FOUND')
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
        return err('SESSION_IDS_REQUIRED')
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
