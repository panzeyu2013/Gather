import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import type { CullingHistoryEntry, CullingHistoryOperation } from '@gather/shared'

@injectable()
export class CullingHistoryRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  append(sessionId: string, entries: CullingHistoryEntry[]): CullingHistoryOperation {
    const createdAt = new Date().toISOString()
    const result = this.db.transaction(() => {
      this.db.prepare(
        'DELETE FROM culling_history WHERE session_id = ? AND undone = 1',
      ).run(sessionId)
      return this.db.prepare(`
        INSERT INTO culling_history (session_id, operation_json, undone, created_at)
        VALUES (?, ?, 0, ?)
      `).run(sessionId, JSON.stringify(entries), createdAt)
    })()
    return {
      id: Number(result.lastInsertRowid),
      sessionId,
      entries,
      undone: false,
      createdAt,
    }
  }

  setUndone(
    sessionId: string,
    operationId: number,
    undone: boolean,
  ): void {
    const boundary = this.db.prepare(`
      SELECT ${undone ? 'MAX' : 'MIN'}(id) AS id
      FROM culling_history WHERE session_id = ? AND undone = ?
    `).get(sessionId, undone ? 0 : 1) as { id: number | null }
    if (boundary.id !== operationId) {
      throw new Error(undone
        ? '只能撤销最近一次尚未撤销的操作'
        : '必须按原顺序重做操作')
    }
    const changed = this.db.prepare(`
      UPDATE culling_history SET undone = ?
      WHERE id = ? AND session_id = ? AND undone = ?
    `).run(undone ? 1 : 0, operationId, sessionId, undone ? 0 : 1).changes
    if (changed !== 1) throw new Error('挑片历史状态已变化，请刷新后重试')
  }

  get(sessionId: string, operationId: number): CullingHistoryOperation | null {
    const row = this.db.prepare(`
      SELECT id, session_id, operation_json, undone, created_at
      FROM culling_history WHERE id = ? AND session_id = ?
    `).get(operationId, sessionId) as {
      id: number
      session_id: string
      operation_json: string
      undone: number
      created_at: string
    } | undefined
    if (!row) return null
    try {
      return {
        id: row.id,
        sessionId: row.session_id,
        entries: JSON.parse(row.operation_json) as CullingHistoryEntry[],
        undone: row.undone === 1,
        createdAt: row.created_at,
      }
    } catch {
      throw new Error('挑片历史记录已损坏，无法执行撤销或重做')
    }
  }

  list(sessionId: string, limit = 100): CullingHistoryOperation[] {
    const rows = this.db.prepare(`
      SELECT id, session_id, operation_json, undone, created_at
      FROM culling_history WHERE session_id = ? ORDER BY id DESC LIMIT ?
    `).all(sessionId, Math.max(1, Math.min(limit, 500))) as Array<{
      id: number
      session_id: string
      operation_json: string
      undone: number
      created_at: string
    }>
    return rows.flatMap(row => {
      try {
        const entries = JSON.parse(row.operation_json) as CullingHistoryEntry[]
        return [{
          id: row.id,
          sessionId: row.session_id,
          entries,
          undone: row.undone === 1,
          createdAt: row.created_at,
        }]
      } catch {
        return []
      }
    })
  }
}
