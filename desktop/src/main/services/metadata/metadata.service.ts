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
import { PhotoAssetResolver } from '../assets/photo-asset-resolver'

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

/** Mirrors EmbeddedWriter's normalization of exifr keyword lists (single
 * values arrive as scalars). */
function normalizeKeywordList(value: unknown): string[] | undefined {
  const list = Array.isArray(value) ? value : value === undefined || value === null ? [] : [value]
  const strings = list
    .filter((item): item is string | number => typeof item === 'string' || typeof item === 'number')
    .map(item => String(item))
  return strings.length > 0 ? strings : undefined
}

@injectable()
export class MetadataService {
  constructor(
    @inject(DI_TOKENS.METADATA_CACHE_REPO) private metadataCacheRepo: MetadataCacheRepository,
    @inject(DI_TOKENS.WRITER_ROUTER) private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.METADATA_MUTATION_SERVICE)
    private metadataMutations: MetadataMutationService,
    @inject(DI_TOKENS.PHOTO_ASSET_RESOLVER)
    private assetResolver?: PhotoAssetResolver,
  ) {}

  private async readEffectiveAttributes(photoPath: string) {
    const selected = this.writerRouter.selectForRead(photoPath)
    const sidecar = this.writerRouter.selectSidecar()
    const selectedAttributes = await selected.readAttributes(photoPath)
    if (selected === sidecar) return selectedAttributes
    const sidecarAttributes = await sidecar.readAttributes(photoPath)
    return { ...selectedAttributes, ...sidecarAttributes }
  }

  /**
   * Effective writer attributes for a photo whose exifr parse already
   * happened in getMetadata. Without this, a JPEG would be read twice: once
   * by exifr and again by EmbeddedWriter.readAttributes extracting its XMP.
   * For JPEG — the only format the embedded reader serves in-process with
   * the same parse options — the embedded values are derived from the shared
   * parse segments instead, so the external sidecar is the only extra read.
   * When the in-process derivation cannot serve the file (IPTC-only keywords
   * are charset-unreliable through exifr) it falls back to
   * readEffectiveAttributes(), which goes through the exiftool pool exactly
   * like the embedded writer does.
   */
  private async readEffectiveAttributesOnce(
    photoPath: string,
    parsed: Record<string, unknown>,
    isJpeg: boolean,
  ): Promise<MetadataWriteAttributes> {
    const selected = this.writerRouter.selectForRead(photoPath)
    const sidecar = this.writerRouter.selectSidecar()
    if (selected === sidecar) {
      // RAW / sidecar-mode photos: the selected reader IS the sidecar, one read.
      return selected.readAttributes(photoPath)
    }
    if (isJpeg) {
      const embedded = this.embeddedAttributesFromParse(parsed)
      if (embedded) {
        const sidecarAttributes = await sidecar.readAttributes(photoPath)
        return { ...embedded, ...sidecarAttributes }
      }
    }
    return this.readEffectiveAttributes(photoPath)
  }

  /**
   * Embedded rating/label/keywords derived from an already-parsed exifr
   * result, using exactly the rules of EmbeddedWriter.readExifrAttributes:
   * XMP dc:subject wins over IPTC, xmp:Rating ?? IFD0 rating coerced to a
   * number, xmp:Label. Returns null when the file must go through the
   * embedded writer's exiftool pool instead (IPTC-only keywords).
   */
  private embeddedAttributesFromParse(
    parsed: Record<string, unknown>,
  ): MetadataWriteAttributes | null {
    const xmp = parsed.xmp as Record<string, unknown> | undefined
    const dc = parsed.dc as Record<string, unknown> | undefined
    const iptc = parsed.iptc as Record<string, unknown> | undefined
    const ifd0 = parsed.ifd0 as Record<string, unknown> | undefined
    const rawRating = xmp?.Rating ?? ifd0?.Rating
    const rating = typeof rawRating === 'number'
      ? rawRating
      : typeof rawRating === 'string' && Number.isFinite(Number(rawRating))
        ? Number(rawRating)
        : undefined
    const keywords = normalizeKeywordList(dc?.subject)
    if (keywords === undefined && iptc?.Keywords !== undefined) {
      return null
    }
    return {
      keywords: keywords ?? normalizeKeywordList(iptc?.Keywords),
      rating,
      label: typeof xmp?.Label === 'string' ? xmp.Label : undefined,
    }
  }

  private getPhotosByIds(photoIds: string[]): { id: string; filepath: string; session_id: string }[] {
    if (photoIds.length === 0) return []
    const photos: { id: string; filepath: string; session_id: string }[] = []
    // Stay below SQLite's commonly configured parameter limit, mirroring the
    // cache repository's getBatch chunking.
    for (let index = 0; index < photoIds.length; index += 800) {
      const chunk = photoIds.slice(index, index + 800)
      const placeholders = chunk.map(() => '?').join(',')
      photos.push(...this.db
        .prepare(`SELECT id, session_id, filepath FROM photos WHERE id IN (${placeholders})`)
        .all(...chunk) as { id: string; filepath: string; session_id: string }[])
    }
    return photos
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
      // Upserts are buffered during the concurrent extraction and flushed in
      // one transaction afterwards (metadataCacheRepo.upsert runs a bare
      // statement, no internal transaction, so wrapping is safe). The per-photo
      // try/catch still isolates extraction failures, which just skip their
      // row's write.
      const pendingUpserts: Array<{
        photoId: string
        sessionId: string
        input: MetadataCacheInput
      }> = []

      await batchAsync(photos, async (photo) => {
        try {
          let tags: MetadataTags = {}
          let cacheInput: MetadataCacheInput = {}
          const fingerprint = fingerprints.get(photo.id)

          if (exifr) {
            // exifr defaults to skipping XMP, and the embedded reader would
            // re-read the whole file to extract it — a JPEG would be parsed
            // twice. Parse with the embedded reader's options (xmp/iptc on,
            // per-segment output) so the effective attributes below derive
            // from this single parse.
            const parseWithOptions = exifr.parse as unknown as (
              filePath: string,
              options: Record<string, unknown>,
            ) => Promise<Record<string, unknown> | null>
            const isJpeg = /\.(?:jpg|jpeg)$/i.test(photo.filepath)
            const exifData = await parseWithOptions(photo.filepath, isJpeg
              ? { xmp: true, iptc: true, mergeOutput: false }
              : { mergeOutput: false })
            if (exifData) {
              const ifd0 = exifData.ifd0 as Record<string, unknown> | undefined
              const exifSegment = exifData.exif as Record<string, unknown> | undefined
              const gps = exifData.gps as Record<string, unknown> | undefined
              tags = {
                make: (ifd0?.Make ?? exifSegment?.Make) as string,
                model: (ifd0?.Model ?? exifSegment?.Model) as string,
                lensModel: exifSegment?.LensModel as string,
                focalLength: exifSegment?.FocalLength as number,
                aperture: exifSegment?.FNumber as number,
                shutterSpeed: exifSegment?.ExposureTime ? String(exifSegment.ExposureTime) : undefined,
                iso: exifSegment?.ISO as number,
                dateTaken: exifSegment?.DateTimeOriginal ? String(exifSegment.DateTimeOriginal) : undefined,
                latitude: gps?.latitude as number,
                longitude: gps?.longitude as number,
                width: (ifd0?.ImageWidth ?? exifSegment?.ExifImageWidth) as number,
                height: (ifd0?.ImageHeight ?? exifSegment?.ExifImageHeight) as number,
                rating: typeof ifd0?.Rating === 'number'
                  ? ifd0.Rating
                  : undefined,
              }
              cacheInput = tagsToCacheInput(tags)
              cacheInput.fileSize = fingerprint?.size
              cacheInput.fileMtime = fingerprint?.value

              const writerAttributes = await this.readEffectiveAttributesOnce(
                photo.filepath,
                exifData,
                isJpeg,
              )
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
              pendingUpserts.push({
                photoId: photo.id,
                sessionId: photo.session_id,
                input: cacheInput,
              })
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
          pendingUpserts.push({
            photoId: photo.id,
            sessionId: photo.session_id,
            input: cacheInput,
          })
        } catch (e) {
          console.warn(`Failed to extract metadata for ${photo.filepath}:`, e instanceof Error ? e.message : e)
          result.set(photo.id, {})
        }
      }, 10)

      if (pendingUpserts.length > 0) {
        const flushUpserts = this.db.transaction(() => {
          for (const entry of pendingUpserts) {
            this.metadataCacheRepo.upsert(entry.photoId, entry.sessionId, entry.input)
          }
        })
        flushUpserts()
      }
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

    // RAW+JPEG pairs (and relinked assets) can share one sidecar between
    // different photo rows, so grouping by photoId alone leaves the order of
    // two photos' writes to the same sidecar to whatever concurrent group
    // reaches the mutation queue first. queueMutation serializes per resolved
    // xmp_path, but only once the calls arrive; group by that same path here
    // so entries of one sidecar run strictly serial and in input order, while
    // different sidecars still run in parallel.
    let photosById: Map<string, { id: string; filepath: string; session_id: string }> | null = null
    try {
      photosById = new Map(
        this.getPhotosByIds(updates.map(update => update.photoId))
          .map(photo => [photo.id, photo]),
      )
    } catch (error) {
      // A single failing chunk must not abort the whole batch; per-photo
      // lookups below fall back to the old per-item behavior.
      console.warn('Failed to batch-load photos for metadata batch:', error instanceof Error ? error.message : error)
    }
    // Batch-preload the resolved sidecar paths (one IN query per session)
    // instead of one 5-way JOIN per update. Photos the resolver cannot serve
    // fall back to the legacy sidecar path, exactly like the per-photo catch.
    let xmpPathByPhoto: Map<string, string> | null = null
    if (
      photosById &&
      this.assetResolver &&
      typeof this.assetResolver.resolveMany === 'function'
    ) {
      try {
        xmpPathByPhoto = new Map()
        const idsBySession = new Map<string, string[]>()
        for (const photo of photosById.values()) {
          const ids = idsBySession.get(photo.session_id) ?? []
          ids.push(photo.id)
          idsBySession.set(photo.session_id, ids)
        }
        for (const [sessionId, ids] of idsBySession) {
          for (const [photoId, asset] of this.assetResolver.resolveMany(sessionId, ids)) {
            xmpPathByPhoto.set(photoId, asset.xmpPath)
          }
        }
      } catch (error) {
        // Fall back to per-photo resolution so a resolution failure cannot
        // abort the whole batch.
        xmpPathByPhoto = null
        console.warn('Failed to batch-resolve assets for metadata batch:', error instanceof Error ? error.message : error)
      }
    }
    const groupKey = (photoId: string): string => {
      let photo = photosById?.get(photoId)
      if (!photo && photosById === null) {
        const row = this.getPhotosByIds([photoId])
        photo = row.length > 0 ? row[0] : undefined
      }
      if (!photo) return `missing:${photoId}`
      if (xmpPathByPhoto) {
        const xmpPath = xmpPathByPhoto.get(photoId)
        if (xmpPath) return xmpPath
      } else if (this.assetResolver) {
        try {
          return this.assetResolver.resolve(photo.session_id, photoId).xmpPath
        } catch {
          // Incomplete asset migration: group by the legacy path, which is
          // what queueMutation resolves to in that case as well.
        }
      }
      return getXmpSidecarPath(photo.filepath)
    }
    const bySidecar = new Map<string, { photoId: string; tags: Partial<MetadataTags> }[]>()
    for (const update of updates) {
      const key = groupKey(update.photoId)
      const group = bySidecar.get(key)
      if (group) group.push(update)
      else bySidecar.set(key, [update])
    }

    await batchAsync([...bySidecar.values()], async (group) => {
      for (const { photoId, tags } of group) {
        try {
          await this.setMetadata(photoId, tags)
          success++
        } catch (e) {
          failed++
          const message = e instanceof Error ? e.message : 'Unknown error'
          errors.push(`${photoId}: ${message}`)
        }
      }
    }, 4)

    return { success, failed, errors }
  }

  async populateCache(sessionId: string, photoIds: string[]): Promise<void> {
    const sharp = (await import('sharp')) as unknown as typeof import('sharp')
    // One batched photos query instead of a SELECT per photo; if the batched
    // read fails, fall back to per-photo lookups inside the per-item try so a
    // single failure cannot abort the whole populateCache.
    let photoById: Map<string, { id: string; filepath: string; session_id: string }> | null = null
    try {
      photoById = new Map(this.getPhotosByIds(photoIds).map(photo => [photo.id, photo]))
    } catch (error) {
      console.warn('Failed to batch-load photos for cache populate:', error instanceof Error ? error.message : error)
    }
    await batchAsync(photoIds, async (photoId) => {
      try {
        let photo = photoById?.get(photoId)
        if (!photo && photoById === null) {
          const row = this.getPhotosByIds([photoId])
          photo = row.length > 0 ? row[0] : undefined
        }
        if (!photo) return
        const metadata = await sharp(photo.filepath).metadata()
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
    }, 10)
  }
}
