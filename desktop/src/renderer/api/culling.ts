import { sendCommand } from './client'
import type { CullingGroup, CullingSummary, WritebackResult } from '@gather/shared'

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

  reset: (sessionId: string, groupId?: string) =>
    sendCommand<boolean>('culling.reset', { sessionId, ...(groupId ? { groupId } : {}), confirmed: true }),
}
