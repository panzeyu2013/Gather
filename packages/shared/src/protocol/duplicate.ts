// packages/shared/src/protocol/duplicate.ts

export interface DupScanParams { sessionId: string; sessionIds?: string[]; visualThreshold?: number }
export interface DupGroupsParams { sessionId: string }
export interface DupResolveParams { groupId: number; resolution: 'keep_one' | 'keep_all'; confirmed: boolean }
export interface DupResolveMemberParams { memberId: number; isKept: boolean; confirmed: boolean }

export interface DupScanOptions {
  visualThreshold: number
}

export interface DuplicateScanResult {
  exactGroups: DuplicateGroup[]
  visualGroups: DuplicateGroup[]
  totalDuplicates: number
}

export interface DuplicateGroup {
  id: number
  groupType: 'exact' | 'visual'
  checksum?: string
  hashHex?: string
  memberCount: number
  members: DuplicateGroupMember[]
  resolution: string | null
  createdAt: string
}

export interface DuplicateGroupMember {
  id: number
  photoId: string
  isKept: boolean
  fileSize: number | null
  fileMtime: string | null
  resolution: string | null
  filepath: string
  filename: string
}
