import { container, DI_TOKENS } from './container'

import { Database } from '../db/database'

import { PhotoRepository } from '../db/repositories/photo.repo'
import { SessionRepository } from '../db/repositories/session.repo'
import { FaceRepository } from '../db/repositories/face.repo'
import { PersonRepository } from '../db/repositories/person.repo'
import { CullingDecisionRepository } from '../db/repositories/culling-decision.repo'
import { SimilarityResultRepository } from '../db/repositories/similarity-result.repo'
import { WritebackRepository } from '../db/repositories/writeback.repo'
import { MetadataCacheRepository } from '../db/repositories/metadata-cache.repo'
import { SmartAlbumRepository } from '../db/repositories/smart-album.repo'
import { SettingsRepository } from '../db/repositories/settings.repo'
import { MetadataOutboxRepository } from '../db/repositories/metadata-outbox.repo'

import { SettingsService } from '../services/settings/settings.service'
import { CullingService } from '../services/culling/culling.service'
import { DuplicateService } from '../services/duplicate/duplicate.service'
import { ExportService } from '../services/export/export.service'
import { ReportService } from '../services/export/report.service'
import { SessionService } from '../services/session/session.service'
import { SimilarityService } from '../services/similarity/similarity.service'
import { FaceKwService } from '../services/face-kw/face-kw.service'
import { MetadataService } from '../services/metadata/metadata.service'
import { WritebackService } from '../services/writeback/writeback.service'
import { TemplateService } from '../services/template/template.service'
import { FilterEngine } from '../services/filter/filter-engine'
import { ImageService, TieredThumbnailCache } from '../services/image'
import { MetadataWriterRouter } from '../services/xmp/metadata-writer-router'
import { MetadataSyncCoordinator } from '../services/metadata/metadata-sync-coordinator'

let initialized = false

export function initContainer(): void {
  if (initialized) return
  initialized = true
  container.registerSingleton(DI_TOKENS.DB, Database)

  container.registerSingleton(DI_TOKENS.PHOTO_REPO, PhotoRepository)
  container.registerSingleton(DI_TOKENS.SESSION_REPO, SessionRepository)
  container.registerSingleton(DI_TOKENS.FACE_REPO, FaceRepository)
  container.registerSingleton(DI_TOKENS.PERSON_REPO, PersonRepository)
  container.registerSingleton(DI_TOKENS.CULLING_DECISION_REPO, CullingDecisionRepository)
  container.registerSingleton(DI_TOKENS.SIMILARITY_RESULT_REPO, SimilarityResultRepository)
  container.registerSingleton(DI_TOKENS.WRITEBACK_REPO, WritebackRepository)
  container.registerSingleton(DI_TOKENS.METADATA_OUTBOX_REPO, MetadataOutboxRepository)
  container.registerSingleton(DI_TOKENS.METADATA_CACHE_REPO, MetadataCacheRepository)
  container.registerSingleton(DI_TOKENS.SMART_ALBUM_REPO, SmartAlbumRepository)
  container.registerSingleton(DI_TOKENS.SETTINGS_REPO, SettingsRepository)

  container.registerSingleton(DI_TOKENS.SETTINGS_SERVICE, SettingsService)
  container.registerSingleton(DI_TOKENS.CULLING_SERVICE, CullingService)
  container.registerSingleton(DI_TOKENS.DUPLICATE_SERVICE, DuplicateService)
  container.registerSingleton(DI_TOKENS.IMAGE_SERVICE, ImageService)
  container.registerSingleton(DI_TOKENS.METADATA_SYNC_COORDINATOR, MetadataSyncCoordinator)
  container.registerSingleton(DI_TOKENS.EXPORT_SERVICE, ExportService)
  container.registerSingleton(DI_TOKENS.REPORT_SERVICE, ReportService)
  container.registerSingleton(DI_TOKENS.SESSION_SERVICE, SessionService)
  container.registerSingleton(DI_TOKENS.SIMILARITY_SERVICE, SimilarityService)
  container.registerSingleton(DI_TOKENS.FACE_KW_SERVICE, FaceKwService)
  container.registerSingleton(DI_TOKENS.METADATA_SERVICE, MetadataService)
  container.registerSingleton(DI_TOKENS.WRITEBACK_SERVICE, WritebackService)
  container.registerSingleton(DI_TOKENS.TEMPLATE_SERVICE, TemplateService)
  container.registerSingleton(DI_TOKENS.FILTER_ENGINE, FilterEngine)

  container.registerSingleton(DI_TOKENS.WRITER_ROUTER, MetadataWriterRouter)
  container.registerSingleton(DI_TOKENS.THUMBNAIL_CACHE, TieredThumbnailCache)
}

export function getService<T>(token: symbol): T {
  return container.resolve<T>(token)
}
