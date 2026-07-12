import { sendCommand } from './client'
import type { OperationLogEntry, UndoStatus, RedoStatus } from '@gather/shared'

export const historyApi = {
  list: (sessionId: string, limit?: number, offset?: number) =>
    sendCommand<OperationLogEntry[]>('history.list', { sessionId, limit, offset }),

  undo: (sessionId: string, operationId?: number) =>
    sendCommand<boolean>('history.undo', { sessionId, operationId, confirmed: true }),

  redo: (sessionId: string) =>
    sendCommand<boolean>('history.redo', { sessionId, confirmed: true }),

  canUndo: (sessionId: string) =>
    sendCommand<UndoStatus>('history.can_undo', { sessionId }),

  canRedo: (sessionId: string) =>
    sendCommand<RedoStatus>('history.can_redo', { sessionId }),
}
