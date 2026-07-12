import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { FaceRepository, type FaceClusterInput } from '../../db/repositories/face.repo'
import { detectFaces, initDetector, releaseDetector } from './face-detector'
import { encodeFace, initEncoder, releaseEncoder, EMBEDDING_DIM } from './face-encoder'
import { clusterEmbeddings, type EmbeddingEntry } from './face-clusterer'
import * as path from 'path'
import sharp from 'sharp'
import { ImageService, TieredThumbnailCache } from '../image'
import { SettingsService } from '../settings'

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
  private imageService = new ImageService(new TieredThumbnailCache())
  private settings = SettingsService.getInstance()

  constructor(
    private photoRepo: PhotoRepository,
    private sessionRepo: SessionRepository,
    private faceRepo: FaceRepository,
  ) {}

  async analyze(
    sessionId: string,
    detectorPath: string,
    encoderPath: string,
    eps = this.settings.getNumber('default_eps', 0.6),
    minPts = this.settings.getNumber('default_min_samples', 2),
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
              embedding: new Array(EMBEDDING_DIM).fill(0),
              confidence: f.confidence,
            }))
            this.faceRepo.saveObservations(sessionId, observations)
          }
        } catch (e) {
          console.warn('Face detection failed for', photo.filepath, e)
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
        } catch (e) {
          console.warn('Face encoding failed for observation', obs.id, e)
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
        const clusterIds = this.faceRepo.saveClusters(sessionId, clusterInputs)

        for (let ci = 0; ci < clusterInputs.length; ci++) {
          const cluster = clusterInputs[ci]
          const firstMember = cluster.members[0]
          const faceThumbSize = this.settings.getNumber('face_thumbnail_size', 80)
          const faceThumbQuality = this.settings.getNumber('face_thumbnail_quality', 70)
          if (firstMember) {
            try {
              const [bx, by, bw, bh] = firstMember.bbox
              const ext = path.extname(firstMember.photoPath).toLowerCase()
              let thumbnailBuffer: Buffer | null = null

              if (['.jpg', '.jpeg', '.png', '.tif', '.tiff'].includes(ext)) {
                const meta = await sharp(firstMember.photoPath).metadata()
                const imgW = meta.width ?? 0
                const imgH = meta.height ?? 0
                thumbnailBuffer = await sharp(firstMember.photoPath)
                  .extract({
                    left: Math.round(bx * imgW),
                    top: Math.round(by * imgH),
                    width: Math.round(bw * imgW),
                    height: Math.round(bh * imgH),
                  })
                  .resize(faceThumbSize, faceThumbSize, { fit: 'cover' })
                  .jpeg({ quality: faceThumbQuality })
                  .toBuffer()
              } else {
                const preview = await this.imageService.getPreview(firstMember.photoPath, 1920)
                thumbnailBuffer = await sharp(preview.buffer)
                  .extract({
                    left: Math.round(bx * preview.width),
                    top: Math.round(by * preview.height),
                    width: Math.round(bw * preview.width),
                    height: Math.round(bh * preview.height),
                  })
                  .resize(faceThumbSize, faceThumbSize, { fit: 'cover' })
                  .jpeg({ quality: faceThumbQuality })
                  .toBuffer()
              }
              if (thumbnailBuffer) {
                const base64 = thumbnailBuffer.toString('base64')
                this.faceRepo.updateClusterThumbnail(clusterIds[ci], base64)
              }
            } catch (e) {
              console.warn('Thumbnail generation failed for cluster', clusterIds[ci], e)
            }
          }
        }
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
      try { await releaseDetector() } catch (e) { console.warn('Failed to release detector', e) }
      try { await releaseEncoder() } catch (e) { console.warn('Failed to release encoder', e) }
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
      thumbnailBase64: c.thumbnail_base64 ?? '',
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
