// packages/shared/src/protocol/face.ts
import type { WritebackOptions, WritebackItem } from './core'

export interface FkwAnalyzeParams {
  sessionId: string
  eps?: number
  minSamples?: number
  detectorPath?: string
  encoderPath?: string
}

export interface FkwCancelAnalysisParams {
  sessionId: string
}

export interface FkwClustersParams {
  sessionId: string
}

export interface FkwBindParams {
  sessionId: string
  clusterId: number
  roleName: string
  keywords: string[]
}

export interface FkwUnbindParams {
  sessionId: string
  clusterId: number
}

export interface FkwMergeParams {
  sessionId: string
  source: number
  target: number
}

export interface FkwRemoveMemberParams {
  sessionId: string
  clusterId: number
  photoId: string
}

export interface FkwPreviewParams {
  sessionId: string
  options?: WritebackOptions
}

export interface FkwWritebackParams {
  sessionId: string
  confirmed?: boolean
  items?: WritebackItem[]
}

export interface FkwConfirmSyncParams {
  sessionId: string
  confirmed?: boolean
}

export interface FkwConfirmCleanupParams {
  sessionId: string
  confirmed?: boolean
}

export interface FkwCleanupParams {
  sessionId: string
  confirmed?: boolean
}

export interface FaceObservation {
  id?: number
  photoId: string
  sessionId: string
  bboxX: number
  bboxY: number
  bboxW: number
  bboxH: number
  embedding: number[]
  confidence: number
}

export interface FaceCluster {
  id: number
  sessionId: string
  label: string
  size: number
  members: ClusterMember[]
  status: string
  binding?: BindingData
  thumbnailBase64?: string
  syncedToLibrary?: boolean
  matchedPersonId?: string
  matchConfidence?: number
}

export interface ClusterMember {
  photoId: string
  photoPath: string
  filename: string
  bbox: number[]
  confidence: number
}

export interface BindingData {
  clusterId: number
  roleName: string
  keywords: string[]
  notes?: string
}
