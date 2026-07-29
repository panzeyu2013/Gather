import { sendCommand } from './client'
import type {
  CleanupResult,
  SimilarityGroup,
  SimilarityImage,
  SimilarityKeywordAssignment,
  WritebackItem,
  WritebackPreview,
  WritebackResult,
} from '@gather/shared'

export interface SimilarityResult {
  groups: SimilarityGroup[]
  ungrouped: SimilarityImage[]
  stats: {
    totalGroups: number
    totalUngrouped: number
    threshold: number
    minGroupSize: number
  }
}

export const similarityApi = {
  analyze: (sessionId: string, threshold?: number, minGroupSize?: number) =>
    sendCommand<boolean>('sim.analyze', {
      sessionId,
      ...(threshold !== undefined ? { threshold } : {}),
      ...(minGroupSize !== undefined ? { minGroupSize } : {}),
    }),

  cancel: (sessionId: string) =>
    sendCommand<boolean>('sim.cancel_analysis', { sessionId }),

  getResult: (sessionId: string) =>
    sendCommand<SimilarityResult | null>('sim.result', { sessionId }),

  recluster: (sessionId: string, threshold: number, minGroupSize: number) =>
    sendCommand<SimilarityResult>('sim.recluster', {
      sessionId,
      threshold,
      minGroupSize,
    }),

  previewWriteback: (sessionId: string, assignments: SimilarityKeywordAssignment[]) =>
    sendCommand<WritebackPreview>('sim.preview_writeback', { sessionId, assignments }),

  writeback: (sessionId: string, items: WritebackItem[]) =>
    sendCommand<WritebackResult>('sim.writeback', {
      sessionId,
      itemIds: items.flatMap(item => item.id == null ? [] : [item.id]),
      confirmed: true,
    }),

  retryFailedWriteback: (sessionId: string) =>
    sendCommand<WritebackResult>('sim.retry_failed_writeback', { sessionId, confirmed: true }),

  confirmSync: (sessionId: string) =>
    sendCommand<boolean>('sim.confirm_sync', { sessionId }),

  cleanup: (sessionId: string) =>
    sendCommand<CleanupResult>('sim.cleanup', { sessionId, confirmed: true }),
}
