import { stat } from 'node:fs/promises'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import type { PhotoRow } from '../../db/repositories/photo.repo'
import type { ImageService } from '../image'
import type { QualityResult } from '@gather/shared'
import type { JobRunContext } from '../jobs/job.service'
import type { CullingService } from '../culling/culling.service'
import { batchAsync } from '../../utils/async'
import { collapsePhotoAssets } from '../assets/logical-photo-assets'

const MODEL_ID = 'technical-quality'
const MODEL_VERSION = '1'

// Decode/stat/sharp-pixel work is I/O and CPU bound; bounded concurrency
// keeps the batch pipeline busy without thrashing the disk (the same
// magnitude as the face pipeline's decode window).
const ANALYZE_CONCURRENCY = 6

// IN-list chunk size for the batch preloads: keeps every statement well under
// SQLite's variable bound (32766 on recent builds) for whole-session runs.
const IN_CHUNK_SIZE = 400

export function metricFromPixels(data: Uint8Array, width: number, height: number): { sharpness: number; exposure: number } {
  if (width < 2 || height < 2 || data.length === 0) return { sharpness: 0, exposure: 0 }
  let gradientSum = 0
  let mean = 0
  for (let index = 0; index < data.length; index++) mean += data[index]
  mean /= data.length
  for (let y = 0; y < height - 1; y++) {
    for (let x = 0; x < width - 1; x++) {
      const index = y * width + x
      gradientSum += Math.abs(data[index] - data[index + 1]) + Math.abs(data[index] - data[index + width])
    }
  }
  const sharpness = Math.max(0, Math.min(1, gradientSum / ((width - 1) * (height - 1) * 510)))
  const exposure = Math.max(0, 1 - Math.abs(mean - 128) / 128)
  return { sharpness, exposure }
}

function regionPixels(
  data: Uint8Array,
  width: number,
  height: number,
  box: { x: number; y: number; width: number; height: number },
): { data: Uint8Array; width: number; height: number } | null {
  const left = Math.max(0, Math.min(width - 1, Math.floor(box.x)))
  const top = Math.max(0, Math.min(height - 1, Math.floor(box.y)))
  const right = Math.max(left + 1, Math.min(width, Math.ceil(box.x + box.width)))
  const bottom = Math.max(top + 1, Math.min(height, Math.ceil(box.y + box.height)))
  const regionWidth = right - left
  const regionHeight = bottom - top
  if (regionWidth < 2 || regionHeight < 2) return null
  const output = new Uint8Array(regionWidth * regionHeight)
  for (let y = 0; y < regionHeight; y++) {
    output.set(data.subarray((top + y) * width + left, (top + y) * width + right), y * regionWidth)
  }
  return { data: output, width: regionWidth, height: regionHeight }
}

@injectable()
export class QualityService {
  constructor(
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.IMAGE_SERVICE) private imageService: ImageService,
    @inject(DI_TOKENS.CULLING_SERVICE) private culling?: CullingService,
  ) {}

  async analyze(
    sessionId: string,
    photoIds?: string[],
    context?: JobRunContext,
  ): Promise<QualityResult[]> {
    const sessionPhotos = this.photoRepo.getBySession(sessionId)
    const photos = photoIds
      ? sessionPhotos.filter(photo => photoIds.includes(photo.id))
      : collapsePhotoAssets(sessionPhotos)
    // Batch preloads: one IN query each replaces the per-photo cache and
    // face lookups (the whole run, not one SELECT per photo).
    const cachedByPhoto = this.getCachedBatch(photos)
    const facesByPhoto = this.getFacesBatch(sessionId, photos)
    // Parallel compute phase with bounded concurrency (stat, thumbnail
    // decode, sharp pixel pass, face region). Writes stay out of it: the
    // INSERTs commit serially in one transaction below.
    // Progress is reported once per completed batch of ANALYZE_CONCURRENCY
    // photos: workers finish in arbitrary order, so per-item index+1 frames
    // could go backwards, and a session of <= 6 photos could flash 100% when
    // its last worker happened to finish first. The final frame (current ===
    // total) is emitted once, outside the loop, after every photo has been
    // processed.
    let completed = 0
    const reportProgress = (current: number): void => {
      context?.updateProgress({
        current,
        total: photos.length,
        message: '正在分析技术质量',
        // Keep the job's creation checkpoint alive: the executor resumes a
        // subset run from checkpoint.photoIds, so a checkpoint update that
        // dropped it would make an interrupted run re-analyze the whole
        // session instead of the requested subset.
        checkpoint: { photoIds, nextPhotoIndex: current },
      })
    }
    const outcomes = await batchAsync(
      photos.map((photo) => ({ photo })),
      async ({ photo }): Promise<{
        result: QualityResult
        insert: {
          photoId: string
          assetFileId: string
          resultJson: string
          warningsJson: string
          fingerprint: string
          updatedAt: string
        } | null
      }> => {
        context?.throwIfCancelled()
        const assetFileId = photo.asset_file_id
        let result: QualityResult
        let insert: {
          photoId: string
          assetFileId: string
          resultJson: string
          warningsJson: string
          fingerprint: string
          updatedAt: string
        } | null = null
        try {
          const source = await stat(photo.filepath)
          const inputFingerprint = `${source.size}:${Math.round(source.mtimeMs)}`
          const cached = cachedByPhoto.get(photo.id)?.find(
            row => row.fingerprint === inputFingerprint,
          )?.result
          if (cached) {
            // Cache hit: the stored row already belongs to the photo's
            // current asset file (the lookup JOINs on asset_file_id), so
            // INSERT OR REPLACE would only be a pointless write — and after a
            // re-link to a new file it would copy the old result onto the new
            // file row instead of letting the next pass recompute it.
            result = { ...cached, photoId: photo.id }
          } else {
            const preview = await this.imageService.getThumbnail(photo.filepath, 512)
            const sharp = (await import('sharp')) as unknown as typeof import('sharp')
            const raw = await sharp(preview.buffer).greyscale().raw().toBuffer({ resolveWithObject: true })
            const metrics = metricFromPixels(raw.data, raw.info.width, raw.info.height)
            const face = facesByPhoto.get(photo.id)
            let subjectSharpness: number | undefined
            let closedEyeRisk: number | undefined
            if (face) {
              let analysisMax = Math.max(photo.width, photo.height)
              try {
                const signature = JSON.parse(face.analysis_signature) as { previewMaxDimension?: unknown }
                if (typeof signature.previewMaxDimension === 'number') {
                  analysisMax = signature.previewMaxDimension
                }
              } catch { /* use source dimensions */ }
              const analysisScale = Math.min(1, analysisMax / Math.max(photo.width, photo.height, 1))
              const analysisWidth = Math.max(1, photo.width * analysisScale)
              const analysisHeight = Math.max(1, photo.height * analysisScale)
              const faceBox = {
                x: face.bbox_x / analysisWidth * raw.info.width,
                y: face.bbox_y / analysisHeight * raw.info.height,
                width: face.bbox_w / analysisWidth * raw.info.width,
                height: face.bbox_h / analysisHeight * raw.info.height,
              }
              const subject = regionPixels(raw.data, raw.info.width, raw.info.height, faceBox)
              if (subject) {
                subjectSharpness = metricFromPixels(subject.data, subject.width, subject.height).sharpness
                const eyes = regionPixels(subject.data, subject.width, subject.height, {
                  x: subject.width * 0.12,
                  y: subject.height * 0.2,
                  width: subject.width * 0.76,
                  height: subject.height * 0.3,
                })
                if (eyes) {
                  const eyeSharpness = metricFromPixels(eyes.data, eyes.width, eyes.height).sharpness
                  closedEyeRisk = Math.max(
                    0,
                    Math.min(1, 1 - eyeSharpness / Math.max(0.01, subjectSharpness * 1.15)),
                  )
                }
              }
            }
            const warnings: string[] = []
            if (metrics.sharpness < 0.12) warnings.push('motion_blur')
            if (metrics.exposure < 0.3) warnings.push('exposure_issue')
            if ((closedEyeRisk ?? 0) > 0.72) warnings.push('closed_eye_risk_heuristic')
            const focusScore = subjectSharpness ?? metrics.sharpness
            result = {
              photoId: photo.id,
              assetFileId: assetFileId ?? undefined,
              status: 'succeeded',
              qualityScore: Math.round((
                focusScore * 0.6 +
                metrics.sharpness * 0.15 +
                metrics.exposure * 0.2 +
                (1 - (closedEyeRisk ?? 0)) * 0.05
              ) * 1000) / 1000,
              sharpness: Math.round(metrics.sharpness * 1000) / 1000,
              exposure: Math.round(metrics.exposure * 1000) / 1000,
              subjectSharpness: subjectSharpness === undefined
                ? undefined
                : Math.round(subjectSharpness * 1000) / 1000,
              faceQuality: subjectSharpness,
              closedEyeRisk: closedEyeRisk === undefined
                ? undefined
                : Math.round(closedEyeRisk * 1000) / 1000,
              confidence: face ? 0.6 : 0.55,
              warnings,
              modelId: MODEL_ID,
              modelVersion: MODEL_VERSION,
              inputFingerprint,
              updatedAt: new Date().toISOString(),
            }
            if (!assetFileId) throw new Error('Photo has no indexed asset file')
            insert = {
              photoId: photo.id,
              assetFileId,
              resultJson: JSON.stringify(result),
              warningsJson: JSON.stringify(result.warnings),
              fingerprint: result.inputFingerprint,
              updatedAt: result.updatedAt,
            }
          }
        } catch (error) {
          const failedAt = new Date().toISOString()
          result = {
            photoId: photo.id,
            assetFileId: assetFileId ?? undefined,
            status: 'failed',
            errorMessage: error instanceof Error ? error.message : String(error),
            qualityScore: 0,
            sharpness: 0,
            exposure: 0,
            warnings: ['analysis_failed'],
            modelId: MODEL_ID,
            modelVersion: MODEL_VERSION,
            inputFingerprint: '',
            updatedAt: failedAt,
          }
          if (assetFileId) {
            insert = {
              photoId: photo.id,
              assetFileId,
              resultJson: JSON.stringify(result),
              warningsJson: JSON.stringify(result.warnings),
              fingerprint: `failed:${photo.updated_at}`,
              updatedAt: failedAt,
            }
          }
        }
        completed++
        if (completed < photos.length && completed % ANALYZE_CONCURRENCY === 0) {
          reportProgress(completed)
        }
        return { result, insert }
      },
      ANALYZE_CONCURRENCY,
    )
    if (photos.length > 0) reportProgress(photos.length)
    // All INSERTs commit in one transaction, serially after the parallel
    // compute phase (better-sqlite3 is synchronous, so the writes never
    // interleave).
    if (outcomes.some(outcome => outcome.insert !== null)) {
      const insertStmt = this.db.prepare(`
        INSERT OR REPLACE INTO asset_analysis (
          photo_id, asset_file_id, analysis_type, result_json, warnings_json,
          model_id, model_version, input_fingerprint, created_at, updated_at
        ) VALUES (?, ?, 'technical_quality', ?, ?, ?, ?, ?, ?, ?)
      `)
      this.db.transaction(() => {
        for (const outcome of outcomes) {
          if (!outcome.insert) continue
          insertStmt.run(
            outcome.insert.photoId,
            outcome.insert.assetFileId,
            outcome.insert.resultJson,
            outcome.insert.warningsJson,
            MODEL_ID,
            MODEL_VERSION,
            outcome.insert.fingerprint,
            outcome.insert.updatedAt,
            outcome.insert.updatedAt,
          )
        }
      })()
    }
    // The culling lookup cache snapshots quality results for the session;
    // invalidate it now that the new results are committed so the next
    // list()/listPage() rebuilds instead of serving stale quality for the
    // remainder of the TTL window.
    this.culling?.invalidateSessionLookup(sessionId)
    const results = outcomes.map(outcome => outcome.result)
    const groups = this.loadSimilarityGroups(sessionId)
    this.applyRelativeRanks(sessionId, results, groups)
    return results
  }

  get(sessionId: string, photoIds?: string[]): QualityResult[] {
    const sessionIds = new Set(this.photoRepo.getBySessionProjection(sessionId).map(photo => photo.id))
    const ids = photoIds
      ? [...new Set(photoIds)].filter(photoId => sessionIds.has(photoId))
      : [...sessionIds]
    if (ids.length === 0) return []
    const placeholders = ids.map(() => '?').join(',')
    const rows = this.db.prepare(`
      SELECT aa.result_json, p.id AS requested_photo_id
      FROM photos p
      JOIN asset_analysis aa ON aa.asset_file_id = p.asset_file_id
      WHERE aa.analysis_type = 'technical_quality' AND p.id IN (${placeholders})
      ORDER BY aa.updated_at DESC
    `).all(...ids) as Array<{ result_json: string; requested_photo_id: string }>
    const latest = new Map<string, QualityResult>()
    for (const row of rows) {
      try {
        if (!latest.has(row.requested_photo_id)) {
          latest.set(row.requested_photo_id, {
            ...JSON.parse(row.result_json) as QualityResult,
            photoId: row.requested_photo_id,
          })
        }
      } catch {
        // Skip invalid historical analysis rows.
      }
    }
    const results = [...latest.values()]
    const groups = this.loadSimilarityGroups(sessionId)
    this.applyRelativeRanks(sessionId, results, groups)
    return results
  }

  /**
   * Batch cache lookup: returns, per photo, every stored result of the same
   * model/version (fingerprints differ per file state, so the exact match is
   * done in JS after stat()). Rows are ordered by updated_at DESC.
   */
  private getCachedBatch(
    photos: PhotoRow[],
  ): Map<string, Array<{ fingerprint: string; result: QualityResult }>> {
    const rowsByPhoto = new Map<string, Array<{ fingerprint: string; result: QualityResult }>>()
    const ids = photos.map(photo => photo.id)
    for (const chunk of this.chunkIds(ids)) {
      const placeholders = chunk.map(() => '?').join(',')
      const rows = this.db.prepare(`
        SELECT p.id AS photo_id, aa.result_json, aa.input_fingerprint
        FROM asset_analysis aa
        JOIN photos p ON p.asset_file_id = aa.asset_file_id
        WHERE p.id IN (${placeholders}) AND aa.analysis_type = 'technical_quality'
          AND model_id = ? AND model_version = ?
        ORDER BY aa.updated_at DESC
      `).all(...chunk, MODEL_ID, MODEL_VERSION) as Array<{
        photo_id: string
        result_json: string
        input_fingerprint: string
      }>
      for (const row of rows) {
        if (!rowsByPhoto.has(row.photo_id)) rowsByPhoto.set(row.photo_id, [])
        try {
          rowsByPhoto.get(row.photo_id)?.push({
            fingerprint: row.input_fingerprint,
            result: JSON.parse(row.result_json) as QualityResult,
          })
        } catch {
          // Skip invalid historical analysis rows.
        }
      }
    }
    return rowsByPhoto
  }

  /**
   * Batch face lookup: the largest face observation per photo, in one IN
   * query instead of one per photo.
   */
  private getFacesBatch(
    sessionId: string,
    photos: PhotoRow[],
  ): Map<string, {
    bbox_x: number
    bbox_y: number
    bbox_w: number
    bbox_h: number
    analysis_signature: string
  }> {
    const faces = new Map<string, {
      bbox_x: number
      bbox_y: number
      bbox_w: number
      bbox_h: number
      analysis_signature: string
    }>()
    const ids = photos.map(photo => photo.id)
    for (const chunk of this.chunkIds(ids)) {
      const placeholders = chunk.map(() => '?').join(',')
      const rows = this.db.prepare(`
        SELECT photo_id, bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
        FROM face_observations
        WHERE session_id = ? AND photo_id IN (${placeholders})
        ORDER BY bbox_w * bbox_h DESC
      `).all(sessionId, ...chunk) as Array<{
        photo_id: string
        bbox_x: number
        bbox_y: number
        bbox_w: number
        bbox_h: number
        analysis_signature: string
      }>
      for (const row of rows) {
        // Rows are ordered by face area desc, so the first row per photo is
        // its largest face.
        if (!faces.has(row.photo_id)) faces.set(row.photo_id, row)
      }
    }
    return faces
  }

  private chunkIds(ids: string[]): string[][] {
    const chunks: string[][] = []
    for (let offset = 0; offset < ids.length; offset += IN_CHUNK_SIZE) {
      chunks.push(ids.slice(offset, offset + IN_CHUNK_SIZE))
    }
    return chunks
  }

  /**
   * Loads the latest similarity groups' members once (a single result + one
   * members query) so callers can reuse the map across applyRelativeRanks
   * instead of re-reading every member per call.
   */
  private loadSimilarityGroups(sessionId: string): Map<number, string[]> | null {
    const latest = this.db.prepare(`
      SELECT id FROM similarity_results
      WHERE session_id = ? ORDER BY id DESC LIMIT 1
    `).get(sessionId) as { id: number } | undefined
    if (!latest) return null
    const rows = this.db.prepare(`
      SELECT group_index, photo_id
      FROM similarity_result_members
      WHERE session_id = ? AND result_id = ?
      ORDER BY group_index, photo_id
    `).all(sessionId, latest.id) as Array<{ group_index: number; photo_id: string }>
    const groups = new Map<number, string[]>()
    for (const row of rows) {
      const members = groups.get(row.group_index) ?? []
      members.push(row.photo_id)
      groups.set(row.group_index, members)
    }
    return groups
  }

  private applyRelativeRanks(
    sessionId: string,
    results: QualityResult[],
    groups?: Map<number, string[]> | null,
  ): void {
    const successful = new Map(
      results.filter(result => result.status === 'succeeded').map(result => [result.photoId, result]),
    )
    const memberGroups = groups ?? this.loadSimilarityGroups(sessionId)
    if (!memberGroups) return
    for (const members of memberGroups.values()) {
      const ranked = members
        .flatMap(photoId => successful.get(photoId) ?? [])
        .sort((a, b) => b.qualityScore - a.qualityScore)
      ranked.forEach((result, index) => { result.relativeRank = index + 1 })
    }
  }
}
