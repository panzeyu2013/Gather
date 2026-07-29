import type { CommandRegistry } from './registry'
import { ok, validateString, validateStringArray, wrapHandler } from './helpers'
import type { CullingService } from '../services/culling/culling.service'
import type { WritebackService } from '../services/writeback/writeback.service'
import { buildCullingWritebackPlan } from '../services/writeback/writeback-planners'

export function registerCullingHandlers(registry: CommandRegistry, cullingService: CullingService, writebackService: WritebackService): void {
  registry.register(
    'culling.groups',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const groups = await cullingService.getGroups(sessionId)
      return ok(groups)
    }),
  )

  registry.register(
    'culling.decide',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const photoId = validateString(params.photoId, 'photoId')
      const decision = validateString(params.decision, 'decision')
      if (!['keep', 'reject', 'pending'].includes(decision)) {
        throw new Error('Invalid decision: must be keep, reject, or pending')
      }
      await cullingService.decide(sessionId, photoId, decision)
      return ok(true)
    }),
  )

  registry.register(
    'culling.batch_decide',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const photoIds = validateStringArray(params.photoIds, 'photoIds')
      const decision = validateString(params.decision, 'decision')
      if (!['keep', 'reject', 'pending'].includes(decision)) {
        throw new Error('Invalid decision: must be keep, reject, or pending')
      }
      await cullingService.batchDecide(sessionId, photoIds, decision)
      return ok(true)
    }),
  )

  registry.register(
    'culling.summary',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const summary = await cullingService.getSummary(sessionId)
      return ok(summary)
    }),
  )

  registry.register(
    'culling.writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Writeback requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const target = validateString(params.target, 'target')
      if (!['rating', 'color_label', 'keyword'].includes(target)) {
        throw new Error('Invalid target: must be rating, color_label, or keyword')
      }

      const plan = buildCullingWritebackPlan(
        cullingService.getDecisions(sessionId),
        target as 'rating' | 'color_label' | 'keyword',
      )
      if (plan.size === 0) {
        throw new Error('No culling decisions to write back')
      }

      const decidedPhotoIds = new Set(plan.keys())

      const preview = await writebackService.preview(sessionId, 'culling', {}, decidedPhotoIds)

      const matchingItems = preview.items.filter((item) => decidedPhotoIds.has(item.photoId))

      for (const item of matchingItems) {
        const attributes = plan.get(item.photoId)
        if (!attributes || item.id == null) continue
        item.attributes = attributes.keywords
          ? { keywords: [...new Set([...item.keywords, ...attributes.keywords])] }
          : attributes
      }

      await writebackService.persistAttributes(matchingItems)

      return ok(await writebackService.execute(sessionId, 'culling', matchingItems))
    }),
  )

  registry.register(
    'culling.reset',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('culling.reset requires confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const groupId = typeof params.groupId === 'string' ? params.groupId : undefined
      await cullingService.reset(sessionId, groupId)
      return ok(true)
    }),
  )

  registry.register(
    'culling.retry_failed_writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Retry failed writeback requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.retryFailed(sessionId, 'culling'))
    }),
  )

  registry.register(
    'culling.confirm_sync',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await writebackService.confirmSync(sessionId, 'culling')
      return ok(true)
    }),
  )

  registry.register(
    'culling.cleanup',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Cleanup requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.cleanup(sessionId, 'culling'))
    }),
  )
}
