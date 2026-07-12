import * as fs from 'fs'
import * as fsp from 'fs/promises'
import sharp from 'sharp'
import { SettingsService } from '../../settings'
import { readDimensions } from './fast-dimensions'
import { IMAGE_CONFIG } from '../image-config'
import type { ImageDecoder, DecodeResult } from '../decoder'

const HEADER_READ_SIZE = 65536

export class SharpDecoder implements ImageDecoder {
  readonly name = 'Sharp (JPEG/PNG/TIFF/WebP + RAW embedded preview)'

  private static SUPPORTED = new Set(IMAGE_CONFIG.sharp.supportedExtensions)

  private static RAW_EXTENSIONS = new Set(IMAGE_CONFIG.sharp.rawExtensions)

  private settings = SettingsService.getInstance()

  supports(ext: string): boolean {
    return SharpDecoder.SUPPORTED.has(ext)
  }

  async getPreview(path: string, _maxDimension?: number): Promise<DecodeResult> {
    const raw = await this.extractFromRaw(path)
    if (raw) {
      const angle = rotateAngle(raw.orientation)
      let pipeline = sharp(raw.jpeg)
      if (angle !== 0) pipeline = pipeline.rotate(angle)
      if (_maxDimension) pipeline = pipeline.resize(_maxDimension, _maxDimension, { fit: 'inside', withoutEnlargement: true })
      const { data, info } = await pipeline.keepExif().jpeg({ quality: 100 }).toBuffer({ resolveWithObject: true })
      return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
    }
    let pipeline = sharp(path).rotate().keepExif()
    if (_maxDimension) pipeline = pipeline.resize(_maxDimension, _maxDimension, { fit: 'inside', withoutEnlargement: true })
    const { data, info } = await pipeline.jpeg({ quality: 100 }).toBuffer({ resolveWithObject: true })
    return { buffer: data, format: 'jpeg', width: info.width, height: info.height }
  }

  async getThumbnail(path: string, size: number): Promise<DecodeResult> {
    const raw = await this.extractFromRaw(path, size)
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
    const ext = path.slice(path.lastIndexOf('.')).toLowerCase()

    const header = await readFileHeader(path, HEADER_READ_SIZE)
    if (header) {
      const dims = readDimensions(header, ext)
      if (dims) return dims
    }

    const raw = await this.extractFromRaw(path)
    const meta = raw ? await sharp(raw.jpeg).metadata() : await sharp(path).metadata()
    let w = meta.width ?? 0
    let h = meta.height ?? 0
    if (meta.orientation && meta.orientation >= 5 && meta.orientation <= 8) {
      ;[w, h] = [h, w]
    }
    return { width: w, height: h }
  }

  // ── RAW file extraction ──

  private async extractFromRaw(filepath: string, targetSize?: number): Promise<{ jpeg: Buffer; orientation: number } | null> {
    const ext = filepath.slice(filepath.lastIndexOf('.')).toLowerCase()
    if (!SharpDecoder.RAW_EXTENSIONS.has(ext)) return null

    let buf: Buffer
    try {
      buf = fs.readFileSync(filepath)
    } catch {
      return null
    }

    const orientation = readTiffOrientation(buf)
    const jpeg = targetSize ? await findBestFitJpeg(buf, targetSize) : findLargestJpeg(buf)
    if (!jpeg) return null
    return { jpeg, orientation }
  }
}

// ── Helpers ──

interface JpegSegment {
  offset: number
  size: number
}

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

function findJpegSegments(buf: Buffer): JpegSegment[] {
  const segments: JpegSegment[] = []
  const len = buf.length

  for (let i = 0; i < len - 1; i++) {
    if (buf[i] !== 0xFF || buf[i + 1] !== 0xD8) continue

    let end = -1
    for (let j = i + 2; j < len - 1; j++) {
      if (buf[j] === 0xFF && buf[j + 1] === 0xD9) { end = j + 2; break }
    }
    if (end < 0) { i++; continue }

    const size = end - i
    if (size >= 10000) segments.push({ offset: i, size })
    i = end
  }

  return segments
}

function findLargestJpeg(buf: Buffer): Buffer | null {
  let best: JpegSegment | null = null
  for (const seg of findJpegSegments(buf)) {
    if (!best || seg.size > best.size) best = seg
  }
  if (!best) return null
  return buf.subarray(best.offset, best.offset + best.size)
}

async function findBestFitJpeg(buf: Buffer, targetSize: number): Promise<Buffer | null> {
  const segments = findJpegSegments(buf)
  if (segments.length === 0) return null

  type Scored = JpegSegment & { width: number }
  const valid: Scored[] = []

  for (const seg of segments) {
    try {
      const sub = buf.subarray(seg.offset, seg.offset + seg.size)
      const meta = await sharp(sub).metadata()
      if (meta.width) {
        valid.push({ offset: seg.offset, size: seg.size, width: meta.width })
      }
    } catch {
      // not a valid JPEG, skip
    }
  }

  if (valid.length === 0) return null

  valid.sort((a, b) => a.width - b.width)
  for (const v of valid) {
    if (v.width >= targetSize) {
      return buf.subarray(v.offset, v.offset + v.size)
    }
  }

  // fallback: largest by byte size
  valid.sort((a, b) => b.size - a.size)
  return buf.subarray(valid[0].offset, valid[0].offset + valid[0].size)
}

async function readFileHeader(filepath: string, size: number): Promise<Buffer | null> {
  try {
    const fd = await fsp.open(filepath, 'r')
    try {
      const buf = Buffer.alloc(size)
      const { bytesRead } = await fd.read(buf, 0, size, 0)
      return buf.subarray(0, bytesRead)
    } finally {
      await fd.close()
    }
  } catch {
    return null
  }
}

function rotateAngle(orientation: number): number {
  switch (orientation) {
    case 3: return 180
    case 6: return 90
    case 8: return 270
    default: return 0
  }
}
