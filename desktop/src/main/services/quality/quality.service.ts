import { stat } from 'node:fs/promises'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import type { ImageService } from '../image'
import type { QualityResult } from '@gather/shared'
import type { JobRunContext } from '../jobs/job.service'
import { collapsePhotoAssets } from '../assets/logical-photo-assets'

const MODEL_ID = 'technical-quality'
const MODEL_VERSION = '1'

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
    const results: QualityResult[] = []
    for (let index = 0; index < photos.length; index++) {
      context?.throwIfCancelled()
      const photo = photos[index]
      const assetFile = this.db.prepare(
        'SELECT asset_file_id FROM photos WHERE id = ?',
      ).get(photo.id) as { asset_file_id: string | null } | undefined
      try {
        const source = await stat(photo.filepath)
        const inputFingerprint = `${source.size}:${Math.round(source.mtimeMs)}`
        const cached = this.getCached(photo.id, inputFingerprint)
        if (cached) {
          results.push({ ...cached, photoId: photo.id })
          context?.updateProgress({
            current: index + 1,
            total: photos.length,
            message: '正在分析技术质量',
            checkpoint: { nextPhotoIndex: index + 1 },
          })
          continue
        }
        const preview = await this.imageService.getThumbnail(photo.filepath, 512)
        const sharp = (await import('sharp')) as unknown as typeof import('sharp')
        const raw = await sharp(preview.buffer).greyscale().raw().toBuffer({ resolveWithObject: true })
        const metrics = metricFromPixels(raw.data, raw.info.width, raw.info.height)
        const face = this.db.prepare(`
          SELECT bbox_x, bbox_y, bbox_w, bbox_h, analysis_signature
          FROM face_observations
          WHERE session_id = ? AND photo_id = ?
          ORDER BY bbox_w * bbox_h DESC LIMIT 1
        `).get(sessionId, photo.id) as {
          bbox_x: number
          bbox_y: number
          bbox_w: number
          bbox_h: number
          analysis_signature: string
        } | undefined
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
        const result: QualityResult = {
          photoId: photo.id,
          assetFileId: assetFile?.asset_file_id ?? undefined,
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
        if (!assetFile?.asset_file_id) throw new Error('Photo has no indexed asset file')
        this.db.prepare(`
          INSERT OR REPLACE INTO asset_analysis (
            photo_id, asset_file_id, analysis_type, result_json, warnings_json,
            model_id, model_version, input_fingerprint, created_at, updated_at
          ) VALUES (?, ?, 'technical_quality', ?, ?, ?, ?, ?, ?, ?)
        `).run(photo.id, assetFile.asset_file_id, JSON.stringify(result), JSON.stringify(warnings), MODEL_ID, MODEL_VERSION, inputFingerprint, result.updatedAt, result.updatedAt)
        results.push(result)
      } catch (error) {
        const failedAt = new Date().toISOString()
        const failure: QualityResult = {
          photoId: photo.id,
          assetFileId: assetFile?.asset_file_id ?? undefined,
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
        results.push(failure)
        if (assetFile?.asset_file_id) {
          this.db.prepare(`
            INSERT OR REPLACE INTO asset_analysis (
              photo_id, asset_file_id, analysis_type, result_json, warnings_json,
              model_id, model_version, input_fingerprint, created_at, updated_at
            ) VALUES (?, ?, 'technical_quality', ?, ?, ?, ?, ?, ?, ?)
          `).run(
            photo.id,
            assetFile.asset_file_id,
            JSON.stringify(failure),
            JSON.stringify(failure.warnings),
            MODEL_ID,
            MODEL_VERSION,
            `failed:${photo.updated_at}`,
            failedAt,
            failedAt,
          )
        }
      }
      context?.updateProgress({
        current: index + 1,
        total: photos.length,
        message: '正在分析技术质量',
        checkpoint: { nextPhotoIndex: index + 1 },
      })
    }
    this.applyRelativeRanks(sessionId, results)
    return results
  }

  get(sessionId: string, photoIds?: string[]): QualityResult[] {
    const sessionIds = new Set(this.photoRepo.getBySession(sessionId).map(photo => photo.id))
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
    this.applyRelativeRanks(sessionId, results)
    return results
  }

  private getCached(photoId: string, fingerprint: string): QualityResult | null {
    const row = this.db.prepare(`
      SELECT aa.result_json FROM asset_analysis aa
      JOIN photos p ON p.asset_file_id = aa.asset_file_id
      WHERE p.id = ? AND aa.analysis_type = 'technical_quality'
        AND model_id = ? AND model_version = ? AND input_fingerprint = ?
      ORDER BY updated_at DESC LIMIT 1
    `).get(photoId, MODEL_ID, MODEL_VERSION, fingerprint) as { result_json: string } | undefined
    if (!row) return null
    try { return JSON.parse(row.result_json) as QualityResult } catch { return null }
  }

  private applyRelativeRanks(sessionId: string, results: QualityResult[]): void {
    const successful = new Map(
      results.filter(result => result.status === 'succeeded').map(result => [result.photoId, result]),
    )
    const latest = this.db.prepare(`
      SELECT id FROM similarity_results
      WHERE session_id = ? ORDER BY id DESC LIMIT 1
    `).get(sessionId) as { id: number } | undefined
    if (!latest) return
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
    for (const members of groups.values()) {
      const ranked = members
        .flatMap(photoId => successful.get(photoId) ?? [])
        .sort((a, b) => b.qualityScore - a.qualityScore)
      ranked.forEach((result, index) => { result.relativeRank = index + 1 })
    }
  }
}
