// packages/shared/src/protocol/culling.ts

import type { PhotoData } from './session'

export type PickState = 'unreviewed' | 'picked' | 'rejected'
export type LegacyCullingDecision = 'keep' | 'reject' | 'pending'
export type CaptureOneColorLabel =
  | 'None'
  | 'Red'
  | 'Orange'
  | 'Yellow'
  | 'Green'
  | 'Blue'
  | 'Pink'
  | 'Purple'
export type CullingScope = 'all' | 'filtered' | 'similarity_group'
export type MetadataSyncStatus =
  | 'clean'
  | 'pending'
  | 'writing'
  | 'written'
  | 'failed'
  | 'conflict'
  | 'synced'
  | 'cleaned'

export interface CullingFilters {
  ratings?: number[]
  pickStates?: PickState[]
  colorLabels?: CaptureOneColorLabel[]
  unreviewedOnly?: boolean
}

export interface AssetCullingState {
  photoId: string
  pickState: PickState
  rating: number
  colorLabel: CaptureOneColorLabel
  revision: number
  updatedAt: string
}

export interface CullingAsset {
  photo: PhotoData
  state: AssetCullingState
  xmpPath: string
  syncStatus: MetadataSyncStatus
  people: string[]
  keywords: string[]
  similarityGroupId?: string
  linkedVariantCount: number
  faceBboxes: number[][]
}

export interface CullingListParams {
  sessionId: string
  scope: CullingScope
  filters?: CullingFilters
  groupId?: string
}

export interface CullingUpdatePatch {
  rating?: number
  pickState?: PickState
  colorLabel?: CaptureOneColorLabel
}

export interface CullingUpdateParams {
  sessionId: string
  photoId: string
  expectedRevision: number
  patch: CullingUpdatePatch
}

export interface CullingUpdateResult {
  states: AssetCullingState[]
  xmpPath: string
  syncStatus: MetadataSyncStatus
}

export interface CullingBatchUpdateParams {
  sessionId: string
  photoIds: string[]
  patch: CullingUpdatePatch
}

export interface CullingDecideGroupParams {
  sessionId: string
  groupId: string
  keepPhotoIds: string[]
}

export interface CullingSyncStatusParams { sessionId: string }
export interface CullingFlushParams { sessionId: string }
export interface CullingRetrySyncParams { sessionId: string }
export interface CullingFinalizeSyncParams { sessionId: string; confirmed: boolean }

export interface MetadataSyncItem {
  xmpPath: string
  revision: number
  persistedRevision: number
  status: MetadataSyncStatus
  attemptCount: number
  errorMessage: string
  updatedAt: string
}

export interface MetadataSyncSummary {
  sessionId: string
  pending: number
  writing: number
  written: number
  failed: number
  conflict: number
  synced: number
  items: MetadataSyncItem[]
}

// Compatibility contracts retained while the old Culling renderer is migrated.
export interface CullingGroupsParams { sessionId: string }
export interface CullingDecideParams { sessionId: string; photoId: string; decision: LegacyCullingDecision }
export interface CullingBatchDecideParams { sessionId: string; photoIds: string[]; decision: LegacyCullingDecision }
export interface CullingSummaryParams { sessionId: string }
export interface CullingWritebackParams { sessionId: string; confirmed: boolean; target: 'rating' | 'color_label' | 'keyword' }
export interface CullingRetryWritebackParams { sessionId: string; confirmed: boolean }
export interface CullingConfirmSyncParams { sessionId: string }
export interface CullingCleanupParams { sessionId: string; confirmed: boolean }
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
  decision: LegacyCullingDecision
}

export interface CullingSummary {
  totalGroups: number
  totalPhotos: number
  kept: number
  rejected: number
  pending: number
  rated: number
  labeled: number
}
