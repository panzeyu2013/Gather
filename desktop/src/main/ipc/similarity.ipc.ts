import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { SimilarityKeywordAssignment } from '@gather/shared'
import type { SimilarityGroupingMode } from '@gather/shared'
import {
  type SimilarityService,
  validateSimilarityParameters,
} from '../services/similarity/similarity.service'
import type { WritebackService } from '../services/writeback/writeback.service'
import type { SettingsService } from '../services/settings/settings.service'
import { buildSimilarityKeywordPlan } from '../services/writeback/writeback-planners'
import type { JobService } from '../services/jobs/job.service'

function normalizeKeywords(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return [...new Set(
    value
      .filter((keyword): keyword is string => typeof keyword === 'string')
      .map(keyword => keyword.trim())
      .filter(Boolean),
  )]
}

// ADR-017: internal-invariant diagnostics below — the renderer validates the
// same shapes from shared constants, so these throws are bug guards only.
function validateAssignments(value: unknown): SimilarityKeywordAssignment[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error('SIM_WRITEBACK_EMPTY')
  }

  return value.map((assignment) => {
    if (!assignment || typeof assignment !== 'object') {
      throw new Error('SIM_ASSIGNMENT_INVALID')
    }
    const groupId = Number((assignment as { groupId?: unknown }).groupId)
    const keywords = normalizeKeywords((assignment as { keywords?: unknown }).keywords)
    if (!Number.isInteger(groupId) || keywords.length === 0) {
      throw new Error('SIM_WRITEBACK_INVALID_ITEM')
    }
    return { groupId, keywords }
  })
}

function validateGroupingMode(value: unknown): SimilarityGroupingMode {
  if (value === undefined || value === 'global') return 'global'
  if (value === 'sequential') return 'sequential'
  throw new Error('SIM_GROUPING_MODE_INVALID')
}

async function buildKeywordPreview(
  sessionId: string,
  assignments: SimilarityKeywordAssignment[],
  similarityService: SimilarityService,
  writebackService: WritebackService,
  threshold?: number,
) {
  // Resolve group ids against the displayed result row: the tier row when a
  // threshold is given (precomputed neighbor tier), the latest main row
  // otherwise. Using getLatest here would map tier group ids to the wrong
  // keywords when the UI is showing a precomputed tier.
  const result = threshold === undefined
    ? similarityService.getResult(sessionId)
    : similarityService.getResult(sessionId, threshold)
  if (!result) {
    throw new Error(
      threshold === undefined
        ? 'SIM_ANALYSIS_MISSING'
        : 'SIM_THRESHOLD_NO_RESULTS',
    )
  }

  const { keywordsBySidecar, affectedPaths } = buildSimilarityKeywordPlan(
    result.groups,
    assignments,
  )

  const preview = await writebackService.preview(sessionId, 'similarity', {})
  const selectedItems = preview.items
    .filter(item => keywordsBySidecar.has(item.xmpPath))
    .map(item => ({
      ...item,
      keywords: [...new Set([...item.keywords, ...(keywordsBySidecar.get(item.xmpPath) ?? [])])],
    }))

  writebackService.persistKeywords(selectedItems)
  return {
    items: selectedItems,
    totalCount: selectedItems.length,
    affectedPhotos: affectedPaths.size,
  }
}

export function registerSimilarityHandlers(
  registry: CommandRegistry,
  similarityService: SimilarityService,
  writebackService: WritebackService,
  settings: SettingsService,
  jobs: JobService,
): void {
  jobs.registerExecutor('similarity.analyze', async (job, context) => {
    const checkpoint = job.checkpoint
    context.signal.addEventListener('abort', () => {
      // Abort from the job system: the similarity run is in flight, so the
      // session column may be updated — but only when this run actually
      // owns it (a queued-job abort must not stomp a concurrent face run).
      void similarityService.cancel(job.scopeId, false)
    }, { once: true })
    await similarityService.analyze(job.scopeId, {
      threshold: typeof checkpoint.threshold === 'number' ? checkpoint.threshold : undefined,
      minGroupSize: typeof checkpoint.minGroupSize === 'number' ? checkpoint.minGroupSize : undefined,
      groupingMode: checkpoint.groupingMode === 'sequential' ? 'sequential' : 'global',
      onProgress: (current, total, phase) => context.updateProgress({
        current,
        total,
        phase,
        checkpoint,
      }),
    })
    return true
  })
  registry.register(
    'sim.analyze',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const threshold =
        typeof params.threshold === 'number' ? params.threshold : undefined
      const minGroupSize =
        typeof params.minGroupSize === 'number' ? params.minGroupSize : undefined
      const groupingMode = validateGroupingMode(params.groupingMode)
      validateSimilarityParameters(
        threshold ?? settings.getNumber('default_threshold', 10),
        minGroupSize ?? settings.getNumber('default_min_group_size', 2),
      )
      const job = jobs.create({
        type: 'similarity.analyze',
        scopeType: 'session',
        scopeId: sessionId,
        dedupeKey: `similarity.analyze:${sessionId}:${threshold ?? 'default'}:${minGroupSize ?? 'default'}:${groupingMode}`,
        checkpoint: { threshold, minGroupSize, groupingMode },
      })
      await jobs.waitForResult(job.id)
      return ok(true)
    }),
  )

  registry.register(
    'sim.cancel_analysis',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      jobs.cancelScope('similarity.analyze', sessionId)
      // The session analysis_status is only written when a similarity run is
      // actually in flight; cancelling a queued job (or an already-finished
      // one) must not clobber a concurrently running face analysis.
      await similarityService.cancel(sessionId, false)
      return ok(true)
    }),
  )

  registry.register(
    'sim.result',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const threshold = typeof params.threshold === 'number' ? params.threshold : undefined
      const result = similarityService.getResult(sessionId, threshold)
      return ok(result)
    }),
  )

  registry.register(
    'sim.recluster',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const threshold =
        typeof params.threshold === 'number' ? params.threshold : settings.getNumber('default_threshold', 10)
      const minGroupSize =
        typeof params.minGroupSize === 'number' ? params.minGroupSize : settings.getNumber('default_min_group_size', 2)
      const groupingMode = validateGroupingMode(params.groupingMode)
      validateSimilarityParameters(threshold, minGroupSize)
      const result = await similarityService.recluster(
        sessionId,
        threshold,
        minGroupSize,
        groupingMode,
      )
      return ok(result)
    }),
  )

  registry.register(
    'sim.preview_writeback',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const assignments = validateAssignments(params.assignments)
      const threshold = typeof params.threshold === 'number' ? params.threshold : undefined
      return ok(await buildKeywordPreview(
        sessionId,
        assignments,
        similarityService,
        writebackService,
        threshold,
      ))
    }),
  )

  registry.register(
    'sim.writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('WRITEBACK_CONFIRM_REQUIRED')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const threshold = typeof params.threshold === 'number' ? params.threshold : undefined
      // The pending items were built from a specific result row; when the
      // caller identifies the tier it was displayed with, make sure that row
      // still exists so group ids never map to a vanished result. This is a
      // cheap row-existence check — not a full getResult rebuild.
      if (threshold !== undefined && !similarityService.hasResult(sessionId, threshold)) {
        throw new Error('SIM_THRESHOLD_NO_RESULTS')
      }
      const itemIds = Array.isArray(params.itemIds)
        ? params.itemIds.filter((id): id is number => Number.isInteger(id))
        : []
      if (itemIds.length === 0) {
        throw new Error('SIM_PREVIEW_REQUIRED')
      }
      const idSet = new Set(itemIds)
      const writebackItems = writebackService
        .getItems(sessionId, 'similarity', 'pending')
        .filter(item => item.id != null && idSet.has(item.id))
      if (writebackItems.length !== idSet.size) {
        throw new Error('SIM_PREVIEW_STALE')
      }
      return ok(await writebackService.execute(sessionId, 'similarity', writebackItems))
    }),
  )

  registry.register(
    'sim.writeback_items',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(writebackService.getItems(sessionId, 'similarity'))
    }),
  )

  registry.register(
    'sim.retry_failed_writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('WRITEBACK_RETRY_CONFIRM_REQUIRED')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.retryFailed(sessionId, 'similarity'))
    }),
  )

  registry.register(
    'sim.confirm_sync',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await writebackService.confirmSync(sessionId, 'similarity')
      return ok(true)
    }),
  )

  registry.register(
    'sim.cleanup',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('WRITEBACK_CLEANUP_CONFIRM_REQUIRED')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.cleanup(sessionId, 'similarity'))
    }),
  )
}
