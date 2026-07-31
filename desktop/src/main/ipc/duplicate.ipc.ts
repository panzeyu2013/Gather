import type { CommandRegistry } from './registry'
import { ok, validateString, validateNumber, wrapHandler } from './helpers'
import type { DuplicateService } from '../services/duplicate/duplicate.service'
import type { JobService } from '../services/jobs/job.service'

export function registerDuplicateHandlers(
  registry: CommandRegistry,
  duplicateService: DuplicateService,
  jobs: JobService,
): void {
  jobs.registerExecutor('duplicate.scan', (job, context) => {
    return duplicateService.scanDuplicates(
      job.scopeId,
      typeof job.checkpoint.visualThreshold === 'number'
        ? job.checkpoint.visualThreshold
        : undefined,
      context.signal,
      (current, total, message) => context.updateProgress({
        current,
        total,
        message,
        checkpoint: job.checkpoint,
      }),
    )
  })
  registry.register(
    'dup.scan',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const visualThreshold = typeof params.visualThreshold === 'number'
        ? params.visualThreshold
        : undefined
      const job = jobs.create({
        type: 'duplicate.scan',
        scopeType: 'session',
        scopeId: sessionId,
        dedupeKey: `duplicate.scan:${sessionId}:${visualThreshold ?? 'default'}`,
        checkpoint: { visualThreshold },
      })
      const result = await jobs.waitForResult(job.id)
      return ok(result)
    }),
  )

  registry.register(
    'dup.groups',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const groups = duplicateService.getGroups(sessionId)
      return ok(groups)
    }),
  )

  registry.register(
    'dup.resolve',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('dup.resolve requires confirmation')
      }
      const groupId = validateNumber(params.groupId, 'groupId')
      const resolution = validateString(params.resolution, 'resolution')
      if (resolution !== 'keep_one' && resolution !== 'keep_all') {
        throw new Error('Invalid resolution: must be keep_one or keep_all')
      }
      await duplicateService.resolveGroup(groupId, resolution)
      return ok(true)
    }),
  )

  registry.register(
    'dup.resolve_member',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('dup.resolve_member requires confirmation')
      }
      const memberId = validateNumber(params.memberId, 'memberId')
      const isKept = typeof params.isKept === 'boolean' ? params.isKept : true
      await duplicateService.resolveMember(memberId, isKept)
      return ok(true)
    }),
  )
}
