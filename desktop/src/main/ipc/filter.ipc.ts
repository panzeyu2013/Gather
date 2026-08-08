import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { FilterGroup, SmartAlbumData, SmartAlbumDetailData, PhotoData, GlobalPhotoResult, FilterSuggestion } from '@gather/shared'
import type { FilterEngine } from '../services/filter/filter-engine'
import type { SmartAlbumRepository } from '../db/repositories/smart-album.repo'

function parseFilterCriteria(criteria: string | FilterGroup, schemaVersion = 1): FilterGroup {
  if (schemaVersion !== 1) {
    throw new Error(`Unsupported filter schema version: ${schemaVersion}`)
  }
  // IPC params arrive as plain objects, so skip the JSON.stringify/parse
  // round-trip entirely; rows loaded from the DB are JSON strings and are
  // still parsed here.
  const parsed = typeof criteria === 'string'
    ? (JSON.parse(criteria) as FilterGroup)
    : criteria
  const validateGroup = (group: FilterGroup): void => {
    if (!group || !['and', 'or'].includes(group.logic) || !Array.isArray(group.conditions)) {
      throw new Error('Filter criteria is invalid')
    }
    for (const condition of group.conditions) {
      if (!condition || typeof condition !== 'object') throw new Error('Filter condition is invalid')
      if ('field' in condition) {
        if (typeof condition.field !== 'string' || typeof condition.operator !== 'string') {
          throw new Error('Filter rule is invalid')
        }
      } else {
        validateGroup(condition)
      }
    }
  }
  validateGroup(parsed)
  return parsed
}

export function registerFilterHandlers(registry: CommandRegistry, filterEngine: FilterEngine): void {
  registry.register(
    'filter.photos',
    wrapHandler((params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const criteria = parseFilterCriteria(params.criteria as FilterGroup)
      const sortBy = typeof params.sortBy === 'string' ? params.sortBy : undefined
      const sortOrder = typeof params.sortOrder === 'string' ? params.sortOrder : undefined
      // Contract: limit/offset are optional (clamped like filter.photos_global,
      // 1..500 / >= 0). Without them the call defaults to a 100-row window:
      // every row carries the heavy p.metadata/p.result JSON plus a per-row
      // face_observations count sub-query, and the FilterBuilder preview would
      // otherwise ship the whole session to the renderer. Callers that only
      // need a count should use countPhotos; callers that need everything
      // must pass an explicit limit.
      const limit = typeof params.limit === 'number'
        ? Math.max(1, Math.min(500, Math.floor(params.limit)))
        : 100
      const offset = typeof params.offset === 'number'
        ? Math.max(0, Math.floor(params.offset))
        : 0
      const photos: PhotoData[] = filterEngine.filterPhotos(
        sessionId,
        criteria,
        sortBy,
        sortOrder,
        limit,
        offset,
      )
      return ok(photos)
    }),
  )

  registry.register(
    'filter.photos_global',
    wrapHandler(async (params) => {
      const criteria = parseFilterCriteria(params.criteria as FilterGroup)
      const sessionId = params.sessionId === undefined
        ? undefined
        : validateString(params.sessionId, 'sessionId')
      const limit = typeof params.limit === 'number'
        ? Math.max(1, Math.min(500, Math.floor(params.limit)))
        : 100
      const offset = typeof params.offset === 'number'
        ? Math.max(0, Math.floor(params.offset))
        : 0
      const results: GlobalPhotoResult[] = filterEngine.filterGlobally(
        criteria,
        undefined,
        undefined,
        limit,
        offset,
        sessionId,
      )
      return ok({ photos: results, total: filterEngine.countGlobally(criteria, sessionId) })
    }),
  )

  registry.register(
    'filter.suggest',
    wrapHandler((params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const keyword = typeof params.keyword === 'string' ? params.keyword : ''
      const suggestions: FilterSuggestion[] = filterEngine.suggest(sessionId, keyword)
      return ok(suggestions)
    }),
  )
}

export function registerAlbumHandlers(registry: CommandRegistry, filterEngine: FilterEngine, smartAlbumRepo: SmartAlbumRepository): void {

  const repo = smartAlbumRepo
  const engine = filterEngine
  registry.register(
    'album.create',
    wrapHandler((params) => {
      const name = validateString(params.name, 'name')
      const criteria = parseFilterCriteria(params.criteria as FilterGroup)
      const sortBy = typeof params.sortBy === 'string' ? params.sortBy : undefined
      const sortOrder = typeof params.sortOrder === 'string' ? params.sortOrder : undefined
      const description = typeof params.description === 'string' ? params.description : undefined
      const icon = typeof params.icon === 'string' ? params.icon : undefined
      engine.buildWhereClause(criteria)

      const row = repo.create({
        name,
        description,
        filterCriteria: criteria,
        sortBy,
        sortOrder,
        icon,
      })

      const data: SmartAlbumDetailData = {
        id: row.id,
        schemaVersion: row.schema_version,
        name: row.name,
        description: row.description,
        filterCriteria: parseFilterCriteria(row.filter_criteria, row.schema_version),
        sortBy: row.sort_by,
        sortOrder: row.sort_order,
        icon: row.icon,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
        photoCount: engine.countGlobally(criteria),
      }
      return ok(data)
    }),
  )

  registry.register(
    'album.list',
    wrapHandler(() => {
      const rows = repo.list()
      const albums: SmartAlbumData[] = rows.flatMap((row) => {
        try {
          const filterCriteria = parseFilterCriteria(row.filter_criteria, row.schema_version)
          engine.buildWhereClause(filterCriteria)
          return [{
            id: row.id,
            schemaVersion: row.schema_version,
            name: row.name,
            description: row.description,
            filterCriteria,
            sortBy: row.sort_by,
            sortOrder: row.sort_order,
            icon: row.icon,
            createdAt: row.created_at,
            updatedAt: row.updated_at,
          }]
        } catch (error) {
          return [{
            id: row.id,
            schemaVersion: row.schema_version,
            name: row.name,
            description: row.description,
            filterCriteria: { logic: 'and', conditions: [] },
            sortBy: row.sort_by,
            sortOrder: row.sort_order,
            icon: row.icon,
            createdAt: row.created_at,
            updatedAt: row.updated_at,
            validationError: error instanceof Error ? error.message : String(error),
          }]
        }
      })
      return ok(albums)
    }),
  )

  registry.register(
    'album.get',
    wrapHandler((params) => {
      const albumId = validateString(params.albumId, 'albumId')
      const row = repo.get(albumId)
      if (!row) return err('Album not found')
      const criteria = parseFilterCriteria(row.filter_criteria, row.schema_version)
      const data: SmartAlbumDetailData = {
        id: row.id,
        schemaVersion: row.schema_version,
        name: row.name,
        description: row.description,
        filterCriteria: criteria,
        sortBy: row.sort_by,
        sortOrder: row.sort_order,
        icon: row.icon,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
        photoCount: engine.countGlobally(criteria),
      }
      return ok(data)
    }),
  )

  registry.register(
    'album.update',
    wrapHandler((params) => {
      const albumId = validateString(params.albumId, 'albumId')
      const updateData: Record<string, unknown> = {}
      if (typeof params.name === 'string') updateData.name = params.name
      if (typeof params.description === 'string') updateData.description = params.description
      if (params.criteria) {
        const criteria = parseFilterCriteria(params.criteria as FilterGroup)
        engine.buildWhereClause(criteria)
        updateData.filterCriteria = criteria
      }
      if (typeof params.sortBy === 'string') updateData.sortBy = params.sortBy
      if (typeof params.sortOrder === 'string') updateData.sortOrder = params.sortOrder
      if (typeof params.icon === 'string') updateData.icon = params.icon
      repo.update(albumId, updateData)
      return ok({ done: true })
    }),
  )

  registry.register(
    'album.delete',
    wrapHandler((params) => {
      if (params.confirmed !== true) {
        throw new Error('album.delete requires confirmation')
      }
      const albumId = validateString(params.albumId, 'albumId')
      repo.delete(albumId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'album.get_photos',
    wrapHandler((params) => {
      const albumId = validateString(params.albumId, 'albumId')
      const row = repo.get(albumId)
      if (!row) return err('Album not found')

      const criteria = parseFilterCriteria(row.filter_criteria, row.schema_version)
      const limit = typeof params.limit === 'number' ? params.limit : undefined
      const offset = typeof params.offset === 'number' ? params.offset : undefined

      const resolvedLimit = Math.max(1, Math.min(500, Math.floor(limit ?? 100)))
      const resolvedOffset = Math.max(0, Math.floor(offset ?? 0))
      const photos = engine.filterGlobally(
        criteria,
        row.sort_by,
        row.sort_order,
        resolvedLimit,
        resolvedOffset,
      )
      return ok({ photos, total: engine.countGlobally(criteria) })
    }),
  )
}
