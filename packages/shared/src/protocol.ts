// packages/shared/src/protocol.ts
// 主进程和渲染进程共享的类型定义 — 编译时类型检查

// ── Status enums (mirror Python shared/models.py) ──

export const AnalysisStatus = {
  IDLE: 'idle',
  RUNNING: 'running',
  DONE: 'done',
  FAILED: 'failed',
  CANCELLED: 'cancelled',
} as const
export type AnalysisStatus = (typeof AnalysisStatus)[keyof typeof AnalysisStatus]

export const SessionStatus = {
  DRAFT: 'draft',
  PHOTOS_LOADED: 'photos_loaded',
  ANALYZING: 'analyzing',
  REVIEW: 'review',
  COMPLETED: 'completed',
} as const
export type SessionStatus = (typeof SessionStatus)[keyof typeof SessionStatus]

export const WritebackStatus = {
  IDLE: 'idle',
  RUNNING: 'running',
  DONE: 'done',
  PARTIAL: 'partial',
  CLEANED: 'cleaned',
} as const
export type WritebackStatus = (typeof WritebackStatus)[keyof typeof WritebackStatus]

// ── 请求命令（Renderer → Main → Python）──

export interface SessionCreateCommand {
  type: 'session.create'
  name: string
}

export interface SessionDeleteCommand {
  type: 'session.delete'
  session_id: string
  confirmed?: boolean
}

export interface SessionListCommand {
  type: 'session.list'
}

export interface SessionAddPhotosCommand {
  type: 'session.add_photos'
  session_id: string
  filepaths: string[]
  source?: string
}

export interface SessionGetCommand {
  type: 'session.get'
  session_id: string
}

export interface SessionUpdateCommand {
  type: 'session.update'
  session_id: string
  name: string
}

export type SessionGetResponse = SessionData

export type SessionUpdateResponse = SessionData

export interface FkwAnalyzeCommand {
  type: 'fkw.analyze'
  session_id: string
  eps?: number
  min_samples?: number
}

export interface FkwCancelAnalysisCommand {
  type: 'fkw.cancel_analysis'
  session_id: string
}

export interface FkwClustersCommand {
  type: 'fkw.clusters'
  session_id: string
}

export interface FkwBindCommand {
  type: 'fkw.bind'
  session_id: string
  cluster_id: number
  role: string
  keywords: string[]
}

export interface FkwUnbindCommand {
  type: 'fkw.unbind'
  session_id: string
  cluster_id: number
}

export interface FkwMergeCommand {
  type: 'fkw.merge'
  session_id: string
  source: number
  target: number
}

export interface FkwRemoveMemberCommand {
  type: 'fkw.remove_member'
  session_id: string
  cluster_id: number
  photo_id: string
}

export interface FkwPreviewCommand {
  type: 'fkw.preview'
  session_id: string
}

export interface FkwWritebackCommand {
  type: 'fkw.writeback'
  session_id: string
  confirmed?: boolean
}

export interface FkwConfirmCleanupCommand {
  type: 'fkw.confirm_cleanup'
  session_id: string
  confirmed?: boolean
}

export interface FkwConfirmSyncCommand {
  type: 'fkw.confirm_sync'
  session_id: string
}

export interface FkwCleanupCommand {
  type: 'fkw.cleanup'
  session_id: string
  confirmed?: boolean
}

export interface SimAnalyzeCommand {
  type: 'sim.analyze'
  session_id: string
  threshold?: number
  min_group_size?: number
}

export interface SimCancelAnalysisCommand {
  type: 'sim.cancel_analysis'
  session_id: string
}

export interface SimResultCommand {
  type: 'sim.result'
  session_id: string
}

export interface SimReclusterCommand {
  type: 'sim.recluster'
  session_id: string
  threshold?: number
  min_group_size?: number
}

export interface SimWritebackCommand {
  type: 'sim.writeback'
  session_id: string
  group_ids: Array<number | string>
  groups?: GroupData[]
  options: WritebackOptions
  confirmed?: boolean
}

export interface SimWritebackItemsCommand {
  type: 'sim.writeback_items'
  session_id: string
}

export interface SimRetryFailedWritebackCommand {
  type: 'sim.retry_failed_writeback'
  session_id: string
  confirmed?: boolean
}

export interface SimPreviewWritebackCommand {
  type: 'sim.preview_writeback'
  session_id: string
  group_ids: Array<number | string>
  options: WritebackOptions
}

export interface ThumbnailGetCommand {
  type: 'thumbnail.get'
  path: string
  bbox?: number[]
  source?: string
}

export interface ShutdownCommand {
  type: 'shutdown'
}

export type Command =
  | SessionCreateCommand
  | SessionDeleteCommand
  | SessionListCommand
  | SessionAddPhotosCommand
  | SessionGetCommand
  | SessionUpdateCommand
  | FkwAnalyzeCommand
  | FkwCancelAnalysisCommand
  | FkwClustersCommand
  | FkwBindCommand
  | FkwUnbindCommand
  | FkwMergeCommand
  | FkwRemoveMemberCommand
  | FkwPreviewCommand
  | FkwWritebackCommand
  | FkwConfirmSyncCommand
  | FkwCleanupCommand
  | FkwConfirmCleanupCommand
  | SimAnalyzeCommand
  | SimCancelAnalysisCommand
  | SimResultCommand
  | SimReclusterCommand
  | SimPreviewWritebackCommand
  | SimWritebackCommand
  | SimWritebackItemsCommand
  | SimRetryFailedWritebackCommand
  | ThumbnailGetCommand
  | ShutdownCommand

// ── 响应 ──

export interface ResponseOk<T = unknown> {
  id: number | string
  ok: true
  data: T
}

export interface ResponseErr {
  id: number | string
  ok: false
  error: string | { type: string; message: string }
}

export type Response<T = unknown> = ResponseOk<T> | ResponseErr

// ── 事件（Python → Renderer，推送）──

export interface ProgressEvent {
  type: 'event'
  event: 'progress'
  data: {
    session_id: string
    current: number
    total: number
    message: string
    status?: AnalysisStatus
  }
}

export interface EngineReadyEvent {
  type: 'event'
  event: 'python:ready'
  version: string
}

export interface C1ImportTriggerEvent {
  type: 'event'
  event: 'c1:import-trigger'
}

export interface EngineDisconnectedEvent {
  type: 'event'
  event: 'python:disconnected'
  data: {
    code?: number | null
  }
}

export type EngineEvent = ProgressEvent | EngineReadyEvent | C1ImportTriggerEvent | EngineDisconnectedEvent

// ── 数据类型 ──

// NOTE: cluster_id is stored as int in the Python backend (SQLite auto-increment PK)
// and transmitted as number via msgpack.

export interface SessionData {
  id: string
  name: string
  status: SessionStatus
  photo_count?: number
  event_date: string
  analysis_status: AnalysisStatus
  writeback_status: WritebackStatus
  created_at: string
  updated_at: string
  import_source?: string
  failed_writeback_count?: number
}

export interface PhotoData {
  id: string
  session_id: string
  filepath: string
  checksum?: string
  status: string
  has_existing_xmp: boolean
  face_count: number
  metadata: Record<string, unknown>
  result: Record<string, unknown>
  created_at: string
  updated_at: string
}

export interface ClusterData {
  cluster_id: number
  label: string
  size: number
  members: ClusterMember[]
  status: string
  binding?: {
    role_name: string
    keywords: string[]
  }
  thumbnail_base64?: string
}

export interface ClusterMember {
  photo_id: string
  photo_path: string
  filename: string
  bbox: number[]
  confidence: number
}

export interface BindingData {
  cluster_id: number
  role_name: string
  keywords: string[]
  notes?: string
}

export interface SimilarityGroup {
  id: number
  label: string
  count: number
  images: SimilarityImage[]
  thumbnail_base64?: string
}

export interface SimilarityImage {
  path: string
  representative?: boolean
}

export interface GroupData {
  id: number | string
  images: { path: string }[]
  label?: string
}

export interface WritebackOptions {
  createAlbums?: boolean
  addPrefix?: boolean
  markUngrouped?: boolean
  writeIPTC?: boolean
}

export interface WritebackReport {
  report: string
  total_affected: number
  written?: number
  failed?: number
  skipped?: number
  errors?: string[]
}

export interface ThumbnailResponse {
  thumbnail_base64: string | null
}

export const ALLOWED_COMMANDS = new Set([
  'session.create', 'session.delete', 'session.list', 'session.get', 'session.update', 'session.add_photos',
  'fkw.analyze', 'fkw.cancel_analysis', 'fkw.clusters', 'fkw.bind', 'fkw.unbind', 'fkw.merge',
  'fkw.remove_member', 'fkw.preview', 'fkw.writeback', 'fkw.confirm_sync', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.analyze', 'sim.cancel_analysis', 'sim.result', 'sim.recluster', 'sim.preview_writeback', 'sim.writeback',
  'sim.retry_failed_writeback', 'sim.writeback_items',
  'thumbnail.get', 'shutdown',
])

export const DESTRUCTIVE_COMMANDS = new Set([
  'session.delete',
  'fkw.writeback', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.writeback', 'sim.retry_failed_writeback',
])

export const ALLOWED_EVENTS = new Set([
  'progress',
  'python:ready',
  'c1:import-trigger',
  'python:disconnected',
])

export function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)
  )
}
