import { getDatabase } from '../database'

export interface MetadataCacheRow {
  id: number
  photo_id: string
  session_id: string
  date_taken: string | null
  camera_make: string | null
  camera_model: string | null
  lens_model: string | null
  focal_length: number | null
  f_number: number | null
  exposure_time: string | null
  iso: number | null
  rating: number
  gps_latitude: number | null
  gps_longitude: number | null
  width: number | null
  height: number | null
  file_size: number | null
  file_mtime: string | null
  cached_at: string
}

export interface MetadataCacheInput {
  sessionId?: string
  dateTaken?: string
  cameraMake?: string
  cameraModel?: string
  lensModel?: string
  focalLength?: number
  fNumber?: number
  exposureTime?: string
  iso?: number
  rating?: number
  gpsLatitude?: number
  gpsLongitude?: number
  width?: number
  height?: number
  fileSize?: number
  fileMtime?: string
}

export class MetadataCacheRepository {
  upsert(photoId: string, sessionId: string, data: MetadataCacheInput): void {
    const db = getDatabase()
    const now = new Date().toISOString()
    db.prepare(
      `INSERT OR REPLACE INTO photo_metadata_cache
       (photo_id, session_id, date_taken, camera_make, camera_model, lens_model,
        focal_length, f_number, exposure_time, iso, rating,
        gps_latitude, gps_longitude, width, height, file_size, file_mtime, cached_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      photoId,
      data.sessionId ?? sessionId,
      data.dateTaken ?? null,
      data.cameraMake ?? null,
      data.cameraModel ?? null,
      data.lensModel ?? null,
      data.focalLength ?? null,
      data.fNumber ?? null,
      data.exposureTime ?? null,
      data.iso ?? null,
      data.rating ?? 0,
      data.gpsLatitude ?? null,
      data.gpsLongitude ?? null,
      data.width ?? null,
      data.height ?? null,
      data.fileSize ?? null,
      data.fileMtime ?? null,
      now,
    )
  }

  get(photoId: string): MetadataCacheRow | null {
    const db = getDatabase()
    const row = db
      .prepare('SELECT * FROM photo_metadata_cache WHERE photo_id = ?')
      .get(photoId) as MetadataCacheRow | undefined
    return row ?? null
  }

  getBatch(photoIds: string[]): MetadataCacheRow[] {
    if (photoIds.length === 0) return []
    const db = getDatabase()
    const placeholders = photoIds.map(() => '?').join(',')
    return db
      .prepare(`SELECT * FROM photo_metadata_cache WHERE photo_id IN (${placeholders})`)
      .all(...photoIds) as MetadataCacheRow[]
  }

  deleteBySession(sessionId: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM photo_metadata_cache WHERE session_id = ?').run(sessionId)
  }

  updateRating(photoId: string, rating: number): void {
    const db = getDatabase()
    db.prepare('UPDATE photo_metadata_cache SET rating = ? WHERE photo_id = ?').run(rating, photoId)
  }
}
