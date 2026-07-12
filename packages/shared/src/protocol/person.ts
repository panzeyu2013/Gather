// packages/shared/src/protocol/person.ts

export interface PersonListParams { }
export interface PersonGetParams { personId: string }
export interface PersonCreateParams { name: string; keywords?: string[] }
export interface PersonUpdateParams { personId: string; name?: string; keywords?: string[]; notes?: string; matchThreshold?: number }
export interface PersonDeleteParams { personId: string; confirmed: boolean }
export interface PersonMergeParams { sourceId: string; targetId: string; confirmed: boolean }
export interface PersonRemovePhotoParams { personId: string; photoId: string; confirmed: boolean }
export interface PersonSearchPhotosParams { personId: string; sessionIds?: string[]; limit?: number; offset?: number }

export interface PersonData {
  id: string
  name: string
  keywords: string[]
  thumbnailBase64?: string
  notes: string
  matchThreshold: number
  photoCount: number
  sessionCount: number
  createdAt: string
  updatedAt: string
}

export interface PersonDetailData extends PersonData {
  photos: PersonPhotoItem[]
  totalPhotoCount: number
}

export interface PersonPhotoItem {
  photoId: string
  sessionId: string
  sessionName: string
  filename: string
  filepath: string
  faceBbox: number[]
  confidence: number
  thumbnailBase64?: string
}
