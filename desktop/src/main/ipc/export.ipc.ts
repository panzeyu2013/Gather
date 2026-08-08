import type { CommandRegistry } from './registry'
import type { ExportProgressData } from '@gather/shared'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { ExportService } from '../services/export/export.service'
import type { ReportService } from '../services/export/report.service'
import type { JobService } from '../services/jobs/job.service'

export function registerExportHandlers(
  registry: CommandRegistry,
  exportService: ExportService,
  reportService: ReportService,
  jobs: JobService,
): void {
  const progressSinks = new Map<string, Set<(progress: ExportProgressData) => void>>()
  jobs.registerExecutor('export.execute', (job, context) => {
    const destinations = (
      job.checkpoint.destinations &&
      typeof job.checkpoint.destinations === 'object' &&
      !Array.isArray(job.checkpoint.destinations)
    )
      ? { ...job.checkpoint.destinations } as Record<string, string>
      : {}
    const persistedCompletedIds = Array.isArray(job.checkpoint.completedPhotoIds)
      ? job.checkpoint.completedPhotoIds.filter(
        (value): value is string => typeof value === 'string',
      )
      : []
    const completedPhotoIds = new Set(persistedCompletedIds)
    // Incremental checkpoint snapshot: onCompleted appends a single id (O(1))
    // instead of re-copying the whole set per photo. The snapshot array is
    // shared by reference with every checkpoint object, so the job layer's
    // throttled (250ms) progress flush always stringifies the live accumulated
    // state — a crash loses at most the last throttled window, exactly as
    // before. The format is unchanged, so old persisted checkpoints read the
    // same way and no DB schema change is needed.
    //
    // The snapshot array itself is only handed to the job layer at most once
    // per CHECKPOINT_WRITE_INTERVAL_MS instead of on every 250ms job-layer
    // flush: a 50k-id export was re-serializing and re-writing the whole
    // array ~4×/s (~1.5MB per write). The last write of every run is forced
    // via updateCheckpoint below, so the persisted completedPhotoIds list
    // remains complete for resume — a crash loses at most the ids completed
    // in the final <=1s window, and those photos get re-exported with a _2
    // suffix, the same order of magnitude as the previous 250ms window.
    const CHECKPOINT_WRITE_INTERVAL_MS = 1000
    const completedIdsSnapshot: string[] = [...persistedCompletedIds]
    let lastCheckpointWriteAt = 0
    const checkpoint = () => ({
      options: job.checkpoint.options,
      destinations,
      completedPhotoIds: completedIdsSnapshot,
    })
    context.signal.addEventListener('abort', () => exportService.cancel(job.scopeId), {
      once: true,
    })
    return exportService.execute(
      job.scopeId,
      job.checkpoint.options as Parameters<typeof exportService.execute>[1],
      progress => {
        const now = Date.now()
        if (now - lastCheckpointWriteAt >= CHECKPOINT_WRITE_INTERVAL_MS) {
          lastCheckpointWriteAt = now
          context.updateProgress({
            current: progress.current,
            total: progress.total,
            message: `${progress.fileName} · ${progress.status}`,
            checkpoint: checkpoint(),
          })
        }
        progressSinks.get(job.id)?.forEach(sink => sink(progress))
      },
      {
        destinations,
        completedPhotoIds,
        signal: context.signal,
        onPlanned: (photoId, destinationName) => {
          destinations[photoId] = destinationName
        },
        onPlanReady: () => context.updateCheckpoint(checkpoint()),
        onCompleted: photoId => {
          // Set.add is idempotent but the snapshot array is not, and a
          // resumed photo whose file vanished re-fires onCompleted; only
          // record ids that are genuinely new.
          if (!completedPhotoIds.has(photoId)) {
            completedPhotoIds.add(photoId)
            completedIdsSnapshot.push(photoId)
          }
          const now = Date.now()
          if (now - lastCheckpointWriteAt >= CHECKPOINT_WRITE_INTERVAL_MS) {
            lastCheckpointWriteAt = now
            context.updateProgress({ checkpoint: checkpoint() })
          }
        },
      },
    ).then(result => {
      // Force the final full snapshot so a resume (or a re-run after a
      // crash/cancel) always reads the complete completedPhotoIds list, even
      // when the run ended inside the throttled window.
      context.updateCheckpoint(checkpoint())
      return result
    })
  })
  registry.register(
    'export.preview',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = params.options as Record<string, unknown>
      if (!options || typeof options !== 'object') {
        return err('导出参数无效')
      }
      const preview = await exportService.preview(sessionId, options as unknown as Parameters<typeof exportService.preview>[1])
      return ok(preview)
    }),
  )

  registry.register(
    'export.execute',
    wrapHandler(async (params, event) => {
      if (params.confirmed !== true) {
        throw new Error('开始导出前需要明确确认')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = params.options as Record<string, unknown>
      if (!options || typeof options !== 'object') {
        return err('导出参数无效')
      }
      const job = jobs.create({
        type: 'export.execute',
        scopeType: 'session',
        scopeId: sessionId,
        dedupeKey: `export.execute:${sessionId}`,
        checkpoint: { options },
      })
      // Key the sink by job id instead of session id: a repeated execute for
      // the same session dedupes to the same job, so every caller's window
      // gets its own progress stream instead of the last one overwriting the
      // previous.
      let sink: ((progress: ExportProgressData) => void) | undefined
      if (event) {
        const sender = event.sender
        sink = (progress: ExportProgressData): void => {
          if (!sender.isDestroyed()) {
            sender.send('gather:event', 'export:progress', progress)
          }
        }
        const sinks = progressSinks.get(job.id) ?? new Set()
        sinks.add(sink)
        progressSinks.set(job.id, sinks)
      }
      try {
        return ok(await jobs.waitForResult(job.id))
      } finally {
        if (sink) {
          const sinks = progressSinks.get(job.id)
          if (sinks) {
            sinks.delete(sink)
            if (sinks.size === 0) progressSinks.delete(job.id)
          }
        }
      }
    }),
  )

  registry.register(
    'export.cancel',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      jobs.cancelScope('export.execute', sessionId)
      exportService.cancel(sessionId)
      return ok(true)
    }),
  )

  registry.register(
    'export.report',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const reportType = typeof params.reportType === 'string' ? params.reportType : 'session_summary'
      const format = typeof params.format === 'string' ? params.format : undefined

      if (reportType === 'person') {
        const content = reportService.generatePersonReport(sessionId)
        return ok({ path: '', content, format: 'md' as const })
      }
      if (reportType === 'keyword') {
        const content = reportService.generateKeywordReport(sessionId)
        return ok({ path: '', content, format: 'md' as const })
      }
      return ok(exportService.generateReport(sessionId, reportType, format))
    }),
  )
}
