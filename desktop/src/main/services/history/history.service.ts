import { getDatabase } from '../../db/database'
import { OperationLogRepository, type OperationLogRow } from '../../db/repositories/operation-log.repo'
import type { OperationLogEntry, UndoStatus, RedoStatus } from '@gather/shared'
import type { UndoHandlerMap } from './undo-handlers'

function rowToEntry(row: OperationLogRow): OperationLogEntry {
  return {
    id: row.id,
    sessionId: row.session_id,
    operationType: row.operation_type,
    params: JSON.parse(row.params),
    snapshotBefore: row.snapshot_before ? JSON.parse(row.snapshot_before) : null,
    snapshotAfter: row.snapshot_after ? JSON.parse(row.snapshot_after) : null,
    isUndo: row.is_undo,
    description: row.description,
    createdAt: row.created_at,
  }
}

export class HistoryService {
  private MAX_SNAPSHOT_SIZE = 64 * 1024
  private undoHandlersPromise: Promise<{ undoHandlers: UndoHandlerMap }> | null = null

  constructor(
    private opLogRepo: OperationLogRepository,
  ) {}

  record(
    sessionId: string,
    operationType: string,
    params: Record<string, unknown>,
    snapshotBefore?: Record<string, unknown>,
    snapshotAfter?: Record<string, unknown>,
  ): void {
    const now = new Date().toISOString()

    const truncate = (data: Record<string, unknown> | undefined): string | null => {
      if (!data) return null
      let json = JSON.stringify(data)
      if (Buffer.byteLength(json, 'utf-8') > this.MAX_SNAPSHOT_SIZE) {
        json = JSON.stringify({ _truncated: true, _keys: Object.keys(data) })
      }
      return json
    }

    this.opLogRepo.insert(
      sessionId,
      operationType,
      JSON.stringify(params),
      truncate(snapshotBefore),
      truncate(snapshotAfter),
      `[${operationType}] ${now}`,
      now,
    )
  }

  list(sessionId: string, limit = 50, offset = 0): OperationLogEntry[] {
    const effectiveLimit = Math.min(limit, 200)
    const rows = this.opLogRepo.list(sessionId, effectiveLimit, offset)
    return rows.map(rowToEntry)
  }

  canUndo(sessionId: string): UndoStatus {
    const row = this.opLogRepo.getLatestNonUndo(sessionId)

    if (!row) return { canUndo: false }

    return {
      canUndo: true,
      operation: rowToEntry(row),
    }
  }

  canRedo(sessionId: string): RedoStatus {
    const row = this.opLogRepo.getLatestUndo(sessionId)

    if (!row) return { canRedo: false }

    return {
      canRedo: true,
      operation: rowToEntry(row),
    }
  }

  async undo(sessionId: string, operationId?: number): Promise<void> {
    const db = getDatabase()
    if (!this.undoHandlersPromise) {
      this.undoHandlersPromise = import('./undo-handlers') as Promise<{ undoHandlers: UndoHandlerMap }>
    }
    const { undoHandlers } = await this.undoHandlersPromise

    let opRow: OperationLogRow | undefined
    if (operationId) {
      opRow = this.opLogRepo.getById(sessionId, operationId, 0)
    } else {
      opRow = this.opLogRepo.getLatestNonUndo(sessionId)
    }

    if (!opRow) throw new Error('No operation to undo')

    const params = JSON.parse(opRow.params) as Record<string, unknown>
    const snapshotBefore = opRow.snapshot_before ? JSON.parse(opRow.snapshot_before) as Record<string, unknown> : {}

    const handler = undoHandlers[opRow.operation_type]
    if (!handler) throw new Error(`No undo handler for operation type: ${opRow.operation_type}`)

    const undoTransaction = db.transaction(() => {
      const current = this.opLogRepo.getIsUndoStatus(opRow!.id)
      if (!current || current.is_undo !== 0) {
        throw new Error('Operation already undone')
      }
      handler(params, snapshotBefore)
      this.opLogRepo.markUndone(opRow!.id)
    })
    undoTransaction()
  }

  async redo(sessionId: string): Promise<void> {
    const db = getDatabase()

    const opRow = this.opLogRepo.getLatestUndo(sessionId)

    if (!opRow) throw new Error('No operation to redo')

    const params = JSON.parse(opRow.params) as Record<string, unknown>
    const snapshotAfter = opRow.snapshot_after ? JSON.parse(opRow.snapshot_after) as Record<string, unknown> : {}

    const redoMethod = this.getRedoMethod(opRow.operation_type)
    const redoTransaction = db.transaction(() => {
      const current = this.opLogRepo.getIsUndoStatus(opRow!.id)
      if (!current || current.is_undo !== 1) {
        throw new Error('Operation already redone or state changed')
      }
      if (redoMethod) {
        redoMethod(sessionId, params, snapshotAfter)
      }
      this.opLogRepo.markRedone(opRow!.id)
    })
    redoTransaction()
  }

  private getRedoMethod(
    operationType: string,
  ): ((sessionId: string, params: Record<string, unknown>, snapshot: Record<string, unknown>) => Promise<void>) | null {
    const redoHandlers: Record<string, (sessionId: string, params: Record<string, unknown>, snapshot: Record<string, unknown>) => Promise<void>> = {
      face_bind: async (sid, _p, snap) => {
        const db = getDatabase()
        const clusterId = snap.cluster_id as number
        const roleName = snap.role_name as string
        const keywords = snap.keywords as string[]
        if (clusterId && roleName && keywords) {
          await db.prepare(
            'INSERT OR REPLACE INTO role_bindings (cluster_id, session_id, role_name, keywords) VALUES (?, ?, ?, ?)',
          ).run(clusterId, sid, roleName, JSON.stringify(keywords))
          db.prepare("UPDATE face_clusters SET status = 'bound' WHERE id = ?").run(clusterId)
        }
      },
      face_unbind: async (_sid, _p, snap) => {
        const db = getDatabase()
        const clusterId = snap.cluster_id as number
        if (clusterId) {
          db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(clusterId)
          db.prepare("UPDATE face_clusters SET status = 'unbound' WHERE id = ?").run(clusterId)
        }
      },
    }
    return redoHandlers[operationType] ?? null
  }
}
