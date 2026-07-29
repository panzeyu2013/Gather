import 'reflect-metadata'
import { container as tsyringeContainer, injectable, inject } from 'tsyringe'

export { injectable, inject }

export const container = tsyringeContainer

export const DI_TOKENS = {
  DB: Symbol('Database'),

  PHOTO_REPO: Symbol('PhotoRepository'),
  SESSION_REPO: Symbol('SessionRepository'),
  FACE_REPO: Symbol('FaceRepository'),
  PERSON_REPO: Symbol('PersonRepository'),
  CULLING_DECISION_REPO: Symbol('CullingDecisionRepository'),
  SIMILARITY_RESULT_REPO: Symbol('SimilarityResultRepository'),
  WRITEBACK_REPO: Symbol('WritebackRepository'),
  METADATA_CACHE_REPO: Symbol('MetadataCacheRepository'),
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

  WRITER_ROUTER: Symbol('MetadataWriterRouter'),
  THUMBNAIL_CACHE: Symbol('TieredThumbnailCache'),
}
