export interface AssetCandidateListParams {
  sessionId?: string
}

export interface AssetCandidateMutationParams {
  candidateId: string
  confirmed: boolean
}

export interface AssetLinkCandidateData {
  id: string
  leftFileId: string
  rightFileId: string
  leftPath: string
  rightPath: string
  confidence: number
  status: 'pending' | 'accepted' | 'rejected'
  evidence: Record<string, unknown>
}

export interface AssetVolumeData {
  volumeId: string
  roots: string[]
  onlineFiles: number
  offlineFiles: number
}

export interface AssetRelinkRootParams {
  oldRoot: string
  newRoot: string
  confirmed: boolean
}
