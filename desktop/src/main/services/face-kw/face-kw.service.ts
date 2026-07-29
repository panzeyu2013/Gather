import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { FaceRepository, type FaceClusterInput } from '../../db/repositories/face.repo'
import type { EmbeddingEntry } from './face-clusterer'
import { clusterFacesInWorker } from '../../utils/analysis-worker-client'
import { FaceInferenceWorker } from './face-inference-worker-client'
import * as path from 'path'
import * as fs from 'fs'
import sharp from 'sharp'
import { ImageService } from '../image'
import { SettingsService } from '../settings/settings.service'
import { CancelledError, NotFoundError, ValidationError } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { MODEL_CONFIG } from './model-config'
import { resolveModelPath } from './provider'
import { batchAsync } from '../../utils/async'

export interface FaceClusterData {
  id: number
  sessionId: string
  label: string
  size: number
  status: string
  thumbnailBase64?: string
  binding?: { roleName: string; keywords: string[] } | null
  thumbnailPhotoId?: string
  members: {
    memberId: number
    photoId: string
    photoPath: string
    filename: string
    bbox: number[]
    confidence: number
  }[]
}

export type ProgressCallback = (data: { current: number; total: number; message: string }) => void

export interface FaceAnalysisResult {
  status: 'done' | 'failed' | 'cancelled'
  detectionFailures: number
  encodingFailures: number
}

@injectable()
export class FaceKwService {
  private controllers = new Map<string, AbortController>()

  constructor(
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.FACE_REPO) private faceRepo: FaceRepository,
    @inject(DI_TOKENS.IMAGE_SERVICE) private imageService: ImageService,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
  ) {}

  async analyze(
    sessionId: string,
    detectorPath: string,
    encoderPath: string,
    eps = this.settings.getNumber('default_eps', 0.6),
    minPts = this.settings.getNumber('default_min_samples', 2),
    onProgress?: ProgressCallback,
  ): Promise<FaceAnalysisResult> {
    if (this.controllers.has(sessionId)) {
      throw new Error('Analysis is already in progress for this session')
    }
    const controller = new AbortController()
    this.controllers.set(sessionId, controller)
    const signal = controller.signal

    let detectionFailures = 0
    let encodingFailures = 0
    let inferenceWorker: FaceInferenceWorker | null = null

    try {
      const session = this.sessionRepo.get(sessionId)
      if (!session) throw new NotFoundError('Session not found')

      this.sessionRepo.updateAnalysisStatus(sessionId, 'running')
      onProgress?.({ current: 0, total: 0, message: 'Initializing face detector...' })

      const onnxProvider = this.settings.get('onnx_provider', 'auto')
      const onnxThreads = this.settings.getNumber('onnx_threads', 4)
      const encoderInputSize = this.settings.getNumber('encoder_input_size', MODEL_CONFIG.encode.inputSize)
      const embeddingDim = this.settings.getNumber('embedding_dim', MODEL_CONFIG.encode.embeddingDim)
      const photos = this.photoRepo.getBySession(sessionId)
      if (signal.aborted) throw new CancelledError('Analysis cancelled')

      const primaryDetectionSize = this.settings.getNumber(
        'detect_input_size',
        MODEL_CONFIG.detect.inputSize,
      )
      const secondaryDetectionSize = this.settings.getNumber(
        'detect_secondary_input_size',
        MODEL_CONFIG.detect.secondaryInputSize,
      )
      const confidenceThreshold = this.settings.getNumber('detect_confidence', 0.5)
      const previewMaxDimension = Math.max(
        MODEL_CONFIG.detect.inputSize,
        this.settings.getNumber('face_preview_max_dimension', 2048),
      )
      const modelFingerprint = async (modelPath: string) => {
        const resolved = resolveModelPath(modelPath)
        try {
          const modelStat = await fs.promises.stat(resolved)
          return `${resolved}:${modelStat.size}:${Math.round(modelStat.mtimeMs)}`
        } catch {
          return resolved
        }
      }
      const analysisSignature = JSON.stringify({
        detector: await modelFingerprint(detectorPath),
        encoder: await modelFingerprint(encoderPath),
        primaryDetectionSize,
        secondaryDetectionSize,
        confidenceThreshold,
        encoderInputSize,
        embeddingDim,
        previewMaxDimension,
        preprocessingVersion: 2,
      })
      const cachedByPhoto = new Map<string, ReturnType<FaceRepository['getObservations']>>()
      for (const observation of this.faceRepo.getObservations(sessionId)) {
        const values = cachedByPhoto.get(observation.photo_id) ?? []
        values.push(observation)
        cachedByPhoto.set(observation.photo_id, values)
      }
      const analysisStates = this.faceRepo.getAnalysisStates(sessionId)

      const totalPhotos = photos.length
      const sourceStats = new Map<string, { size: number; mtimeMs: number }>()
      await batchAsync(photos, async (photo) => {
        try {
          const sourceStat = await fs.promises.stat(photo.filepath)
          sourceStats.set(photo.id, {
            size: sourceStat.size,
            mtimeMs: sourceStat.mtimeMs,
          })
        } catch {
          // The normal per-photo error path below records unreadable inputs.
        }
      }, 32)
      const photosNeedingAnalysis = photos.filter((photo) => {
        const sourceStat = sourceStats.get(photo.id)
        if (!sourceStat) return false
        const analysisState = analysisStates.get(photo.id)
        return !analysisState ||
          analysisState.sourceFileSize !== sourceStat.size ||
          Math.abs(analysisState.sourceFileMtimeMs - sourceStat.mtimeMs) >= 1 ||
          analysisState.analysisSignature !== analysisSignature
      })
      const clusterSignature = `${eps}:${minPts}`
      if (
        photosNeedingAnalysis.length === 0 &&
        this.faceRepo.getClusterSignature(sessionId) === clusterSignature &&
        this.faceRepo.getClusters(sessionId).length > 0
      ) {
        onProgress?.({ current: totalPhotos, total: totalPhotos, message: 'Reusing cached face clusters...' })
        this.sessionRepo.updateAnalysisStatus(sessionId, 'done')
        return { status: 'done', detectionFailures, encodingFailures }
      }
      this.faceRepo.deleteClustersBySession(sessionId)
      if (photosNeedingAnalysis.length > 0) {
        inferenceWorker = new FaceInferenceWorker()
        await inferenceWorker.init({
          detectorPath: resolveModelPath(detectorPath),
          encoderPath: resolveModelPath(encoderPath),
          provider: onnxProvider,
          threads: onnxThreads,
          encoderInputSize,
          embeddingDim,
        }, signal)
      }

      onProgress?.({ current: 0, total: totalPhotos, message: 'Detecting faces...' })

      let totalFaces = 0
      for (let i = 0; i < totalPhotos; i++) {
        if (signal.aborted) throw new CancelledError('Analysis cancelled')
        const photo = photos[i]
        try {
          const sourceStat = sourceStats.get(photo.id)
          if (!sourceStat) throw new Error(`Photo is not readable: ${photo.filepath}`)
          const cached = cachedByPhoto.get(photo.id) ?? []
          const analysisState = analysisStates.get(photo.id)
          if (
            analysisState &&
            analysisState.sourceFileSize === sourceStat.size &&
            Math.abs(analysisState.sourceFileMtimeMs - sourceStat.mtimeMs) < 1 &&
            analysisState.analysisSignature === analysisSignature
          ) {
            totalFaces += cached.length
            onProgress?.({ current: i + 1, total: totalPhotos, message: 'Reusing cached faces...' })
            continue
          }
          this.faceRepo.deleteObservationsByPhoto(sessionId, photo.id)
          const preview = await this.imageService.getPreview(
            photo.filepath,
            previewMaxDimension,
          )
          if (!inferenceWorker) throw new Error('Face inference worker is not initialized')
          const inference = await inferenceWorker.analyze(
            preview.buffer,
            {
              inputSizes: [secondaryDetectionSize, primaryDetectionSize],
              confidenceThreshold,
              nmsThreshold: this.settings.getNumber('nms_threshold', 0.4),
              maxDetections: this.settings.getNumber('max_detections', 100),
              embeddingDim,
            },
            signal,
          )
          const faces = inference.observations
          encodingFailures += inference.encodingFailures
          if (faces.length > 0) {
            totalFaces += faces.length
            const observations = faces.map(face => ({
                photoId: photo.id,
                bboxX: face.bbox[0],
                bboxY: face.bbox[1],
                bboxW: face.bbox[2],
                bboxH: face.bbox[3],
                embedding: face.embedding,
                confidence: face.confidence,
                sourceFileSize: sourceStat.size,
                sourceFileMtimeMs: sourceStat.mtimeMs,
                analysisSignature,
              }))
            this.faceRepo.saveObservations(sessionId, observations)
          }
          this.faceRepo.upsertAnalysisState(
            sessionId,
            photo.id,
            sourceStat.size,
            sourceStat.mtimeMs,
            analysisSignature,
          )
        } catch (e) {
          detectionFailures++
          console.warn('Face detection failed for', photo.filepath, e)
        }
        onProgress?.({ current: i + 1, total: totalPhotos, message: 'Detecting faces...' })
      }

      if (signal.aborted) throw new CancelledError('Analysis cancelled')

      onProgress?.({ current: 0, total: 0, message: 'Clustering faces...' })
      await this.clusterStoredObservations(sessionId, photos, eps, minPts, signal)
      this.faceRepo.upsertClusterSignature(sessionId, clusterSignature)

      const allDetectionsFailed = detectionFailures === totalPhotos && totalPhotos > 0
      const allEncodingsFailed =
        encodingFailures === totalFaces && totalFaces > 0
      if (allDetectionsFailed || allEncodingsFailed) {
        this.sessionRepo.updateAnalysisStatus(sessionId, 'failed')
        return { status: 'failed', detectionFailures, encodingFailures }
      }
      onProgress?.({ current: 0, total: 0, message: 'Analysis complete' })
      this.sessionRepo.updateAnalysisStatus(sessionId, 'done')
      return { status: 'done', detectionFailures, encodingFailures }
    } catch (e) {
      if (e instanceof CancelledError) {
        this.sessionRepo.updateAnalysisStatus(sessionId, 'cancelled')
        return { status: 'cancelled', detectionFailures, encodingFailures }
      }
      this.sessionRepo.updateAnalysisStatus(sessionId, 'failed')
      throw e
    } finally {
      this.controllers.delete(sessionId)
      if (inferenceWorker) {
        try { await inferenceWorker.shutdown() } catch (e) { console.warn('Failed to stop inference worker', e) }
      }
    }
  }

  async recluster(sessionId: string, eps: number, minPts: number): Promise<void> {
    const session = this.sessionRepo.get(sessionId)
    if (!session) throw new NotFoundError('Session not found')
    const observations = this.faceRepo.getObservations(sessionId)
    if (observations.length === 0) {
      throw new ValidationError('No cached face observations found. Run analysis first.')
    }
    const photos = this.photoRepo.getBySession(sessionId)
    this.faceRepo.deleteClustersBySession(sessionId)
    await this.clusterStoredObservations(sessionId, photos, eps, minPts)
    this.faceRepo.upsertClusterSignature(sessionId, `${eps}:${minPts}`)
  }

  private async clusterStoredObservations(
    sessionId: string,
    photos: ReturnType<PhotoRepository['getBySession']>,
    eps: number,
    minPts: number,
    signal?: AbortSignal,
  ): Promise<void> {
    const observations = this.faceRepo.getObservations(sessionId)
    const observationById = new Map(observations.map(observation => [observation.id, observation]))
    const photoById = new Map(photos.map(photo => [photo.id, photo]))
    const entries: EmbeddingEntry[] = []
    for (const observation of observations) {
      const bytes = new Uint8Array(observation.embedding)
      const embedding = Array.from(
        new Float32Array(bytes.buffer, bytes.byteOffset, bytes.length / 4),
      )
      if (embedding.some(value => value !== 0)) {
        entries.push({
          observationId: observation.id,
          embedding,
          photoId: observation.photo_id,
        })
      }
    }

    const { clusters } = await clusterFacesInWorker(
      entries,
      eps,
      minPts,
      signal,
    )
    const clusterInputs: FaceClusterInput[] = clusters.map((cluster, index) => ({
      label: `Person ${index + 1}`,
      members: cluster.map((entry) => {
        const observation = observationById.get(entry.observationId)
        return {
          photoId: entry.photoId,
          photoPath: photoById.get(entry.photoId)?.filepath ?? '',
          bbox: [
            observation?.bbox_x ?? 0,
            observation?.bbox_y ?? 0,
            observation?.bbox_w ?? 0,
            observation?.bbox_h ?? 0,
          ],
          confidence: observation?.confidence ?? 0,
          observationId: entry.observationId,
        }
      }),
    }))
    if (clusterInputs.length === 0) return

    const clusterIds = this.faceRepo.saveClusters(sessionId, clusterInputs)
    const thumbDir = this.faceRepo.getFaceThumbDir()
    await batchAsync(clusterInputs.map((_, index) => index), async (index) => {
      const firstMember = clusterInputs[index].members[0]
      if (!firstMember) return
      try {
        const [bx, by, bw, bh] = firstMember.bbox
        const faceThumbSize = this.settings.getNumber('face_thumbnail_size', 320)
        const preview = await this.imageService.getPreview(
          firstMember.photoPath,
          this.settings.getNumber('face_preview_max_dimension', 2048),
        )
        const left = Math.min(preview.width - 1, Math.max(0, Math.round(bx * preview.width)))
        const top = Math.min(preview.height - 1, Math.max(0, Math.round(by * preview.height)))
        const thumbnailBuffer = await sharp(preview.buffer)
          .extract({
            left,
            top,
            width: Math.max(1, Math.min(preview.width - left, Math.round(bw * preview.width))),
            height: Math.max(1, Math.min(preview.height - top, Math.round(bh * preview.height))),
          })
          .resize(faceThumbSize, faceThumbSize, { fit: 'cover' })
          .jpeg({ quality: this.settings.getNumber('face_thumbnail_quality', 70) })
          .toBuffer()
        const fileName = `${clusterIds[index]}.jpg`
        await fs.promises.writeFile(path.join(thumbDir, fileName), thumbnailBuffer)
        this.faceRepo.updateClusterThumbnail(clusterIds[index], fileName)
      } catch (error) {
        console.warn('Thumbnail generation failed for cluster', clusterIds[index], error)
      }
    }, 2)
  }

  async getClusters(sessionId: string): Promise<FaceClusterData[]> {
    const clusters = this.faceRepo.getClusters(sessionId, true)
    return clusters.map((c) => ({
      id: c.id,
      sessionId: c.session_id,
      label: c.label,
      size: c.member_count,
      status: c.status,
      thumbnailBase64: '',
      binding: c.binding ? { roleName: c.binding.roleName, keywords: c.binding.keywords } : null,
      thumbnailPhotoId: c.members?.[0]?.photo_id,
      members: (c.members ?? []).map((m) => ({
        memberId: m.id,
        photoId: m.photo_id,
        photoPath: m.photo_path,
        filename: m.photo_path.split(/[/\\]/).pop() ?? '',
        bbox: JSON.parse(m.bbox) as number[],
        confidence: m.confidence,
      })),
    }))
  }

  async getClusterThumbnail(clusterId: number): Promise<string> {
    const thumbPath = this.faceRepo.getClusterThumbnailPath(clusterId)
    if (!thumbPath) return ''
    try {
      const thumbDir = this.faceRepo.getFaceThumbDir()
      const buffer = await fs.promises.readFile(path.join(thumbDir, thumbPath))
      return buffer.toString('base64')
    } catch (e) {
      console.warn('Failed to read cluster thumbnail', clusterId, e)
      return ''
    }
  }

  async bindCluster(sessionId: string, clusterId: number, roleName: string, keywords: string[]): Promise<void> {
    const clusterSessionId = this.faceRepo.getClusterSessionId(clusterId)
    if (!clusterSessionId) throw new NotFoundError('Cluster not found')
    if (clusterSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    this.faceRepo.updateBinding(clusterId, roleName, keywords)
  }

  async unbindCluster(sessionId: string, clusterId: number): Promise<void> {
    const clusterSessionId = this.faceRepo.getClusterSessionId(clusterId)
    if (!clusterSessionId) throw new NotFoundError('Cluster not found')
    if (clusterSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    this.faceRepo.deleteBinding(clusterId)
  }

  async mergeClusters(sessionId: string, sourceId: number, targetId: number): Promise<void> {
    const sourceSessionId = this.faceRepo.getClusterSessionId(sourceId)
    const targetSessionId = this.faceRepo.getClusterSessionId(targetId)
    if (!sourceSessionId || !targetSessionId) throw new NotFoundError('Cluster not found')
    if (sourceSessionId !== sessionId || targetSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    this.faceRepo.mergeClusters(sourceId, targetId)
  }

  async removeMember(sessionId: string, clusterId: number, memberId: number): Promise<void> {
    const clusterSessionId = this.faceRepo.getClusterSessionId(clusterId)
    if (!clusterSessionId) throw new NotFoundError('Cluster not found')
    if (clusterSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    if (!this.faceRepo.removeMemberFromCluster(clusterId, memberId)) {
      throw new NotFoundError('Cluster member not found')
    }
  }

  async cancel(sessionId: string): Promise<void> {
    this.controllers.get(sessionId)?.abort()
  }
}
