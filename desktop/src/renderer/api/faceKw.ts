import { sendCommand } from './client'
import type { FaceCluster, WritebackPreview, WritebackResult, CleanupResult } from '@gather/shared'

export interface FaceAnalysisResult {
  status: 'done' | 'failed' | 'cancelled'
  detectionFailures: number
  encodingFailures: number
}

export const faceKwApi = {
  analyze: (sessionId: string, opts?: { eps?: number; minSamples?: number; detectorPath?: string; encoderPath?: string }) =>
    sendCommand<FaceAnalysisResult>('fkw.analyze', { sessionId, ...opts }),

  recluster: (sessionId: string, eps: number, minSamples: number) =>
    sendCommand<{ done: boolean }>('fkw.recluster', { sessionId, eps, minSamples }),

  cancel: (sessionId: string) =>
    sendCommand<{ done: boolean }>('fkw.cancel_analysis', { sessionId }),

  getClusters: (sessionId: string) =>
    sendCommand<FaceCluster[]>('fkw.clusters', { sessionId }),

  bind: (sessionId: string, clusterId: number, roleName: string, keywords: string[]) =>
    sendCommand<{ done: boolean }>('fkw.bind', { sessionId, clusterId, roleName, keywords }),

  unbind: (sessionId: string, clusterId: number) =>
    sendCommand<{ done: boolean; removedKeywords: number }>('fkw.unbind', {
      sessionId,
      clusterId,
      confirmed: true,
    }),

  merge: (sessionId: string, sourceId: number, targetId: number) =>
    sendCommand<{ done: boolean }>('fkw.merge', { sessionId, source: sourceId, target: targetId }),

  getClusterThumbnail: (sessionId: string, clusterId: number) =>
    sendCommand<{ base64: string }>('fkw.get_cluster_thumbnail', { sessionId, clusterId }),

  removeMember: (sessionId: string, clusterId: number, memberId: number) =>
    sendCommand<{ done: boolean }>('fkw.remove_member', { sessionId, clusterId, memberId }),

  previewWriteback: (sessionId: string) =>
    sendCommand<WritebackPreview>('fkw.preview', { sessionId }),

  writeback: (sessionId: string, items: unknown[]) =>
    sendCommand<WritebackResult>('fkw.writeback', { sessionId, items, confirmed: true }),

  confirmSync: (sessionId: string) =>
    sendCommand<boolean>('fkw.confirm_sync', { sessionId }),

  confirmCleanup: (sessionId: string) =>
    sendCommand<CleanupResult>('fkw.confirm_cleanup', { sessionId, confirmed: true }),

  cleanup: (sessionId: string) =>
    sendCommand<CleanupResult>('fkw.cleanup', { sessionId, confirmed: true }),
}
