// src/main/services/image/decoder.ts

export interface DecodeResult {
  buffer: Buffer
  format: 'jpeg' | 'png' | 'webp'
  width: number
  height: number
}

export interface ImageDecoder {
  getPreview(path: string, maxDimension: number): Promise<DecodeResult>
  getDimensions(path: string): Promise<{ width: number; height: number }>
  getThumbnail(path: string, size: number): Promise<DecodeResult>
  readonly name: string
  supports(ext: string): boolean
}
