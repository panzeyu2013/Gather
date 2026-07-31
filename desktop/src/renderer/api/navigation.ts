import type { NavigationGroup } from '@gather/shared'
import { sendCommand } from './client'

export const navigationApi = {
  analyze: (
    sessionId: string,
    burstGapSeconds?: number,
    sceneGapSeconds?: number,
    dryRun = false,
  ) => sendCommand<NavigationGroup[]>('navigation.analyze', {
    sessionId,
    burstGapSeconds,
    sceneGapSeconds,
    dryRun,
  }),
  list: (sessionId: string) =>
    sendCommand<NavigationGroup[]>('navigation.list', { sessionId }),
  split: (sessionId: string, groupId: string, beforePhotoId: string) =>
    sendCommand<NavigationGroup[]>('navigation.split', {
      sessionId,
      groupId,
      beforePhotoId,
    }),
  merge: (sessionId: string, groupIds: string[]) =>
    sendCommand<NavigationGroup[]>('navigation.merge', { sessionId, groupIds }),
}
