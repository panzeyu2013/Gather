import 'reflect-metadata'
import { container as tsyringeContainer, injectable, inject } from 'tsyringe'

export { injectable, inject }

export const container = tsyringeContainer

export const DI_TOKENS = {
  DB: Symbol('Database'),

  PHOTO_REPO: Symbol('IPhotoRepository'),
  SESSION_REPO: Symbol('ISessionRepository'),
  FACE_REPO: Symbol('IFaceRepository'),
  PERSON_REPO: Symbol('IPersonRepository'),
  CULLING_DECISION_REPO: Symbol('ICullingDecisionRepository'),
  SIMILARITY_RESULT_REPO: Symbol('ISimilarityResultRepository'),
  OPERATION_LOG_REPO: Symbol('IOperationLogRepository'),
  WRITEBACK_REPO: Symbol('IWritebackRepository'),
  METADATA_CACHE_REPO: Symbol('IMetadataCacheRepository'),
  SMART_ALBUM_REPO: Symbol('ISmartAlbumRepository'),
  SETTINGS_REPO: Symbol('ISettingsRepository'),

  SETTINGS_SERVICE: Symbol('SettingsService'),
  CULLING_SERVICE: Symbol('CullingService'),
  DUPLICATE_SERVICE: Symbol('DuplicateService'),
  EXPORT_SERVICE: Symbol('ExportService'),
  REPORT_SERVICE: Symbol('ReportService'),
  HISTORY_SERVICE: Symbol('HistoryService'),
  SESSION_SERVICE: Symbol('SessionService'),
  SIMILARITY_SERVICE: Symbol('SimilarityService'),
  FACE_KW_SERVICE: Symbol('FaceKwService'),
  METADATA_SERVICE: Symbol('MetadataService'),
  WRITEBACK_SERVICE: Symbol('WritebackService'),
  TEMPLATE_SERVICE: Symbol('TemplateService'),
  FILTER_ENGINE: Symbol('FilterEngine'),
  IMAGE_SERVICE: Symbol('ImageService'),

  WRITER_ROUTER: Symbol('MetadataWriterRouter'),
  THUMBNAIL_CACHE: Symbol('TieredThumbnailCache'),
}
