import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateStringArray, wrapHandler } from './helpers'
import { MetadataService } from '../services/metadata/metadata.service'
import { getServices } from '../bootstrap'

export function registerMetadataHandlers(registry: CommandRegistry): void {
  const { metadataService } = getServices()
  registry.register(
    'metadata.get',
    wrapHandler(async (params) => {
      const photoIds = validateStringArray(params.photoIds, 'photoIds')
      const map = await metadataService.getMetadata(photoIds)
      return ok(Object.fromEntries(map))
    }),
  )

  registry.register(
    'metadata.set',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('metadata.set requires confirmation')
      }
      const photoId = validateString(params.photoId, 'photoId')
      const tags = (params.tags ?? {}) as Record<string, unknown>
      const result = await metadataService.setMetadata(photoId, tags)
      return ok(result)
    }),
  )

  registry.register(
    'metadata.batch_set',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('metadata.batch_set requires confirmation')
      }
      const updates = (params.updates ?? []) as { photoId: string; tags: Record<string, unknown> }[]
      if (!Array.isArray(updates) || updates.length === 0) {
        return err('Invalid updates: must be a non-empty array')
      }
      const result = await metadataService.batchSet(
        updates.map((u) => ({
          photoId: validateString(u.photoId, 'photoId'),
          tags: (u.tags ?? {}) as Record<string, unknown>,
        })),
      )
      return ok(result)
    }),
  )
}
