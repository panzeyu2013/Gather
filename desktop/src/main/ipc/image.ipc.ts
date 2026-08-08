import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { ImageService } from '../services/image'
import type { SettingsService } from '../services/settings/settings.service'
import type { JobService } from '../services/jobs/job.service'
import { createHash } from 'node:crypto'

// Viewport preloads during scrolling re-request the same path windows many
// times; answering those from an in-memory fingerprint map avoids scanning
// the jobs table (and re-creating job rows) on every request. The map is
// capped and evicted FIFO (an insertion-order array) so it cannot grow
// without bound. No completion event is wired to this module (the progress
// sink is owned by index.ts), so entries whose job is no longer reusable
// (failed/cancelled/interrupted, or cleared from the jobs table) would stay
// valid forever unless a HIT validates them: each HIT checks the job id
// against a throttled snapshot of the live thumbnail.build jobs, and a HIT
// that fails the check falls through to the scan path below, which prunes
// the stale entry and returns a live job. The size is folded into the key so
// equal path lists with different sizes never collide.
const PRELOAD_THUMBNAIL_CACHE_MAX = 64
// Scrolling re-requests the same window many times per second, so a full
// jobs.list() scan per HIT (the scan the miss path runs per request) would
// defeat the cache. HIT liveness is instead validated against a snapshot
// refreshed at most once per interval; a job that died since the snapshot
// self-heals on the next request after a refresh.
const PRELOAD_REUSABLE_REFRESH_MS = 250
const preloadThumbnailJobs = new Map<string, string>()
const preloadThumbnailOrder: string[] = []
let preloadReusableJobIds = new Set<string>()
let preloadReusableRefreshedAt = 0

function reusablePreloadJobIds(jobs: JobService): Set<string> {
  const now = Date.now()
  if (now - preloadReusableRefreshedAt < PRELOAD_REUSABLE_REFRESH_MS) {
    return preloadReusableJobIds
  }
  preloadReusableRefreshedAt = now
  preloadReusableJobIds = new Set(
    jobs
      .list()
      .filter(job =>
        job.type === 'thumbnail.build' &&
        ['queued', 'running', 'succeeded'].includes(job.status))
      .map(job => job.id),
  )
  return preloadReusableJobIds
}

function cachePreloadThumbnailJob(cacheKey: string, jobId: string): void {
  if (preloadThumbnailJobs.has(cacheKey)) {
    const index = preloadThumbnailOrder.indexOf(cacheKey)
    if (index >= 0) preloadThumbnailOrder.splice(index, 1)
  }
  preloadThumbnailJobs.set(cacheKey, jobId)
  preloadThumbnailOrder.push(cacheKey)
  while (preloadThumbnailOrder.length > PRELOAD_THUMBNAIL_CACHE_MAX) {
    const evicted = preloadThumbnailOrder.shift()
    if (evicted !== undefined) preloadThumbnailJobs.delete(evicted)
  }
}

export function registerImageHandlers(
  registry: CommandRegistry,
  imageService: ImageService,
  settings: SettingsService,
  jobs: JobService,
): void {
  jobs.registerExecutor('thumbnail.build', (job, context) => {
    const paths = Array.isArray(job.checkpoint.paths)
      ? job.checkpoint.paths.filter((value): value is string => typeof value === 'string')
      : []
    const size = typeof job.checkpoint.size === 'number'
      ? job.checkpoint.size
      : settings.getNumber('thumbnail_size', 1024)
    return imageService.buildThumbnails(paths, size, context.signal, (current, total) => {
      context.updateProgress({
        current,
        total,
        message: '正在生成缩略图',
        checkpoint: { ...job.checkpoint, nextPathIndex: current },
      })
    })
  })

  registry.register(
    'image.prioritize_thumbnail',
    wrapHandler(async (params) => {
      const path = validateString(params.path, 'path')
      const size = typeof params.size === 'number' ? params.size : undefined
      await imageService.prioritizeThumbnail(path, size ?? settings.getNumber('thumbnail_size', 1024))
      return ok(null)
    }),
  )

  registry.register(
    'image.preload_thumbnails',
    wrapHandler(async (params) => {
      const paths: string[] = Array.isArray(params.paths) ? params.paths.map((p: unknown) => validateString(p, 'paths[]')) : []
      const size = typeof params.size === 'number' ? params.size : settings.getNumber('thumbnail_size', 1024)
      if (paths.length === 0) return ok(null)
      // Scrolling produces a new fingerprint per viewport, which would grow
      // the jobs table with succeeded preload jobs forever. Reuse an existing
      // non-failed job only when its path list already COVERS the requested
      // paths (superset or equal): then nothing starves — a window with new
      // paths still gets a fresh job that builds them.
      const fingerprint = createHash('sha256')
        .update(paths.join('\0'))
        .digest('hex')
      const cacheKey = `${size}:${fingerprint}`
      const cachedJobId = preloadThumbnailJobs.get(cacheKey)
      if (cachedJobId) {
        // A cached job id can outlive its job (clearCompleted, failed run),
        // and a window that keeps re-requesting the same paths never reaches
        // the miss-path pruning below — it would return the dead id forever.
        // Validate the HIT against the throttled liveness snapshot; an
        // invalid entry falls through to the scan path, which prunes it and
        // returns (or creates) a live job.
        if (reusablePreloadJobIds(jobs).has(cachedJobId)) return ok(cachedJobId)
      }
      const requested = new Set(paths)
      const allJobs = jobs.list()
      // Prune cache entries whose job is no longer reusable (failed/
      // cancelled/interrupted, or cleared from the jobs table). The scan
      // that just ran is the only cheap place to learn that.
      const reusableJobIds = new Set(
        allJobs
          .filter(job => job.type === 'thumbnail.build' && ['queued', 'running', 'succeeded'].includes(job.status))
          .map(job => job.id),
      )
      for (const key of preloadThumbnailOrder) {
        const jobId = preloadThumbnailJobs.get(key)
        if (jobId !== undefined && !reusableJobIds.has(jobId)) {
          preloadThumbnailJobs.delete(key)
        }
      }
      if (preloadThumbnailJobs.size !== preloadThumbnailOrder.length) {
        preloadThumbnailOrder.length = 0
        preloadThumbnailOrder.push(...preloadThumbnailJobs.keys())
      }
      const existing = allJobs.find(job => {
        if (job.type !== 'thumbnail.build' || job.scopeType !== 'paths') return false
        if (!['queued', 'running', 'succeeded'].includes(job.status)) return false
        if (typeof job.checkpoint.size !== 'number' || job.checkpoint.size !== size) return false
        const existingPaths = Array.isArray(job.checkpoint.paths)
          ? job.checkpoint.paths.filter((value): value is string => typeof value === 'string')
          : []
        const existingSet = new Set(existingPaths)
        return existingPaths.length > 0 &&
          requested.size <= existingPaths.length &&
          paths.every(p => existingSet.has(p))
      })
      if (existing) {
        cachePreloadThumbnailJob(cacheKey, existing.id)
        return ok(existing.id)
      }
      const created = jobs.create({
        type: 'thumbnail.build',
        scopeType: 'paths',
        scopeId: paths[0],
        dedupeKey: `thumbnail.build:${size}:${fingerprint}`,
        checkpoint: { paths, size },
        priority: -1,
      })
      cachePreloadThumbnailJob(cacheKey, created.id)
      return ok(created.id)
    }),
  )

  registry.register(
    'image.preload_previews',
    wrapHandler(async (params) => {
      const paths: string[] = Array.isArray(params.paths)
        ? params.paths.map((p: unknown) => validateString(p, 'paths[]'))
        : []
      const maxDimension = typeof params.maxDimension === 'number'
        ? params.maxDimension
        : 2048
      imageService.preloadPreviews(paths.slice(0, 4), maxDimension)
      return ok(null)
    }),
  )

  registry.register(
    'image.get_dimensions',
    wrapHandler(async (params) => {
      const paths: string[] = Array.isArray(params.paths) ? params.paths.map((p: unknown) => validateString(p, 'paths[]')) : []
      if (paths.length === 0) return ok({})
      const results: Record<string, { width: number; height: number }> = {}
      const concurrency = Math.min(paths.length, 8)
      const chunks: string[][] = []
      for (let i = 0; i < paths.length; i += concurrency) {
        chunks.push(paths.slice(i, i + concurrency))
      }
      for (const chunk of chunks) {
        const settled = await Promise.allSettled(
          chunk.map(async (p) => {
            const dims = await imageService.getDimensions(p)
            return { path: p, ...dims }
          }),
        )
        for (const r of settled) {
          if (r.status === 'fulfilled') {
            results[r.value.path] = { width: r.value.width, height: r.value.height }
          }
        }
      }
      return ok(results)
    }),
  )
}
