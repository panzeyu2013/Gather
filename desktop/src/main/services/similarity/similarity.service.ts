import { SettingsService } from '../settings'
import { getDatabase } from '../../db/database'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { computeBatchDHash } from './hash-computer'
import { clusterByHash, type HashEntry } from './cluster-engine'
import type { SimilarityGroup, SimilarityImage } from '@gather/shared'

export interface SimilarityResult {
  groups: SimilarityGroup[]
  ungrouped: SimilarityImage[]
  stats: {
    totalGroups: number
    totalUngrouped: number
    threshold: number
    minGroupSize: number
  }
}

export class SimilarityService {
  private controllers = new Map<string, AbortController>()
  private settings = SettingsService.getInstance()

  constructor(
    private photoRepo: PhotoRepository,
    private sessionRepo: SessionRepository,
  ) {}

  async analyze(
    sessionId: string,
    options?: {
      threshold?: number
      minGroupSize?: number
      onProgress?: (current: number, total: number, message: string) => void
    },
  ): Promise<void> {
    const controller = new AbortController()
    this.controllers.set(sessionId, controller)
    const { signal } = controller

    const threshold = options?.threshold ?? this.settings.getNumber('default_threshold', 10)
    const minGroupSize = options?.minGroupSize ?? this.settings.getNumber('default_min_group_size', 2)

    try {
      this.sessionRepo.updateAnalysisStatus(sessionId, 'running')

      const photos = this.photoRepo.getBySession(sessionId)
      if (photos.length === 0) {
        throw new Error('No photos in session')
      }

      const onProgress = options?.onProgress

      if (signal.aborted) return

      const db = getDatabase()
      const existingHashes = db
        .prepare(
          'SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?',
        )
        .all(sessionId) as { photo_id: string; hash_hex: string }[]
      const existingHashMap = new Map(
        existingHashes.map((r) => [r.photo_id, r.hash_hex]),
      )

      const uncachedPhotos = photos.filter(
        (p) => !existingHashMap.has(p.id),
      )
      const uncachedPaths = uncachedPhotos.map((p) => p.filepath)

      if (uncachedPaths.length > 0) {
        if (signal.aborted) return

        onProgress?.(0, uncachedPaths.length, 'Computing perceptual hashes...')
        const newHashes = await computeBatchDHash(uncachedPaths)

        if (signal.aborted) return

        const insertStmt = db.prepare(
          'INSERT INTO similarity_hashes (session_id, photo_id, hash_hex) VALUES (?, ?, ?)',
        )
        const insertAll = db.transaction(
          (rows: { sessionId: string; photoId: string; hash: string }[]) => {
            for (const r of rows) {
              insertStmt.run(r.sessionId, r.photoId, r.hash)
            }
          },
        )

        const insertRows: { sessionId: string; photoId: string; hash: string }[] = []
        const pathToId = new Map(
          uncachedPhotos.map((p) => [p.filepath, p.id]),
        )
        for (const [path, hash] of newHashes) {
          const photoId = pathToId.get(path)
          if (photoId) {
            existingHashMap.set(photoId, hash)
            insertRows.push({ sessionId, photoId, hash })
          }
        }
        if (insertRows.length > 0) {
          insertAll(insertRows)
        }

        onProgress?.(uncachedPaths.length, uncachedPaths.length, 'Hash computation complete')
      }

      if (signal.aborted) return

      const entries: HashEntry[] = photos
        .filter((p) => existingHashMap.has(p.id))
        .map((p) => ({ photoId: p.id, hash: existingHashMap.get(p.id)! }))

      if (entries.length === 0) {
        throw new Error('No hash data available for clustering')
      }

      onProgress?.(0, entries.length, 'Clustering similar images...')

      const { groups: rawGroups, ungrouped: rawUngrouped } = clusterByHash(
        entries,
        threshold,
        minGroupSize,
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
      })

      db.prepare(
        `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      ).run(sessionId, groupsJson, statsJson, threshold, minGroupSize, new Date().toISOString())

      this.sessionRepo.updateAnalysisStatus(sessionId, 'done')
    } catch (e: unknown) {
      this.sessionRepo.updateAnalysisStatus(sessionId, 'failed')
      throw e
    } finally {
      this.controllers.delete(sessionId)
    }
  }

  getResult(sessionId: string): SimilarityResult | null {
    const db = getDatabase()
    const row = db
      .prepare(
        'SELECT groups_json, stats_json FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1',
      )
      .get(sessionId) as { groups_json: string; stats_json: string } | undefined

    if (!row) return null

    return {
      groups: JSON.parse(row.groups_json).groups,
      ungrouped: JSON.parse(row.groups_json).ungrouped ?? [],
      stats: JSON.parse(row.stats_json),
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
  ): Promise<SimilarityResult> {
    const db = getDatabase()

    const existing = db
      .prepare(
        'SELECT groups_json, stats_json FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1',
      )
      .get(sessionId) as { groups_json: string; stats_json: string } | undefined

    if (!existing) {
      throw new Error('No existing similarity results found. Run analysis first.')
    }

    const prevResult = JSON.parse(existing.groups_json) as { groups: SimilarityGroup[]; ungrouped: SimilarityImage[] }
    const allImages = [...prevResult.groups.flatMap((g) => g.images), ...(prevResult.ungrouped ?? [])]
    const allPaths = allImages.map((img) => img.path)

    const photos = this.photoRepo.getBySession(sessionId)
    const pathToPhoto = new Map(photos.map((p) => [p.filepath, p]))
    const hashRows = db
      .prepare(
        'SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?',
      )
      .all(sessionId) as { photo_id: string; hash_hex: string }[]
    const hashMap = new Map(hashRows.map((r) => [r.photo_id, r.hash_hex]))

    const entries: HashEntry[] = []
    for (const path of allPaths) {
      const photo = pathToPhoto.get(path)
      if (photo && hashMap.has(photo.id)) {
        entries.push({ photoId: photo.id, hash: hashMap.get(photo.id)! })
      }
    }

    if (entries.length === 0) {
      throw new Error('No hash data available for reclustering')
    }

    const { groups: rawGroups, ungrouped: rawUngrouped } = clusterByHash(
      entries,
      threshold,
      minGroupSize,
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
    })

    db.prepare(
      `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(sessionId, groupsJson, statsJson, threshold, minGroupSize, new Date().toISOString())

    this.sessionRepo.updateAnalysisStatus(sessionId, 'done')

    return {
      groups,
      ungrouped,
      stats: {
        totalGroups: groups.length,
        totalUngrouped: ungrouped.length,
        threshold,
        minGroupSize,
      },
    }
  }
}
