// packages/shared/src/protocol/core.ts
// 核心类型：响应类型、Command/Event 联合类型、白名单、状态枚举

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

// ── 共享的 writeback / cleanup 类型 ──

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
  photoPath: string
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

// ── 缩略图 / 图片相关参数类型 ──

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

export interface ImagePreloadThumbnailsParams {
  paths: string[]
  size?: number
}

export interface ImagePreviewResult {
  buffer: string
  width: number
  height: number
  format: string
}

// ── 事件数据类型 ──

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

export interface ExportProgressData {
  sessionId: string
  current: number
  total: number
  fileName: string
  bytesWritten: number
  status: string
  errorMessage?: string
}

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

// ── 导入子模块类型（仅类型，用于 Command 联合）──

import type { SessionCreateParams, SessionDeleteParams, SessionDeleteManyParams, SessionAddPhotosParams, SessionGetParams, SessionUpdateParams } from './session'
import type { FkwAnalyzeParams, FkwCancelAnalysisParams, FkwClustersParams, FkwBindParams, FkwUnbindParams, FkwMergeParams, FkwRemoveMemberParams, FkwPreviewParams, FkwWritebackParams, FkwConfirmSyncParams, FkwConfirmCleanupParams, FkwCleanupParams, FkwGetClusterThumbnailParams } from './face'
import type { SimAnalyzeParams, SimCancelAnalysisParams, SimResultParams, SimReclusterParams, SimPreviewWritebackParams, SimWritebackParams, SimWritebackItemsParams, SimRetryFailedWritebackParams } from './similarity'
import type { PersonListParams, PersonGetParams, PersonCreateParams, PersonUpdateParams, PersonDeleteParams, PersonMergeParams, PersonRemovePhotoParams, PersonSearchPhotosParams } from './person'
import type { MetadataGetParams, MetadataSetParams, MetadataBatchSetParams } from './metadata'
import type { DupScanParams, DupGroupsParams, DupResolveParams, DupResolveMemberParams } from './duplicate'
import type { FilterPhotosParams, FilterPhotosGlobalParams, FilterSuggestParams, AlbumCreateParams, AlbumListParams, AlbumGetParams, AlbumUpdateParams, AlbumDeleteParams, AlbumGetPhotosParams } from './filter'
import type { ExportPreviewParams, ExportExecuteParams, ExportCancelParams, ExportReportParams } from './export'
import type { TemplateCreateParams, TemplateListParams, TemplateGetParams, TemplateUpdateParams, TemplateDeleteParams, TemplateApplyParams } from './template'
import type { CullingGroupsParams, CullingDecideParams, CullingBatchDecideParams, CullingSummaryParams, CullingWritebackParams, CullingResetParams } from './culling'
import type { HistoryListParams, HistoryUndoParams, HistoryRedoParams, HistoryCanUndoParams, HistoryCanRedoParams } from './history'

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
  | { type: 'fkw.get_cluster_thumbnail'; params: FkwGetClusterThumbnailParams }
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
  | { type: 'image.preload_thumbnails'; params: ImagePreloadThumbnailsParams }
  | { type: 'photo.list'; params: { sessionId: string } }
  | { type: 'settings.get_all'; params: Record<string, never> }
  | { type: 'settings.get'; params: { key: string } }
  | { type: 'settings.set'; params: { key: string; value: string } }
  | { type: 'settings.reset'; params: Record<string, never> }
  | { type: 'person.list'; params: PersonListParams }
  | { type: 'person.get'; params: PersonGetParams }
  | { type: 'person.create'; params: PersonCreateParams }
  | { type: 'person.update'; params: PersonUpdateParams }
  | { type: 'person.delete'; params: PersonDeleteParams }
  | { type: 'person.merge'; params: PersonMergeParams }
  | { type: 'person.remove_photo'; params: PersonRemovePhotoParams }
  | { type: 'person.search_photos'; params: PersonSearchPhotosParams }
  | { type: 'metadata.get'; params: MetadataGetParams }
  | { type: 'metadata.set'; params: MetadataSetParams }
  | { type: 'metadata.batch_set'; params: MetadataBatchSetParams }
  | { type: 'dup.scan'; params: DupScanParams }
  | { type: 'dup.groups'; params: DupGroupsParams }
  | { type: 'dup.resolve'; params: DupResolveParams }
  | { type: 'dup.resolve_member'; params: DupResolveMemberParams }
  | { type: 'filter.photos'; params: FilterPhotosParams }
  | { type: 'filter.photos_global'; params: FilterPhotosGlobalParams }
  | { type: 'filter.suggest'; params: FilterSuggestParams }
  | { type: 'album.create'; params: AlbumCreateParams }
  | { type: 'album.list'; params: AlbumListParams }
  | { type: 'album.get'; params: AlbumGetParams }
  | { type: 'album.update'; params: AlbumUpdateParams }
  | { type: 'album.delete'; params: AlbumDeleteParams }
  | { type: 'album.get_photos'; params: AlbumGetPhotosParams }
  | { type: 'export.preview'; params: ExportPreviewParams }
  | { type: 'export.execute'; params: ExportExecuteParams }
  | { type: 'export.cancel'; params: ExportCancelParams }
  | { type: 'export.report'; params: ExportReportParams }
  | { type: 'template.create'; params: TemplateCreateParams }
  | { type: 'template.list'; params: TemplateListParams }
  | { type: 'template.get'; params: TemplateGetParams }
  | { type: 'template.update'; params: TemplateUpdateParams }
  | { type: 'template.delete'; params: TemplateDeleteParams }
  | { type: 'template.apply'; params: TemplateApplyParams }
  | { type: 'culling.groups'; params: CullingGroupsParams }
  | { type: 'culling.decide'; params: CullingDecideParams }
  | { type: 'culling.batch_decide'; params: CullingBatchDecideParams }
  | { type: 'culling.summary'; params: CullingSummaryParams }
  | { type: 'culling.writeback'; params: CullingWritebackParams }
  | { type: 'culling.reset'; params: CullingResetParams }
  | { type: 'history.list'; params: HistoryListParams }
  | { type: 'history.undo'; params: HistoryUndoParams }
  | { type: 'history.redo'; params: HistoryRedoParams }
  | { type: 'history.can_undo'; params: HistoryCanUndoParams }
  | { type: 'history.can_redo'; params: HistoryCanRedoParams }

// ── 事件联合类型 ──

export type Event =
  | { type: 'progress'; data: ProgressData }
  | { type: 'engine:status'; data: EngineStatusData }
  | { type: 'c1:import-trigger'; data: C1ImportData }
  | { type: 'c1:plugin-import'; data: C1PluginImportData }
  | { type: 'export:progress'; data: ExportProgressData }

// ── 命令白名单 ──

export const ALLOWED_COMMANDS = new Set([
  'session.create', 'session.delete', 'session.delete_many', 'session.list', 'session.get', 'session.update', 'session.add_photos',
  'fkw.analyze', 'fkw.cancel_analysis', 'fkw.clusters', 'fkw.bind', 'fkw.unbind', 'fkw.merge',
  'fkw.remove_member', 'fkw.get_cluster_thumbnail', 'fkw.preview', 'fkw.writeback', 'fkw.confirm_sync', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.analyze', 'sim.cancel_analysis', 'sim.result', 'sim.recluster', 'sim.preview_writeback', 'sim.writeback',
  'sim.retry_failed_writeback', 'sim.writeback_items',
  'thumbnail.get', 'image.get_preview', 'image.get_thumbnail', 'image.preload_thumbnails',
  'photo.list',
  'settings.get_all', 'settings.get', 'settings.set', 'settings.reset',
  'person.list', 'person.get', 'person.create', 'person.update', 'person.delete', 'person.merge', 'person.remove_photo', 'person.search_photos',
  'metadata.get', 'metadata.set', 'metadata.batch_set',
  'dup.scan', 'dup.groups', 'dup.resolve', 'dup.resolve_member',
  'filter.photos', 'filter.photos_global', 'filter.suggest',
  'album.create', 'album.list', 'album.get', 'album.update', 'album.delete', 'album.get_photos',
  'export.preview', 'export.execute', 'export.cancel', 'export.report',
  'template.create', 'template.list', 'template.get', 'template.update', 'template.delete', 'template.apply',
  'culling.groups', 'culling.decide', 'culling.batch_decide', 'culling.summary', 'culling.writeback', 'culling.reset',
  'history.list', 'history.undo', 'history.redo', 'history.can_undo', 'history.can_redo',
])

export const DESTRUCTIVE_COMMANDS = new Set([
  'session.delete', 'session.delete_many',
  'fkw.writeback', 'fkw.cleanup', 'fkw.confirm_cleanup',
  'sim.writeback', 'sim.retry_failed_writeback',
  'person.delete', 'person.merge', 'person.remove_photo',
  'dup.resolve', 'dup.resolve_member',
  'culling.writeback', 'culling.reset',
  'metadata.set', 'metadata.batch_set',
  'template.delete',
  'history.undo',
  'album.delete',
  'export.execute', 'template.apply',
])

export const ALLOWED_EVENTS = new Set([
  'progress',
  'engine:status',
  'c1:import-trigger',
  'c1:plugin-import',
  'export:progress',
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
