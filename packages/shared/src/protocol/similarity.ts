// packages/shared/src/protocol/similarity.ts
import type { WritebackOptions, WritebackItem } from './core'

export interface SimAnalyzeParams {
  sessionId: string
  threshold?: number
  minGroupSize?: number
}

export interface SimCancelAnalysisParams {
  sessionId: string
}

export interface SimResultParams {
  sessionId: string
}

export interface SimReclusterParams {
  sessionId: string
  threshold?: number
  minGroupSize?: number
}

export interface SimPreviewWritebackParams {
  sessionId: string
  groupIds: Array<number | string>
  options: WritebackOptions
}

export interface SimWritebackParams {
  sessionId: string
  groupIds: Array<number | string>
  groups?: import('./core').GroupData[]
  options: WritebackOptions
  confirmed?: boolean
  items?: WritebackItem[]
}

export interface SimWritebackItemsParams {
  sessionId: string
}

export interface SimRetryFailedWritebackParams {
  sessionId: string
  confirmed?: boolean
}

export interface SimilarityGroup {
  id: number
  label: string
  count: number
  images: SimilarityImage[]
  thumbnailBase64?: string
}

export interface SimilarityImage {
  path: string
  representative?: boolean
}
