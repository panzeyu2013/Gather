import { getDatabase } from '../db/database'
import { getServices } from '../bootstrap'
import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr, PhotoData } from '@gather/shared'

function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

function err(error: string): ResponseErr {
  return { ok: false, error }
}

function wrapHandler(handler: (params: Record<string, unknown>) => unknown) {
  return async (params: unknown) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>)
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err(message)
    }
  }
}

export function registerPhotoHandlers(registry: CommandRegistry): void {
  const { photoRepo } = getServices()
  registry.register(
    'photo.list',
    wrapHandler(async (params) => {
      const sessionId = params.sessionId as string
      if (!sessionId || typeof sessionId !== 'string') throw new Error('Invalid sessionId')
      const rows = photoRepo.getBySession(sessionId)
      const db = getDatabase()
      const faceCounts = db.prepare(
        'SELECT photo_id, COUNT(*) as cnt FROM face_observations WHERE session_id = ? GROUP BY photo_id',
      ).all(sessionId) as { photo_id: string; cnt: number }[]
      const faceCountMap = new Map(faceCounts.map((f) => [f.photo_id, f.cnt]))
      const photos: PhotoData[] = rows.map((row) => ({
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
        createdAt: row.created_at,
        updatedAt: row.updated_at,
      }))
      return ok(photos)
    }),
  )
}
