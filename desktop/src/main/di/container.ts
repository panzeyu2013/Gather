export class Container {
  private factories = new Map<symbol, () => unknown>()
  private instances = new Map<symbol, unknown>()

  register<T>(token: symbol, factory: () => T): void {
    this.factories.set(token, factory)
  }

  resolve<T>(token: symbol): T {
    if (!this.instances.has(token)) {
      const factory = this.factories.get(token)
      if (!factory) {
        throw new Error(`No factory registered for ${token.description ?? String(token)}`)
      }
      this.instances.set(token, factory())
    }
    return this.instances.get(token) as T
  }

  has(token: symbol): boolean {
    return this.factories.has(token)
  }

  reset(): void {
    this.instances.clear()
  }
}

export const DI_TOKENS = {
  // Repositories
  PHOTO_REPO: Symbol('PhotoRepository'),
  SESSION_REPO: Symbol('SessionRepository'),
  FACE_REPO: Symbol('FaceRepository'),
  PERSON_REPO: Symbol('PersonRepository'),
  CULLING_DECISION_REPO: Symbol('CullingDecisionRepository'),
  SIMILARITY_RESULT_REPO: Symbol('SimilarityResultRepository'),
  OPERATION_LOG_REPO: Symbol('OperationLogRepository'),
  WRITEBACK_REPO: Symbol('WritebackRepository'),
  METADATA_CACHE_REPO: Symbol('MetadataCacheRepository'),
  SMART_ALBUM_REPO: Symbol('SmartAlbumRepository'),

  // Services
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

  // Utilities
  XMP_WRITER: Symbol('XmpWriter'),
  THUMBNAIL_CACHE: Symbol('ThumbnailCache'),
}

export const container = new Container()
