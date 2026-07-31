import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { PhotoData } from '@gather/shared'
import type { PhotoRepository } from '../db/repositories/photo.repo'
import type { Database } from '../db/database'

export function registerPhotoHandlers(registry: CommandRegistry, photoRepo: PhotoRepository, db: Database): void {
  registry.register(
    'photo.list',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId', 64)
      const rows = photoRepo.getBySession(sessionId)
      const memberRoles = new Map(
        (db.prepare(`
          SELECT p.id AS photo_id, am.member_role
          FROM photos p
          LEFT JOIN asset_members am ON am.file_id = p.asset_file_id
          WHERE p.session_id = ?
        `).all(sessionId) as Array<{ photo_id: string; member_role: string | null }>)
          .map(row => [row.photo_id, row.member_role ?? 'unknown']),
      )
      const faceCounts = db.prepare(
        'SELECT photo_id, COUNT(*) as cnt FROM face_observations WHERE session_id = ? GROUP BY photo_id',
      ).all(sessionId) as { photo_id: string; cnt: number }[]
      const faceCountMap = new Map(faceCounts.map((f) => [f.photo_id, f.cnt]))
      const toPhotoData = (row: typeof rows[number], variants: typeof rows): PhotoData => ({
        id: row.id,
        sessionId: row.session_id,
        filepath: row.filepath,
        filename: row.filename,
        checksum: row.checksum,
        hasExistingXmp: false,
        faceCount: faceCountMap.get(row.id) ?? 0,
        width: row.width ?? 0,
        height: row.height ?? 0,
        metadata: typeof row.metadata === 'string' ? JSON.parse(row.metadata) : row.metadata,
        result: typeof row.result === 'string' ? JSON.parse(row.result) : row.result,
        status: row.status,
        assetId: row.asset_id ?? undefined,
        variantCount: variants.length,
        variants: variants.map(variant => ({
          photoId: variant.id,
          filepath: variant.filepath,
          filename: variant.filename,
          role: memberRoles.get(variant.id) ?? 'unknown',
        })),
        createdAt: row.created_at,
        updatedAt: row.updated_at,
      })
      const groups = new Map<string, typeof rows>()
      for (const row of rows) {
        const key = row.asset_id ?? `photo:${row.id}`
        const group = groups.get(key) ?? []
        group.push(row)
        groups.set(key, group)
      }
      const photos: PhotoData[] = params.expandVariants === true
        ? rows.map(row => toPhotoData(row, groups.get(row.asset_id ?? `photo:${row.id}`) ?? [row]))
        : [...groups.values()].map(variants => {
          const preferred = variants.find(row => memberRoles.get(row.id) === 'raw')
            ?? variants.find(row => memberRoles.get(row.id) === 'camera_jpeg')
            ?? variants[0]
          return toPhotoData(preferred, variants)
        })
      return ok(photos)
    }),
  )
}
