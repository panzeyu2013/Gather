// packages/shared/src/protocol.ts
// 主进程和渲染进程共享的类型定义 — 编译时类型检查

// ── Status enums ──

export const SessionStatus = {
  DRAFT: 'draft',
  PHOTOS_LOADED: 'photos_loaded',
  ANALYZING: 'analyzing',
  REVIEW: 'review',
  COMPLETED: 'completed',
} as const
export type SessionStatus = (typeof SessionStatus)[keyof typeof SessionStatus]

export const AnalysisStatus = {
  IDLE: 'idle',
  RUNNING: 'running',
  DONE: 'done',
  FAILED: 'failed',
  CANCELLED: 'cancelled',
} as const
export type AnalysisStatus = (typeof AnalysisStatus)[keyof typeof AnalysisStatus]

export const WritebackStatus = {
  IDLE: 'idle',
  RUNNING: 'running',
  DONE: 'done',
  PARTIAL: 'partial',
  CLEANED: 'cleaned',
} as const
export type WritebackStatus = (typeof WritebackStatus)[keyof typeof WritebackStatus]

// ── 参数类型 ──

export interface SessionCreateParams {
  name: string
  filepaths?: string[]
  source?: string
}

export interface SessionDeleteParams {
  sessionId: string
  confirmed: boolean
}

export interface SessionDeleteManyParams {
  sessionIds: string[]
  confirmed: boolean
}

export interface SessionAddPhotosParams {
  sessionId: string
  filepaths: string[]
  source?: string
}

export interface SessionGetParams {
  sessionId: string
}

export interface SessionUpdateParams {
  sessionId: string
  name: string
}

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
  groups?: GroupData[]
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

export interface ThumbnailGetParams {
  path: string
  bbox?: number[]
  source?: string
}

export interface ImageGetPreviewParams {
  path: string
  maxDimension?: number
}

export interface ImageGetThumbnailParams {
  path: string
  size?: number
}

export interface ImagePreviewResult {
  buffer: string
  width: number
  height: number
  format: string
}

// ── 命令联合类型 ──

export type Command =
  | { type: 'session.create'; params: SessionCreateParams }
  | { type: 'session.list'; params: Record<string, never> }
  | { type: 'session.delete'; params: SessionDeleteParams }
  | { type: 'session.delete_many'; params: SessionDeleteManyParams }
  | { type: 'session.add_photos'; params: SessionAddPhotosParams }
  | { type: 'session.get'; params: SessionGetParams }
  | { type: 'session.update'; params: SessionUpdateParams }
  | { type: 'fkw.analyze'; params: FkwAnalyzeParams }
  | { type: 'fkw.cancel_analysis'; params: FkwCancelAnalysisParams }
  | { type: 'fkw.clusters'; params: FkwClustersParams }
  | { type: 'fkw.bind'; params: FkwBindParams }
  | { type: 'fkw.unbind'; params: FkwUnbindParams }
  | { type: 'fkw.merge'; params: FkwMergeParams }
  | { type: 'fkw.remove_member'; params: FkwRemoveMemberParams }
  | { type: 'fkw.preview'; params: FkwPreviewParams }
  | { type: 'fkw.writeback'; params: FkwWritebackParams }
  | { type: 'fkw.confirm_sync'; params: FkwConfirmSyncParams }
  | { type: 'fkw.confirm_cleanup'; params: FkwConfirmCleanupParams }
  | { type: 'fkw.cleanup'; params: FkwCleanupParams }
  | { type: 'sim.analyze'; params: SimAnalyzeParams }
  | { type: 'sim.cancel_analysis'; params: SimCancelAnalysisParams }
  | { type: 'sim.result'; params: SimResultParams }
  | { type: 'sim.recluster'; params: SimReclusterParams }
  | { type: 'sim.preview_writeback'; params: SimPreviewWritebackParams }
  | { type: 'sim.writeback'; params: SimWritebackParams }
  | { type: 'sim.writeback_items'; params: SimWritebackItemsParams }
  | { type: 'sim.retry_failed_writeback'; params: SimRetryFailedWritebackParams }
  | { type: 'thumbnail.get'; params: ThumbnailGetParams }
  | { type: 'image.get_preview'; params: ImageGetPreviewParams }
  | { type: 'image.get_thumbnail'; params: ImageGetThumbnailParams }
  | { type: 'photo.list'; params: { sessionId: string } }
  | { type: 'settings.get_all'; params: Record<string, never> }
  | { type: 'settings.get'; params: { key: string } }
  | { type: 'settings.set'; params: { key: string; value: string } }
  | { type: 'settings.reset'; params: Record<string, never> }

// ── 事件联合类型 ──

export interface ProgressData {
  sessionId: string
  current: number
  total: number
  message: string
  status?: AnalysisStatus
}

export interface EngineStatusData {
  status: 'connecting' | 'ready' | 'disconnected'
  version?: string
}

export interface C1ImportData {
  photoCount: number
}

export interface C1PluginImportData {
  files: string[]
}

export type Event =
  | { type: 'progress'; data: ProgressData }
  | { type: 'engine:status'; data: EngineStatusData }
  | { type: 'c1:import-trigger'; data: C1ImportData }
  | { type: 'c1:plugin-import'; data: C1PluginImportData }

// ── 响应 ──

export interface ResponseOk<T = unknown> {
  id?: number | string
  ok: true
  data: T
}

export interface ResponseErr {
  id?: number | string
  ok: false
  error: string | { type: string; message: string }
}

export type Response<T = unknown> = ResponseOk<T> | ResponseErr

// ── 数据类型 ──

export interface SessionData {
  id: string
  name: string
  status: SessionStatus
  photoCount: number
  analysisStatus: AnalysisStatus
  writebackStatus: WritebackStatus
  importSource: string
  failedWritebackCount: number
  createdAt: string
  updatedAt: string
}

export interface PhotoData {
  id: string
  sessionId: string
  filepath: string
  filename: string
  checksum: string
  hasExistingXmp: boolean
  faceCount: number
  width: number
  height: number
  metadata: Record<string, unknown>
  result: Record<string, unknown>
  status: string
  createdAt: string
  updatedAt: string
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

export interface WritebackPreview {
  items: WritebackItem[]
  totalCount: number
  affectedPhotos: number
}

export interface WritebackItem {
  id?: number
  photoId: string
  sessionId: string
  module: string
  keywords: string[]
  xmpPath: string
  backupPath: string
  xmpStatus: string
  errorMessage: string
  attemptCount: number
  lastAttemptAt: string
}

export interface WritebackResult {
  totalAffected: number
  written: number
  failed: number
  skipped: number
  errors: string[]
  failedItems: WritebackItem[]
  report: string
}

export interface CleanupResult {
  deletedCount: number
  errors: string[]
}

export interface AddPhotoResult {
  added: number
  skipped: number
  total: number
}

// ── 命令白名单（保留向后兼容）──

export const ALLOWED_COMMANDS = new Set([
  'session.create', 'session.delete', 'session.delete_many', 'session.list', 'session.get', 'session.update', 'session.add_photos',
  'fkw.analyze', 'fkw.cancel_analysis', 'fkw.clusters', 'fkw.bind', 'fkw.unbind', 'fkw.merge',
  'fkw.remove_member', 'fkw.preview', 'fkw.writeback', 'fkw.confirm_sync', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.analyze', 'sim.cancel_analysis', 'sim.result', 'sim.recluster', 'sim.preview_writeback', 'sim.writeback',
  'sim.retry_failed_writeback', 'sim.writeback_items',
  'thumbnail.get', 'image.get_preview', 'image.get_thumbnail',
  'photo.list',
  'settings.get_all', 'settings.get', 'settings.set', 'settings.reset',
])

export const DESTRUCTIVE_COMMANDS = new Set([
  'session.delete', 'session.delete_many',
  'fkw.writeback', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.writeback', 'sim.retry_failed_writeback',
])

export const ALLOWED_EVENTS = new Set([
  'progress',
  'engine:status',
  'c1:import-trigger',
  'c1:plugin-import',
])

// ── Guard 函数 ──

export function isRecord(value: unknown): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null)
  )
}
