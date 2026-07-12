// packages/shared/src/protocol.ts
// 向后兼容的 re-export barrel —— 拆分到 protocol/ 下各个领域模块

export {
  SessionStatus,
  AnalysisStatus,
  WritebackStatus,
  ALLOWED_COMMANDS,
  DESTRUCTIVE_COMMANDS,
  ALLOWED_EVENTS,
  isRecord,
} from './protocol/core'
export type {
  ResponseOk,
  ResponseErr,
  Response,
  Command,
  Event,
  ProgressData,
  EngineStatusData,
  C1ImportData,
  C1PluginImportData,
  ExportProgressData,
  GroupData,
  WritebackOptions,
  WritebackPreview,
  WritebackItem,
  WritebackResult,
  CleanupResult,
  AddPhotoResult,
  ThumbnailGetParams,
  ImageGetPreviewParams,
  ImageGetThumbnailParams,
  ImagePreviewResult,
} from './protocol/core'

export type {
  SessionCreateParams,
  SessionDeleteParams,
  SessionDeleteManyParams,
  SessionAddPhotosParams,
  SessionGetParams,
  SessionUpdateParams,
  SessionData,
  PhotoData,
} from './protocol/session'

export type {
  FkwAnalyzeParams,
  FkwCancelAnalysisParams,
  FkwClustersParams,
  FkwBindParams,
  FkwUnbindParams,
  FkwMergeParams,
  FkwRemoveMemberParams,
  FkwPreviewParams,
  FkwWritebackParams,
  FkwConfirmSyncParams,
  FkwConfirmCleanupParams,
  FkwCleanupParams,
  FaceObservation,
  FaceCluster,
  ClusterMember,
  BindingData,
} from './protocol/face'

export type {
  SimAnalyzeParams,
  SimCancelAnalysisParams,
  SimResultParams,
  SimReclusterParams,
  SimPreviewWritebackParams,
  SimWritebackParams,
  SimWritebackItemsParams,
  SimRetryFailedWritebackParams,
  SimilarityGroup,
  SimilarityImage,
} from './protocol/similarity'

export type {
  PersonListParams,
  PersonGetParams,
  PersonCreateParams,
  PersonUpdateParams,
  PersonDeleteParams,
  PersonMergeParams,
  PersonRemovePhotoParams,
  PersonSearchPhotosParams,
  PersonData,
  PersonDetailData,
  PersonPhotoItem,
} from './protocol/person'

export type {
  MetadataGetParams,
  MetadataSetParams,
  MetadataBatchSetParams,
  MetadataTags,
  BatchMetadataResult,
} from './protocol/metadata'

export type {
  DupScanParams,
  DupGroupsParams,
  DupResolveParams,
  DupResolveMemberParams,
  DupScanOptions,
  DuplicateScanResult,
  DuplicateGroup,
  DuplicateGroupMember,
} from './protocol/duplicate'

export type {
  FilterPhotosParams,
  FilterPhotosGlobalParams,
  FilterSuggestParams,
  AlbumCreateParams,
  AlbumListParams,
  AlbumGetParams,
  AlbumUpdateParams,
  AlbumDeleteParams,
  AlbumGetPhotosParams,
  FilterRule,
  FilterGroup,
  FilterSuggestion,
  GlobalPhotoResult,
  SmartAlbumData,
  SmartAlbumDetailData,
} from './protocol/filter'

export type {
  ExportPreviewParams,
  ExportExecuteParams,
  ExportCancelParams,
  ExportReportParams,
  ExportOptions,
  ExportPreview,
  ExportResult,
  ExportProgressEvent,
  ReportData,
} from './protocol/export'

export type {
  TemplateCreateParams,
  TemplateListParams,
  TemplateGetParams,
  TemplateUpdateParams,
  TemplateDeleteParams,
  TemplateApplyParams,
  WorkflowTemplateConfig,
  TemplateData,
} from './protocol/template'

export type {
  CullingGroupsParams,
  CullingDecideParams,
  CullingBatchDecideParams,
  CullingSummaryParams,
  CullingWritebackParams,
  CullingResetParams,
  CullingGroup,
  CullingImage,
  CullingSummary,
} from './protocol/culling'

export type {
  HistoryListParams,
  HistoryUndoParams,
  HistoryRedoParams,
  HistoryCanUndoParams,
  HistoryCanRedoParams,
  OperationLogEntry,
  UndoStatus,
  RedoStatus,
} from './protocol/history'
