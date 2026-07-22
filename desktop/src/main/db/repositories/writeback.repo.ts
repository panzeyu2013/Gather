import { getDatabase } from '../database'
import { IWritebackRepository } from './interfaces'

export interface WritebackItemInput {
  photoId: string
  photoPath: string
  module: string
  keywords: string[]
  xmpPath: string
  backupPath: string
}

export interface WritebackItemRow {
  id: number
  photo_id: string
  photo_path: string
  session_id: string
  module: string
  keywords: string
  xmp_path: string
  backup_path: string
  xmp_status: string
  error_message: string
  attempt_count: number
  last_attempt_at: string
}

export class WritebackRepository implements IWritebackRepository {
  saveItems(sessionId: string, module: string, items: WritebackItemInput[]): void {
    const db = getDatabase()
    const now = new Date().toISOString()

    const replaceAll = db.transaction(() => {
      db.prepare(
        'DELETE FROM writeback_items WHERE session_id = ? AND module = ? AND xmp_status = ?',
      ).run(sessionId, module, 'pending')

      const insertStmt = db.prepare(
        `INSERT INTO writeback_items (photo_id, photo_path, session_id, module, keywords, xmp_path, backup_path, xmp_status, error_message, last_attempt_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', '', ?)`,
      )

      for (const item of items) {
        insertStmt.run(
          item.photoId,
          item.photoPath,
          sessionId,
          module,
          JSON.stringify(item.keywords),
          item.xmpPath,
          item.backupPath,
          now,
        )
      }
    })

    replaceAll()
  }

  getItems(sessionId: string, module?: string, status?: string): WritebackItemRow[] {
    const db = getDatabase()
    let sql = 'SELECT * FROM writeback_items WHERE session_id = ?'
    const params: unknown[] = [sessionId]

    if (module) {
      sql += ' AND module = ?'
      params.push(module)
    }
    if (status) {
      sql += ' AND xmp_status = ?'
      params.push(status)
    }

    sql += ' ORDER BY id ASC'
    return db.prepare(sql).all(...params) as WritebackItemRow[]
  }

  updateStatus(itemId: number, status: string, error?: string): void {
    const db = getDatabase()
    const now = new Date().toISOString()
    db.prepare(
      `UPDATE writeback_items SET xmp_status = ?, error_message = ?, attempt_count = attempt_count + 1, last_attempt_at = ? WHERE id = ?`,
    ).run(status, error ?? '', now, itemId)
  }

  getFailedCount(sessionId: string): number {
    const db = getDatabase()
    const row = db
      .prepare('SELECT COUNT(*) as count FROM writeback_items WHERE session_id = ? AND xmp_status = ?')
      .get(sessionId, 'failed') as { count: number } | undefined
    return row?.count ?? 0
  }

  deleteItems(sessionId: string): void {
    const db = getDatabase()
    db.prepare('DELETE FROM writeback_items WHERE session_id = ?').run(sessionId)
  }

  updateBackupPath(itemId: number, path: string): void {
    const db = getDatabase()
    db.prepare('UPDATE writeback_items SET backup_path = ? WHERE id = ?').run(path, itemId)
  }
}
