import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { ImageService } from '../services/image'
import type { SettingsService } from '../services/settings/settings.service'

export function registerSystemHandlers(registry: CommandRegistry, imageService: ImageService, settings: SettingsService): void {

  registry.register(
    'thumbnail.get',
    wrapHandler(async (params) => {
      const imagePath = validateString(params.path, 'path')
      const result = await imageService.getThumbnail(imagePath, settings.getNumber('thumbnail_size', 200))
      return ok(result.buffer.toString('base64'))
    }),
  )
}
