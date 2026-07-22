import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import { getServices } from '../bootstrap'

export function registerSystemHandlers(registry: CommandRegistry): void {
  const { imageService, settingsService: settings } = getServices()

  registry.register(
    'thumbnail.get',
    wrapHandler(async (params) => {
      const imagePath = validateString(params.path, 'path')
      const result = await imageService.getThumbnail(imagePath, settings.getNumber('thumbnail_size', 200))
      return ok(result.buffer.toString('base64'))
    }),
  )
}
