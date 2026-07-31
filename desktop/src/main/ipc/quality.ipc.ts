import type { CommandRegistry } from './registry'
import { ok, validateString, validateStringArray, wrapHandler } from './helpers'
import type { QualityService } from '../services/quality/quality.service'
import type { JobService } from '../services/jobs/job.service'

export function registerQualityHandlers(registry: CommandRegistry, quality: QualityService, jobs: JobService): void {
  jobs.registerExecutor('quality.score', (job, context) => {
    const photoIds = Array.isArray(job.checkpoint.photoIds)
      ? job.checkpoint.photoIds.filter((id): id is string => typeof id === 'string')
      : undefined
    return quality.analyze(job.scopeId, photoIds, context)
  })
  registry.register('quality.analyze', wrapHandler(async (params) => {
    const photoIds = params.photoIds === undefined
      ? undefined
      : validateStringArray(params.photoIds, 'photoIds')
    const sessionId = validateString(params.sessionId, 'sessionId')
    const job = jobs.create({
      type: 'quality.score', scopeType: 'session', scopeId: sessionId,
      dedupeKey: `quality.score:${sessionId}:${photoIds?.slice().sort().join(',') ?? 'all'}`,
      checkpoint: { photoIds },
    })
    return ok(job)
  }))
  registry.register('quality.get', wrapHandler(async (params) => {
    const photoIds = params.photoIds === undefined
      ? undefined
      : validateStringArray(params.photoIds, 'photoIds')
    return ok(quality.get(validateString(params.sessionId, 'sessionId'), photoIds))
  }))
}
