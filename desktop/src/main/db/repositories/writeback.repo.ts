import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import type { WritebackAttributes } from '@gather/shared'

export interface WritebackItemInput {
  photoId: string
  photoPath: string
  module: string
  keywords: string[]
  attributes?: WritebackAttributes
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
  attributes_json: string
  xmp_path: string
  backup_path: string
  xmp_status: string
  error_message: string
  attempt_count: number
  last_attempt_at: string
}

@injectable()
export class WritebackRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  saveItems(sessionId: string, module: string, items: WritebackItemInput[]): void {
    const now = new Date().toISOString()

    const replaceAll = this.db.transaction(() => {
      this.db.prepare(
        `DELETE FROM writeback_items
         WHERE session_id = ? AND module = ? AND xmp_status IN ('pending', 'failed')`,
      ).run(sessionId, module)

      const insertStmt = this.db.prepare(
        `INSERT INTO writeback_items (photo_id, photo_path, session_id, module, keywords, attributes_json, xmp_path, backup_path, xmp_status, error_message, last_attempt_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', '', ?)`,
      )

      for (const item of items) {
        insertStmt.run(
          item.photoId,
          item.photoPath,
          sessionId,
          module,
          JSON.stringify(item.keywords),
          JSON.stringify(item.attributes ?? {}),
          item.xmpPath,
          item.backupPath,
          now,
        )
      }
    })

    replaceAll()
  }

  getItems(sessionId: string, module?: string, status?: string): WritebackItemRow[] {
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
    return this.db.prepare(sql).all(...params) as WritebackItemRow[]
  }

  getItem(itemId: number): WritebackItemRow | undefined {
    return this.db.prepare('SELECT * FROM writeback_items WHERE id = ?').get(itemId) as WritebackItemRow | undefined
  }

  updateStatus(itemId: number, status: string, error?: string): void {
    const now = new Date().toISOString()
    this.db.prepare(
      `UPDATE writeback_items SET xmp_status = ?, error_message = ?, attempt_count = attempt_count + 1, last_attempt_at = ? WHERE id = ?`,
    ).run(status, error ?? '', now, itemId)
  }

  getFailedCount(sessionId: string, module?: string): number {
    let sql = 'SELECT COUNT(*) as count FROM writeback_items WHERE session_id = ? AND xmp_status = ?'
    const params: unknown[] = [sessionId, 'failed']
    if (module) {
      sql += ' AND module = ?'
      params.push(module)
    }
    const row = this.db
      .prepare(sql)
      .get(...params) as { count: number } | undefined
    return row?.count ?? 0
  }

  deleteItems(sessionId: string, module?: string): void {
    if (module) {
      this.db.prepare('DELETE FROM writeback_items WHERE session_id = ? AND module = ?')
        .run(sessionId, module)
      return
    }
    this.db.prepare('DELETE FROM writeback_items WHERE session_id = ?').run(sessionId)
  }

  /** Delete only the given rows of a module — cleanup must not remove a new
   * pending round that a re-preview created after the confirmed round. */
  deleteItemsByIds(sessionId: string, module: string, ids: number[]): void {
    const doomed: number[] = []
    const selectStmt = this.db.prepare(`
      SELECT id FROM writeback_items
      WHERE session_id = ? AND module = ? AND xmp_status = 'synced' AND id IN (${ids.map(() => '?').join(',')})
    `)
    for (let offset = 0; offset < ids.length; offset += 400) {
      const chunk = ids.slice(offset, offset + 400)
      doomed.push(...(selectStmt.all(sessionId, module, ...chunk) as Array<{ id: number }>)
        .map(row => row.id))
    }
    for (let offset = 0; offset < doomed.length; offset += 400) {
      const chunk = doomed.slice(offset, offset + 400)
      const placeholders = chunk.map(() => '?').join(',')
      this.db.prepare(`DELETE FROM writeback_items WHERE id IN (${placeholders})`).run(...chunk)
    }
  }

  updateBackupPath(itemId: number, path: string): void {
    this.db.prepare('UPDATE writeback_items SET backup_path = ? WHERE id = ?').run(path, itemId)
  }

  updateAttributes(itemId: number, attributes: Record<string, unknown>): void {
    this.db.prepare('UPDATE writeback_items SET attributes_json = ? WHERE id = ?')
      .run(JSON.stringify(attributes), itemId)
  }

  updateKeywords(itemId: number, keywords: string[]): void {
    this.db.prepare('UPDATE writeback_items SET keywords = ? WHERE id = ?')
      .run(JSON.stringify(keywords), itemId)
  }

  updateAttributesMany(items: Array<{ id: number; attributes: Record<string, unknown> }>): void {
    const statement = this.db.prepare(
      'UPDATE writeback_items SET attributes_json = ? WHERE id = ?',
    )
    this.db.transaction(() => {
      for (const item of items) {
        statement.run(JSON.stringify(item.attributes), item.id)
      }
    })()
  }

  updateKeywordsMany(items: Array<{ id: number; keywords: string[] }>): void {
    const statement = this.db.prepare(
      'UPDATE writeback_items SET keywords = ? WHERE id = ?',
    )
    this.db.transaction(() => {
      for (const item of items) {
        statement.run(JSON.stringify(item.keywords), item.id)
      }
    })()
  }

  markWrittenAsSynced(sessionId: string, module: string): void {
    this.db.prepare(
      `UPDATE writeback_items
       SET xmp_status = 'synced'
       WHERE session_id = ? AND module = ? AND xmp_status = 'written'`,
    ).run(sessionId, module)
  }

  updateStatusByXmpPath(
    sessionId: string,
    module: string,
    xmpPath: string,
    status: string,
  ): void {
    this.db.prepare(
      `UPDATE writeback_items
       SET xmp_status = ?, error_message = ''
       WHERE session_id = ? AND module = ? AND xmp_path = ?`,
    ).run(status, sessionId, module, xmpPath)
  }

  hasActiveForXmpPath(xmpPath: string): boolean {
    const row = this.db.prepare(`
      SELECT 1
      FROM writeback_items
      WHERE xmp_path = ?
        AND xmp_status IN ('pending', 'writing', 'written', 'synced')
      LIMIT 1
    `).get(xmpPath)
    return row !== undefined
  }

  discardPendingByXmpPath(xmpPath: string): number {
    return this.db.prepare(`
      DELETE FROM writeback_items
      WHERE xmp_path = ? AND xmp_status IN ('pending', 'failed')
    `).run(xmpPath).changes
  }
}
