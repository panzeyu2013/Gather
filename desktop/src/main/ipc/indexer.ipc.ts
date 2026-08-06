import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { IndexService } from '../services/indexer/index.service'
import type { JobService } from '../services/jobs/job.service'
import type { MetadataService } from '../services/metadata/metadata.service'
import type { PhotoRepository } from '../db/repositories/photo.repo'
import type { AssetRepository } from '../db/repositories/asset.repo'

export function registerIndexerHandlers(
  registry: CommandRegistry,
  indexer: IndexService,
  jobs: JobService,
  metadata: MetadataService,
  photos: PhotoRepository,
  assets: AssetRepository,
): void {
  const scheduleScan = (sessionId: string) => {
    jobs.create({
      type: 'metadata.scan',
      scopeType: 'session',
      scopeId: sessionId,
      dedupeKey: `metadata.scan:${sessionId}`,
    })
  }
  indexer.setRecoveryScanScheduler(scheduleScan)
  jobs.registerExecutor(
    'checksum.backfill',
    async (job, context) => {
      await indexer.backfillChecksums(job.scopeId, context)
    },
    { autoResume: true },
  )
  jobs.registerExecutor(
    'metadata.scan',
    async (job, context) => {
      const result = await indexer.scanSession(job.scopeId, context)
      context.throwIfCancelled()
      const photoIds = photos.getBySessionProjection(job.scopeId)
        .filter(photo => photo.status !== 'missing')
        .map(photo => photo.id)
      context.updateProgress({
        current: 0,
        total: photoIds.length,
        message: '正在读取拍摄元数据',
      })
      await metadata.getMetadata(photoIds)
      assets.reconcileRawJpegLinks(job.scopeId)
      context.updateCheckpoint({ result })
      context.updateProgress({
        current: photoIds.length,
        total: photoIds.length,
        message: '索引与元数据完成',
      })
      // Lazy mode leaves new/changed files without a checksum; queue a
      // background backfill. The dedupe_key makes concurrent creates collapse
      // onto the active job, which re-queries until nothing is left.
      if (indexer.pendingChecksums(job.scopeId) > 0) {
        jobs.create({
          type: 'checksum.backfill',
          scopeType: 'session',
          scopeId: job.scopeId,
          dedupeKey: `checksum.backfill:${job.scopeId}`,
        })
      }
      return result
    },
  )
  registry.register('index.scan', wrapHandler(async (params) => {
    const sessionId = validateString(params.sessionId, 'sessionId')
    const job = jobs.create({
      type: 'metadata.scan',
      scopeType: 'session',
      scopeId: sessionId,
      dedupeKey: `metadata.scan:${sessionId}`,
    })
    return ok(job)
  }))
}
