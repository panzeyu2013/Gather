// packages/shared/src/protocol/metadata.ts

export interface MetadataGetParams { photoIds: string[] }
export interface MetadataSetParams { photoId: string; tags: Partial<MetadataTags>; confirmed: boolean }
export interface MetadataBatchSetParams { updates: { photoId: string; tags: Partial<MetadataTags> }[]; confirmed: boolean }

export type MetadataField = 'rating' | 'label' | 'keywords'
export type MetadataMutationSource = 'culling' | 'face-keyword' | 'similarity' | 'template' | 'manual'

export interface MetadataPatch {
  rating?: { op: 'set'; value: number }
  label?: { op: 'set'; value: string }
  keywords?: { op: 'append' | 'replace' | 'remove'; values: string[] }
}

export interface MetadataMutationRequest {
  target: { photoId: string }
  patch: MetadataPatch
  source: MetadataMutationSource
  sourceRevision?: number
  requestedAt: string
}

export interface MetadataMutationResult {
  photoId: string
  xmpPath: string
  dirtyFields: MetadataField[]
  revision: number
  status: string
}

export interface MetadataConflictField {
  field: MetadataField
  baseline: unknown
  local: unknown
  remote: unknown
}

export interface MetadataConflict {
  xmpPath: string
  photoPath: string
  revision: number
  fields: MetadataConflictField[]
}

export type MetadataConflictChoice = 'keep_local' | 'use_remote'
export interface MetadataConflictListParams { sessionId: string }
export interface MetadataConflictResolveParams {
  sessionId: string
  xmpPath: string
  choices: Partial<Record<MetadataField, MetadataConflictChoice>>
  confirmed: boolean
}

export interface MetadataOrphan {
  xmpPath: string
  photoPath: string
  status: string
  revision: number
  errorMessage: string
  updatedAt: string
}
export interface MetadataOrphanResolveParams {
  xmpPath: string
  action: 'keep' | 'restore' | 'retry'
  confirmed: boolean
}

export interface MetadataTags {
  filename?: string
  fileSize?: number
  format?: string
  width?: number
  height?: number
  mime?: string
  make?: string
  model?: string
  serialNumber?: string
  lensModel?: string
  focalLength?: number
  maxAperture?: number
  aperture?: number
  shutterSpeed?: string
  iso?: number
  exposureComp?: string
  meteringMode?: string
  whiteBalance?: string
  dateTaken?: string
  dateDigitized?: string
  title?: string
  description?: string
  author?: string
  copyright?: string
  keywords?: string[]
  rating?: number
  label?: string
  latitude?: number
  longitude?: number
  altitude?: number
}

export interface BatchMetadataResult {
  success: number
  failed: number
  errors: string[]
}
