import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'
import { ImageService, TieredThumbnailCache } from '../services/image'
import { SettingsService } from '../services/settings'

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

export function registerSystemHandlers(registry: CommandRegistry): void {
  const settings = SettingsService.getInstance()

  ImageService.getInstance(new TieredThumbnailCache())

  registry.register(
    'thumbnail.get',
    wrapHandler(async (params) => {
      const { path: imagePath } = params as { path: string }
      const result = await ImageService.getInstance().getThumbnail(imagePath, settings.getNumber('thumbnail_size', 320))
      return ok(result.buffer.toString('base64'))
    }),
  )
}
