// packages/shared/src/protocol/metadata.ts

export interface MetadataGetParams { photoIds: string[] }
export interface MetadataSetParams { photoId: string; tags: Partial<MetadataTags>; confirmed: boolean }
export interface MetadataBatchSetParams { updates: { photoId: string; tags: Partial<MetadataTags> }[]; confirmed: boolean }

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
