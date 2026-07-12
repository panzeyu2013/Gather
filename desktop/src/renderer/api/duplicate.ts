import { sendCommand } from './client'
import type { DuplicateScanResult, DuplicateGroup } from '@gather/shared'

export const duplicateApi = {
  scan: (sessionId: string, sessionIds?: string[], visualThreshold?: number) =>
    sendCommand<DuplicateScanResult>('dup.scan', {
      sessionId,
      ...(sessionIds ? { sessionIds } : {}),
      ...(visualThreshold !== undefined ? { visualThreshold } : {}),
    }),

  getGroups: (sessionId: string) =>
    sendCommand<DuplicateGroup[]>('dup.groups', { sessionId }),

  resolveGroup: (groupId: number, resolution: 'keep_one' | 'keep_all') =>
    sendCommand<boolean>('dup.resolve', { groupId, resolution, confirmed: true }),

  resolveMember: (memberId: number, isKept: boolean) =>
    sendCommand<boolean>('dup.resolve_member', { memberId, isKept, confirmed: true }),

  getThumbnail: (path: string) =>
    sendCommand<string>('thumbnail.get', { path }),
}
