export type NavigationGroupType = 'burst' | 'scene'

export interface NavigationAnalyzeParams {
  sessionId: string
  burstGapSeconds?: number
  sceneGapSeconds?: number
  dryRun?: boolean
}

export interface NavigationGroup {
  id: string
  type: NavigationGroupType
  photoIds: string[]
  startAt: string
  endAt: string
  leadPhotoId?: string
  explanation: string
  source: 'automatic' | 'manual'
}

export interface NavigationListParams { sessionId: string }
export interface NavigationSplitParams {
  sessionId: string
  groupId: string
  beforePhotoId: string
}
export interface NavigationMergeParams {
  sessionId: string
  groupIds: string[]
}
