import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { PhotoData } from '@gather/shared'
import type { PhotoRepository, PhotoProjectionRow } from '../db/repositories/photo.repo'
import type { Database } from '../db/database'

const PAGE_SIZE = 200
const PAGE_SIZE_MAX = 1000

// Minimal row shape shared by the full projection and the keyset page rows.
type ListRow = Pick<
  PhotoProjectionRow,
  'id' | 'session_id' | 'filepath' | 'filename' | 'status' | 'asset_id' | 'width' | 'height' | 'created_at' | 'updated_at'
> & { checksum?: string }

// Shared PhotoData assembly for both the full list and keyset pages: member
// roles and face counts are queried for the given rows only, so a page costs
// three small queries instead of a whole-session scan.
function assemblePhotos(
  db: Database,
  sessionId: string,
  rows: ListRow[],
  expandVariants: boolean,
): PhotoData[] {
  const ids = rows.map(row => row.id)
  if (ids.length === 0) return []
  const placeholders = ids.map(() => '?').join(', ')
  const memberRoles = new Map(
    (db.prepare(`
      SELECT p.id AS photo_id, am.member_role
      FROM photos p
      LEFT JOIN asset_members am ON am.file_id = p.asset_file_id
      WHERE p.session_id = ? AND p.id IN (${placeholders})
    `).all(sessionId, ...ids) as Array<{ photo_id: string; member_role: string | null }>)
      .map(row => [row.photo_id, row.member_role ?? 'unknown']),
  )
  const faceCounts = db.prepare(
    `SELECT photo_id, COUNT(*) as cnt FROM face_observations
     WHERE session_id = ? AND photo_id IN (${placeholders}) GROUP BY photo_id`,
  ).all(sessionId, ...ids) as { photo_id: string; cnt: number }[]
  const faceCountMap = new Map(faceCounts.map((f) => [f.photo_id, f.cnt]))
  const toPhotoData = (row: ListRow, variants: ListRow[]): PhotoData => ({
    id: row.id,
    sessionId: row.session_id,
    filepath: row.filepath,
    filename: row.filename,
    checksum: row.checksum ?? '',
    hasExistingXmp: false,
    faceCount: faceCountMap.get(row.id) ?? 0,
    width: row.width ?? 0,
    height: row.height ?? 0,
    metadata: {},
    result: {},
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
  const groups = new Map<string, ListRow[]>()
  for (const row of rows) {
    const key = row.asset_id ?? `photo:${row.id}`
    const group = groups.get(key) ?? []
    group.push(row)
    groups.set(key, group)
  }
  return expandVariants
    ? rows.map(row => toPhotoData(row, groups.get(row.asset_id ?? `photo:${row.id}`) ?? [row]))
    : [...groups.values()].map(variants => {
      const preferred = variants.find(row => memberRoles.get(row.id) === 'raw')
        ?? variants.find(row => memberRoles.get(row.id) === 'camera_jpeg')
        ?? variants[0]
      return toPhotoData(preferred, variants)
    })
}

export function registerPhotoHandlers(registry: CommandRegistry, photoRepo: PhotoRepository, db: Database): void {
  registry.register(
    'photo.list',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId', 64)
      const rows = photoRepo.getBySessionProjection(sessionId)
      return ok(assemblePhotos(db, sessionId, rows, params.expandVariants === true))
    }),
  )

  // Keyset-paginated listing for the gallery: pages cut at logical-asset
  // boundaries (RAW/JPEG variants never split across pages), so a 100k-photo
  // session loads in ~10-30KB IPC chunks instead of a 30-100MB full dump.
  registry.register(
    'photo.list_page',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId', 64)
      const limit = Number.isFinite(params.limit) && typeof params.limit === 'number'
        ? Math.max(1, Math.min(PAGE_SIZE_MAX, Math.floor(params.limit)))
        : PAGE_SIZE
      const afterFirstRowid = typeof params.afterFirstRowid === 'number' && Number.isFinite(params.afterFirstRowid)
        ? params.afterFirstRowid
        : undefined
      const { rows, cursor } = photoRepo.getAssetPage(sessionId, afterFirstRowid, limit)
      return ok({
        rows: assemblePhotos(db, sessionId, rows, params.expandVariants === true),
        cursor,
      })
    }),
  )
}
