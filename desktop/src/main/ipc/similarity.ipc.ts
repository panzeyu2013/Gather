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

function validateAssignments(value: unknown): SimilarityKeywordAssignment[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error('请至少选择一个相似分组并填写关键词')
  }

  return value.map((assignment) => {
    if (!assignment || typeof assignment !== 'object') {
      throw new Error('Invalid similarity keyword assignment')
    }
    const groupId = Number((assignment as { groupId?: unknown }).groupId)
    const keywords = normalizeKeywords((assignment as { keywords?: unknown }).keywords)
    if (!Number.isInteger(groupId) || keywords.length === 0) {
      throw new Error('每个分组必须包含有效的分组 ID 和至少一个关键词')
    }
    return { groupId, keywords }
  })
}

function validateGroupingMode(value: unknown): SimilarityGroupingMode {
  if (value === undefined || value === 'global') return 'global'
  if (value === 'sequential') return 'sequential'
  throw new Error('Invalid similarity grouping mode')
}

async function buildKeywordPreview(
  sessionId: string,
  assignments: SimilarityKeywordAssignment[],
  similarityService: SimilarityService,
  writebackService: WritebackService,
) {
  const result = similarityService.getResult(sessionId)
  if (!result) {
    throw new Error('尚无相似度分析结果，请先完成分析')
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
      void similarityService.cancel(job.scopeId)
    }, { once: true })
    await similarityService.analyze(job.scopeId, {
      threshold: typeof checkpoint.threshold === 'number' ? checkpoint.threshold : undefined,
      minGroupSize: typeof checkpoint.minGroupSize === 'number' ? checkpoint.minGroupSize : undefined,
      groupingMode: checkpoint.groupingMode === 'sequential' ? 'sequential' : 'global',
      onProgress: (current, total, message) => context.updateProgress({
        current,
        total,
        message,
        checkpoint,
      }),
    })
    return true
  })
  registry.register(
    'sim.analyze',
    wrapHandler(async (params, event) => {
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
      event?.sender.send('gather:event', 'progress', {
        sessionId,
        current: 1,
        total: 1,
        message: 'Similarity analysis complete',
      })
      return ok(true)
    }),
  )

  registry.register(
    'sim.cancel_analysis',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      jobs.cancelScope('similarity.analyze', sessionId)
      await similarityService.cancel(sessionId)
      return ok(true)
    }),
  )

  registry.register(
    'sim.result',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const result = similarityService.getResult(sessionId)
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
      return ok(await buildKeywordPreview(sessionId, assignments, similarityService, writebackService))
    }),
  )

  registry.register(
    'sim.writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Writeback requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const itemIds = Array.isArray(params.itemIds)
        ? params.itemIds.filter((id): id is number => Number.isInteger(id))
        : []
      if (itemIds.length === 0) {
        throw new Error('没有可写入的预览项，请先生成预览')
      }
      const idSet = new Set(itemIds)
      const writebackItems = writebackService
        .getItems(sessionId, 'similarity', 'pending')
        .filter(item => item.id != null && idSet.has(item.id))
      if (writebackItems.length !== idSet.size) {
        throw new Error('写回预览已失效，请重新预览后再执行')
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
        throw new Error('Retry failed writeback requires explicit confirmation')
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
        throw new Error('Cleanup requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.cleanup(sessionId, 'similarity'))
    }),
  )
}
