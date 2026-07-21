import { container, DI_TOKENS } from './di/container'

import { PhotoRepository } from './db/repositories/photo.repo'
import { SessionRepository } from './db/repositories/session.repo'
import { CullingDecisionRepository } from './db/repositories/culling-decision.repo'
import { SimilarityResultRepository } from './db/repositories/similarity-result.repo'
import { OperationLogRepository } from './db/repositories/operation-log.repo'
import { WritebackRepository } from './db/repositories/writeback.repo'
import { FaceRepository } from './db/repositories/face.repo'
import { MetadataCacheRepository } from './db/repositories/metadata-cache.repo'
import { PersonRepository } from './db/repositories/person.repo'
import { SmartAlbumRepository } from './db/repositories/smart-album.repo'

import { CullingService } from './services/culling/culling.service'
import { DuplicateService } from './services/duplicate/duplicate.service'
import { ExportService } from './services/export/export.service'
import { ReportService } from './services/export/report.service'
import { HistoryService } from './services/history/history.service'
import { SessionService } from './services/session/session.service'
import { SimilarityService } from './services/similarity/similarity.service'
import { FaceKwService } from './services/face-kw/face-kw.service'
import { MetadataService } from './services/metadata/metadata.service'
import { WritebackService } from './services/writeback/writeback.service'
import { TemplateService } from './services/template/template.service'
import { FilterEngine } from './services/filter/filter-engine'
import { ImageService, TieredThumbnailCache } from './services/image'
import { MetadataWriterRouter } from './services/xmp/metadata-writer-router'

export function getServices() {
  if (container.has(DI_TOKENS.PHOTO_REPO)) {
    return {
      cullingService: container.resolve<CullingService>(DI_TOKENS.CULLING_SERVICE),
      duplicateService: container.resolve<DuplicateService>(DI_TOKENS.DUPLICATE_SERVICE),
      exportService: container.resolve<ExportService>(DI_TOKENS.EXPORT_SERVICE),
      reportService: container.resolve<ReportService>(DI_TOKENS.REPORT_SERVICE),
      historyService: container.resolve<HistoryService>(DI_TOKENS.HISTORY_SERVICE),
      sessionService: container.resolve<SessionService>(DI_TOKENS.SESSION_SERVICE),
      similarityService: container.resolve<SimilarityService>(DI_TOKENS.SIMILARITY_SERVICE),
      faceKwService: container.resolve<FaceKwService>(DI_TOKENS.FACE_KW_SERVICE),
      metadataService: container.resolve<MetadataService>(DI_TOKENS.METADATA_SERVICE),
      writebackService: container.resolve<WritebackService>(DI_TOKENS.WRITEBACK_SERVICE),
      templateService: container.resolve<TemplateService>(DI_TOKENS.TEMPLATE_SERVICE),
      filterEngine: container.resolve<FilterEngine>(DI_TOKENS.FILTER_ENGINE),
      imageService: container.resolve<ImageService>(DI_TOKENS.IMAGE_SERVICE),

      photoRepo: container.resolve<PhotoRepository>(DI_TOKENS.PHOTO_REPO),
      sessionRepo: container.resolve<SessionRepository>(DI_TOKENS.SESSION_REPO),
      cullingDecisionRepo: container.resolve<CullingDecisionRepository>(DI_TOKENS.CULLING_DECISION_REPO),
      similarityResultRepo: container.resolve<SimilarityResultRepository>(DI_TOKENS.SIMILARITY_RESULT_REPO),
      operationLogRepo: container.resolve<OperationLogRepository>(DI_TOKENS.OPERATION_LOG_REPO),
      writebackRepo: container.resolve<WritebackRepository>(DI_TOKENS.WRITEBACK_REPO),
      faceRepo: container.resolve<FaceRepository>(DI_TOKENS.FACE_REPO),
      metadataCacheRepo: container.resolve<MetadataCacheRepository>(DI_TOKENS.METADATA_CACHE_REPO),
      personRepo: container.resolve<PersonRepository>(DI_TOKENS.PERSON_REPO),
      smartAlbumRepo: container.resolve<SmartAlbumRepository>(DI_TOKENS.SMART_ALBUM_REPO),
    }
  }

  const photoRepo = new PhotoRepository()
  const sessionRepo = new SessionRepository()
  const cullingDecisionRepo = new CullingDecisionRepository()
  const similarityResultRepo = new SimilarityResultRepository()
  const operationLogRepo = new OperationLogRepository()
  const writebackRepo = new WritebackRepository()
  const faceRepo = new FaceRepository()
  const metadataCacheRepo = new MetadataCacheRepository()
  const personRepo = new PersonRepository()
  const smartAlbumRepo = new SmartAlbumRepository()

  const writerRouter = new MetadataWriterRouter()
  const thumbnailCache = new TieredThumbnailCache()
  const imageService = new ImageService(thumbnailCache)

  container.register(DI_TOKENS.PHOTO_REPO, () => photoRepo)
  container.register(DI_TOKENS.SESSION_REPO, () => sessionRepo)
  container.register(DI_TOKENS.CULLING_DECISION_REPO, () => cullingDecisionRepo)
  container.register(DI_TOKENS.SIMILARITY_RESULT_REPO, () => similarityResultRepo)
  container.register(DI_TOKENS.OPERATION_LOG_REPO, () => operationLogRepo)
  container.register(DI_TOKENS.WRITEBACK_REPO, () => writebackRepo)
  container.register(DI_TOKENS.FACE_REPO, () => faceRepo)
  container.register(DI_TOKENS.METADATA_CACHE_REPO, () => metadataCacheRepo)
  container.register(DI_TOKENS.PERSON_REPO, () => personRepo)
  container.register(DI_TOKENS.SMART_ALBUM_REPO, () => smartAlbumRepo)
  container.register(DI_TOKENS.WRITER_ROUTER, () => writerRouter)
  container.register(DI_TOKENS.THUMBNAIL_CACHE, () => thumbnailCache)
  container.register(DI_TOKENS.IMAGE_SERVICE, () => imageService)
  container.register(DI_TOKENS.CULLING_SERVICE, () => new CullingService(photoRepo, cullingDecisionRepo, similarityResultRepo))
  container.register(DI_TOKENS.DUPLICATE_SERVICE, () => new DuplicateService())
  container.register(DI_TOKENS.EXPORT_SERVICE, () => new ExportService())
  container.register(DI_TOKENS.REPORT_SERVICE, () => new ReportService())
  container.register(DI_TOKENS.HISTORY_SERVICE, () => new HistoryService(operationLogRepo))
  container.register(DI_TOKENS.SESSION_SERVICE, () => new SessionService(sessionRepo, photoRepo, faceRepo))
  container.register(DI_TOKENS.SIMILARITY_SERVICE, () => new SimilarityService(photoRepo, sessionRepo))
  container.register(DI_TOKENS.FACE_KW_SERVICE, () => new FaceKwService(photoRepo, sessionRepo, faceRepo, imageService))
  container.register(DI_TOKENS.METADATA_SERVICE, () => new MetadataService(metadataCacheRepo, writerRouter))
  container.register(DI_TOKENS.WRITEBACK_SERVICE, () => new WritebackService(writebackRepo, writerRouter, photoRepo, sessionRepo))
  container.register(DI_TOKENS.TEMPLATE_SERVICE, () => new TemplateService())
  container.register(DI_TOKENS.FILTER_ENGINE, () => new FilterEngine())

  return {
    cullingService: container.resolve<CullingService>(DI_TOKENS.CULLING_SERVICE),
    duplicateService: container.resolve<DuplicateService>(DI_TOKENS.DUPLICATE_SERVICE),
    exportService: container.resolve<ExportService>(DI_TOKENS.EXPORT_SERVICE),
    reportService: container.resolve<ReportService>(DI_TOKENS.REPORT_SERVICE),
    historyService: container.resolve<HistoryService>(DI_TOKENS.HISTORY_SERVICE),
    sessionService: container.resolve<SessionService>(DI_TOKENS.SESSION_SERVICE),
    similarityService: container.resolve<SimilarityService>(DI_TOKENS.SIMILARITY_SERVICE),
    faceKwService: container.resolve<FaceKwService>(DI_TOKENS.FACE_KW_SERVICE),
    metadataService: container.resolve<MetadataService>(DI_TOKENS.METADATA_SERVICE),
    writebackService: container.resolve<WritebackService>(DI_TOKENS.WRITEBACK_SERVICE),
    templateService: container.resolve<TemplateService>(DI_TOKENS.TEMPLATE_SERVICE),
    filterEngine: container.resolve<FilterEngine>(DI_TOKENS.FILTER_ENGINE),
    imageService: container.resolve<ImageService>(DI_TOKENS.IMAGE_SERVICE),

    photoRepo,
    sessionRepo,
    cullingDecisionRepo,
    similarityResultRepo,
    operationLogRepo,
    writebackRepo,
    faceRepo,
    metadataCacheRepo,
    personRepo,
    smartAlbumRepo,
  }
}
