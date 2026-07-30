import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

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
  label: string | null
  gps_latitude: number | null
  gps_longitude: number | null
  width: number | null
  height: number | null
  file_size: number | null
  file_mtime: string | null
  keywords: string
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
  label?: string
  gpsLatitude?: number
  gpsLongitude?: number
  width?: number
  height?: number
  fileSize?: number
  fileMtime?: string
  keywords?: string[]
}

@injectable()
export class MetadataCacheRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  upsert(photoId: string, sessionId: string, data: MetadataCacheInput): void {
    const now = new Date().toISOString()
    this.db.prepare(
      `INSERT INTO photo_metadata_cache
       (photo_id, session_id, date_taken, camera_make, camera_model, lens_model,
        focal_length, f_number, exposure_time, iso, rating, label,
        gps_latitude, gps_longitude, width, height, file_size, file_mtime, keywords, cached_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(photo_id) DO UPDATE SET
        session_id = excluded.session_id,
        date_taken = excluded.date_taken,
        camera_make = excluded.camera_make,
        camera_model = excluded.camera_model,
        lens_model = excluded.lens_model,
        focal_length = excluded.focal_length,
        f_number = excluded.f_number,
        exposure_time = excluded.exposure_time,
        iso = excluded.iso,
        rating = excluded.rating,
        label = excluded.label,
        gps_latitude = excluded.gps_latitude,
        gps_longitude = excluded.gps_longitude,
        width = excluded.width,
        height = excluded.height,
        file_size = excluded.file_size,
        file_mtime = excluded.file_mtime,
        keywords = excluded.keywords,
        cached_at = excluded.cached_at`,
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
      data.label ?? null,
      data.gpsLatitude ?? null,
      data.gpsLongitude ?? null,
      data.width ?? null,
      data.height ?? null,
      data.fileSize ?? null,
      data.fileMtime ?? null,
      JSON.stringify(data.keywords ?? []),
      now,
    )
  }

  get(photoId: string): MetadataCacheRow | null {
    const row = this.db
      .prepare('SELECT * FROM photo_metadata_cache WHERE photo_id = ?')
      .get(photoId) as MetadataCacheRow | undefined
    return row ?? null
  }

  getBatch(photoIds: string[]): MetadataCacheRow[] {
    if (photoIds.length === 0) return []
    const rows: MetadataCacheRow[] = []
    // Stay below SQLite's commonly configured parameter limit while allowing
    // large sessions to open in one workbench query.
    for (let index = 0; index < photoIds.length; index += 800) {
      const chunk = photoIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(',')
      rows.push(...this.db
        .prepare(`SELECT * FROM photo_metadata_cache WHERE photo_id IN (${placeholders})`)
        .all(...chunk) as MetadataCacheRow[])
    }
    return rows
  }

  deleteBySession(sessionId: string): void {
    this.db.prepare('DELETE FROM photo_metadata_cache WHERE session_id = ?').run(sessionId)
  }

  deleteByPhotoId(photoId: string): void {
    this.db.prepare('DELETE FROM photo_metadata_cache WHERE photo_id = ?').run(photoId)
  }

  updateRating(photoId: string, rating: number): void {
    const now = new Date().toISOString()
    this.db.prepare(`
      INSERT INTO photo_metadata_cache
        (photo_id, session_id, rating, keywords, cached_at)
      SELECT id, session_id, ?, '[]', ?
      FROM photos
      WHERE id = ?
      ON CONFLICT(photo_id) DO UPDATE SET
        rating = excluded.rating,
        cached_at = excluded.cached_at
    `).run(rating, now, photoId)
  }

  updateLabel(photoId: string, label: string): void {
    const now = new Date().toISOString()
    this.db.prepare(`
      INSERT INTO photo_metadata_cache
        (photo_id, session_id, rating, label, keywords, cached_at)
      SELECT id, session_id, 0, ?, '[]', ?
      FROM photos
      WHERE id = ?
      ON CONFLICT(photo_id) DO UPDATE SET
        label = excluded.label,
        cached_at = excluded.cached_at
    `).run(label, now, photoId)
  }

  updateKeywords(photoId: string, keywords: string[]): void {
    const now = new Date().toISOString()
    this.db.prepare(`
      INSERT INTO photo_metadata_cache
        (photo_id, session_id, rating, keywords, cached_at)
      SELECT id, session_id, 0, ?, ?
      FROM photos
      WHERE id = ?
      ON CONFLICT(photo_id) DO UPDATE SET
        keywords = excluded.keywords,
        cached_at = excluded.cached_at
    `).run(JSON.stringify(keywords), now, photoId)
  }
}
