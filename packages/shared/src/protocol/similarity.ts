// packages/shared/src/protocol/similarity.ts

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

export interface SimilarityKeywordAssignment {
  groupId: number
  keywords: string[]
}

export interface SimPreviewWritebackParams {
  sessionId: string
  assignments: SimilarityKeywordAssignment[]
}

export interface SimWritebackParams {
  sessionId: string
  itemIds: number[]
  confirmed: boolean
}

export interface SimWritebackItemsParams {
  sessionId: string
}

export interface SimRetryFailedWritebackParams {
  sessionId: string
  confirmed: boolean
}

export interface SimConfirmSyncParams {
  sessionId: string
}

export interface SimCleanupParams {
  sessionId: string
  confirmed: boolean
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
