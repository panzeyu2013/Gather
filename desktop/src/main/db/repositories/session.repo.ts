import { Database } from '../database'
import crypto from 'crypto'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface SessionRow {
  id: string
  name: string
  status: string
  analysis_status: string
  writeback_status: string
  import_source: string
  source_path: string
  truncated_import: number
  reload_acked_at: string | null
  index_seq: number
  photo_count: number
  failed_writeback_count: number
  created_at: string
  updated_at: string
}

@injectable()
export class SessionRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  get(id: string): SessionRow | null {
    const row = this.db.prepare('SELECT * FROM sessions WHERE id = ?').get(id) as SessionRow | undefined
    return row ?? null
  }

  create(name: string, source: string, sourcePath = '', truncatedImport = false): SessionRow {
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    this.db.prepare(
      `INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, truncated_import, photo_count, failed_writeback_count, created_at, updated_at)
       VALUES (?, ?, 'draft', 'idle', 'idle', ?, ?, ?, 0, 0, ?, ?)`,
    ).run(id, name, source, sourcePath, truncatedImport ? 1 : 0, now, now)
    return this.get(id)!
  }

  delete(id: string): boolean {
    const result = this.db.prepare('DELETE FROM sessions WHERE id = ?').run(id)
    return result.changes > 0
  }

  deleteMany(ids: string[]): number {
    const deleteStmt = this.db.prepare('DELETE FROM sessions WHERE id = ?')
    const deleteMany = this.db.transaction((sessionIds: string[]) => {
      for (const sid of sessionIds) {
        deleteStmt.run(sid)
      }
    })
    deleteMany(ids)
    return ids.length
  }

  deleteSimilarityDataBySession(sessionId: string): void {
    this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?').run(sessionId)
    this.db.prepare('DELETE FROM similarity_hashes WHERE session_id = ?').run(sessionId)
  }

  list(): SessionRow[] {
    return this.db.prepare('SELECT * FROM sessions ORDER BY updated_at DESC').all() as SessionRow[]
  }

  updateName(id: string, name: string): boolean {
    const result = this.db
      .prepare('UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?')
      .run(name, new Date().toISOString(), id)
    return result.changes > 0
  }

  updateSourcePath(id: string, sourcePath: string): boolean {
    const result = this.db
      .prepare('UPDATE sessions SET source_path = ?, updated_at = ? WHERE id = ?')
      .run(sourcePath, new Date().toISOString(), id)
    return result.changes > 0
  }

  updateStatus(id: string, status: string): void {
    this.db.prepare('UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?').run(
      status,
      new Date().toISOString(),
      id,
    )
  }

  updatePhotoCount(id: string, count: number): void {
    this.db.prepare('UPDATE sessions SET photo_count = ?, updated_at = ? WHERE id = ?').run(
      count,
      new Date().toISOString(),
      id,
    )
  }

  updateAnalysisStatus(id: string, status: string): void {
    this.db.prepare('UPDATE sessions SET analysis_status = ?, updated_at = ? WHERE id = ?').run(
      status,
      new Date().toISOString(),
      id,
    )
  }

  updateWritebackStatus(id: string, status: string): void {
    this.db.prepare('UPDATE sessions SET writeback_status = ?, updated_at = ? WHERE id = ?').run(
      status,
      new Date().toISOString(),
      id,
    )
  }

  updateFailedWritebackCount(id: string, count: number): void {
    this.db.prepare('UPDATE sessions SET failed_writeback_count = ?, updated_at = ? WHERE id = ?').run(
      count,
      new Date().toISOString(),
      id,
    )
  }

  getReloadAckedAt(sessionId: string): string | null {
    const row = this.db.prepare(
      'SELECT reload_acked_at FROM sessions WHERE id = ?',
    ).get(sessionId) as { reload_acked_at: string | null } | undefined
    return row?.reload_acked_at ?? null
  }

  setReloadAckedAt(sessionId: string, iso: string): boolean {
    const result = this.db.prepare(
      'UPDATE sessions SET reload_acked_at = ?, updated_at = ? WHERE id = ?',
    ).run(iso, new Date().toISOString(), sessionId)
    return result.changes > 0
  }

  getIndexSeq(id: string): number {
    const row = this.db.prepare('SELECT index_seq FROM sessions WHERE id = ?')
      .get(id) as { index_seq: number } | undefined
    return row?.index_seq ?? 0
  }

  bumpIndexSeq(id: string): number {
    const bump = this.db.transaction(() => {
      this.db.prepare('UPDATE sessions SET index_seq = index_seq + 1, updated_at = ? WHERE id = ?')
        .run(new Date().toISOString(), id)
      const row = this.db.prepare('SELECT index_seq FROM sessions WHERE id = ?')
        .get(id) as { index_seq: number } | undefined
      return row?.index_seq ?? 0
    })
    return bump()
  }
}
