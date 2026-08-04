import 'reflect-metadata'
import { container as tsyringeContainer, injectable, inject } from 'tsyringe'

export { injectable, inject }

export const container = tsyringeContainer

export const DI_TOKENS = {
  DB: Symbol('Database'),

  PHOTO_REPO: Symbol('PhotoRepository'),
  ASSET_REPO: Symbol('AssetRepository'),
  SESSION_REPO: Symbol('SessionRepository'),
  FACE_REPO: Symbol('FaceRepository'),
  PERSON_REPO: Symbol('PersonRepository'),
  CULLING_DECISION_REPO: Symbol('CullingDecisionRepository'),
  CULLING_HISTORY_REPO: Symbol('CullingHistoryRepository'),
  SIMILARITY_RESULT_REPO: Symbol('SimilarityResultRepository'),
  WRITEBACK_REPO: Symbol('WritebackRepository'),
  METADATA_OUTBOX_REPO: Symbol('MetadataOutboxRepository'),
  METADATA_CACHE_REPO: Symbol('MetadataCacheRepository'),
  METADATA_KEYWORD_ORIGIN_REPO: Symbol('MetadataKeywordOriginRepository'),
  SMART_ALBUM_REPO: Symbol('SmartAlbumRepository'),
  SETTINGS_REPO: Symbol('SettingsRepository'),

  SETTINGS_SERVICE: Symbol('SettingsService'),
  CULLING_SERVICE: Symbol('CullingService'),
  DUPLICATE_SERVICE: Symbol('DuplicateService'),
  EXPORT_SERVICE: Symbol('ExportService'),
  REPORT_SERVICE: Symbol('ReportService'),
  SESSION_SERVICE: Symbol('SessionService'),
  SIMILARITY_SERVICE: Symbol('SimilarityService'),
  FACE_KW_SERVICE: Symbol('FaceKwService'),
  METADATA_SERVICE: Symbol('MetadataService'),
  WRITEBACK_SERVICE: Symbol('WritebackService'),
  TEMPLATE_SERVICE: Symbol('TemplateService'),
  FILTER_ENGINE: Symbol('FilterEngine'),
  IMAGE_SERVICE: Symbol('ImageService'),
  METADATA_SYNC_COORDINATOR: Symbol('MetadataSyncCoordinator'),
  METADATA_MUTATION_SERVICE: Symbol('MetadataMutationService'),
  ANALYSIS_JOB_REPO: Symbol('AnalysisJobRepository'),
  JOB_SERVICE: Symbol('JobService'),
  INDEX_SERVICE: Symbol('IndexService'),
  QUALITY_SERVICE: Symbol('QualityService'),
  NAVIGATION_SERVICE: Symbol('NavigationService'),
  PHOTO_ASSET_RESOLVER: Symbol('PhotoAssetResolver'),

  WRITER_ROUTER: Symbol('MetadataWriterRouter'),
  THUMBNAIL_CACHE: Symbol('TieredThumbnailCache'),
  IMAGE_DECODERS: Symbol('ImageDecoders'),
}
