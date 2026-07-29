import { sendCommand } from './client'
import type { CleanupResult, CullingGroup, CullingSummary, WritebackResult } from '@gather/shared'

export const cullingApi = {
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
