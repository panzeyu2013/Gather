import sharp from 'sharp'
import { SettingsService } from '../../settings'
import type { ImageDecoder, DecodeResult } from '../decoder'

export class SharpDecoder implements ImageDecoder {
  readonly name = 'Sharp (JPEG/PNG/TIFF/WebP)'

  private static SUPPORTED = new Set(['.jpg', '.jpeg', '.png', '.tif', '.tiff', '.webp'])
  private settings = SettingsService.getInstance()

  supports(ext: string): boolean {
    return SharpDecoder.SUPPORTED.has(ext)
  }

  async getPreview(path: string, maxDimension = 1920): Promise<DecodeResult> {
    const pipeline = sharp(path).resize(maxDimension, maxDimension, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: this.settings.getNumber('preview_quality', 85) })
    const { data, info } = await pipeline.toBuffer({ resolveWithObject: true })
    return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
  }

  async getThumbnail(path: string, size: number): Promise<DecodeResult> {
    const pipeline = sharp(path).resize(size, size, { fit: 'cover' }).jpeg({ quality: this.settings.getNumber('thumbnail_quality', 80) })
    const { data, info } = await pipeline.toBuffer({ resolveWithObject: true })
    return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const meta = await sharp(path).metadata()
    return { width: meta.width ?? 0, height: meta.height ?? 0 }
  }
}
