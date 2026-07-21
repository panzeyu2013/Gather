import { MetadataCacheRepository, MetadataCacheInput, MetadataCacheRow } from '../../db/repositories/metadata-cache.repo'
import { MetadataWriterRouter } from '../xmp/metadata-writer-router'
import { getDatabase } from '../../db/database'
import { batchAsync, parseKeywords } from '../../utils/async'
import type { MetadataTags, BatchMetadataResult } from '@gather/shared'

async function getExifr() {
  try {
    return await import('exifr')
  } catch {
    return null
  }
}

function cacheRowToTags(row: MetadataCacheRow): MetadataTags {
  const keywords = parseKeywords(row.keywords)
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
    keywords: keywords.length > 0 ? keywords : undefined,
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
    keywords: tags.keywords,
  }
}

export class MetadataService {
  constructor(
    private metadataCacheRepo: MetadataCacheRepository,
    private writerRouter: MetadataWriterRouter,
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

      await batchAsync(photos, async (photo) => {
        try {
          let tags: MetadataTags = {}
          let cacheInput: MetadataCacheInput = {}

          if (exifr) {
            const exifData = await exifr.parse(photo.filepath)
            if (exifData) {
              tags = {
                make: exifData.Make as string,
                model: exifData.Model as string,
                lensModel: exifData.LensModel as string,
                focalLength: exifData.FocalLength as number,
                aperture: exifData.FNumber as number,
                shutterSpeed: exifData.ExposureTime ? String(exifData.ExposureTime) : undefined,
                iso: exifData.ISO as number,
                dateTaken: exifData.DateTimeOriginal ? String(exifData.DateTimeOriginal) : undefined,
                latitude: exifData.latitude as number,
                longitude: exifData.longitude as number,
                width: (exifData.ImageWidth ?? exifData.ExifImageWidth) as number,
                height: (exifData.ImageHeight ?? exifData.ExifImageHeight) as number,
              }
              cacheInput = tagsToCacheInput(tags)
              // exifr parses embedded XMP: use Subject/Keywords if present, skip separate readKeywords
              const exifrSubject = (exifData as Record<string, unknown>).Subject
              const exifrKeywords = (exifData as Record<string, unknown>).Keywords
              const fromExifr = (Array.isArray(exifrSubject) ? exifrSubject : Array.isArray(exifrKeywords) ? exifrKeywords : null) as string[] | null
              if (fromExifr && fromExifr.length > 0) {
                tags.keywords = fromExifr
                cacheInput.keywords = fromExifr
              } else {
                const writer = this.writerRouter.select(photo.filepath)
                const existingKeywords = await writer.readKeywords(photo.filepath)
                if (existingKeywords.length > 0) {
                  tags.keywords = existingKeywords
                  cacheInput.keywords = existingKeywords
                }
              }

              result.set(photo.id, tags)
              this.metadataCacheRepo.upsert(photo.id, photo.session_id, cacheInput)
              return
            }
          }

          sharpModule ??= (await import('sharp')) as unknown as typeof import('sharp')
          const metadata = await sharpModule(photo.filepath).metadata()
          tags = {
            width: metadata.width,
            height: metadata.height,
            fileSize: metadata.size,
            format: metadata.format,
          }
          cacheInput = {
            width: metadata.width,
            height: metadata.height,
            fileSize: metadata.size,
          }

          const writer = this.writerRouter.select(photo.filepath)
          const existingKeywords = await writer.readKeywords(photo.filepath)
          if (existingKeywords.length > 0) {
            tags.keywords = existingKeywords
            cacheInput.keywords = existingKeywords
          }

          result.set(photo.id, tags)
          this.metadataCacheRepo.upsert(photo.id, photo.session_id, cacheInput)
        } catch (e) {
          console.warn(`Failed to extract metadata for ${photo.filepath}:`, e instanceof Error ? e.message : e)
          result.set(photo.id, {})
        }
      }, 10)
    }

    return result
  }

  async setMetadata(photoId: string, tags: Partial<MetadataTags>): Promise<MetadataTags> {
    const existing = this.metadataCacheRepo.get(photoId)
    const baseTags = existing ? cacheRowToTags(existing) : ({} as MetadataTags)
    const merged = { ...baseTags }
    for (const key of Object.keys(tags) as (keyof MetadataTags)[]) {
      if (tags[key] !== undefined) (merged as Record<string, unknown>)[key] = tags[key]
    }

    const cacheInput = tagsToCacheInput(merged)
    const photos = this.getPhotosByIds([photoId])
    const photo = photos.length > 0 ? photos[0] : null
    let sessionId = photo ? photo.session_id : existing?.session_id ?? ''

    if (photo) {
      const hasMetaFields =
        tags.keywords !== undefined ||
        tags.rating !== undefined ||
        tags.dateTaken !== undefined ||
        tags.latitude !== undefined ||
        tags.longitude !== undefined
      if (hasMetaFields) {
        const writer = this.writerRouter.select(photo.filepath)
        await writer.writeAttributes(photo.filepath, {
          keywords: tags.keywords,
          rating: tags.rating,
          dateTaken: tags.dateTaken,
          latitude: tags.latitude,
          longitude: tags.longitude,
        })
      }
    }

    this.metadataCacheRepo.upsert(photoId, sessionId, cacheInput)
    return merged
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
    const sharp = (await import('sharp')) as unknown as typeof import('sharp')
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
      } catch (e) {
        console.warn(`Failed to populate cache for photo ${photoId}:`, e instanceof Error ? e.message : e)
      }
    }
  }
}
