import { getDatabase } from '../database'

export interface SessionRow {
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
}

export class SessionRepository {
  get(id: string): SessionRow | null {
    const db = getDatabase()
    const row = db.prepare('SELECT * FROM sessions WHERE id = ?').get(id) as SessionRow | undefined
    return row ?? null
  }

  create(name: string, source: string): SessionRow {
    const db = getDatabase()
    const id = crypto.randomUUID()
    const now = new Date().toISOString()
    db.prepare(
      `INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, photo_count, failed_writeback_count, created_at, updated_at)
       VALUES (?, ?, 'draft', 'idle', 'idle', ?, 0, 0, ?, ?)`,
    ).run(id, name, source, now, now)
    return this.get(id)!
  }

  delete(id: string): boolean {
    const db = getDatabase()
    const result = db.prepare('DELETE FROM sessions WHERE id = ?').run(id)
    return result.changes > 0
  }

  list(): SessionRow[] {
    const db = getDatabase()
    return db.prepare('SELECT * FROM sessions ORDER BY updated_at DESC').all() as SessionRow[]
  }

  updateName(id: string, name: string): boolean {
    const db = getDatabase()
    const result = db
      .prepare('UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?')
      .run(name, new Date().toISOString(), id)
    return result.changes > 0
  }

  updateStatus(id: string, status: string): void {
    const db = getDatabase()
    db.prepare('UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?').run(
      status,
      new Date().toISOString(),
      id,
    )
  }

  updatePhotoCount(id: string, count: number): void {
    const db = getDatabase()
    db.prepare('UPDATE sessions SET photo_count = ?, updated_at = ? WHERE id = ?').run(
      count,
      new Date().toISOString(),
      id,
    )
  }

  updateAnalysisStatus(id: string, status: string): void {
    const db = getDatabase()
    db.prepare('UPDATE sessions SET analysis_status = ?, updated_at = ? WHERE id = ?').run(
      status,
      new Date().toISOString(),
      id,
    )
  }

  updateWritebackStatus(id: string, status: string): void {
    const db = getDatabase()
    db.prepare('UPDATE sessions SET writeback_status = ?, updated_at = ? WHERE id = ?').run(
      status,
      new Date().toISOString(),
      id,
    )
  }

  updateFailedWritebackCount(id: string, count: number): void {
    const db = getDatabase()
    db.prepare('UPDATE sessions SET failed_writeback_count = ?, updated_at = ? WHERE id = ?').run(
      count,
      new Date().toISOString(),
      id,
    )
  }
}
