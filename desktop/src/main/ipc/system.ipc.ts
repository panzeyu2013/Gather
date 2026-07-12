import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import { getServices } from '../bootstrap'
import { SettingsService } from '../services/settings'

export function registerSystemHandlers(registry: CommandRegistry): void {
  const { imageService } = getServices()
  const settings = SettingsService.getInstance()

  registry.register(
    'thumbnail.get',
    wrapHandler(async (params) => {
      const imagePath = validateString(params.path, 'path')
      const result = await imageService.getThumbnail(imagePath, settings.getNumber('thumbnail_size', 200))
      return ok(result.buffer.toString('base64'))
    }),
  )
}
