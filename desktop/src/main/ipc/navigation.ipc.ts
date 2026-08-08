import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { NavigationService } from '../services/navigation/navigation.service'

export function registerNavigationHandlers(registry: CommandRegistry, navigation: NavigationService): void {
  registry.register('navigation.analyze', wrapHandler(async params => {
    const burstGapSeconds = typeof params.burstGapSeconds === 'number' ? params.burstGapSeconds : undefined
    const sceneGapSeconds = typeof params.sceneGapSeconds === 'number' ? params.sceneGapSeconds : undefined
    return ok(navigation.analyze(
      validateString(params.sessionId, 'sessionId'),
      burstGapSeconds,
      sceneGapSeconds,
      params.dryRun === true,
    ))
  }))
  registry.register('navigation.list', wrapHandler(async params => {
    return ok(navigation.list(validateString(params.sessionId, 'sessionId')))
  }))
  registry.register('navigation.split', wrapHandler(async params => {
    return ok(navigation.split(
      validateString(params.sessionId, 'sessionId'),
      validateString(params.groupId, 'groupId'),
      validateString(params.beforePhotoId, 'beforePhotoId'),
    ))
  }))
  registry.register('navigation.merge', wrapHandler(async params => {
    // ADR-017: internal-invariant diagnostic — the service re-validates this
    // and maps the user-reachable condition to NAV_MERGE_MIN_TWO.
    if (!Array.isArray(params.groupIds) || params.groupIds.length < 2) {
      throw new Error('groupIds must contain at least two groups')
    }
    return ok(navigation.merge(
      validateString(params.sessionId, 'sessionId'),
      params.groupIds.map((id, index) => validateString(id, `groupIds[${index}]`)),
    ))
  }))
}
