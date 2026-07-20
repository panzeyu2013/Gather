import { getServices } from '../bootstrap'
import { SettingsService } from '../services/settings'
import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'

export function registerImageHandlers(registry: CommandRegistry): void {
  const { imageService } = getServices()
  const settings = SettingsService.getInstance()

  registry.register(
    'image.get_preview',
    wrapHandler(async (params) => {
      const path = validateString(params.path, 'path')
      const maxDimension = typeof params.maxDimension === 'number' ? params.maxDimension : undefined
      const result = await imageService.getPreview(path, maxDimension)
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
      const path = validateString(params.path, 'path')
      const size = typeof params.size === 'number' ? params.size : undefined
      const result = await imageService.getThumbnail(path, size ?? settings.getNumber('thumbnail_size', 2880))
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
      const path = validateString(params.path, 'path')
      const size = typeof params.size === 'number' ? params.size : undefined
      await imageService.prioritizeThumbnail(path, size ?? settings.getNumber('thumbnail_size', 2880))
      return ok(null)
    }),
  )

  registry.register(
    'image.preload_thumbnails',
    wrapHandler(async (params) => {
      const paths: string[] = Array.isArray(params.paths) ? params.paths.map((p: unknown) => validateString(p, 'paths[]')) : []
      const size = typeof params.size === 'number' ? params.size : settings.getNumber('thumbnail_size', 2880)
      imageService.preloadThumbnails(paths, size)
      return ok(null)
    }),
  )
}
