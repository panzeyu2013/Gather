// packages/shared/src/protocol/filter.ts

export interface FilterPhotosParams { sessionId: string; criteria: FilterGroup; sortBy?: string; sortOrder?: string }
export interface FilterPhotosGlobalParams { criteria: FilterGroup }
export interface FilterSuggestParams { sessionId: string; keyword: string }
export interface AlbumCreateParams { name: string; criteria: FilterGroup; sortBy?: string; sortOrder?: string; description?: string; icon?: string }
export interface AlbumListParams { }
export interface AlbumGetParams { albumId: string }
export interface AlbumUpdateParams { albumId: string; name?: string; criteria?: FilterGroup; sortBy?: string; sortOrder?: string; description?: string; icon?: string }
export interface AlbumDeleteParams { albumId: string; confirmed: boolean }
export interface AlbumGetPhotosParams { albumId: string; limit?: number; offset?: number }

export interface FilterRule {
  field: string
  operator: 'eq' | 'neq' | 'gte' | 'lte' | 'gt' | 'lt' | 'between' | 'in' | 'contains' | 'contains_any' | 'contains_all' | 'starts_with' | 'regex' | 'exists'
  value: unknown
}

export interface FilterGroup {
  logic: 'and' | 'or'
  conditions: Array<FilterRule | FilterGroup>
}

export interface FilterSuggestion {
  field: string
  values: string[]
}

export interface GlobalPhotoResult {
  photoId: string
  sessionId: string
  sessionName: string
  filename: string
}

export interface SmartAlbumData {
  id: string
  name: string
  description: string
  filterCriteria: FilterGroup
  sortBy: string
  sortOrder: string
  icon: string
  createdAt: string
  updatedAt: string
}

export interface SmartAlbumDetailData extends SmartAlbumData {
  photoCount: number
}
