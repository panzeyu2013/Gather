import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateNumber, wrapHandler } from './helpers'
import { getServices } from '../bootstrap'

export function registerDuplicateHandlers(registry: CommandRegistry): void {
  const { duplicateService } = getServices()
  registry.register(
    'dup.scan',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const sessionIds = Array.isArray(params.sessionIds)
        ? (params.sessionIds as string[]).filter(
            (s): s is string => typeof s === 'string' && s.trim().length > 0,
          )
        : undefined
      const visualThreshold = typeof params.visualThreshold === 'number'
        ? params.visualThreshold
        : undefined
      const result = await duplicateService.scanDuplicates(sessionId, sessionIds, visualThreshold)
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
