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

import { XmpWriter } from './services/xmp/xmp-writer'

export interface Services {
  cullingService: CullingService
  duplicateService: DuplicateService
  exportService: ExportService
  reportService: ReportService
  historyService: HistoryService
  sessionService: SessionService
  similarityService: SimilarityService
  faceKwService: FaceKwService
  metadataService: MetadataService
  writebackService: WritebackService
  templateService: TemplateService
  filterEngine: FilterEngine
  imageService: ImageService

  photoRepo: PhotoRepository
  sessionRepo: SessionRepository
  cullingDecisionRepo: CullingDecisionRepository
  similarityResultRepo: SimilarityResultRepository
  operationLogRepo: OperationLogRepository
  writebackRepo: WritebackRepository
  faceRepo: FaceRepository
  metadataCacheRepo: MetadataCacheRepository
  personRepo: PersonRepository
  smartAlbumRepo: SmartAlbumRepository
}

let servicesInstance: Services | null = null

export function getServices(): Services {
  if (!servicesInstance) {
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

    const xmpWriter = new XmpWriter()
    const thumbnailCache = new TieredThumbnailCache()
    const imageService = new ImageService(thumbnailCache)

    servicesInstance = {
      cullingService: new CullingService(photoRepo, cullingDecisionRepo, similarityResultRepo),
      duplicateService: new DuplicateService(),
      exportService: new ExportService(),
      reportService: new ReportService(),
      historyService: new HistoryService(operationLogRepo),
      sessionService: new SessionService(sessionRepo, photoRepo),
      similarityService: new SimilarityService(photoRepo, sessionRepo),
      faceKwService: new FaceKwService(photoRepo, sessionRepo, faceRepo, imageService),
      metadataService: new MetadataService(metadataCacheRepo, xmpWriter),
      writebackService: new WritebackService(writebackRepo, xmpWriter, photoRepo, sessionRepo),
      templateService: new TemplateService(),
      filterEngine: new FilterEngine(),
      imageService,

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
  return servicesInstance
}
