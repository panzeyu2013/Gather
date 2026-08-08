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
  /**
   * Deprecated: base64-encoded JPEG thumbnail inlined in the payload.
   * Kept for backward compatibility; renderers should prefer `thumbnailPath`
   * and imageApi.thumbnailUrl instead (disk-cached, no base64 decode cost).
   */
  thumbnailBase64?: string
  /** File path of the person's most recent photo. Renderers display the
   * avatar via imageApi.thumbnailUrl(path, size); missing on legacy data
   * (no person_photos rows). */
  thumbnailPath?: string
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
  /** @deprecated Always undefined; use `filepath` + imageApi.thumbnailUrl. */
  thumbnailBase64?: string
}
