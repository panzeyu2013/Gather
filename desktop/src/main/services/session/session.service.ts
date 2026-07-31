import { Database } from '../../db/database'
import { SessionRepository } from '../../db/repositories/session.repo'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { FaceRepository } from '../../db/repositories/face.repo'
import { AssetRepository } from '../../db/repositories/asset.repo'
import type { ImageService } from '../image'
import { SettingsService } from '../settings/settings.service'
import type {
  SessionData,
  AddPhotoResult,
  SessionStatus,
  AnalysisStatus,
  WritebackStatus,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import path from 'path'

export function commonParentDirectory(filepaths: string[]): string {
  if (filepaths.length === 0) return ''
  const directories = filepaths.map((filepath) => path.dirname(path.resolve(filepath)))
  let candidate = directories[0]
  for (const directory of directories.slice(1)) {
    while (candidate !== path.dirname(candidate)) {
      const relative = path.relative(candidate, directory)
      if (relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative))) {
        break
      }
      candidate = path.dirname(candidate)
    }
  }
  // A filesystem root is not a meaningful photo source. Persisting "/" here
  // would make the indexer recursively watch and scan the entire volume when
  // a plugin imports files from unrelated directories.
  if (candidate === path.parse(candidate).root) return ''
  return candidate
}

export function normalizeImportFilepaths(filepaths: string[]): string[] {
  return [...new Set(
    filepaths
      .map(filepath => filepath.trim())
      .filter(Boolean)
      .map(filepath => path.resolve(filepath)),
  )]
}

function toSessionData(
  row: {
    id: string
    name: string
    status: string
    analysis_status: string
    writeback_status: string
    import_source: string
    source_path: string
    photo_count: number
    failed_writeback_count: number
    created_at: string
    updated_at: string
  },
): SessionData {
  return {
    id: row.id,
    name: row.name,
    status: row.status as SessionStatus,
    photoCount: row.photo_count,
    analysisStatus: row.analysis_status as AnalysisStatus,
    writebackStatus: row.writeback_status as WritebackStatus,
    importSource: row.import_source,
    sourcePath: row.source_path,
    failedWritebackCount: row.failed_writeback_count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

@injectable()
export class SessionService {
  constructor(
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.FACE_REPO) private faceRepo: FaceRepository,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
    @inject(DI_TOKENS.IMAGE_SERVICE) private imageService: ImageService,
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.ASSET_REPO) private assetRepo?: AssetRepository,
  ) {}

  createSession(name: string, source: string, sourcePath = ''): SessionData {
    const row = this.sessionRepo.create(name, source, sourcePath)
    return toSessionData(row)
  }

  listSessions(): SessionData[] {
    return this.sessionRepo.list().map(toSessionData)
  }

  getSession(sessionId: string): SessionData | null {
    const row = this.sessionRepo.get(sessionId)
    if (!row) return null
    if (!row.source_path) {
      const firstPhoto = this.photoRepo.getBySession(sessionId)[0]
      if (firstPhoto) {
        row.source_path = path.dirname(firstPhoto.filepath)
        this.sessionRepo.updateSourcePath(sessionId, row.source_path)
      }
    }
    return toSessionData(row)
  }

  deleteSession(sessionId: string, confirmed: boolean): void {
    if (!confirmed) {
      throw new Error('Deletion must be confirmed')
    }
    const del = this.db.transaction(() => {
      this.faceRepo.deleteObservationsBySession(sessionId)
      this.faceRepo.deleteClustersBySession(sessionId)
      this.sessionRepo.deleteSimilarityDataBySession(sessionId)
      this.photoRepo.deleteBySession(sessionId)
      const deleted = this.sessionRepo.delete(sessionId)
      if (!deleted) {
        throw new Error('Session not found')
      }
      this.db.prepare(`
        UPDATE assets SET status = 'orphan', updated_at = ?
        WHERE status != 'orphan'
          AND NOT EXISTS (
            SELECT 1 FROM session_assets sa WHERE sa.asset_id = assets.id
          )
      `).run(new Date().toISOString())
    })
    del()
  }

  deleteSessions(sessionIds: string[], confirmed: boolean): number {
    if (!confirmed) {
      throw new Error('Deletion must be confirmed')
    }
    const del = this.db.transaction((ids: string[]) => {
      for (const id of ids) {
        this.faceRepo.deleteObservationsBySession(id)
        this.faceRepo.deleteClustersBySession(id)
        this.sessionRepo.deleteSimilarityDataBySession(id)
        this.photoRepo.deleteBySession(id)
      }
      const deleted = this.sessionRepo.deleteMany(ids)
      this.db.prepare(`
        UPDATE assets SET status = 'orphan', updated_at = ?
        WHERE status != 'orphan'
          AND NOT EXISTS (
            SELECT 1 FROM session_assets sa WHERE sa.asset_id = assets.id
          )
      `).run(new Date().toISOString())
      return deleted
    })
    return del(sessionIds)
  }

  async addPhotos(sessionId: string, filepaths: string[], source: string): Promise<AddPhotoResult> {
    const session = this.sessionRepo.get(sessionId)
    if (!session) {
      throw new Error('Session not found')
    }
    const normalizedFilepaths = normalizeImportFilepaths(filepaths)
    if (!session.source_path && normalizedFilepaths.length > 0) {
      const sourcePath = commonParentDirectory(normalizedFilepaths)
      if (sourcePath) {
        this.sessionRepo.updateSourcePath(sessionId, sourcePath)
      }
    }
    const failedFiles: string[] = []
    const entries: Array<{ filepath: string; width: number; height: number }> = []

    const configuredBatchSize = this.settings.getNumber('import_concurrency', 8)
    const batchSize = Math.max(1, Math.min(32, Math.floor(configuredBatchSize)))
    for (let i = 0; i < normalizedFilepaths.length; i += batchSize) {
      const batch = normalizedFilepaths.slice(i, i + batchSize)
      const dimResults = await Promise.allSettled(
        batch.map((fp) => this.imageService.getDimensions(fp)),
      )
      batch.forEach((fp, idx) => {
        const r = dimResults[idx]
        if (r.status === 'fulfilled') {
          entries.push({ filepath: fp, width: r.value.width, height: r.value.height })
        } else {
          failedFiles.push(fp)
        }
      })
    }

    const result = this.photoRepo.addPhotos(sessionId, entries, source)
    this.assetRepo?.backfillSession(sessionId)
    const totalCount = this.photoRepo.countBySession(sessionId)
    this.sessionRepo.updatePhotoCount(sessionId, totalCount)
    if (totalCount > 0 && session.status === 'draft') {
      this.sessionRepo.updateStatus(sessionId, 'photos_loaded')
    }
    return { ...result, total: totalCount, failedFiles }
  }

  updateSession(sessionId: string, name: string): SessionData {
    const updated = this.sessionRepo.updateName(sessionId, name)
    if (!updated) {
      throw new Error('Session not found')
    }
    return toSessionData(this.sessionRepo.get(sessionId)!)
  }
}
