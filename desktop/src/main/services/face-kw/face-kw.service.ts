import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { FaceRepository, type FaceClusterInput } from '../../db/repositories/face.repo'
import { detectFaces, initDetector, releaseDetector } from './face-detector'
import { encodeFace, initEncoder, releaseEncoder } from './face-encoder'
import { clusterEmbeddings, type EmbeddingEntry } from './face-clusterer'

export interface FaceClusterData {
  id: number
  sessionId: string
  label: string
  size: number
  status: string
  binding?: { roleName: string; keywords: string[] } | null
  thumbnailPhotoId?: string
  members: {
    photoId: string
    photoPath: string
    filename: string
    bbox: number[]
    confidence: number
  }[]
}

export type ProgressCallback = (data: { current: number; total: number; message: string }) => void

export class FaceKwService {
  private abortController: AbortController | null = null

  constructor(
    private photoRepo: PhotoRepository,
    private sessionRepo: SessionRepository,
    private faceRepo: FaceRepository,
  ) {}

  async analyze(
    sessionId: string,
    detectorPath: string,
    encoderPath: string,
    eps = 0.6,
    minPts = 3,
    onProgress?: ProgressCallback,
  ): Promise<void> {
    this.abortController = new AbortController()
    const signal = this.abortController.signal

    try {
      const session = this.sessionRepo.get(sessionId)
      if (!session) throw new Error('Session not found')

      this.sessionRepo.updateAnalysisStatus(sessionId, 'running')
      onProgress?.({ current: 0, total: 0, message: 'Initializing face detector...' })

      await initDetector(detectorPath)
      await initEncoder(encoderPath)

      const photos = this.photoRepo.getBySession(sessionId)
      if (signal.aborted) throw new Error('Analysis cancelled')

      this.faceRepo.deleteObservationsBySession(sessionId)
      this.faceRepo.deleteClustersBySession(sessionId)

      const totalPhotos = photos.length
      onProgress?.({ current: 0, total: totalPhotos, message: 'Detecting faces...' })

      for (let i = 0; i < totalPhotos; i++) {
        if (signal.aborted) throw new Error('Analysis cancelled')
        const photo = photos[i]
        try {
          const faces = await detectFaces(photo.filepath)
          if (faces.length > 0) {
            const observations = faces.map((f) => ({
              photoId: photo.id,
              bboxX: f.bbox[0],
              bboxY: f.bbox[1],
              bboxW: f.bbox[2],
              bboxH: f.bbox[3],
              embedding: new Array(128).fill(0),
              confidence: f.confidence,
            }))
            this.faceRepo.saveObservations(sessionId, observations)
          }
        } catch {
          // skip failed detections
        }
        onProgress?.({ current: i + 1, total: totalPhotos, message: 'Detecting faces...' })
      }

      const observations = this.faceRepo.getObservations(sessionId)
      const totalFaces = observations.length
      onProgress?.({ current: 0, total: totalFaces, message: 'Encoding faces...' })

      for (let i = 0; i < totalFaces; i++) {
        if (signal.aborted) throw new Error('Analysis cancelled')
        const obs = observations[i]
        try {
          const embedding = await encodeFace(
            photos.find((p) => p.id === obs.photo_id)?.filepath ?? '',
            [obs.bbox_x, obs.bbox_y, obs.bbox_w, obs.bbox_h],
          )
          this.faceRepo.updateEmbedding(obs.id, embedding)
        } catch {
          // skip failed encodings
        }
        onProgress?.({ current: i + 1, total: totalFaces, message: 'Encoding faces...' })
      }

      if (signal.aborted) throw new Error('Analysis cancelled')

      const updatedObs = this.faceRepo.getObservations(sessionId)
      const entries: EmbeddingEntry[] = []
      const buffToArr = (buf: Buffer): number[] => {
        const bytes = new Uint8Array(buf)
        return Array.from(new Float32Array(bytes.buffer, bytes.byteOffset, bytes.length / 4))
      }
      for (const obs of updatedObs) {
        const emb = buffToArr(obs.embedding)
        const hasNonZero = emb.some((v) => v !== 0)
        if (!hasNonZero) continue
        entries.push({ observationId: obs.id, embedding: emb, photoId: obs.photo_id })
      }

      onProgress?.({ current: 0, total: 0, message: 'Clustering faces...' })

      const { clusters, noise } = clusterEmbeddings(entries, eps, minPts)

      const clusterInputs: FaceClusterInput[] = clusters.map((cluster, idx) => ({
        label: `Person ${idx + 1}`,
        members: cluster.map((entry) => {
          const obs = updatedObs.find((o) => o.id === entry.observationId)
          const photo = photos.find((p) => p.id === entry.photoId)
          return {
            photoId: entry.photoId,
            photoPath: photo?.filepath ?? '',
            bbox: [obs?.bbox_x ?? 0, obs?.bbox_y ?? 0, obs?.bbox_w ?? 0, obs?.bbox_h ?? 0],
            confidence: obs?.confidence ?? 0,
            observationId: entry.observationId,
          }
        }),
      }))

      if (clusterInputs.length > 0) {
        this.faceRepo.saveClusters(sessionId, clusterInputs)
      }

      onProgress?.({ current: 0, total: 0, message: 'Analysis complete' })
      this.sessionRepo.updateAnalysisStatus(sessionId, 'done')
    } catch (e) {
      if ((e as Error).message === 'Analysis cancelled') {
        this.sessionRepo.updateAnalysisStatus(sessionId, 'cancelled')
        return
      }
      this.sessionRepo.updateAnalysisStatus(sessionId, 'failed')
      throw e
    } finally {
      this.abortController = null
      try { await releaseDetector() } catch { /* ignore */ }
      try { await releaseEncoder() } catch { /* ignore */ }
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
      binding: c.binding ? { roleName: c.binding.roleName, keywords: c.binding.keywords } : null,
      thumbnailPhotoId: c.members?.[0]?.photo_id,
      members: (c.members ?? []).map((m) => ({
        photoId: m.photo_id,
        photoPath: m.photo_path,
        filename: m.photo_path.split(/[/\\]/).pop() ?? '',
        bbox: JSON.parse(m.bbox) as number[],
        confidence: m.confidence,
      })),
    }))
  }

  async bindCluster(sessionId: string, clusterId: number, roleName: string, keywords: string[]): Promise<void> {
    this.faceRepo.updateBinding(clusterId, roleName, keywords)
  }

  async unbindCluster(_sessionId: string, clusterId: number): Promise<void> {
    this.faceRepo.deleteBinding(clusterId)
  }

  async mergeClusters(_sessionId: string, sourceId: number, targetId: number): Promise<void> {
    this.faceRepo.mergeClusters(sourceId, targetId)
  }

  async removeMember(_sessionId: string, clusterId: number, photoId: string): Promise<void> {
    this.faceRepo.removeMemberFromCluster(clusterId, photoId)
  }

  async cancel(_sessionId: string): Promise<void> {
    if (this.abortController) {
      this.abortController.abort()
    }
  }
}
