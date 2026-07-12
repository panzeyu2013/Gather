import { ImageService, TieredThumbnailCache, ThumbnailQueue } from '../services/image'
import { SettingsService } from '../services/settings'
import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'

function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

function err(error: string): ResponseErr {
  return { ok: false, error }
}

function wrapHandler(handler: (params: Record<string, unknown>) => unknown) {
  return async (params: unknown) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>)
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err(message)
    }
  }
}

export function registerImageHandlers(registry: CommandRegistry): void {
  const settings = SettingsService.getInstance()

  ImageService.getInstance(new TieredThumbnailCache())

  registry.register(
    'image.get_preview',
    wrapHandler(async (params) => {
      const { path, maxDimension } = params as { path: string; maxDimension?: number }
      const result = await ImageService.getInstance().getPreview(path, maxDimension ?? settings.getNumber('preview_max_dimension', 1920))
      return ok({
        buffer: result.buffer.toString('base64'),
        width: result.width,
        height: result.height,
        format: result.format,
      })
    }),
  )

  registry.register(
    'image.get_thumbnail',
    wrapHandler(async (params) => {
      const { path, size } = params as { path: string; size?: number }
      const result = await ImageService.getInstance().getThumbnail(path, size ?? settings.getNumber('thumbnail_size', 320))
      return ok({
        buffer: result.buffer.toString('base64'),
        width: result.width,
        height: result.height,
        format: result.format,
      })
    }),
  )

  registry.register(
    'image.prioritize_thumbnail',
    wrapHandler(async (params) => {
      const { path, size } = params as { path: string; size?: number }
      const sz = size ?? settings.getNumber('thumbnail_size', 320)
      ThumbnailQueue.getInstance().enqueuePriority(path, sz)
      return ok(null)
    }),
  )

  registry.register(
    'image.preload_thumbnails',
    wrapHandler(async (params) => {
      const { paths, size } = params as { paths: string[]; size?: number }
      const sz = size ?? settings.getNumber('thumbnail_size', 320)
      ThumbnailQueue.getInstance().enqueue(paths, sz)
      return ok(null)
    }),
  )

  registry.register(
    'image.get_dimensions',
    wrapHandler(async (params) => {
      const { paths } = params as { paths: string[] }
      if (!Array.isArray(paths)) throw new Error('Invalid paths: must be a string array')
      const result: Record<string, { width: number; height: number }> = {}
      const svc = ImageService.getInstance()
      for (const p of paths) {
        try {
          const dims = await svc.getDimensions(p)
          result[p] = dims
        } catch {
          result[p] = { width: 0, height: 0 }
        }
      }
      return ok(result)
    }),
  )
}
