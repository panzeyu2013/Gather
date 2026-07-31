import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { ImageService } from '../services/image'
import type { SettingsService } from '../services/settings/settings.service'
import type { JobService } from '../services/jobs/job.service'
import { createHash } from 'node:crypto'

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
      const fingerprint = createHash('sha256')
        .update(paths.join('\0'))
        .digest('hex')
      return ok(jobs.create({
        type: 'thumbnail.build',
        scopeType: 'paths',
        scopeId: paths[0],
        dedupeKey: `thumbnail.build:${size}:${fingerprint}`,
        checkpoint: { paths, size },
        priority: -1,
      }))
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
