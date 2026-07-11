import { SessionRepository } from '../../db/repositories/session.repo'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import type {
  SessionData,
  AddPhotoResult,
  SessionStatus,
  AnalysisStatus,
  WritebackStatus,
} from '@gather/shared'

function toSessionData(
  row: {
    id: string
    name: string
    status: string
    analysis_status: string
    writeback_status: string
    import_source: string
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
    failedWritebackCount: row.failed_writeback_count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }
}

export class SessionService {
  constructor(
    private sessionRepo: SessionRepository,
    private photoRepo: PhotoRepository,
  ) {}

  createSession(name: string, source: string): SessionData {
    const row = this.sessionRepo.create(name, source)
    return toSessionData(row)
  }

  listSessions(): SessionData[] {
    return this.sessionRepo.list().map(toSessionData)
  }

  getSession(sessionId: string): SessionData | null {
    const row = this.sessionRepo.get(sessionId)
    return row ? toSessionData(row) : null
  }

  deleteSession(sessionId: string, confirmed: boolean): void {
    if (!confirmed) {
      throw new Error('Deletion must be confirmed')
    }
    this.photoRepo.deleteBySession(sessionId)
    const deleted = this.sessionRepo.delete(sessionId)
    if (!deleted) {
      throw new Error('Session not found')
    }
  }

  deleteSessions(sessionIds: string[], confirmed: boolean): number {
    if (!confirmed) {
      throw new Error('Deletion must be confirmed')
    }
    for (const id of sessionIds) {
      this.photoRepo.deleteBySession(id)
    }
    return this.sessionRepo.deleteMany(sessionIds)
  }

  addPhotos(sessionId: string, filepaths: string[], source: string): AddPhotoResult {
    const session = this.sessionRepo.get(sessionId)
    if (!session) {
      throw new Error('Session not found')
    }
    const result = this.photoRepo.addPhotos(sessionId, filepaths, source)
    const totalCount = this.photoRepo.countBySession(sessionId)
    this.sessionRepo.updatePhotoCount(sessionId, totalCount)
    if (totalCount > 0 && session.status === 'draft') {
      this.sessionRepo.updateStatus(sessionId, 'photos_loaded')
    }
    return { ...result, total: totalCount }
  }

  updateSession(sessionId: string, name: string): SessionData {
    const updated = this.sessionRepo.updateName(sessionId, name)
    if (!updated) {
      throw new Error('Session not found')
    }
    return toSessionData(this.sessionRepo.get(sessionId)!)
  }
}
