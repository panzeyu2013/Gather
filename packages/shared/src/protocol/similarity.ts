// packages/shared/src/protocol/similarity.ts

export type SimilarityGroupingMode = 'sequential' | 'global'

export interface SimAnalyzeParams {
  sessionId: string
  threshold?: number
  minGroupSize?: number
  groupingMode?: SimilarityGroupingMode
}

export interface SimCancelAnalysisParams {
  sessionId: string
}

export interface SimResultParams {
  sessionId: string
  threshold?: number
}

export interface SimReclusterParams {
  sessionId: string
  threshold?: number
  minGroupSize?: number
  groupingMode?: SimilarityGroupingMode
}

export interface SimilarityKeywordAssignment {
  groupId: number
  keywords: string[]
}

export interface SimPreviewWritebackParams {
  sessionId: string
  assignments: SimilarityKeywordAssignment[]
  threshold?: number
}

export interface SimWritebackParams {
  sessionId: string
  itemIds: number[]
  confirmed: boolean
  threshold?: number
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

// Stats carried by the similarity result rows; `precomputed` marks rows
// produced by the neighbor-threshold tier precomputation during analyze (their
// minGroupSize/groupingMode reflect the main analysis, not the draft settings).
export interface SimilarityResultStats {
  totalGroups: number
  totalUngrouped: number
  threshold: number
  minGroupSize: number
  groupingMode: SimilarityGroupingMode
  precomputed?: boolean
}
