// packages/shared/src/protocol/culling.ts

export interface CullingGroupsParams { sessionId: string }
export interface CullingDecideParams { sessionId: string; photoId: string; decision: 'keep' | 'reject' | 'pending' }
export interface CullingBatchDecideParams { sessionId: string; photoIds: string[]; decision: 'keep' | 'reject' | 'pending' }
export interface CullingSummaryParams { sessionId: string }
export interface CullingWritebackParams { sessionId: string; confirmed: boolean; target: 'rating' | 'color_label' | 'keyword' }
export interface CullingResetParams { sessionId: string; groupId?: string; confirmed: boolean }

export interface CullingGroup {
  groupId: string
  groupIndex: number
  images: CullingImage[]
  keepCount: number
  rejectCount: number
  pendingCount: number
}

export interface CullingImage {
  photoId: string
  filepath: string
  filename: string
  decision: 'keep' | 'reject' | 'pending'
}

export interface CullingSummary {
  totalGroups: number
  totalPhotos: number
  kept: number
  rejected: number
  pending: number
}
