import { container, DI_TOKENS } from './container'

import { Database } from '../db/database'

import { PhotoRepository } from '../db/repositories/photo.repo'
import { AssetRepository } from '../db/repositories/asset.repo'
import { SessionRepository } from '../db/repositories/session.repo'
import { FaceRepository } from '../db/repositories/face.repo'
import { PersonRepository } from '../db/repositories/person.repo'
import { CullingDecisionRepository } from '../db/repositories/culling-decision.repo'
import { CullingHistoryRepository } from '../db/repositories/culling-history.repo'
import { SimilarityResultRepository } from '../db/repositories/similarity-result.repo'
import { WritebackRepository } from '../db/repositories/writeback.repo'
import { MetadataCacheRepository } from '../db/repositories/metadata-cache.repo'
import { SmartAlbumRepository } from '../db/repositories/smart-album.repo'
import { SettingsRepository } from '../db/repositories/settings.repo'
import { MetadataOutboxRepository } from '../db/repositories/metadata-outbox.repo'
import { MetadataKeywordOriginRepository } from '../db/repositories/metadata-keyword-origin.repo'

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
import { SharpDecoder } from '../services/image/decoders/sharp-decoder'
import { SipsDecoder } from '../services/image/decoders/sips-decoder'
import type { ImageDecoder } from '../services/image/decoder'
import { MetadataWriterRouter } from '../services/xmp/metadata-writer-router'
import { MetadataSyncCoordinator } from '../services/metadata/metadata-sync-coordinator'
import { MetadataMutationService } from '../services/metadata/metadata-mutation.service'
import { AnalysisJobRepository } from '../db/repositories/analysis-job.repo'
import { JobService } from '../services/jobs/job.service'
import { IndexService } from '../services/indexer/index.service'
import { QualityService } from '../services/quality/quality.service'
import { NavigationService } from '../services/navigation/navigation.service'
import { PhotoAssetResolver } from '../services/assets/photo-asset-resolver'
import { CaptureOneSyncState } from '../services/capture-one/sync-state'
import { WorkspaceStatusService } from '../services/workspace/workspace-status.service'

let initialized = false

export function initContainer(): void {
  if (initialized) return
  initialized = true
  container.registerSingleton(DI_TOKENS.DB, Database)

  container.registerSingleton(DI_TOKENS.PHOTO_REPO, PhotoRepository)
  container.registerSingleton(DI_TOKENS.ASSET_REPO, AssetRepository)
  container.registerSingleton(DI_TOKENS.SESSION_REPO, SessionRepository)
  container.registerSingleton(DI_TOKENS.FACE_REPO, FaceRepository)
  container.registerSingleton(DI_TOKENS.PERSON_REPO, PersonRepository)
  container.registerSingleton(DI_TOKENS.CULLING_DECISION_REPO, CullingDecisionRepository)
  container.registerSingleton(DI_TOKENS.CULLING_HISTORY_REPO, CullingHistoryRepository)
  container.registerSingleton(DI_TOKENS.SIMILARITY_RESULT_REPO, SimilarityResultRepository)
  container.registerSingleton(DI_TOKENS.WRITEBACK_REPO, WritebackRepository)
  container.registerSingleton(DI_TOKENS.METADATA_OUTBOX_REPO, MetadataOutboxRepository)
  container.registerSingleton(DI_TOKENS.METADATA_CACHE_REPO, MetadataCacheRepository)
  container.registerSingleton(DI_TOKENS.METADATA_KEYWORD_ORIGIN_REPO, MetadataKeywordOriginRepository)
  container.registerSingleton(DI_TOKENS.SMART_ALBUM_REPO, SmartAlbumRepository)
  container.registerSingleton(DI_TOKENS.SETTINGS_REPO, SettingsRepository)

  container.registerSingleton(DI_TOKENS.SETTINGS_SERVICE, SettingsService)
  container.registerSingleton(DI_TOKENS.CULLING_SERVICE, CullingService)
  container.registerSingleton(DI_TOKENS.DUPLICATE_SERVICE, DuplicateService)
  container.registerSingleton(DI_TOKENS.IMAGE_SERVICE, ImageService)
  container.registerSingleton(DI_TOKENS.METADATA_SYNC_COORDINATOR, MetadataSyncCoordinator)
  container.registerSingleton(DI_TOKENS.METADATA_MUTATION_SERVICE, MetadataMutationService)
  container.registerSingleton(DI_TOKENS.ANALYSIS_JOB_REPO, AnalysisJobRepository)
  container.registerSingleton(DI_TOKENS.JOB_SERVICE, JobService)
  container.registerSingleton(DI_TOKENS.INDEX_SERVICE, IndexService)
  container.registerSingleton(DI_TOKENS.QUALITY_SERVICE, QualityService)
  container.registerSingleton(DI_TOKENS.NAVIGATION_SERVICE, NavigationService)
  container.registerSingleton(DI_TOKENS.PHOTO_ASSET_RESOLVER, PhotoAssetResolver)
  container.registerSingleton(DI_TOKENS.CAPTURE_ONE_SYNC_STATE, CaptureOneSyncState)
  container.registerSingleton(DI_TOKENS.WORKSPACE_STATUS_SERVICE, WorkspaceStatusService)
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

  // Decoder composition lives at the composition root: sips is a macOS system
  // tool, so it is only available on darwin. The ImageService core stays
  // platform-agnostic and receives the finished list.
  container.register(DI_TOKENS.IMAGE_DECODERS, {
    useFactory: (c) => {
      const settings = c.resolve<SettingsService>(DI_TOKENS.SETTINGS_SERVICE)
      const decoders: ImageDecoder[] = [new SharpDecoder(settings)]
      if (process.platform === 'darwin') {
        decoders.push(new SipsDecoder())
      }
      return decoders
    },
  })
}

export function getService<T>(token: symbol): T {
  return container.resolve<T>(token)
}
