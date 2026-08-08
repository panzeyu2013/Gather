import type { CommandRegistry } from './registry'
import { ok, validateString, validateStringArray, wrapHandler } from './helpers'
import type { CullingService } from '../services/culling/culling.service'
import type { WritebackService } from '../services/writeback/writeback.service'
import { buildCullingWritebackPlan } from '../services/writeback/writeback-planners'
import type { MetadataSyncCoordinator } from '../services/metadata/metadata-sync-coordinator'
import type {
  CaptureOneColorLabel,
  CullingFilters,
  CullingScope,
  CullingUpdatePatch,
  PickState,
} from '@gather/shared'

const PICK_STATES = new Set(['unreviewed', 'picked', 'rejected'])
const COLOR_LABELS = new Set([
  'None', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple',
])

function parseFilters(value: unknown): CullingFilters | undefined {
  if (value === undefined) return undefined
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('filters must be an object')
  }
  const input = value as Record<string, unknown>
  const filters: CullingFilters = {}
  if (input.unreviewedOnly !== undefined) {
    if (typeof input.unreviewedOnly !== 'boolean') {
      throw new Error('unreviewedOnly must be a boolean')
    }
    filters.unreviewedOnly = input.unreviewedOnly
  }
  if (input.ratings !== undefined) {
    if (
      !Array.isArray(input.ratings) ||
      input.ratings.some(rating => !Number.isInteger(rating) || rating < 0 || rating > 5)
    ) {
      throw new Error('ratings must contain integers from 0 to 5')
    }
    filters.ratings = input.ratings as number[]
  }
  if (input.pickStates !== undefined) {
    if (
      !Array.isArray(input.pickStates) ||
      input.pickStates.some(state => typeof state !== 'string' || !PICK_STATES.has(state))
    ) {
      throw new Error('pickStates contains an invalid state')
    }
    filters.pickStates = input.pickStates as PickState[]
  }
  if (input.colorLabels !== undefined) {
    if (
      !Array.isArray(input.colorLabels) ||
      input.colorLabels.some(label => typeof label !== 'string' || !COLOR_LABELS.has(label))
    ) {
      throw new Error('colorLabels contains an invalid label')
    }
    filters.colorLabels = input.colorLabels as CaptureOneColorLabel[]
  }
  if (input.qualityStatus !== undefined) {
    if (!['analysed', 'unanalysed', 'failed'].includes(String(input.qualityStatus))) {
      throw new Error('qualityStatus is invalid')
    }
    filters.qualityStatus = input.qualityStatus as CullingFilters['qualityStatus']
  }
  if (input.metadataConflictOnly !== undefined) {
    if (typeof input.metadataConflictOnly !== 'boolean') {
      throw new Error('metadataConflictOnly must be a boolean')
    }
    filters.metadataConflictOnly = input.metadataConflictOnly
  }
  return filters
}

export function registerCullingHandlers(
  registry: CommandRegistry,
  cullingService: CullingService,
  writebackService: WritebackService,
  metadataSync: MetadataSyncCoordinator,
): void {
  registry.register(
    'culling.list',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const scope = validateString(params.scope, 'scope') as CullingScope
      if (!['all', 'filtered', 'similarity_group'].includes(scope)) {
        throw new Error('Invalid culling scope')
      }
      const filters = parseFilters(params.filters)
      const groupId = typeof params.groupId === 'string' ? params.groupId : undefined
      return ok(cullingService.list(sessionId, scope, filters, groupId))
    }),
  )

  registry.register(
    'culling.list_page',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const scope = validateString(params.scope, 'scope') as CullingScope
      if (!['all', 'filtered', 'similarity_group'].includes(scope)) {
        throw new Error('Invalid culling scope')
      }
      const filters = parseFilters(params.filters)
      const groupId = typeof params.groupId === 'string' ? params.groupId : undefined
      // afterRowId is the opaque keyset cursor returned as `nextRowId` by the
      // previous page: the first rowid of its last asset group (asset-grouped
      // pagination keeps RAW/JPEG variants on one page). Still a photos.rowid
      // value, so validation is unchanged.
      const afterRowId = params.afterRowId === undefined ? undefined : Number(params.afterRowId)
      if (afterRowId !== undefined && (!Number.isInteger(afterRowId) || afterRowId < 1)) {
        throw new Error('afterRowId must be a positive integer')
      }
      const limit = params.limit === undefined ? 200 : Number(params.limit)
      if (!Number.isInteger(limit) || limit < 1 || limit > 2000) {
        throw new Error('limit must be an integer between 1 and 2000')
      }
      return ok(cullingService.listPage(sessionId, scope, filters, groupId, afterRowId, limit))
    }),
  )

  registry.register('culling.history', wrapHandler(async (params) => {
    const sessionId = validateString(params.sessionId, 'sessionId')
    const limit = params.limit === undefined ? undefined : Number(params.limit)
    if (limit !== undefined && (!Number.isInteger(limit) || limit < 1 || limit > 500)) {
      throw new Error('limit must be an integer between 1 and 500')
    }
    return ok(cullingService.getHistory(sessionId, limit))
  }))

  registry.register('culling.apply_history', wrapHandler(async params => {
    const sessionId = validateString(params.sessionId, 'sessionId')
    if (!Array.isArray(params.entries) || params.entries.length === 0 || params.entries.length > 10_000) {
      throw new Error('entries must be a non-empty array with at most 10000 items')
    }
    const entries = params.entries.map((entry, index) => {
      if (!entry || typeof entry !== 'object') throw new Error(`entries[${index}] is invalid`)
      if (!Number.isInteger(entry.expectedRevision) || entry.expectedRevision < 0) {
        throw new Error(`entries[${index}].expectedRevision is invalid`)
      }
      if (!entry.patch || typeof entry.patch !== 'object') {
        throw new Error(`entries[${index}].patch is invalid`)
      }
      return {
        photoId: validateString(entry.photoId, `entries[${index}].photoId`),
        expectedRevision: entry.expectedRevision,
        patch: entry.patch as CullingUpdatePatch,
      }
    })
    const historyOperationId = typeof params.historyOperationId === 'number'
      ? params.historyOperationId
      : Number.NaN
    if (!Number.isInteger(historyOperationId) || historyOperationId <= 0) {
      throw new Error('historyOperationId must be a positive integer')
    }
    if (params.direction !== 'undo' && params.direction !== 'redo') {
      throw new Error('direction must be undo or redo')
    }
    return ok(cullingService.applyHistory(
      sessionId,
      entries,
      historyOperationId,
      params.direction,
    ))
  }))

  registry.register(
    'culling.update',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const photoId = validateString(params.photoId, 'photoId')
      if (!Number.isInteger(params.expectedRevision) || Number(params.expectedRevision) < 0) {
        throw new Error('expectedRevision must be a non-negative integer')
      }
      if (!params.patch || typeof params.patch !== 'object') {
        throw new Error('patch must be an object')
      }
      return ok(cullingService.updateState(
        sessionId,
        photoId,
        Number(params.expectedRevision),
        params.patch as CullingUpdatePatch,
      ))
    }),
  )

  registry.register(
    'culling.batch_update',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const photoIds = validateStringArray(params.photoIds, 'photoIds')
      if (photoIds.length > 10_000) throw new Error('Too many photoIds in one batch')
      if (!params.patch || typeof params.patch !== 'object') {
        throw new Error('patch must be an object')
      }
      return ok(cullingService.batchUpdate(
        sessionId,
        photoIds,
        params.patch as {
          pickState?: PickState
          rating?: number
          colorLabel?: CaptureOneColorLabel
        },
      ))
    }),
  )

  registry.register(
    'culling.decide_group',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const groupId = validateString(params.groupId, 'groupId')
      const keepPhotoIds = validateStringArray(params.keepPhotoIds, 'keepPhotoIds')
      if (keepPhotoIds.length > 10_000) throw new Error('Too many keepPhotoIds')
      return ok(cullingService.decideSimilarityGroup(
        sessionId,
        groupId,
        keepPhotoIds,
      ))
    }),
  )

  registry.register(
    'culling.sync_status',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(metadataSync.getSummary(sessionId))
    }),
  )

  registry.register(
    'culling.flush',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await metadataSync.flushSession(sessionId))
    }),
  )

  registry.register(
    'culling.retry_sync',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await metadataSync.retrySession(sessionId))
    }),
  )

  registry.register(
    'culling.finalize_sync',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Finalizing XMP sync requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await metadataSync.finalizeSession(sessionId))
    }),
  )

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
      metadataSync.confirmSync(sessionId, 'culling')
      if (writebackService.getItems(sessionId, 'culling').length > 0) {
        await writebackService.confirmSync(sessionId, 'culling')
      }
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
      const backgroundResult = await metadataSync.cleanup(sessionId, 'culling')
      const explicitResult = await writebackService.cleanup(sessionId, 'culling')
      return ok({
        deletedCount: backgroundResult.deletedCount + explicitResult.deletedCount,
        errors: [...backgroundResult.errors, ...explicitResult.errors],
      })
    }),
  )
}
