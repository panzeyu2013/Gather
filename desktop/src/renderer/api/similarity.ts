import { sendCommand } from './client'
import type {
  CleanupResult,
  SimilarityGroup,
  SimilarityGroupingMode,
  SimilarityImage,
  SimilarityKeywordAssignment,
  SimilarityResultStats,
  WritebackItem,
  WritebackPreview,
  WritebackResult,
} from '@gather/shared'

export interface SimilarityResult {
  groups: SimilarityGroup[]
  ungrouped: SimilarityImage[]
  stats: SimilarityResultStats
}

export const similarityApi = {
  analyze: (
    sessionId: string,
    threshold?: number,
    minGroupSize?: number,
    groupingMode: SimilarityGroupingMode = 'global',
  ) =>
    sendCommand<boolean>('sim.analyze', {
      sessionId,
      ...(threshold !== undefined ? { threshold } : {}),
      ...(minGroupSize !== undefined ? { minGroupSize } : {}),
      groupingMode,
    }),

  cancel: (sessionId: string) =>
    sendCommand<boolean>('sim.cancel_analysis', { sessionId }),

  getResult: (sessionId: string, threshold?: number) =>
    sendCommand<SimilarityResult | null>('sim.result', {
      sessionId,
      ...(threshold !== undefined ? { threshold } : {}),
    }),

  recluster: (
    sessionId: string,
    threshold: number,
    minGroupSize: number,
    groupingMode: SimilarityGroupingMode = 'global',
  ) =>
    sendCommand<SimilarityResult>('sim.recluster', {
      sessionId,
      threshold,
      minGroupSize,
      groupingMode,
    }),

  previewWriteback: (
    sessionId: string,
    assignments: SimilarityKeywordAssignment[],
    threshold?: number,
  ) =>
    sendCommand<WritebackPreview>('sim.preview_writeback', {
      sessionId,
      assignments,
      ...(threshold !== undefined ? { threshold } : {}),
    }),

  writeback: (sessionId: string, items: WritebackItem[], threshold?: number) =>
    sendCommand<WritebackResult>('sim.writeback', {
      sessionId,
      itemIds: items.flatMap(item => item.id == null ? [] : [item.id]),
      confirmed: true,
      ...(threshold !== undefined ? { threshold } : {}),
    }),

  retryFailedWriteback: (sessionId: string) =>
    sendCommand<WritebackResult>('sim.retry_failed_writeback', { sessionId, confirmed: true }),

  confirmSync: (sessionId: string) =>
    sendCommand<boolean>('sim.confirm_sync', { sessionId }),

  cleanup: (sessionId: string) =>
    sendCommand<CleanupResult>('sim.cleanup', { sessionId, confirmed: true }),
}
