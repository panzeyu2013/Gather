import { MetadataCacheRepository, MetadataCacheInput, MetadataCacheRow } from '../../db/repositories/metadata-cache.repo'
import { MetadataWriterRouter } from '../xmp/metadata-writer-router'
import { Database } from '../../db/database'
import { batchAsync, parseKeywords } from '../../utils/async'
import type { MetadataTags, BatchMetadataResult } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'
import type { MetadataWriteAttributes } from './metadata-writer.interface'
import { cacheStalenessKey } from './metadata-fingerprint'
import { existsSync } from 'fs'
import { MetadataMutationService } from './metadata-mutation.service'

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
    label: row.label ?? undefined,
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
    label: tags.label,
    gpsLatitude: tags.latitude,
    gpsLongitude: tags.longitude,
    width: tags.width,
    height: tags.height,
    fileSize: tags.fileSize,
    keywords: tags.keywords,
  }
}

@injectable()
export class MetadataService {
  constructor(
    @inject(DI_TOKENS.METADATA_CACHE_REPO) private metadataCacheRepo: MetadataCacheRepository,
    @inject(DI_TOKENS.WRITER_ROUTER) private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.METADATA_MUTATION_SERVICE)
    private metadataMutations: MetadataMutationService,
  ) {}

  private async readEffectiveAttributes(photoPath: string) {
    const selected = this.writerRouter.selectForRead(photoPath)
    const sidecar = this.writerRouter.selectSidecar()
    const selectedAttributes = await selected.readAttributes(photoPath)
    if (selected === sidecar) return selectedAttributes
    const sidecarAttributes = await sidecar.readAttributes(photoPath)
    return { ...selectedAttributes, ...sidecarAttributes }
  }

  private getPhotosByIds(photoIds: string[]): { id: string; filepath: string; session_id: string }[] {
    if (photoIds.length === 0) return []
    const placeholders = photoIds.map(() => '?').join(',')
    return this.db
      .prepare(`SELECT id, session_id, filepath FROM photos WHERE id IN (${placeholders})`)
      .all(...photoIds) as { id: string; filepath: string; session_id: string }[]
  }

  /**
   * A corrupt sidecar makes readAttributes() return an empty object even
   * though the file exists. Without this guard the cache would be overwritten
   * with empty keywords/rating/label, erasing previously valid values until
   * the file changes again.
   */
  private preserveValuesOnCorruptSidecar(
    photoId: string,
    filepath: string,
    writerAttributes: MetadataWriteAttributes,
  ): void {
    if (Object.keys(writerAttributes).length > 0) return
    if (!existsSync(getXmpSidecarPath(filepath))) return
    const previous = this.metadataCacheRepo.get(photoId)
    if (!previous) return
    const previousKeywords = parseKeywords(previous.keywords)
    if (previousKeywords.length > 0) {
      writerAttributes.keywords = previousKeywords
    }
    if (previous.rating != null) {
      writerAttributes.rating = previous.rating
    }
    if (previous.label != null) {
      writerAttributes.label = previous.label
    }
  }

  async getMetadata(photoIds: string[]): Promise<Map<string, MetadataTags>> {
    const result = new Map<string, MetadataTags>()
    const allPhotos = this.getPhotosByIds(photoIds)
    const photoById = new Map(allPhotos.map(photo => [photo.id, photo]))
    const fingerprints = new Map<string, { size: number; value: string }>()
    await batchAsync(allPhotos, async (photo) => {
      try {
        const fingerprint = await cacheStalenessKey(photo.filepath)
        if (fingerprint) {
          fingerprints.set(photo.id, fingerprint)
        }
      } catch {
        // Unreadable files will be handled by extraction.
      }
    }, 16)
    const cached = this.metadataCacheRepo.getBatch(photoIds)
      .filter(row => {
        const fingerprint = fingerprints.get(row.photo_id)
        return Boolean(
          fingerprint &&
          row.file_size === fingerprint.size &&
          row.file_mtime === fingerprint.value,
        )
      })
    const cachedIds = new Set(cached.map(row => row.photo_id))
    const missingIds = photoIds.filter((id) => !cachedIds.has(id))

    for (const row of cached) {
      result.set(row.photo_id, cacheRowToTags(row))
    }

    if (missingIds.length > 0) {
      const photos = missingIds.flatMap(id => {
        const photo = photoById.get(id)
        return photo ? [photo] : []
      })
      const exifr = await getExifr()
      let sharpModule: typeof import('sharp') | null = null

      await batchAsync(photos, async (photo) => {
        try {
          let tags: MetadataTags = {}
          let cacheInput: MetadataCacheInput = {}
          const fingerprint = fingerprints.get(photo.id)

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
                rating: typeof exifData.Rating === 'number'
                  ? exifData.Rating
                  : undefined,
                label: typeof exifData.Label === 'string'
                  ? exifData.Label
                  : undefined,
              }
              cacheInput = tagsToCacheInput(tags)
              cacheInput.fileSize = fingerprint?.size
              cacheInput.fileMtime = fingerprint?.value
              // exifr parses embedded XMP when present; the selected writer also
              // covers RAW sidecars that are not part of the source file.
              const exifrSubject = (exifData as Record<string, unknown>).Subject
              const exifrKeywords = (exifData as Record<string, unknown>).Keywords
              const fromExifr = (Array.isArray(exifrSubject) ? exifrSubject : Array.isArray(exifrKeywords) ? exifrKeywords : null) as string[] | null
              if (fromExifr && fromExifr.length > 0) {
                tags.keywords = fromExifr
                cacheInput.keywords = fromExifr
              }

              const writerAttributes = await this.readEffectiveAttributes(photo.filepath)
              this.preserveValuesOnCorruptSidecar(photo.id, photo.filepath, writerAttributes)
              if (writerAttributes.keywords !== undefined) {
                tags.keywords = writerAttributes.keywords
                cacheInput.keywords = writerAttributes.keywords
              }
              if (writerAttributes.rating !== undefined) {
                tags.rating = writerAttributes.rating
                cacheInput.rating = writerAttributes.rating
              }
              if (writerAttributes.label !== undefined) {
                tags.label = writerAttributes.label
                cacheInput.label = writerAttributes.label
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
            fileSize: fingerprint?.size ?? metadata.size,
            fileMtime: fingerprint?.value,
          }

          const existingAttributes = await this.readEffectiveAttributes(photo.filepath)
          this.preserveValuesOnCorruptSidecar(photo.id, photo.filepath, existingAttributes)
          Object.assign(tags, existingAttributes)
          if (existingAttributes.keywords !== undefined) cacheInput.keywords = existingAttributes.keywords
          if (existingAttributes.rating !== undefined) cacheInput.rating = existingAttributes.rating
          if (existingAttributes.label !== undefined) cacheInput.label = existingAttributes.label

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
    const supportedMutationFields = new Set(['rating', 'label', 'keywords'])
    const unsupported = Object.keys(tags).filter(key => !supportedMutationFields.has(key))
    if (unsupported.length > 0) {
      throw new Error(`Metadata writeback does not support these fields: ${unsupported.join(', ')}`)
    }
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

    if (photo && (tags.keywords !== undefined || tags.rating !== undefined || tags.label !== undefined)) {
      await this.metadataMutations.queueMutation(
        sessionId,
        photoId,
        {
          ...(tags.rating !== undefined ? { rating: { op: 'set' as const, value: tags.rating } } : {}),
          ...(tags.label !== undefined ? { label: { op: 'set' as const, value: tags.label } } : {}),
          ...(tags.keywords !== undefined ? { keywords: { op: 'replace' as const, values: tags.keywords } } : {}),
        },
        'manual',
      )
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
