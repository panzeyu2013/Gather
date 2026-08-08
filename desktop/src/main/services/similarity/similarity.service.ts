import { SettingsService } from '../settings/settings.service'
import { Database } from '../../db/database'
import {
  PhotoRepository,
  type PhotoProjectionRow,
  type PhotoRow,
} from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { SimilarityResultRepository } from '../../db/repositories/similarity-result.repo'
import { ImageService } from '../image'
import { computeBatchDHash } from './hash-computer'
import type { HashEntry } from './cluster-engine'
import type {
  SimilarityGroup,
  SimilarityGroupingMode,
  SimilarityImage,
  SimilarityResultStats,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { stat } from 'fs/promises'
import { batchAsync } from '../../utils/async'
import { collapsePhotoAssets } from '../assets/logical-photo-assets'
import { clusterHashesInWorker, clusterHashesInWorkerMulti } from '../../utils/analysis-worker-client'

/** Collapse physical photos into logical assets; only reads id/asset_id/
 * filename, so it works on the light projection rows used by analyze. */
export const collapseSimilarityAssets = (
  photos: PhotoProjectionRow[],
): PhotoProjectionRow[] => collapsePhotoAssets(photos as PhotoRow[])

export interface SimilarityResult {
  groups: SimilarityGroup[]
  ungrouped: SimilarityImage[]
  stats: SimilarityResultStats
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

// Number of asset_file_id values per IN chunk; keeps queries far under the
// SQLite 999 bound while reducing 1-N per-photo lookups to a handful of
// batched reads.
const REUSE_HASH_CHUNK_SIZE = 400
const NEIGHBOR_TIER_STEPS = [8, 4, -4, -8]

export function reuseSimilarityHashes(
  db: Database,
  sessionId: string,
  photos: Array<{ id: string }>,
  sourceStats: Map<string, { size: number; mtimeMs: number }>,
  existingHashMap: Map<string, string>,
): number {
  const photoRows = db
    .prepare(
      'SELECT id, asset_file_id FROM photos WHERE session_id = ? AND asset_file_id IS NOT NULL',
    )
    .all(sessionId) as Array<{ id: string; asset_file_id: string }>
  const assetFileByPhoto = new Map(photoRows.map(row => [row.id, row.asset_file_id]))
  const assetFileIds = [...new Set(photoRows.map(row => row.asset_file_id))]

  // One batched read per chunk of asset files: every similarity hash belonging
  // to photos that share an asset file with any target photo.
  const rowsByAssetFile = new Map<
    string,
    Array<{ id: number; photoId: string; hashHex: string; fileSize: number; fileMtimeMs: number }>
  >()
  for (let offset = 0; offset < assetFileIds.length; offset += REUSE_HASH_CHUNK_SIZE) {
    const chunk = assetFileIds.slice(offset, offset + REUSE_HASH_CHUNK_SIZE)
    const placeholders = chunk.map(() => '?').join(', ')
    const rows = db.prepare(`
      SELECT h.id AS hash_id, h.photo_id, h.hash_hex, h.file_size, h.file_mtime_ms, p.asset_file_id
      FROM similarity_hashes h
      JOIN photos p ON h.photo_id = p.id
      WHERE p.asset_file_id IN (${placeholders})
    `).all(...chunk) as Array<{
      hash_id: number
      photo_id: string
      hash_hex: string
      file_size: number
      file_mtime_ms: number
      asset_file_id: string
    }>
    for (const row of rows) {
      const assetFileId = row.asset_file_id
      if (!assetFileId) continue
      const list = rowsByAssetFile.get(assetFileId) ?? []
      list.push({
        id: row.hash_id,
        photoId: row.photo_id,
        hashHex: row.hash_hex,
        fileSize: row.file_size,
        fileMtimeMs: row.file_mtime_ms,
      })
      rowsByAssetFile.set(assetFileId, list)
    }
  }

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
      const assetFileId = assetFileByPhoto.get(photo.id)
      if (!assetFileId) continue
      const candidates = rowsByAssetFile.get(assetFileId)
      if (!candidates) continue
      let source: {
        id: number
        photoId: string
        hashHex: string
        fileSize: number
        fileMtimeMs: number
      } | undefined
      for (const candidate of candidates) {
        if (candidate.photoId === photo.id) continue
        if (candidate.fileSize !== sourceStat.size) continue
        if (Math.abs(candidate.fileMtimeMs - sourceStat.mtimeMs) >= 1) continue
        if (!source || candidate.id > source.id) source = candidate
      }
      if (!source) continue
      saveReusableHash.run(
        sessionId,
        photo.id,
        source.hashHex,
        sourceStat.size,
        sourceStat.mtimeMs,
      )
      existingHashMap.set(photo.id, source.hashHex)
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

      const photos = collapseSimilarityAssets(this.photoRepo.getBySessionProjection(sessionId))
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
      // File stats come from the index scan (photos.checksum_file_size /
      // checksum_file_mtime_ms) when available, so a full analyze no longer
      // stats every photo on disk (SSD 1-3s, network volumes minutes). Only
      // photos without an indexed stat (lazy imports, backfill pending) hit
      // the filesystem.
      const sourceStats = new Map<string, { size: number; mtimeMs: number }>()
      const needsStat: string[] = []
      for (const photo of photos) {
        // Photos already marked missing on disk must never reuse a stale
        // indexed stat; only photos with a real indexed size take the
        // no-stat fast path.
        if (photo.status !== 'missing' && photo.checksum_file_size > 0) {
          sourceStats.set(photo.id, {
            size: photo.checksum_file_size,
            mtimeMs: photo.checksum_file_mtime_ms,
          })
        } else {
          needsStat.push(photo.id)
        }
      }
      const photosById = new Map(photos.map(photo => [photo.id, photo]))
      await batchAsync(needsStat, async (photoId) => {
        const photo = photosById.get(photoId)
        if (!photo) return
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
        (current, total) => onProgress?.(current, total, 'Clustering similar images...'),
      )

      onProgress?.(entries.length, entries.length, 'Clustering complete')

      const pathMap = new Map(photos.map((p) => [p.id, p.filepath]))

      const built = this.buildStoredResult(
        rawGroups,
        rawUngrouped,
        pathMap,
        threshold,
        minGroupSize,
        groupingMode,
        false,
      )

      this.similarityResultRepo.replace(
        sessionId,
        built.groupsJson,
        built.statsJson,
        threshold,
        minGroupSize,
        built.memberships,
      )

      this.sessionRepo.updateAnalysisStatus(sessionId, 'done')

      // Best-effort neighbor-threshold tiers: cheap to cluster with the same
      // already-computed hashes, and a failure or cancellation here must not
      // affect the main result which was already saved above.
      try {
        await this.precomputeNeighborTiers(
          sessionId,
          entries,
          pathMap,
          threshold,
          minGroupSize,
          groupingMode,
          signal,
          onProgress,
        )
      } catch (error) {
        if (signal.aborted) return
        console.warn('Similarity neighbor threshold precomputation failed', error)
      }
    } catch (e: unknown) {
      this.sessionRepo.updateAnalysisStatus(
        sessionId,
        signal.aborted ? 'cancelled' : 'failed',
      )
      throw e
    } finally {
      if (this.controllers.get(sessionId) === controller) {
        this.controllers.delete(sessionId)
      }
    }
  }

  /**
   * Cheap existence check for a result row: unlike getResult, this never
   * touches the members table, the photo projection or the result payload,
   * so "is this threshold precomputed" checks cost one indexed lookup instead
   * of a full result rebuild.
   */
  hasResult(sessionId: string, threshold?: number): boolean {
    const row = threshold === undefined
      ? this.similarityResultRepo.getLatest(sessionId)
      : this.similarityResultRepo.getByThreshold(sessionId, threshold)
    return row !== undefined
  }

  getResult(sessionId: string, threshold?: number): SimilarityResult | null {
    const row = threshold === undefined
      ? this.similarityResultRepo.getLatest(sessionId)
      : this.similarityResultRepo.getByThreshold(sessionId, threshold)

    if (!row) return null

    const storedStats = JSON.parse(row.stats_json) as Partial<SimilarityResultStats> & {
      groupingMode?: SimilarityGroupingMode
    }
    const stats: SimilarityResultStats = {
      totalGroups: storedStats.totalGroups ?? 0,
      totalUngrouped: storedStats.totalUngrouped ?? 0,
      threshold: storedStats.threshold ?? 0,
      minGroupSize: storedStats.minGroupSize ?? 2,
      groupingMode: storedStats.groupingMode ?? 'global',
      precomputed: storedStats.precomputed === true,
    }

    // The members table is the source of truth for the group structure;
    // groups_json is only parsed for legacy rows written before the members
    // table existed (they have no member rows).
    const members = this.similarityResultRepo.getGroupMembers(sessionId, row.id)
    if (members === null) {
      const storedGroups = JSON.parse(row.groups_json) as {
        groups: SimilarityGroup[]
        ungrouped?: SimilarityImage[]
      }
      return {
        groups: storedGroups.groups,
        ungrouped: storedGroups.ungrouped ?? [],
        stats,
      }
    }

    const groupsByIndex = new Map<number, SimilarityGroup>()
    const groups: SimilarityGroup[] = []
    for (const member of members) {
      let group = groupsByIndex.get(member.groupIndex)
      if (!group) {
        group = {
          id: member.groupIndex + 1,
          label: `Group ${member.groupIndex + 1}`,
          count: 0,
          images: [],
        }
        groupsByIndex.set(member.groupIndex, group)
        groups.push(group)
      }
      group.images.push({
        path: member.filepath,
        // First member of the group (lowest members rowid) is its
        // representative, mirroring buildStoredResult.
        representative: group.count === 0,
      })
      group.count++
    }

    // Ungrouped = logical assets of the session outside the members table,
    // mirroring what analyze put in groups_json (collapsed assets minus
    // grouped members). Order follows the import order of the projection.
    const memberPhotoIds = new Set(members.map(member => member.photoId))
    const ungrouped: SimilarityImage[] = collapseSimilarityAssets(
      this.photoRepo.getBySessionProjection(sessionId),
    )
      .filter(photo => !memberPhotoIds.has(photo.id))
      .map(photo => ({ path: photo.filepath }))

    return { groups, ungrouped, stats }
  }

  async cancel(sessionId: string, markStatus = false): Promise<void> {
    const controller = this.controllers.get(sessionId)
    const hadController = controller !== undefined
    if (controller) {
      controller.abort()
    }
    // analysis_status is a single session column shared with face analysis.
    // Only write 'cancelled' when this module actually had an in-flight run —
    // a cancel of a queued job, or a cancel while face analysis runs, must
    // not flip the face status. The job row itself carries the cancelled
    // state for queued jobs.
    if (hadController || markStatus) {
      this.sessionRepo.updateAnalysisStatus(sessionId, 'cancelled')
    }
  }

  async recluster(
    sessionId: string,
    threshold: number,
    minGroupSize: number,
    groupingMode: SimilarityGroupingMode = 'global',
  ): Promise<SimilarityResult> {
    validateSimilarityParameters(threshold, minGroupSize)
    const db = this.db

    const existing = this.similarityResultRepo.getLatest(sessionId)

    if (!existing) {
      throw new Error('No existing similarity results found. Run analysis first.')
    }

    const photos = collapseSimilarityAssets(this.photoRepo.getBySessionProjection(sessionId))
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

    const built = this.buildStoredResult(
      rawGroups,
      rawUngrouped,
      pathMap,
      threshold,
      minGroupSize,
      groupingMode,
      false,
    )

    this.similarityResultRepo.replace(
      sessionId,
      built.groupsJson,
      built.statsJson,
      threshold,
      minGroupSize,
      built.memberships,
    )

    this.sessionRepo.updateAnalysisStatus(sessionId, 'done')

    try {
      await this.precomputeNeighborTiers(
        sessionId,
        entries,
        pathMap,
        threshold,
        minGroupSize,
        groupingMode,
      )
    } catch (error) {
      console.warn('Similarity neighbor threshold precomputation failed', error)
    }

    return built.result
  }

  private buildStoredResult(
    rawGroups: string[][],
    rawUngrouped: string[],
    pathMap: Map<string, string>,
    threshold: number,
    minGroupSize: number,
    groupingMode: SimilarityGroupingMode,
    precomputed: boolean,
    compactGroupsJson = false,
  ): {
    result: SimilarityResult
    groupsJson: string
    statsJson: string
    memberships: Array<{ photoId: string; groupIndex: number }>
  } {
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

    // Precomputed neighbor-tier rows are never read through groups_json:
    // getLatest excludes them, culling resolves memberships from the members
    // table, and getResult rebuilds groups from members too. Stringifying a
    // multi-MB payload per tier is pure waste, so tier rows store a compact
    // placeholder (the schema requires a non-empty string).
    const groupsJson = compactGroupsJson
      ? '{"groups":[],"ungrouped":[]}'
      : JSON.stringify({ groups, ungrouped })
    const statsJson = JSON.stringify({
      totalGroups: groups.length,
      totalUngrouped: ungrouped.length,
      threshold,
      minGroupSize,
      groupingMode,
      ...(precomputed ? { precomputed: true } : {}),
    })

    return {
      result: {
        groups,
        ungrouped,
        stats: {
          totalGroups: groups.length,
          totalUngrouped: ungrouped.length,
          threshold,
          minGroupSize,
          groupingMode,
        },
      },
      groupsJson,
      statsJson,
      memberships: rawGroups.flatMap((photoIds, groupIndex) =>
        photoIds.map(photoId => ({ photoId, groupIndex })),
      ),
    }
  }

  private async precomputeNeighborTiers(
    sessionId: string,
    entries: HashEntry[],
    pathMap: Map<string, string>,
    threshold: number,
    minGroupSize: number,
    groupingMode: SimilarityGroupingMode,
    signal?: AbortSignal,
    onProgress?: (current: number, total: number, message: string) => void,
  ): Promise<void> {
    if (signal?.aborted) return

    const savedTiers = new Set<number>([threshold])
    const candidates: number[] = []
    for (const step of NEIGHBOR_TIER_STEPS) {
      const tier = Math.max(0, Math.min(30, threshold + step))
      if (!savedTiers.has(tier)) {
        savedTiers.add(tier)
        candidates.push(tier)
      }
    }
    if (candidates.length === 0) return

    // One worker run clusters all tiers in a single pairwise distance pass
    // (the distance is threshold-independent; only the judgment differs), so
    // the 4-way precomputation no longer repeats the O(n^2) pass per tier.
    const results = await clusterHashesInWorkerMulti(
      entries,
      candidates,
      minGroupSize,
      groupingMode,
      signal,
      (current, total) => onProgress?.(current, total, 'Precomputing neighbor thresholds...'),
    )
    for (const [index, tier] of candidates.entries()) {
      if (signal?.aborted) return
      const built = this.buildStoredResult(
        results[index].groups,
        results[index].ungrouped,
        pathMap,
        tier,
        minGroupSize,
        groupingMode,
        true,
        true,
      )
      this.similarityResultRepo.replaceForThreshold(
        sessionId,
        built.groupsJson,
        built.statsJson,
        tier,
        minGroupSize,
        built.memberships,
      )
    }
  }
}
