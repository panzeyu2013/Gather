import { PhotoRepository, type PhotoProjectionRow } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { FaceRepository, type FaceClusterInput } from '../../db/repositories/face.repo'
import { PersonRepository } from '../../db/repositories/person.repo'
import type { EmbeddingEntry } from './face-clusterer'
import { clusterFacesInWorker } from '../../utils/analysis-worker-client'
import { FaceInferenceWorker } from './face-inference-worker-client'
import * as fs from 'fs'
import { ImageService } from '../image'
import type { DecodeResult } from '../image'
import { SettingsService } from '../settings/settings.service'
import { CancelledError, NotFoundError, ValidationError } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { MODEL_CONFIG } from './model-config'
import { resolveModelPath } from './provider'
import { batchAsync } from '../../utils/async'
import { collapsePhotoAssets } from '../assets/logical-photo-assets'

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

export function validateFaceClusteringParameters(eps: number, minPts: number): void {
  if (!Number.isFinite(eps) || eps < 0 || eps > 1) {
    throw new ValidationError('人脸聚类相似度必须是 0 到 1 之间的数字')
  }
  if (!Number.isInteger(minPts) || minPts < 1) {
    throw new ValidationError('人脸聚类最小样本数必须是大于等于 1 的整数')
  }
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
    @inject(DI_TOKENS.PERSON_REPO) private personRepo: PersonRepository,
  ) {}

  async analyze(
    sessionId: string,
    detectorPath: string,
    encoderPath: string,
    eps = this.settings.getNumber('default_eps', 0.6),
    minPts = this.settings.getNumber('default_min_samples', 2),
    onProgress?: ProgressCallback,
  ): Promise<FaceAnalysisResult> {
    validateFaceClusteringParameters(eps, minPts)
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
      // Light projection: only identity/file/asset/dimension columns are
      // needed here, so skip the heavy metadata/result JSON blobs.
      const photos = collapsePhotoAssets(this.photoRepo.getBySessionProjection(sessionId))
      if (photos.length === 0) throw new ValidationError('当前工作区没有可分析的照片')
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
      let reusedAcrossSessions = false
      for (const photo of photos) {
        const sourceStat = sourceStats.get(photo.id)
        if (!sourceStat) continue
        const analysisState = analysisStates.get(photo.id)
        const cacheIsValid = Boolean(
          analysisState &&
          analysisState.sourceFileSize === sourceStat.size &&
          Math.abs(analysisState.sourceFileMtimeMs - sourceStat.mtimeMs) < 1 &&
          analysisState.analysisSignature === analysisSignature,
        )
        if (cacheIsValid) continue
        const reused = this.faceRepo.reuseObservationsForAssetFile(
          sessionId,
          photo.id,
          sourceStat.size,
          sourceStat.mtimeMs,
          analysisSignature,
        )
        if (reused.reused) {
          reusedAcrossSessions = true
          analysisStates.set(photo.id, {
            sourceFileSize: sourceStat.size,
            sourceFileMtimeMs: sourceStat.mtimeMs,
            analysisSignature,
          })
        }
      }
      if (reusedAcrossSessions) {
        cachedByPhoto.clear()
        for (const observation of this.faceRepo.getObservations(sessionId)) {
          const values = cachedByPhoto.get(observation.photo_id) ?? []
          values.push(observation)
          cachedByPhoto.set(observation.photo_id, values)
        }
      }
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
      // Old clusters and role bindings are deliberately kept until new results
      // are ready. Deleting them first would destroy user-bound clusters and
      // role names whenever model initialization or inference fails.
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
      // Sliding-window decode pipeline: while photo i is being inferred, the
      // previews for i+1..i+window are already being decoded (getPreview
      // dedupes in-flight work and its DecodeLimiter caps actual decode
      // concurrency). Cache hits slide the window without decoding.
      const decodeWindow = Math.max(
        1,
        Math.min(8, Math.floor(this.settings.getNumber('face_decode_concurrency', 4))),
      )
      const decodePromises: Array<Promise<DecodeResult>> = new Array(totalPhotos)
      let prefetchUntil = 0
      const isCacheValid = (photoId: string, sourceStat: { size: number; mtimeMs: number }): boolean => {
        const analysisState = analysisStates.get(photoId)
        return Boolean(
          analysisState &&
          analysisState.sourceFileSize === sourceStat.size &&
          Math.abs(analysisState.sourceFileMtimeMs - sourceStat.mtimeMs) < 1 &&
          analysisState.analysisSignature === analysisSignature,
        )
      }
      const prefetchDecodes = (current: number): void => {
        const limit = Math.min(totalPhotos, current + decodeWindow)
        while (prefetchUntil < limit) {
          const index = prefetchUntil++
          const photo = photos[index]
          const sourceStat = sourceStats.get(photo.id)
          if (!sourceStat || isCacheValid(photo.id, sourceStat)) continue
          const pending = this.imageService.getPreview(photo.filepath, previewMaxDimension)
          // Suppress unhandled-rejection warnings while the decode is in
          // flight; the failure is observed when the photo is processed.
          pending.catch(() => {})
          decodePromises[index] = pending
        }
      }
      for (let i = 0; i < totalPhotos; i++) {
        if (signal.aborted) throw new CancelledError('Analysis cancelled')
        prefetchDecodes(i)
        const photo = photos[i]
        try {
          const sourceStat = sourceStats.get(photo.id)
          if (!sourceStat) throw new Error(`Photo is not readable: ${photo.filepath}`)
          const cached = cachedByPhoto.get(photo.id) ?? []
          if (isCacheValid(photo.id, sourceStat)) {
            totalFaces += cached.length
            onProgress?.({ current: i + 1, total: totalPhotos, message: 'Reusing cached faces...' })
            continue
          }
          const preview = await (decodePromises[i] ??
            this.imageService.getPreview(photo.filepath, previewMaxDimension))
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
          // Replace old observations only after inference succeeded: a failed
          // run must not destroy previously valid detections for this photo.
          this.faceRepo.replaceObservationsByPhoto(sessionId, photo.id, observations)
          if (faces.length > 0) {
            totalFaces += faces.length
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

      // Determine failure before re-clustering so that an all-failed run does
      // not clear the previously bound clusters and role names.
      const allDetectionsFailed = detectionFailures === totalPhotos && totalPhotos > 0
      const allEncodingsFailed =
        encodingFailures === totalFaces && totalFaces > 0
      const analysisFailed = allDetectionsFailed || allEncodingsFailed

      onProgress?.({ current: 0, total: 0, message: 'Clustering faces...' })
      await this.clusterStoredObservations(
        sessionId,
        photos,
        eps,
        minPts,
        signal,
        !analysisFailed,
        (current, total) => {
          onProgress?.({ current, total, message: 'Clustering faces...' })
        },
      )
      this.faceRepo.upsertClusterSignature(sessionId, clusterSignature)

      if (analysisFailed) {
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
    validateFaceClusteringParameters(eps, minPts)
    const session = this.sessionRepo.get(sessionId)
    if (!session) throw new NotFoundError('Session not found')
    const observations = this.faceRepo.getObservations(sessionId)
    if (observations.length === 0) {
      throw new ValidationError('No cached face observations found. Run analysis first.')
    }
    const photos = this.photoRepo.getBySessionProjection(sessionId)
    await this.clusterStoredObservations(sessionId, photos, eps, minPts)
    this.faceRepo.upsertClusterSignature(sessionId, `${eps}:${minPts}`)
  }

  private async clusterStoredObservations(
    sessionId: string,
    photos: PhotoProjectionRow[],
    eps: number,
    minPts: number,
    signal?: AbortSignal,
    clearOnEmpty = true,
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const observations = this.faceRepo.getObservations(sessionId)
    const observationById = new Map(observations.map(observation => [observation.id, observation]))
    const photoById = new Map(photos.map(photo => [photo.id, photo]))
    const entries: EmbeddingEntry[] = []
    for (const observation of observations) {
      // View the stored BLOB directly as Float32Array — no per-row JS array
      // copy; Float32Array survives the worker postMessage structured clone.
      const embedding = new Float32Array(
        observation.embedding.buffer,
        observation.embedding.byteOffset,
        observation.embedding.byteLength / 4,
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
      onProgress,
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
    if (clusterInputs.length === 0) {
      // A completed analysis with no faces should not leave stale clusters
      // behind, so clear the previous results — but only when the run is a
      // real success. On an all-failed run keep the existing clusters and
      // role bindings intact.
      if (clearOnEmpty) this.faceRepo.deleteClustersBySession(sessionId)
      return
    }

    // Replace previous clusters only when new ones are ready to persist. This
    // keeps existing clusters and role bindings intact if a re-analysis or
    // re-cluster fails partway through.
    this.faceRepo.deleteClustersBySession(sessionId)
    this.faceRepo.saveClusters(sessionId, clusterInputs)
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

  async bindCluster(sessionId: string, clusterId: number, roleName: string, keywords: string[]): Promise<void> {
    const clusterSessionId = this.faceRepo.getClusterSessionId(clusterId)
    if (!clusterSessionId) throw new NotFoundError('Cluster not found')
    if (clusterSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    const normalizedRoleName = roleName.trim()
    if (!normalizedRoleName) throw new ValidationError('Role name cannot be empty')
    if (!Array.isArray(keywords) || keywords.some(keyword => typeof keyword !== 'string')) {
      throw new ValidationError('Keywords must be an array of strings')
    }
    const dedupedKeywords = [...new Set(keywords.map(keyword => keyword.trim()).filter(Boolean))]
    this.faceRepo.updateBinding(
      clusterId,
      normalizedRoleName,
      dedupedKeywords,
    )
    // Bridge bound roles into the person library so the "人脸库" page is not
    // an orphan: upsert a person per role name and attach the cluster's photos.
    // Best-effort — a linkage failure must not fail the binding itself.
    try {
      const members = this.faceRepo.getClusterMembers(clusterId)
      const personId = this.personRepo.upsertByName(normalizedRoleName, dedupedKeywords)
      this.personRepo.addPhotos(
        personId,
        sessionId,
        members.map(member => ({
          photoId: member.photoId,
          faceBbox: member.bbox,
          confidence: member.confidence,
        })),
      )
    } catch (error) {
      console.warn('Failed to link bound role into person library', error)
    }
  }

  async unbindCluster(sessionId: string, clusterId: number): Promise<void> {
    const clusterSessionId = this.faceRepo.getClusterSessionId(clusterId)
    if (!clusterSessionId) throw new NotFoundError('Cluster not found')
    if (clusterSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    this.faceRepo.deleteBinding(clusterId)
    // Drop person-library links for photos no longer covered by a role binding.
    // Best-effort — a linkage failure must not fail the unbinding itself.
    try {
      this.personRepo.reconcileSession(sessionId)
    } catch (error) {
      console.warn('Failed to reconcile person library after unbind', error)
    }
  }

  async mergeClusters(sessionId: string, sourceId: number, targetId: number): Promise<void> {
    if (sourceId === targetId) {
      throw new ValidationError('不能将人脸组与自身合并')
    }
    const sourceSessionId = this.faceRepo.getClusterSessionId(sourceId)
    const targetSessionId = this.faceRepo.getClusterSessionId(targetId)
    if (!sourceSessionId || !targetSessionId) throw new NotFoundError('Cluster not found')
    if (sourceSessionId !== sessionId || targetSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    this.faceRepo.mergeClusters(sourceId, targetId)
    // Photos that moved to the target cluster now belong to the target role in
    // the person library; the source role loses them. Best-effort.
    try {
      this.personRepo.reconcileSession(sessionId)
    } catch (error) {
      console.warn('Failed to reconcile person library after merge', error)
    }
  }

  async removeMember(sessionId: string, clusterId: number, memberId: number): Promise<void> {
    const clusterSessionId = this.faceRepo.getClusterSessionId(clusterId)
    if (!clusterSessionId) throw new NotFoundError('Cluster not found')
    if (clusterSessionId !== sessionId) throw new ValidationError('Cluster does not belong to this session')
    if (!this.faceRepo.removeMemberFromCluster(clusterId, memberId)) {
      throw new NotFoundError('Cluster member not found')
    }
    // The removed member's photo is no longer covered by this cluster's role
    // binding; drop it from the person library if nothing else covers it.
    // Best-effort.
    try {
      this.personRepo.reconcileSession(sessionId)
    } catch (error) {
      console.warn('Failed to reconcile person library after member removal', error)
    }
  }

  async cancel(sessionId: string): Promise<void> {
    this.controllers.get(sessionId)?.abort()
  }
}
