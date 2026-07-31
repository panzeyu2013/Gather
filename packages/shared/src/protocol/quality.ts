export interface QualityAnalyzeParams { sessionId: string; photoIds?: string[] }
export interface QualityGetParams { sessionId: string; photoIds?: string[] }

export interface QualityResult {
  photoId: string
  assetFileId?: string
  status: 'succeeded' | 'failed'
  errorMessage?: string
  qualityScore: number
  sharpness: number
  exposure: number
  subjectSharpness?: number
  faceQuality?: number
  closedEyeRisk?: number
  /** @deprecated Historical field; new heuristic results use closedEyeRisk. */
  closedEyeProbability?: number
  confidence?: number
  relativeRank?: number
  warnings: string[]
  modelId: string
  modelVersion: string
  inputFingerprint: string
  updatedAt: string
}
