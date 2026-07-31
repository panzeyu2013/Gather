import { SettingsService } from '../settings/settings.service'
import { Database } from '../../db/database'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { SimilarityResultRepository } from '../../db/repositories/similarity-result.repo'
import { ImageService } from '../image'
import { computeBatchDHash } from './hash-computer'
import type { HashEntry } from './cluster-engine'
import { clusterHashesInWorker } from '../../utils/analysis-worker-client'
import type {
  SimilarityGroup,
  SimilarityGroupingMode,
  SimilarityImage,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { stat } from 'fs/promises'
import { batchAsync } from '../../utils/async'
import { collapsePhotoAssets } from '../assets/logical-photo-assets'

export const collapseSimilarityAssets = collapsePhotoAssets

export interface SimilarityResult {
  groups: SimilarityGroup[]
  ungrouped: SimilarityImage[]
  stats: {
    totalGroups: number
    totalUngrouped: number
    threshold: number
    minGroupSize: number
    groupingMode: SimilarityGroupingMode
  }
}

export function validateSimilarityParameters(
  threshold: number,
  minGroupSize: number,
): void {
  if (!Number.isInteger(threshold) || threshold < 0 || threshold > 64) {
    throw new Error('相似度阈值必须是 0 到 64 之间的整数')
  }
  if (!Number.isInteger(minGroupSize) || minGroupSize < 2) {
    throw new Error('相似组最小照片数必须是大于等于 2 的整数')
  }
}

export function reuseSimilarityHashes(
  db: Database,
  sessionId: string,
  photos: Array<{ id: string }>,
  sourceStats: Map<string, { size: number; mtimeMs: number }>,
  existingHashMap: Map<string, string>,
): number {
  const reusableHash = db.prepare(`
    SELECT source_hash.hash_hex
    FROM photos target
    JOIN photos source_photo
      ON source_photo.asset_file_id = target.asset_file_id
     AND source_photo.id <> target.id
    JOIN similarity_hashes source_hash
      ON source_hash.photo_id = source_photo.id
     AND source_hash.session_id = source_photo.session_id
    WHERE target.id = ?
      AND target.session_id = ?
      AND target.asset_file_id IS NOT NULL
      AND source_hash.file_size = ?
      AND ABS(source_hash.file_mtime_ms - ?) < 1
    ORDER BY source_hash.id DESC
    LIMIT 1
  `)
  const saveReusableHash = db.prepare(`
    INSERT INTO similarity_hashes
      (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(session_id, photo_id) DO UPDATE SET
      hash_hex = excluded.hash_hex,
      file_size = excluded.file_size,
      file_mtime_ms = excluded.file_mtime_ms
  `)
  let reused = 0
  db.transaction(() => {
    for (const photo of photos) {
      if (existingHashMap.has(photo.id)) continue
      const sourceStat = sourceStats.get(photo.id)
      if (!sourceStat) continue
      const source = reusableHash.get(
        photo.id,
        sessionId,
        sourceStat.size,
        sourceStat.mtimeMs,
      ) as { hash_hex: string } | undefined
      if (!source) continue
      saveReusableHash.run(
        sessionId,
        photo.id,
        source.hash_hex,
        sourceStat.size,
        sourceStat.mtimeMs,
      )
      existingHashMap.set(photo.id, source.hash_hex)
      reused++
    }
  })()
  return reused
}

@injectable()
export class SimilarityService {
  private controllers = new Map<string, AbortController>()

  constructor(
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.SIMILARITY_RESULT_REPO) private similarityResultRepo: SimilarityResultRepository,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
    @inject(DI_TOKENS.IMAGE_SERVICE) private imageService: ImageService,
    @inject(DI_TOKENS.DB) private db: Database,
  ) {}

  async analyze(
    sessionId: string,
    options?: {
      threshold?: number
      minGroupSize?: number
      groupingMode?: SimilarityGroupingMode
      onProgress?: (current: number, total: number, message: string) => void
    },
  ): Promise<void> {
    if (this.controllers.has(sessionId)) {
      throw new Error('Similarity analysis is already running for this session')
    }
    const controller = new AbortController()
    this.controllers.set(sessionId, controller)
    const { signal } = controller

    const threshold = options?.threshold ?? this.settings.getNumber('default_threshold', 10)
    const minGroupSize = options?.minGroupSize ?? this.settings.getNumber('default_min_group_size', 2)
    const groupingMode = options?.groupingMode ?? 'global'
    validateSimilarityParameters(threshold, minGroupSize)

    try {
      this.sessionRepo.updateAnalysisStatus(sessionId, 'running')

      const photos = collapseSimilarityAssets(this.photoRepo.getBySession(sessionId))
      if (photos.length === 0) {
        throw new Error('No photos in session')
      }

      const onProgress = options?.onProgress

      if (signal.aborted) return

      const db = this.db
      const existingHashes = db
        .prepare(
          `SELECT photo_id, hash_hex, file_size, file_mtime_ms
           FROM similarity_hashes WHERE session_id = ?`,
        )
        .all(sessionId) as {
          photo_id: string
          hash_hex: string
          file_size: number
          file_mtime_ms: number
        }[]
      const sourceStats = new Map<string, { size: number; mtimeMs: number }>()
      await batchAsync(photos, async (photo) => {
        try {
          const sourceStat = await stat(photo.filepath)
          sourceStats.set(photo.id, {
            size: sourceStat.size,
            mtimeMs: sourceStat.mtimeMs,
          })
        } catch {
          // Unreadable files are handled by the normal preview failure path.
        }
      }, 32)
      const existingHashMap = new Map(
        existingHashes
          .filter((row) => {
            const stat = sourceStats.get(row.photo_id)
            return Boolean(
              stat &&
              stat.size === row.file_size &&
              Math.abs(stat.mtimeMs - row.file_mtime_ms) < 1,
            )
          })
          .map((row) => [row.photo_id, row.hash_hex]),
      )
      reuseSimilarityHashes(db, sessionId, photos, sourceStats, existingHashMap)

      const uncachedPhotos = photos.filter(
        (p) => !existingHashMap.has(p.id),
      )
      if (uncachedPhotos.length > 0) {
        if (signal.aborted) return

        onProgress?.(0, uncachedPhotos.length, 'Computing perceptual hashes...')
        const insertStmt = db.prepare(
          `INSERT INTO similarity_hashes
             (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(session_id, photo_id) DO UPDATE SET
             hash_hex = excluded.hash_hex,
             file_size = excluded.file_size,
             file_mtime_ms = excluded.file_mtime_ms`,
        )
        const insertAll = db.transaction(
          (rows: {
            sessionId: string
            photoId: string
            hash: string
            fileSize: number
            fileMtimeMs: number
          }[]) => {
            for (const r of rows) {
              insertStmt.run(
                r.sessionId,
                r.photoId,
                r.hash,
                r.fileSize,
                r.fileMtimeMs,
              )
            }
          },
        )

        const decodeBatchSize = Math.min(
          32,
          Math.max(1, Math.floor(
            this.settings.getNumber('similarity_decode_concurrency', 4),
          )),
        )
        const previewMaxDimension = Math.min(
          2048,
          Math.max(64, Math.floor(
            this.settings.getNumber('similarity_preview_max_dimension', 256),
          )),
        )

        for (let offset = 0; offset < uncachedPhotos.length; offset += decodeBatchSize) {
          if (signal.aborted) return
          const batch = uncachedPhotos.slice(offset, offset + decodeBatchSize)
          const previews = await Promise.all(
            batch.map(async (photo) => {
              try {
                const preview = await this.imageService.getThumbnail(
                  photo.filepath,
                  previewMaxDimension,
                )
                return { photoId: photo.id, buffer: preview.buffer }
              } catch {
                return null
              }
            }),
          )
          const validPreviews = previews.filter(
            (preview): preview is NonNullable<typeof preview> => preview !== null,
          )
          const hashes = validPreviews.length > 0
            ? await computeBatchDHash(validPreviews.map((preview) => preview.buffer))
            : new Map<number, string>()

          if (signal.aborted) return
          const insertRows: {
            sessionId: string
            photoId: string
            hash: string
            fileSize: number
            fileMtimeMs: number
          }[] = []
          validPreviews.forEach((preview, index) => {
            const hash = hashes.get(index)
            const stat = sourceStats.get(preview.photoId)
            if (!hash || !stat) return
            existingHashMap.set(preview.photoId, hash)
            insertRows.push({
              sessionId,
              photoId: preview.photoId,
              hash,
              fileSize: stat.size,
              fileMtimeMs: stat.mtimeMs,
            })
          })
          if (insertRows.length > 0) {
            insertAll(insertRows)
          }
          onProgress?.(
            Math.min(offset + batch.length, uncachedPhotos.length),
            uncachedPhotos.length,
            'Computing perceptual hashes...',
          )
        }

        onProgress?.(
          uncachedPhotos.length,
          uncachedPhotos.length,
          'Hash computation complete',
        )
      }

      if (signal.aborted) return

      const entries: HashEntry[] = photos
        .filter((p) => existingHashMap.has(p.id))
        .map((p) => ({ photoId: p.id, hash: existingHashMap.get(p.id)! }))

      if (entries.length === 0) {
        throw new Error('No hash data available for clustering')
      }

      onProgress?.(0, entries.length, 'Clustering similar images...')

      const { groups: rawGroups, ungrouped: rawUngrouped } = await clusterHashesInWorker(
        entries,
        threshold,
        minGroupSize,
        groupingMode,
        signal,
      )

      onProgress?.(entries.length, entries.length, 'Clustering complete')

      const pathMap = new Map(photos.map((p) => [p.id, p.filepath]))

      const groups: SimilarityGroup[] = rawGroups.map((memberIds, idx) => ({
        id: idx + 1,
        label: `Group ${idx + 1}`,
        count: memberIds.length,
        images: memberIds.map((photoId, i) => ({
          path: pathMap.get(photoId)!,
          representative: i === 0,
        })),
      }))

      const ungrouped: SimilarityImage[] = rawUngrouped.map((photoId) => ({
        path: pathMap.get(photoId)!,
      }))

      const groupsJson = JSON.stringify({ groups, ungrouped })
      const statsJson = JSON.stringify({
        totalGroups: groups.length,
        totalUngrouped: ungrouped.length,
        threshold,
        minGroupSize,
        groupingMode,
      })

      this.similarityResultRepo.replace(
        sessionId,
        groupsJson,
        statsJson,
        threshold,
        minGroupSize,
        rawGroups.flatMap((photoIds, groupIndex) =>
          photoIds.map(photoId => ({ photoId, groupIndex })),
        ),
      )

      this.sessionRepo.updateAnalysisStatus(sessionId, 'done')
    } catch (e: unknown) {
      this.sessionRepo.updateAnalysisStatus(
        sessionId,
        signal.aborted ? 'cancelled' : 'failed',
      )
      throw e
    } finally {
      this.controllers.delete(sessionId)
    }
  }

  getResult(sessionId: string): SimilarityResult | null {
    const db = this.db
    const row = db
      .prepare(
        'SELECT groups_json, stats_json FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1',
      )
      .get(sessionId) as { groups_json: string; stats_json: string } | undefined

    if (!row) return null

    const storedGroups = JSON.parse(row.groups_json) as {
      groups: SimilarityGroup[]
      ungrouped?: SimilarityImage[]
    }
    const storedStats = JSON.parse(row.stats_json) as Omit<
      SimilarityResult['stats'],
      'groupingMode'
    > & { groupingMode?: SimilarityGroupingMode }
    return {
      groups: storedGroups.groups,
      ungrouped: storedGroups.ungrouped ?? [],
      stats: {
        ...storedStats,
        groupingMode: storedStats.groupingMode ?? 'global',
      },
    }
  }

  async cancel(sessionId: string): Promise<void> {
    const controller = this.controllers.get(sessionId)
    if (controller) {
      controller.abort()
      this.controllers.delete(sessionId)
    }
    this.sessionRepo.updateAnalysisStatus(sessionId, 'cancelled')
  }

  async recluster(
    sessionId: string,
    threshold: number,
    minGroupSize: number,
    groupingMode: SimilarityGroupingMode = 'global',
  ): Promise<SimilarityResult> {
    validateSimilarityParameters(threshold, minGroupSize)
    const db = this.db

    const existing = db
      .prepare(
        'SELECT groups_json, stats_json FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1',
      )
      .get(sessionId) as { groups_json: string; stats_json: string } | undefined

    if (!existing) {
      throw new Error('No existing similarity results found. Run analysis first.')
    }

    const photos = collapseSimilarityAssets(this.photoRepo.getBySession(sessionId))
    const hashRows = db
      .prepare(
        'SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?',
      )
      .all(sessionId) as { photo_id: string; hash_hex: string }[]
    const hashMap = new Map(hashRows.map((r) => [r.photo_id, r.hash_hex]))

    const entries: HashEntry[] = photos.flatMap(photo => {
      const hash = hashMap.get(photo.id)
      return hash ? [{ photoId: photo.id, hash }] : []
    })

    if (entries.length === 0) {
      throw new Error('No hash data available for reclustering')
    }

    const { groups: rawGroups, ungrouped: rawUngrouped } = await clusterHashesInWorker(
      entries,
      threshold,
      minGroupSize,
      groupingMode,
    )

    const pathMap = new Map(photos.map((p) => [p.id, p.filepath]))

    const groups: SimilarityGroup[] = rawGroups.map((memberIds, idx) => ({
      id: idx + 1,
      label: `Group ${idx + 1}`,
      count: memberIds.length,
      images: memberIds.map((photoId, i) => ({
        path: pathMap.get(photoId)!,
        representative: i === 0,
      })),
    }))

    const ungrouped: SimilarityImage[] = rawUngrouped.map((photoId) => ({
      path: pathMap.get(photoId)!,
    }))

    const groupsJson = JSON.stringify({ groups, ungrouped })
    const statsJson = JSON.stringify({
      totalGroups: groups.length,
      totalUngrouped: ungrouped.length,
      threshold,
      minGroupSize,
      groupingMode,
    })

    this.similarityResultRepo.replace(
      sessionId,
      groupsJson,
      statsJson,
      threshold,
      minGroupSize,
      rawGroups.flatMap((photoIds, groupIndex) =>
        photoIds.map(photoId => ({ photoId, groupIndex })),
      ),
    )

    this.sessionRepo.updateAnalysisStatus(sessionId, 'done')

    return {
      groups,
      ungrouped,
      stats: {
        totalGroups: groups.length,
        totalUngrouped: ungrouped.length,
        threshold,
        minGroupSize,
        groupingMode,
      },
    }
  }
}
