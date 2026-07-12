import { MetadataCacheRepository, MetadataCacheInput, MetadataCacheRow } from '../../db/repositories/metadata-cache.repo'
import { XmpWriter } from '../xmp/xmp-writer'
import { getDatabase } from '../../db/database'
import type { MetadataTags, BatchMetadataResult } from '@gather/shared'

async function getExifr() {
  try {
    return await import('exifr')
  } catch {
    return null
  }
}

function cacheRowToTags(row: MetadataCacheRow): MetadataTags {
  return {
    width: row.width ?? undefined,
    height: row.height ?? undefined,
    fileSize: row.file_size ?? undefined,
    make: row.camera_make ?? undefined,
    model: row.camera_model ?? undefined,
    lensModel: row.lens_model ?? undefined,
    focalLength: row.focal_length ?? undefined,
    aperture: row.f_number ?? undefined,
    shutterSpeed: row.exposure_time ?? undefined,
    iso: row.iso ?? undefined,
    dateTaken: row.date_taken ?? undefined,
    rating: row.rating ?? undefined,
    latitude: row.gps_latitude ?? undefined,
    longitude: row.gps_longitude ?? undefined,
  }
}

function tagsToCacheInput(tags: Partial<MetadataTags>): MetadataCacheInput {
  return {
    dateTaken: tags.dateTaken,
    cameraMake: tags.make,
    cameraModel: tags.model,
    lensModel: tags.lensModel,
    focalLength: tags.focalLength,
    fNumber: tags.aperture,
    exposureTime: tags.shutterSpeed,
    iso: tags.iso,
    rating: tags.rating,
    gpsLatitude: tags.latitude,
    gpsLongitude: tags.longitude,
    width: tags.width,
    height: tags.height,
    fileSize: tags.fileSize,
  }
}

export class MetadataService {
  constructor(
    private metadataCacheRepo: MetadataCacheRepository,
    private xmpWriter: XmpWriter,
  ) {}

  private getPhotosByIds(photoIds: string[]): { id: string; filepath: string; session_id: string }[] {
    if (photoIds.length === 0) return []
    const db = getDatabase()
    const placeholders = photoIds.map(() => '?').join(',')
    return db
      .prepare(`SELECT id, filepath, session_id FROM photos WHERE id IN (${placeholders})`)
      .all(...photoIds) as { id: string; filepath: string; session_id: string }[]
  }

  async getMetadata(photoIds: string[]): Promise<Map<string, MetadataTags>> {
    const result = new Map<string, MetadataTags>()
    const cached = this.metadataCacheRepo.getBatch(photoIds)
    const cachedIds = new Set(cached.map((r) => r.photo_id))
    const missingIds = photoIds.filter((id) => !cachedIds.has(id))

    for (const row of cached) {
      result.set(row.photo_id, cacheRowToTags(row))
    }

    if (missingIds.length > 0) {
      const photos = this.getPhotosByIds(missingIds)
      const exifr = await getExifr()
      let sharpModule: typeof import('sharp') | null = null

      for (const photo of photos) {
        try {
          if (exifr) {
            const exifData = await exifr.parse(photo.filepath)
            if (exifData) {
              const tags: MetadataTags = {
                make: exifData.Make,
                model: exifData.Model,
                lensModel: exifData.LensModel,
                focalLength: exifData.FocalLength,
                aperture: exifData.FNumber,
                shutterSpeed: exifData.ExposureTime ? String(exifData.ExposureTime) : undefined,
                iso: exifData.ISO,
                dateTaken: exifData.DateTimeOriginal ? String(exifData.DateTimeOriginal) : undefined,
                latitude: exifData.latitude,
                longitude: exifData.longitude,
                width: exifData.ImageWidth ?? exifData.ExifImageWidth,
                height: exifData.ImageHeight ?? exifData.ExifImageHeight,
              }
              result.set(photo.id, tags)
              this.metadataCacheRepo.upsert(photo.id, photo.session_id, tagsToCacheInput(tags))
              continue
            }
          }

          const sharp = sharpModule ?? (sharpModule = await import('sharp'))
          const metadata = await sharp(photo.filepath).metadata()
          const tags: MetadataTags = {
            width: metadata.width,
            height: metadata.height,
            fileSize: metadata.size,
            format: metadata.format,
          }
          result.set(photo.id, tags)
          this.metadataCacheRepo.upsert(photo.id, photo.session_id, {
            width: metadata.width,
            height: metadata.height,
            fileSize: metadata.size,
          })
        } catch {
          result.set(photo.id, {})
        }
      }
    }

    return result
  }

  setMetadata(photoId: string, tags: Partial<MetadataTags>): MetadataTags {
    const cacheInput = tagsToCacheInput(tags)
    const photos = this.getPhotosByIds([photoId])
    const photo = photos.length > 0 ? photos[0] : null
    let sessionId = ''

    if (photo) {
      sessionId = photo.session_id
      const xmpPath = photo.filepath + '.xmp'
      const xmpTags: Record<string, unknown> = {}
      if (tags.keywords !== undefined) xmpTags.keywords = tags.keywords
      if (tags.rating !== undefined) xmpTags.rating = tags.rating
      if (tags.dateTaken !== undefined) xmpTags.dateTaken = tags.dateTaken
      if (tags.latitude !== undefined) xmpTags.latitude = tags.latitude
      if (tags.longitude !== undefined) xmpTags.longitude = tags.longitude
      if (Object.keys(xmpTags).length > 0) {
        this.xmpWriter.writeAttributes(xmpPath, xmpTags)
      }
    }

    this.metadataCacheRepo.upsert(photoId, sessionId, cacheInput)

    const existing = this.metadataCacheRepo.get(photoId)
    const base = existing ? cacheRowToTags(existing) : {}
    return { ...base, ...tags }
  }

  async batchSet(updates: { photoId: string; tags: Partial<MetadataTags> }[]): Promise<BatchMetadataResult> {
    let success = 0
    let failed = 0
    const errors: string[] = []

    for (const { photoId, tags } of updates) {
      try {
        await this.setMetadata(photoId, tags)
        success++
      } catch (e) {
        failed++
        const message = e instanceof Error ? e.message : 'Unknown error'
        errors.push(`${photoId}: ${message}`)
      }
    }

    return { success, failed, errors }
  }

  async populateCache(sessionId: string, photoIds: string[]): Promise<void> {
    const sharp = await import('sharp')
    for (const photoId of photoIds) {
      try {
        const photos = this.getPhotosByIds([photoId])
        if (photos.length === 0) continue
        const metadata = await sharp(photos[0].filepath).metadata()
        const input: MetadataCacheInput = {
          sessionId,
          width: metadata.width,
          height: metadata.height,
          fileSize: metadata.size,
        }
        this.metadataCacheRepo.upsert(photoId, sessionId, input)
      } catch {
        // skip files that cannot be read
      }
    }
  }
}
