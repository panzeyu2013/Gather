import { sendCommand } from './client'
import type { SimilarityGroup, SimilarityImage, WritebackPreview, WritebackResult, WritebackOptions } from '@gather/shared'

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

  previewWriteback: (sessionId: string, groupIds: Array<number | string>, options: WritebackOptions) =>
    sendCommand<WritebackPreview>('sim.preview_writeback', { sessionId, groupIds, options }),

  writeback: (sessionId: string, groupIds: Array<number | string>, options: WritebackOptions) =>
    sendCommand<WritebackResult>('sim.writeback', { sessionId, groupIds, options, confirmed: true }),

  getWritebackItems: (sessionId: string) =>
    sendCommand<WritebackPreview>('sim.writeback_items', { sessionId }),

  retryFailedWriteback: (sessionId: string) =>
    sendCommand<WritebackResult>('sim.retry_failed_writeback', { sessionId, confirmed: true }),

  getThumbnail: (path: string) =>
    sendCommand<string>('thumbnail.get', { path }),
}
