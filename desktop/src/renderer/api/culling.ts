import { sendCommand } from './client'
import type {
  CleanupResult,
  CullingAsset,
  CullingFilters,
  CullingGroup,
  CullingPage,
  CullingScope,
  CullingSummary,
  CullingUpdatePatch,
  CullingUpdateResult,
  CullingHistoryOperation,
  MetadataSyncSummary,
  WritebackResult,
} from '@gather/shared'

export const cullingApi = {
  list: (
    sessionId: string,
    scope: CullingScope,
    filters?: CullingFilters,
    groupId?: string,
  ) => sendCommand<CullingAsset[]>('culling.list', {
    sessionId,
    scope,
    ...(filters ? { filters } : {}),
    ...(groupId ? { groupId } : {}),
  }),

  listPage: (
    sessionId: string,
    scope: CullingScope,
    filters?: CullingFilters,
    groupId?: string,
    afterRowId?: number,
    limit?: number,
  ) => sendCommand<CullingPage>('culling.list_page', {
    sessionId,
    scope,
    ...(filters ? { filters } : {}),
    ...(groupId ? { groupId } : {}),
    ...(afterRowId !== undefined ? { afterRowId } : {}),
    ...(limit !== undefined ? { limit } : {}),
  }),

  update: (
    sessionId: string,
    photoId: string,
    expectedRevision: number,
    patch: CullingUpdatePatch,
  ) => sendCommand<CullingUpdateResult>('culling.update', {
    sessionId,
    photoId,
    expectedRevision,
    patch,
  }),

  batchUpdate: (
    sessionId: string,
    photoIds: string[],
    patch: CullingUpdatePatch,
  ) => sendCommand<CullingUpdateResult[]>('culling.batch_update', {
    sessionId,
    photoIds,
    patch,
  }),

  history: (sessionId: string, limit?: number) =>
    sendCommand<CullingHistoryOperation[]>('culling.history', { sessionId, limit }),

  applyHistory: (
    sessionId: string,
    entries: Array<{ photoId: string; expectedRevision: number; patch: CullingUpdatePatch }>,
    historyOperationId: number,
    direction: 'undo' | 'redo',
  ) => sendCommand<CullingUpdateResult[]>('culling.apply_history', {
    sessionId,
    entries,
    historyOperationId,
    direction,
  }),

  decideGroup: (
    sessionId: string,
    groupId: string,
    keepPhotoIds: string[],
  ) => sendCommand<CullingUpdateResult[]>('culling.decide_group', {
    sessionId,
    groupId,
    keepPhotoIds,
  }),

  syncStatus: (sessionId: string) =>
    sendCommand<MetadataSyncSummary>('culling.sync_status', { sessionId }),

  flush: (sessionId: string) =>
    sendCommand<MetadataSyncSummary>('culling.flush', { sessionId }),

  retrySync: (sessionId: string) =>
    sendCommand<MetadataSyncSummary>('culling.retry_sync', { sessionId }),

  finalizeSync: (sessionId: string) =>
    sendCommand<MetadataSyncSummary>('culling.finalize_sync', {
      sessionId,
      confirmed: true,
    }),

  getGroups: (sessionId: string) =>
    sendCommand<CullingGroup[]>('culling.groups', { sessionId }),

  decide: (sessionId: string, photoId: string, decision: 'keep' | 'reject' | 'pending') =>
    sendCommand<boolean>('culling.decide', { sessionId, photoId, decision }),

  batchDecide: (sessionId: string, photoIds: string[], decision: 'keep' | 'reject' | 'pending') =>
    sendCommand<boolean>('culling.batch_decide', { sessionId, photoIds, decision }),

  getSummary: (sessionId: string) =>
    sendCommand<CullingSummary>('culling.summary', { sessionId }),

  writeback: (sessionId: string, target: 'rating' | 'color_label' | 'keyword') =>
    sendCommand<WritebackResult>('culling.writeback', { sessionId, target, confirmed: true }),

  retryFailedWriteback: (sessionId: string) =>
    sendCommand<WritebackResult>('culling.retry_failed_writeback', { sessionId, confirmed: true }),

  confirmSync: (sessionId: string) =>
    sendCommand<boolean>('culling.confirm_sync', { sessionId }),

  cleanup: (sessionId: string) =>
    sendCommand<CleanupResult>('culling.cleanup', { sessionId, confirmed: true }),

  reset: (sessionId: string, groupId?: string) =>
    sendCommand<boolean>('culling.reset', { sessionId, ...(groupId ? { groupId } : {}), confirmed: true }),
}
