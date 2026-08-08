// packages/shared/src/protocol/workspace.ts
// 工作区状态只读聚合（design_improvements.md 1.4.1–1.4.5）
// WorkspaceStatusService（主进程只读读模型）的 IPC 契约。

export type WorkspaceStage = 'created' | 'imported' | 'indexed' | 'analyzed'

export interface WorkspaceIndexingProgress {
  total: number
  done: number
  percent: number
  /** Live index-job state: 'active' while a metadata.scan job is
   * queued/running/cancelling, 'failed' after one failed, 'idle' otherwise
   * (settled success or never scanned). */
  status: 'idle' | 'active' | 'failed'
}

export interface WorkspaceStaleAnalysis {
  kind: 'similarity' | 'face'
  lastRunAt: string
}

export interface WorkspaceXmpCounts {
  pending: number
  conflict: number
}

export interface WorkspaceFailedJob {
  id: string
  type: string
  message: string
}

export interface WorkspaceRecommendedNext {
  action: string
  target: string
}

export interface WorkspaceStatus {
  sessionId: string
  stage: WorkspaceStage
  softFlags: { culled: boolean; exported: boolean }
  indexing: WorkspaceIndexingProgress
  staleAnalyses: WorkspaceStaleAnalysis[]
  xmp: WorkspaceXmpCounts
  offlinePhotos: number
  failedJobs: WorkspaceFailedJob[]
  recommendedNext: WorkspaceRecommendedNext | null
  generatedAt: string
}

export interface WorkspaceStatusParams {
  sessionId: string
}
