// packages/shared/src/protocol/history.ts

export interface HistoryListParams { sessionId: string; limit?: number; offset?: number }
export interface HistoryUndoParams { sessionId: string; operationId?: number; confirmed: boolean }
export interface HistoryRedoParams { sessionId: string; confirmed: boolean }
export interface HistoryCanUndoParams { sessionId: string }
export interface HistoryCanRedoParams { sessionId: string }

export interface OperationLogEntry {
  id: number
  sessionId: string
  operationType: string
  params: Record<string, unknown>
  snapshotBefore: Record<string, unknown> | null
  snapshotAfter: Record<string, unknown> | null
  isUndo: number
  description: string
  createdAt: string
}

export interface UndoStatus {
  canUndo: boolean
  operation?: OperationLogEntry
}

export interface RedoStatus {
  canRedo: boolean
  operation?: OperationLogEntry
}
