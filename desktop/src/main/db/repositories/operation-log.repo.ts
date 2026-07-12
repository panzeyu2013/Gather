import { getDatabase } from '../database'

export interface OperationLogRow {
  id: number
  session_id: string
  operation_type: string
  params: string
  snapshot_before: string | null
  snapshot_after: string | null
  is_undo: number
  description: string
  created_at: string
}

export class OperationLogRepository {
  insert(
    sessionId: string,
    operationType: string,
    params: string,
    snapshotBefore: string | null,
    snapshotAfter: string | null,
    description: string,
    createdAt: string,
  ): void {
    const db = getDatabase()
    db.prepare(
      `INSERT INTO operation_log (session_id, operation_type, params, snapshot_before, snapshot_after, is_undo, description, created_at)
       VALUES (?, ?, ?, ?, ?, 0, ?, ?)`,
    ).run(sessionId, operationType, params, snapshotBefore, snapshotAfter, description, createdAt)
  }

  list(sessionId: string, limit: number, offset: number): OperationLogRow[] {
    const db = getDatabase()
    return db
      .prepare(
        'SELECT * FROM operation_log WHERE session_id = ? ORDER BY created_at DESC LIMIT ? OFFSET ?',
      )
      .all(sessionId, limit, offset) as OperationLogRow[]
  }

  getLatestNonUndo(sessionId: string): OperationLogRow | undefined {
    const db = getDatabase()
    return db
      .prepare(
        'SELECT * FROM operation_log WHERE session_id = ? AND is_undo = 0 ORDER BY created_at DESC LIMIT 1',
      )
      .get(sessionId) as OperationLogRow | undefined
  }

  getLatestUndo(sessionId: string): OperationLogRow | undefined {
    const db = getDatabase()
    return db
      .prepare(
        'SELECT * FROM operation_log WHERE session_id = ? AND is_undo = 1 ORDER BY created_at DESC LIMIT 1',
      )
      .get(sessionId) as OperationLogRow | undefined
  }

  getById(sessionId: string, operationId: number, isUndo: number): OperationLogRow | undefined {
    const db = getDatabase()
    return db
      .prepare('SELECT * FROM operation_log WHERE id = ? AND session_id = ? AND is_undo = ?')
      .get(operationId, sessionId, isUndo) as OperationLogRow | undefined
  }

  getIsUndoStatus(operationId: number): { is_undo: number } | undefined {
    const db = getDatabase()
    return db
      .prepare('SELECT is_undo FROM operation_log WHERE id = ?')
      .get(operationId) as { is_undo: number } | undefined
  }

  markUndone(operationId: number): void {
    const db = getDatabase()
    db.prepare('UPDATE operation_log SET is_undo = 1 WHERE id = ?').run(operationId)
  }

  markRedone(operationId: number): void {
    const db = getDatabase()
    db.prepare('UPDATE operation_log SET is_undo = 0 WHERE id = ?').run(operationId)
  }
}
