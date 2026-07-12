import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateStringArray, wrapHandler } from './helpers'
import { CullingService } from '../services/culling/culling.service'
import { WritebackService } from '../services/writeback/writeback.service'
import { getServices } from '../bootstrap'

function buildKeywords(target: string, decision: string): string[] {
  if (target === 'keyword') {
    return [`culling:${decision}`]
  } else if (target === 'rating') {
    return decision === 'keep' ? ['rating:5'] : ['rating:1']
  } else if (target === 'color_label') {
    return decision === 'keep' ? ['label:green'] : ['label:red']
  }
  return []
}

export function registerCullingHandlers(registry: CommandRegistry): void {
  const { cullingService, writebackService } = getServices()
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

      const decisions = cullingService.getDecisions(sessionId)
        .filter((d) => d.decision !== 'pending')

      if (decisions.length === 0) {
        throw new Error('No culling decisions to write back')
      }

      const decisionMap = new Map(decisions.map((d) => [d.photo_id, d.decision]))
      const decidedPhotoIds = new Set(decisions.map((d) => d.photo_id))

      const preview = await writebackService.preview(sessionId, 'culling', {} as Parameters<WritebackService['preview']>[2])

      const items = preview.items.filter((item) => decidedPhotoIds.has(item.photoId))

      for (const item of items) {
        const decision = decisionMap.get(item.photoId)
        if (decision) {
          item.keywords = buildKeywords(target, decision)
        }
      }

      return ok(await writebackService.execute(sessionId, 'culling', items))
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
}
