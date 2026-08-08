export type AnalysisJobType =
  | 'metadata.scan'
  | 'thumbnail.build'
  | 'similarity.analyze'
  | 'duplicate.scan'
  | 'face.analyze'
  | 'quality.score'
  | 'export.execute'
  | 'checksum.backfill'

export type AnalysisJobStatus =
  | 'queued'
  | 'running'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'interrupted'
  | 'cancelling'

export interface AnalysisJobData {
  id: string
  type: AnalysisJobType
  scopeType: string
  scopeId: string
  dedupeKey: string
  status: AnalysisJobStatus
  priority: number
  progressCurrent: number
  progressTotal: number
  progressMessage: string
  inputFingerprint: string
  modelId: string
  modelVersion: string
  checkpoint: Record<string, unknown>
  attemptCount: number
  leaseOwner: string
  heartbeatAt: string
  errorCode: string
  errorMessage: string
  createdAt: string
  startedAt: string
  finishedAt: string
  updatedAt: string
}

export interface JobCreateParams {
  type: AnalysisJobType
  scopeType: string
  scopeId: string
  dedupeKey: string
  priority?: number
  inputFingerprint?: string
  modelId?: string
  modelVersion?: string
  checkpoint?: Record<string, unknown>
}

export interface JobListParams { status?: AnalysisJobStatus }
export interface JobCancelParams { jobId: string }
export interface JobRetryParams { jobId: string }
export interface JobClearCompletedParams { confirmed: boolean }
export interface JobProgressUpdate {
  current?: number
  total?: number
  /** Stage code for the running job (design_improvements.md 4.4.2), e.g.
   * `index.scanning` / `similarity.cluster`. The main process never sends
   * natural-language progress copy; the renderer maps the code to copy. */
  phase?: string
  message?: string
  checkpoint?: Record<string, unknown>
}
