import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { PersonData, PersonDetailData, PersonPhotoItem } from '@gather/shared'
import { PersonRepository } from '../db/repositories/person.repo'
import { getServices } from '../bootstrap'

function toPersonData(row: ReturnType<PersonRepository['get']>): PersonData | null {
  if (!row) return null
  let keywords: string[] = []
  try {
    keywords = JSON.parse(row.keywords)
  } catch { /* ignore */ }
  const { personRepo: repo } = getServices()
  return {
    id: row.id,
    name: row.name,
    keywords,
    thumbnailBase64: row.thumbnail_base64,
    notes: row.notes,
    matchThreshold: row.match_threshold,
    photoCount: repo.countPhotos(row.id),
    sessionCount: repo.getSessionCount(row.id),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

export function registerPersonHandlers(registry: CommandRegistry): void {
  const { personRepo } = getServices()
  registry.register(
    'person.list',
    wrapHandler(async () => {
      const rows = personRepo.listWithCounts()
      const persons: PersonData[] = rows.map((r) => {
        let keywords: string[] = []
        try {
          keywords = JSON.parse(r.keywords)
        } catch { /* ignore */ }
        return {
          id: r.id,
          name: r.name,
          keywords,
          thumbnailBase64: r.thumbnail_base64,
          notes: r.notes,
          matchThreshold: r.match_threshold,
          photoCount: r.photo_count,
          sessionCount: r.session_count,
          createdAt: r.created_at,
          updatedAt: r.updated_at,
        }
      })
      return ok(persons)
    }),
  )

  registry.register(
    'person.get',
    wrapHandler(async (params) => {
      const personId = validateString(params.personId, 'personId')
      const row = personRepo.get(personId)
      if (!row) throw new Error('Person not found')
      const data = toPersonData(row)!
      const photosResult = personRepo.getPhotosWithDetails(personId)
      const photos: PersonPhotoItem[] = photosResult.photos.map((p) => ({
        photoId: p.photo_id,
        sessionId: p.session_id,
        sessionName: p.sessionName,
        filename: p.filename,
        filepath: p.filepath,
        faceBbox: (() => { try { return JSON.parse(p.face_bbox) } catch { return [] } })(),
        confidence: p.confidence,
        thumbnailBase64: undefined,
      }))
      const detail: PersonDetailData = { ...data, photos, totalPhotoCount: photosResult.total }
      return ok(detail)
    }),
  )

  registry.register(
    'person.create',
    wrapHandler(async (params) => {
      const name = validateString(params.name, 'name')
      const keywords = Array.isArray(params.keywords) ? (params.keywords as string[]) : undefined
      const id = personRepo.create(name, keywords)
      return ok({ id })
    }),
  )

  registry.register(
    'person.update',
    wrapHandler(async (params) => {
      const personId = validateString(params.personId, 'personId')
      const fields: Record<string, unknown> = {}
      if (typeof params.name === 'string') fields.name = params.name.trim()
      if (Array.isArray(params.keywords)) fields.keywords = params.keywords as string[]
      if (typeof params.notes === 'string') fields.notes = params.notes
      if (typeof params.matchThreshold === 'number') fields.matchThreshold = params.matchThreshold
      personRepo.update(personId, fields)
      return ok({ done: true })
    }),
  )

  registry.register(
    'person.delete',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Delete requires explicit confirmation')
      }
      const personId = validateString(params.personId, 'personId')
      personRepo.delete(personId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'person.merge',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Merge requires explicit confirmation')
      }
      const sourceId = validateString(params.sourceId, 'sourceId')
      const targetId = validateString(params.targetId, 'targetId')
      personRepo.merge(sourceId, targetId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'person.remove_photo',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('person.remove_photo requires confirmation')
      }
      const personId = validateString(params.personId, 'personId')
      const photoId = validateString(params.photoId, 'photoId')
      personRepo.removePhoto(personId, photoId)
      return ok({ done: true })
    }),
  )

  registry.register(
    'person.search_photos',
    wrapHandler(async (params) => {
      const personId = validateString(params.personId, 'personId')
      const sessionIds = Array.isArray(params.sessionIds)
        ? (params.sessionIds as string[]).filter((s: unknown) => typeof s === 'string')
        : undefined
      const limit = typeof params.limit === 'number' ? params.limit : undefined
      const offset = typeof params.offset === 'number' ? params.offset : undefined
      const result = personRepo.getPhotosWithDetails(personId, sessionIds, limit, offset)
      const photos: PersonPhotoItem[] = result.photos.map((p) => ({
        photoId: p.photo_id,
        sessionId: p.session_id,
        sessionName: p.sessionName,
        filename: p.filename,
        filepath: p.filepath,
        faceBbox: (() => { try { return JSON.parse(p.face_bbox) } catch { return [] } })(),
        confidence: p.confidence,
        thumbnailBase64: undefined,
      }))
      return ok({ photos, total: result.total })
    }),
  )
}
