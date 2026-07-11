import { ImageService, TieredThumbnailCache } from '../services/image'
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

let imageService: ImageService | null = null

function getImageService(): ImageService {
  if (!imageService) {
    imageService = new ImageService(new TieredThumbnailCache())
  }
  return imageService
}

export function registerImageHandlers(registry: CommandRegistry): void {
  const settings = SettingsService.getInstance()

  registry.register(
    'image.get_preview',
    wrapHandler(async (params) => {
      const { path, maxDimension } = params as { path: string; maxDimension?: number }
      const result = await getImageService().getPreview(path, maxDimension ?? settings.getNumber('preview_max_dimension', 1920))
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
      const result = await getImageService().getThumbnail(path, size ?? settings.getNumber('thumbnail_size', 320))
      return ok({
        buffer: result.buffer.toString('base64'),
        width: result.width,
        height: result.height,
        format: result.format,
      })
    }),
  )
}
