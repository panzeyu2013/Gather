import * as fs from 'fs'
import sharp from 'sharp'
import { SettingsService } from '../../settings'
import type { ImageDecoder, DecodeResult } from '../decoder'

export class SharpDecoder implements ImageDecoder {
  readonly name = 'Sharp (JPEG/PNG/TIFF/WebP + RAW embedded preview)'

  private static SUPPORTED = new Set([
    '.jpg', '.jpeg', '.png', '.tif', '.tiff', '.webp',
    '.nef', '.nrw', '.cr2', '.dng', '.orf', '.pef', '.srw',
    '.arw', '.rw2', '.raf', '.mef', '.mos', '.3fr',
    '.erf', '.kdc', '.mrw', '.x3f',
  ])

  private static RAW_EXTENSIONS = new Set([
    '.nef', '.nrw', '.cr2', '.dng', '.orf', '.pef', '.srw',
    '.arw', '.rw2', '.raf', '.mef', '.mos', '.3fr',
    '.erf', '.kdc', '.mrw', '.x3f',
  ])

  private settings = SettingsService.getInstance()

  supports(ext: string): boolean {
    return SharpDecoder.SUPPORTED.has(ext)
  }

  async getPreview(path: string, _maxDimension = 1920): Promise<DecodeResult> {
    const raw = this.extractFromRaw(path)
    if (raw) {
      const angle = rotateAngle(raw.orientation)
      if (angle !== 0) {
        const { data, info } = await sharp(raw.jpeg).rotate(angle).keepExif().jpeg({ quality: 100 }).toBuffer({ resolveWithObject: true })
        return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
      }
      const meta = await sharp(raw.jpeg).metadata()
      return { buffer: raw.jpeg, format: 'jpeg', width: meta.width ?? 0, height: meta.height ?? 0 }
    }
    const pipeline = sharp(path).rotate().keepExif().resize(_maxDimension, _maxDimension, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: this.settings.getNumber('preview_quality', 85) })
    const { data, info } = await pipeline.toBuffer({ resolveWithObject: true })
    return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
  }

  async getThumbnail(path: string, size: number): Promise<DecodeResult> {
    const raw = this.extractFromRaw(path)
    if (raw) {
      let pipeline = sharp(raw.jpeg)
      const angle = rotateAngle(raw.orientation)
      if (angle !== 0) pipeline = pipeline.rotate(angle)
      pipeline = pipeline.keepExif().resize(size, size, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: this.settings.getNumber('thumbnail_quality', 80) })
      const { data, info } = await pipeline.toBuffer({ resolveWithObject: true })
      return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
    }
    const pipeline = sharp(path).rotate().keepExif().resize(size, size, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: this.settings.getNumber('thumbnail_quality', 80) })
    const { data, info } = await pipeline.toBuffer({ resolveWithObject: true })
    return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const raw = this.extractFromRaw(path)
    const meta = raw ? await sharp(raw.jpeg).metadata() : await sharp(path).metadata()
    let w = meta.width ?? 0
    let h = meta.height ?? 0
    if (meta.orientation && meta.orientation >= 5 && meta.orientation <= 8) {
      ;[w, h] = [h, w]
    }
    return { width: w, height: h }
  }

  // ── RAW file extraction ──

  private extractFromRaw(filepath: string): { jpeg: Buffer; orientation: number } | null {
    const ext = filepath.slice(filepath.lastIndexOf('.')).toLowerCase()
    if (!SharpDecoder.RAW_EXTENSIONS.has(ext)) return null

    let buf: Buffer
    try {
      buf = fs.readFileSync(filepath)
    } catch {
      return null
    }

    const orientation = readTiffOrientation(buf)
    const jpeg = findLargestJpeg(buf)
    if (!jpeg) return null
    return { jpeg, orientation }
  }
}

// ── Helpers ──

function readTiffOrientation(buf: Buffer): number {
  if (buf.length < 8) return 1
  const isLE = buf[0] === 0x49
  const r16 = (o: number) => isLE ? buf.readUInt16LE(o) : buf.readUInt16BE(o)
  const r32 = (o: number) => isLE ? buf.readUInt32LE(o) : buf.readUInt32BE(o)

  const firstIFD = r32(4)
  if (firstIFD < 8 || firstIFD + 2 >= buf.length) return 1

  const n = r16(firstIFD)
  for (let i = 0; i < n && firstIFD + 2 + (i + 1) * 12 <= buf.length; i++) {
    const eo = firstIFD + 2 + i * 12
    if (r16(eo) === 0x0112) return r32(eo + 8)
  }
  return 1
}

function findLargestJpeg(buf: Buffer): Buffer | null {
  let best: { offset: number; size: number } | null = null
  const len = buf.length

  for (let i = 0; i < len - 1; i++) {
    if (buf[i] !== 0xFF || buf[i + 1] !== 0xD8) continue

    let end = -1
    for (let j = i + 2; j < len - 1; j++) {
      if (buf[j] === 0xFF && buf[j + 1] === 0xD9) { end = j + 2; break }
    }
    if (end < 0) { i++; continue }

    const size = end - i
    if (!best || size > best.size) best = { offset: i, size }
    i = end
  }

  if (!best || best.size < 10000) return null
  return buf.subarray(best.offset, best.offset + best.size)
}

function rotateAngle(orientation: number): number {
  switch (orientation) {
    case 3: return 180
    case 6: return 90
    case 8: return 270
    default: return 0
  }
}
