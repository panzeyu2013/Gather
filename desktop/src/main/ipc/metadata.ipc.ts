import type { CommandRegistry } from './registry'
import { ok, err, validateString, validateStringArray, wrapHandler } from './helpers'
import type { MetadataService } from '../services/metadata/metadata.service'
import type { MetadataSyncCoordinator } from '../services/metadata/metadata-sync-coordinator'

export function registerMetadataHandlers(
  registry: CommandRegistry,
  metadataService: MetadataService,
  metadataSync: MetadataSyncCoordinator,
): void {
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
        throw new Error('METADATA_SET_CONFIRM_REQUIRED')
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
        throw new Error('METADATA_BATCH_SET_CONFIRM_REQUIRED')
      }
      const updates = (params.updates ?? []) as { photoId: string; tags: Record<string, unknown> }[]
      if (!Array.isArray(updates) || updates.length === 0) {
        // ADR-017: internal-invariant diagnostic (caller shape guard).
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

  registry.register('metadata.conflicts', wrapHandler(async params => {
    return ok(await metadataSync.getConflicts(validateString(params.sessionId, 'sessionId')))
  }))

  registry.register('metadata.resolve_conflict', wrapHandler(async params => {
    if (params.confirmed !== true) throw new Error('METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED')
    const choices = params.choices
    if (!choices || typeof choices !== 'object' || Array.isArray(choices)) {
      // ADR-017: internal-invariant diagnostic (caller shape guard).
      throw new Error('choices must be an object')
    }
    for (const [field, choice] of Object.entries(choices)) {
      if (!['rating', 'label', 'keywords'].includes(field)) throw new Error(`Invalid metadata field: ${field}`)
      if (!['keep_local', 'use_remote'].includes(String(choice))) throw new Error(`Invalid conflict choice: ${String(choice)}`)
    }
    return ok(await metadataSync.resolveConflict(
      validateString(params.sessionId, 'sessionId'),
      validateString(params.xmpPath, 'xmpPath'),
      choices as never,
    ))
  }))

  registry.register('metadata.orphans', wrapHandler(async () => {
    return ok(metadataSync.listOrphans())
  }))

  registry.register('metadata.resolve_orphan', wrapHandler(async params => {
    if (params.confirmed !== true) throw new Error('METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED')
    const action = validateString(params.action, 'action')
    // ADR-017: internal-invariant diagnostics below (caller shape guard).
    if (!['keep', 'restore', 'retry'].includes(action)) throw new Error('Invalid orphan action')
    return ok(await metadataSync.resolveOrphan(
      validateString(params.xmpPath, 'xmpPath'),
      action as 'keep' | 'restore' | 'retry',
    ))
  }))
}
