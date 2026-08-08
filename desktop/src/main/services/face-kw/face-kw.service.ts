import { PhotoRepository, type PhotoProjectionRow } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { FaceRepository, type FaceClusterInput } from '../../db/repositories/face.repo'
import { PersonRepository } from '../../db/repositories/person.repo'
import type { EmbeddingEntry } from './face-clusterer'
import { clusterFacesInWorker } from '../../utils/analysis-worker-client'
import { FaceInferenceWorker, type FaceInferenceBatchItem } from './face-inference-worker-client'
import * as fs from 'fs'
import { ImageService } from '../image'
import type { DecodeResult } from '../image'
import { SettingsService } from '../settings/settings.service'
import type { CullingService } from '../culling/culling.service'
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
    @inject(DI_TOKENS.CULLING_SERVICE) private culling?: CullingService,
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
    let inferenceWorkers: FaceInferenceWorker[] = []

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
      // Photos whose files are confirmed gone (ENOENT) must not keep stale
      // face observations: they would otherwise keep clustering into results
      // forever. Other stat failures (permissions, transient I/O) are left
      // alone so nothing is destroyed on a temporary error.
      const missingPhotoIds = new Set<string>()
      await batchAsync(photos, async (photo) => {
        try {
          const sourceStat = await fs.promises.stat(photo.filepath)
          sourceStats.set(photo.id, {
            size: sourceStat.size,
            mtimeMs: sourceStat.mtimeMs,
          })
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
            missingPhotoIds.add(photo.id)
          }
        }
      }, 32)
      if (missingPhotoIds.size > 0) {
        for (const photoId of missingPhotoIds) {
          this.faceRepo.deleteObservationsByPhoto(sessionId, photoId)
          this.faceRepo.deleteAnalysisStateByPhoto(sessionId, photoId)
          analysisStates.delete(photoId)
          cachedByPhoto.delete(photoId)
        }
        console.warn(
          `Face analysis: cleaned up ${missingPhotoIds.size} photo(s) whose files no longer exist`,
        )
      }
      // Batch the cross-session reuse lookup: one IN query for every photo
      // that needs analysis instead of a SELECT per photo.
      const reuseTargets: Array<{
        photoId: string
        assetFileId: string | null
        sourceFileSize: number
        sourceFileMtimeMs: number
      }> = []
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
        reuseTargets.push({
          photoId: photo.id,
          assetFileId: photo.asset_file_id ?? null,
          sourceFileSize: sourceStat.size,
          sourceFileMtimeMs: sourceStat.mtimeMs,
        })
      }
      const reuseResults = this.faceRepo.reuseObservationsForAssetFile(
        sessionId,
        reuseTargets,
        analysisSignature,
      )
      let reusedAcrossSessions = false
      for (const target of reuseTargets) {
        const reused = reuseResults[target.photoId]
        if (reused?.reused) {
          reusedAcrossSessions = true
          analysisStates.set(target.photoId, {
            sourceFileSize: target.sourceFileSize,
            sourceFileMtimeMs: target.sourceFileMtimeMs,
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
        missingPhotoIds.size === 0 &&
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
        // Parallel inference workers share the ONNX thread pool, so each
        // worker gets the configured thread budget divided evenly. Workers
        // are started one at a time: worker 0 must succeed, and any later
        // worker that fails to init degrades the run back to fewer workers.
        const requestedWorkers = Math.max(
          1,
          Math.min(2, Math.floor(this.settings.getNumber('face_inference_parallel_workers', 1))),
        )
        const threadsPerWorker = Math.max(1, Math.floor(onnxThreads / requestedWorkers))
        for (let w = 0; w < requestedWorkers; w++) {
          const worker = new FaceInferenceWorker()
          try {
            await worker.init({
              detectorPath: resolveModelPath(detectorPath),
              encoderPath: resolveModelPath(encoderPath),
              provider: onnxProvider,
              threads: threadsPerWorker,
              encoderInputSize,
              embeddingDim,
              inputSizes: [primaryDetectionSize, secondaryDetectionSize],
            }, signal)
            inferenceWorkers.push(worker)
          } catch (error) {
            // A cancelled init must keep the cancelled status, not degrade
            // into a generic init failure.
            if (signal.aborted || error instanceof CancelledError) throw error
            console.warn(
              `Face inference worker ${w} failed to initialize; continuing with ${inferenceWorkers.length} worker(s)`,
              error,
            )
            try { await worker.shutdown() } catch { /* worker never started */ }
            break
          }
        }
        if (inferenceWorkers.length === 0) {
          throw new Error('Face inference workers failed to initialize')
        }
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

      const inferenceConfig = {
        inputSizes: [secondaryDetectionSize, primaryDetectionSize],
        confidenceThreshold,
        nmsThreshold: this.settings.getNumber('nms_threshold', 0.4),
        maxDetections: this.settings.getNumber('max_detections', 100),
        embeddingDim,
      }

      // Profiling counters: decode wait (the time awaiting an already
      // prefetched decode) and per-batch inference time reveal which stage is
      // the pipeline bottleneck on real libraries.
      let decodeWaitMs = 0
      let inferMs = 0
      let inferredPhotoCount = 0
      const pipelineStart = performance.now()

      const applyInferenceResult = (index: number, item: FaceInferenceBatchItem): void => {
        const photo = photos[index]
        const sourceStat = sourceStats.get(photo.id)
        if (!sourceStat) return
        if (item.error) {
          detectionFailures++
          console.warn('Face detection failed for', photo.filepath, item.error)
          return
        }
        try {
          const faces = item.observations
          encodingFailures += item.encodingFailures
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
      }

      // One batch queue per worker; photo i is assigned to worker i % N so
      // the inference load stays balanced while the batches stay small.
      // Batches are dispatched as soon as a queue fills, but the in-flight
      // count per worker is capped: without backpressure a large session
      // would buffer every photo's preview in the worker's message queue
      // (the pre-parallel code awaited inline for the same reason), which is
      // gigabytes of memory on big libraries.
      const MAX_IN_FLIGHT_BATCHES_PER_WORKER = 2
      const batchImages: Buffer[][] = inferenceWorkers.map(() => [])
      const batchIndices: number[][] = inferenceWorkers.map(() => [])
      const pendingFlushes: Array<Promise<void>> = []
      const inFlightByWorker: Array<Promise<void>[]> = inferenceWorkers.map(() => [])
      const flushBatch = (w: number): void => {
        if (batchIndices[w].length === 0) return
        // A rejected request (worker crash, corrupt model) rejects the
        // collected promise and aborts the whole analysis: a dead worker
        // cannot be healed by retrying, and the observations already
        // committed stay in place.
        const worker = inferenceWorkers[w]
        if (!worker) throw new Error('Face inference worker is not initialized')
        const images = batchImages[w].splice(0)
        const indices = batchIndices[w].splice(0)
        const inferStart = performance.now()
        const flushPromise = worker.analyzeBatch(images, inferenceConfig, signal)
          .then((results) => {
            inferMs += performance.now() - inferStart
            if (results.length !== indices.length) {
              throw new Error('Face inference worker returned a mismatched batch')
            }
            for (let b = 0; b < indices.length; b++) {
              applyInferenceResult(indices[b], results[b])
            }
          })
          .finally(() => {
            const tracked = inFlightByWorker[w]
            const index = tracked.indexOf(flushPromise)
            if (index >= 0) tracked.splice(index, 1)
          })
        // The rejection is observed by flushAllBatches' Promise.all; this
        // noop catch only prevents an unhandled-rejection warning if the
        // worker dies while the loop is still awaiting decodes.
        flushPromise.catch(() => {})
        pendingFlushes.push(flushPromise)
        inFlightByWorker[w].push(flushPromise)
      }
      const flushAllBatches = async (): Promise<void> => {
        for (let w = 0; w < inferenceWorkers.length; w++) {
          flushBatch(w)
        }
        await Promise.all(pendingFlushes)
        pendingFlushes.length = 0
      }

      for (let i = 0; i < totalPhotos; i++) {
        if (signal.aborted) throw new CancelledError('Analysis cancelled')
        prefetchDecodes(i)
        const photo = photos[i]
        const sourceStat = sourceStats.get(photo.id)
        if (!sourceStat) {
          if (missingPhotoIds.has(photo.id)) {
            // Observations for ENOENT photos were cleaned up up-front; do
            // not count them as detection failures.
            onProgress?.({ current: i + 1, total: totalPhotos, message: 'Detecting faces...' })
            continue
          }
          detectionFailures++
          console.warn('Face detection failed for', photo.filepath, 'photo is not readable')
          onProgress?.({ current: i + 1, total: totalPhotos, message: 'Detecting faces...' })
          continue
        }
        const cached = cachedByPhoto.get(photo.id) ?? []
        if (isCacheValid(photo.id, sourceStat)) {
          totalFaces += cached.length
          onProgress?.({ current: i + 1, total: totalPhotos, message: 'Reusing cached faces...' })
          continue
        }
        const decodeStart = performance.now()
        let preview: DecodeResult
        try {
          preview = await (decodePromises[i] ??
            this.imageService.getPreview(photo.filepath, previewMaxDimension))
        } catch (e) {
          detectionFailures++
          console.warn('Face detection failed for', photo.filepath, e)
          onProgress?.({ current: i + 1, total: totalPhotos, message: 'Detecting faces...' })
          continue
        }
        decodeWaitMs += performance.now() - decodeStart
        // Photos reaching here are all in photosNeedingAnalysis, so the
        // workers were initialized above; guard anyway so a future refactor
        // cannot divide by zero.
        if (inferenceWorkers.length === 0) {
          throw new Error('Face inference worker is not initialized')
        }
        const w = i % inferenceWorkers.length
        if (batchIndices[w].length >= decodeWindow) {
          // Backpressure: wait for an in-flight batch to finish before
          // dispatching another, keeping at most MAX_IN_FLIGHT_BATCHES_PER_WORKER
          // batches queued in the worker's message pipeline.
          if (inFlightByWorker[w].length >= MAX_IN_FLIGHT_BATCHES_PER_WORKER) {
            await inFlightByWorker[w][0].catch(() => undefined)
          }
          flushBatch(w)
        }
        batchImages[w].push(preview.buffer)
        batchIndices[w].push(i)
        inferredPhotoCount++
        onProgress?.({ current: i + 1, total: totalPhotos, message: 'Detecting faces...' })
      }
      await flushAllBatches()

      if (signal.aborted) throw new CancelledError('Analysis cancelled')

      if (inferredPhotoCount > 0) {
        console.debug(
          `[face-kw] pipeline ${(performance.now() - pipelineStart).toFixed(0)}ms ` +
            `(${inferenceWorkers.length} worker(s), decode wait avg ${(decodeWaitMs / inferredPhotoCount).toFixed(1)}ms, ` +
            `infer avg ${(inferMs / Math.max(1, Math.ceil(inferredPhotoCount / decodeWindow))).toFixed(1)}ms per batch of ${decodeWindow})`,
        )
      }

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
        // Observations written during this pass may have changed even though
        // the run is reported failed; drop the culling lookup cache so its
        // faces/quality snapshots rebuild on the next list() call.
        this.culling?.invalidateSessionLookup(sessionId)
        return { status: 'failed', detectionFailures, encodingFailures }
      }
      onProgress?.({ current: 0, total: 0, message: 'Analysis complete' })
      this.sessionRepo.updateAnalysisStatus(sessionId, 'done')
      // The culling lookup cache snapshots face observations; invalidate it
      // now that the new observations/clusters are committed so the next
      // list()/listPage() rebuilds instead of serving stale faces for the
      // remainder of the TTL window.
      this.culling?.invalidateSessionLookup(sessionId)
      return { status: 'done', detectionFailures, encodingFailures }
    } catch (e) {
      if (e instanceof CancelledError) {
        this.sessionRepo.updateAnalysisStatus(sessionId, 'cancelled')
        this.culling?.invalidateSessionLookup(sessionId)
        return { status: 'cancelled', detectionFailures, encodingFailures }
      }
      this.sessionRepo.updateAnalysisStatus(sessionId, 'failed')
      this.culling?.invalidateSessionLookup(sessionId)
      throw e
    } finally {
      this.controllers.delete(sessionId)
      for (const worker of inferenceWorkers) {
        try { await worker.shutdown() } catch (e) { console.warn('Failed to stop inference worker', e) }
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
    // User-bound roles are migrated by member overlap: re-clustering replaces
    // every cluster id, so without this the bindings would silently vanish.
    const previousBindings = this.faceRepo.getBindingsBySession(sessionId)
    this.faceRepo.deleteClustersBySession(sessionId)
    const newClusterIds = this.faceRepo.saveClusters(sessionId, clusterInputs)
    if (previousBindings.length > 0) {
      const membersByCluster = newClusterIds.map((clusterId, index) => ({
        clusterId,
        photoIds: new Set(
          clusterInputs[index].members
            .map(member => member.photoId)
            .filter((id): id is string => id !== ''),
        ),
      }))
      this.migrateBindings(previousBindings, membersByCluster)
    }
  }

  /**
   * Re-attach each role binding to the new cluster with the largest member
   * overlap. Overlap is measured on photo ids (stable across re-analysis).
   * Claims are made in descending overlap order so a competition between two
   * bindings for one cluster is always won by the better match; a binding
   * whose faces vanished from the new result is dropped. Best-effort: a
   * migration failure must not fail the analysis itself.
   */
  private migrateBindings(
    previousBindings: Array<{
      clusterId: number
      roleName: string
      keywords: string[]
      memberPhotoIds: string[]
    }>,
    newMembers: Array<{ clusterId: number; photoIds: Set<string> }>,
  ): void {
    const candidates: Array<{ binding: typeof previousBindings[number]; clusterId: number; overlap: number }> = []
    for (const binding of previousBindings) {
      const memberPhotos = new Set(binding.memberPhotoIds)
      for (const candidate of newMembers) {
        let overlap = 0
        for (const photoId of candidate.photoIds) {
          if (memberPhotos.has(photoId)) overlap++
        }
        if (overlap > 0) {
          candidates.push({ binding, clusterId: candidate.clusterId, overlap })
        }
      }
    }
    candidates.sort((a, b) => b.overlap - a.overlap)
    const claimedClusters = new Set<number>()
    const migratedBindings = new Set<number>()
    for (const candidate of candidates) {
      if (claimedClusters.has(candidate.clusterId)) continue
      if (migratedBindings.has(candidate.binding.clusterId)) continue
      claimedClusters.add(candidate.clusterId)
      migratedBindings.add(candidate.binding.clusterId)
      try {
        this.faceRepo.updateBinding(candidate.clusterId, candidate.binding.roleName, candidate.binding.keywords)
      } catch (error) {
        console.warn('Failed to migrate role binding after re-clustering', error)
      }
    }
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
