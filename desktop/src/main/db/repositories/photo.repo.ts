import { getDatabase } from '../database'

export interface PhotoRow {
  id: string
  session_id: string
  filepath: string
  filename: string
  checksum: string
  status: string
  metadata: string
  result: string
  created_at: string
  updated_at: string
}

export class PhotoRepository {
  getBySession(sessionId: string): PhotoRow[] {
    const db = getDatabase()
    return db.prepare('SELECT * FROM photos WHERE session_id = ?').all(sessionId) as PhotoRow[]
  }

  countBySession(sessionId: string): number {
    const db = getDatabase()
    const row = db
      .prepare('SELECT COUNT(*) as count FROM photos WHERE session_id = ?')
      .get(sessionId) as { count: number } | undefined
    return row?.count ?? 0
  }

  addPhotos(
    sessionId: string,
    filepaths: string[],
    _source: string,
  ): { added: number; skipped: number } {
    const db = getDatabase()
    const now = new Date().toISOString()
    let added = 0
    let skipped = 0

    const insertStmt = db.prepare(
      `INSERT OR IGNORE INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, created_at, updated_at)
       VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?)`,
    )

    const insertMany = db.transaction((paths: string[]) => {
      for (const filepath of paths) {
        const filename = filepath.split(/[/\\]/).pop() ?? filepath
        const id = crypto.randomUUID()
        const result = insertStmt.run(id, sessionId, filepath, filename, now, now)
        if (result.changes > 0) {
          added++
        } else {
          skipped++
        }
      }
    })

    insertMany(filepaths)
    return { added, skipped }
  }

  deleteBySession(sessionId: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM photos WHERE session_id = ?').run(sessionId)
  }
}
