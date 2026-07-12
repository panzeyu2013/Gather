import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { FilterGroup, SmartAlbumData, SmartAlbumDetailData, PhotoData, GlobalPhotoResult, FilterSuggestion } from '@gather/shared'
import { FilterEngine } from '../services/filter/filter-engine'
import { getServices } from '../bootstrap'

export function registerFilterHandlers(registry: CommandRegistry): void {
  const { filterEngine } = getServices()
  registry.register(
    'filter.photos',
    wrapHandler((params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const criteria = params.criteria as FilterGroup
      if (!criteria || !criteria.conditions) throw new Error('Invalid filter criteria')
      const sortBy = typeof params.sortBy === 'string' ? params.sortBy : undefined
      const sortOrder = typeof params.sortOrder === 'string' ? params.sortOrder : undefined
      const photos: PhotoData[] = filterEngine.filterPhotos(sessionId, criteria, sortBy, sortOrder)
      return ok(photos)
    }),
  )

  registry.register(
    'filter.photos_global',
    wrapHandler(async (params) => {
      const criteria = params.criteria as FilterGroup
      if (!criteria || !criteria.conditions) throw new Error('Invalid filter criteria')
      const results: GlobalPhotoResult[] = await filterEngine.filterGlobally(criteria)
      return ok(results)
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

export function registerAlbumHandlers(registry: CommandRegistry): void {
  const { filterEngine, smartAlbumRepo } = getServices()

  const repo = smartAlbumRepo
  const engine = filterEngine

  registry.register(
    'album.create',
    wrapHandler((params) => {
      const name = validateString(params.name, 'name')
      const criteria = params.criteria as FilterGroup
      if (!criteria || !criteria.conditions) throw new Error('Invalid filter criteria')
      const sortBy = typeof params.sortBy === 'string' ? params.sortBy : undefined
      const sortOrder = typeof params.sortOrder === 'string' ? params.sortOrder : undefined
      const description = typeof params.description === 'string' ? params.description : undefined
      const icon = typeof params.icon === 'string' ? params.icon : undefined

      const row = repo.create({
        name,
        description,
        filterCriteria: criteria,
        sortBy,
        sortOrder,
        icon,
      })

      const photos = engine.filterPhotos('__global__', criteria, sortBy, sortOrder)
      const data: SmartAlbumDetailData = {
        id: row.id,
        name: row.name,
        description: row.description,
        filterCriteria: JSON.parse(row.filter_criteria),
        sortBy: row.sort_by,
        sortOrder: row.sort_order,
        icon: row.icon,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
        photoCount: photos.length,
      }
      return ok(data)
    }),
  )

  registry.register(
    'album.list',
    wrapHandler(() => {
      const rows = repo.list()
      const albums: SmartAlbumData[] = rows.map((row) => ({
        id: row.id,
        name: row.name,
        description: row.description,
        filterCriteria: JSON.parse(row.filter_criteria),
        sortBy: row.sort_by,
        sortOrder: row.sort_order,
        icon: row.icon,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
      }))
      return ok(albums)
    }),
  )

  registry.register(
    'album.get',
    wrapHandler((params) => {
      const albumId = validateString(params.albumId, 'albumId')
      const row = repo.get(albumId)
      if (!row) return err('Album not found')
      const criteria: FilterGroup = JSON.parse(row.filter_criteria)
      const photos = engine.filterPhotos('__global__', criteria, row.sort_by, row.sort_order)
      const data: SmartAlbumDetailData = {
        id: row.id,
        name: row.name,
        description: row.description,
        filterCriteria: criteria,
        sortBy: row.sort_by,
        sortOrder: row.sort_order,
        icon: row.icon,
        createdAt: row.created_at,
        updatedAt: row.updated_at,
        photoCount: photos.length,
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
      if (params.criteria) updateData.filterCriteria = params.criteria as FilterGroup
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

      const criteria: FilterGroup = JSON.parse(row.filter_criteria)
      const sortBy = row.sort_by
      const sortOrder = row.sort_order

      const limit = typeof params.limit === 'number' ? params.limit : undefined
      const offset = typeof params.offset === 'number' ? params.offset : undefined

      const photos = engine.filterPhotos('__global__', criteria, sortBy, sortOrder, limit, offset)

      return ok({ photos, total: photos.length })
    }),
  )
}
