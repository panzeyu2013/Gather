import * as fsp from 'fs/promises'
import * as crypto from 'crypto'
import * as nodePath from 'path'
import { app } from 'electron'
import sharp from 'sharp'
import { exiftool } from 'exiftool-vendored'
import { SettingsService } from '../../settings/settings.service'
import { readDimensions } from './fast-dimensions'
import { IMAGE_CONFIG } from '../image-config'
import type { ImageDecoder, DecodeResult } from '../decoder'

const HEADER_READ_SIZE = 65536

export class SharpDecoder implements ImageDecoder {
  readonly name = 'Sharp (JPEG/PNG/TIFF/WebP + RAW embedded preview)'

  private static SUPPORTED = new Set(IMAGE_CONFIG.sharp.supportedExtensions)

  private static RAW_EXTENSIONS = new Set(IMAGE_CONFIG.sharp.rawExtensions)

  private settings: SettingsService
  private rawIndexDir: string

  constructor(settings: SettingsService) {
    this.settings = settings
    const cacheRoot = settings.get('disk_cache_dir', '') ||
      nodePath.join(app.getPath('userData'), 'thumbnails')
    this.rawIndexDir = nodePath.join(cacheRoot, 'raw-index')
  }

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
    const isRaw = SharpDecoder.RAW_EXTENSIONS.has(ext)

    const header = await readFileHeader(path, HEADER_READ_SIZE)
    if (header) {
      const dims = readDimensions(header, ext)
      if (dims) {
        let { width, height } = dims
        if (isRaw) {
          const orientation = readTiffOrientation(header)
          if (orientation >= 5 && orientation <= 8) {
            ;[width, height] = [height, width]
          }
        }
        return { width, height }
      }
    }

    const raw = await this.extractFromRaw(path)
    const meta = raw ? await sharp(raw.jpeg).metadata() : await sharp(path).metadata()
    let w = meta.width ?? 0
    let h = meta.height ?? 0
    const orientation = raw?.orientation ?? meta.orientation ?? 1
    if (orientation >= 5 && orientation <= 8) {
      ;[w, h] = [h, w]
    }
    return { width: w, height: h }
  }

  // ── RAW file extraction ──

  private async extractFromRaw(filepath: string, targetSize?: number): Promise<{ jpeg: Buffer; orientation: number } | null> {
    const ext = filepath.slice(filepath.lastIndexOf('.')).toLowerCase()
    if (!SharpDecoder.RAW_EXTENSIONS.has(ext)) return null

    const cached = await this.readRawIndex(filepath)
    if (cached) {
      const selected = selectBestSegment(cached.segments, targetSize)
      if (selected) {
        const jpeg = await readFileRange(filepath, selected.offset, selected.size)
        if (jpeg) return { jpeg, orientation: cached.orientation }
      }
    }

    let buf: Buffer
    try {
      buf = await fsp.readFile(filepath)
    } catch {
      return null
    }

    const orientation = readTiffOrientation(buf)
    const segments = await findJpegSegmentsWithDimensions(buf)
    const selected = selectBestSegment(segments, targetSize)
    if (selected) {
      await this.writeRawIndex(filepath, orientation, segments)
      return {
        jpeg: buf.subarray(selected.offset, selected.offset + selected.size),
        orientation,
      }
    }

    // Some RAW containers (notably CR3/IIQ) do not expose their preview as a
    // simple TIFF JPEG segment. ExifTool reads the container offsets directly,
    // so keep this as the final embedded-preview attempt before ImageService
    // falls back to rendering the RAW through sips.
    const extracted = await extractEmbeddedPreview(filepath)
    return extracted ? { jpeg: extracted, orientation } : null
  }

  private indexPath(filepath: string): string {
    const hash = crypto.createHash('sha256').update(filepath).digest('hex')
    return nodePath.join(this.rawIndexDir, `${hash}.json`)
  }

  private async readRawIndex(filepath: string): Promise<RawPreviewIndex | null> {
    try {
      const [sourceStat, raw] = await Promise.all([
        fsp.stat(filepath),
        fsp.readFile(this.indexPath(filepath), 'utf8'),
      ])
      const parsed = JSON.parse(raw) as RawPreviewIndex
      if (
        parsed.fileSize !== sourceStat.size ||
        Math.abs(parsed.fileMtimeMs - sourceStat.mtimeMs) >= 1 ||
        !Array.isArray(parsed.segments)
      ) {
        return null
      }
      return parsed
    } catch {
      return null
    }
  }

  private async writeRawIndex(
    filepath: string,
    orientation: number,
    segments: ScoredJpegSegment[],
  ): Promise<void> {
    try {
      const stat = await fsp.stat(filepath)
      await fsp.mkdir(this.rawIndexDir, { recursive: true })
      const index: RawPreviewIndex = {
        fileSize: stat.size,
        fileMtimeMs: stat.mtimeMs,
        orientation,
        segments,
      }
      await fsp.writeFile(this.indexPath(filepath), JSON.stringify(index), 'utf8')
    } catch {
      // Indexing is an optimization; decoding must still succeed without it.
    }
  }
}

// ── Helpers ──

interface JpegSegment {
  offset: number
  size: number
}

interface ScoredJpegSegment extends JpegSegment {
  width: number
  height: number
}

interface RawPreviewIndex {
  fileSize: number
  fileMtimeMs: number
  orientation: number
  segments: ScoredJpegSegment[]
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
    if (r16(eo) === 0x0112) {
      const type = r16(eo + 2)
      return type === 3 ? r16(eo + 8) : r32(eo + 8)
    }
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

async function findJpegSegmentsWithDimensions(buf: Buffer): Promise<ScoredJpegSegment[]> {
  const segments = findJpegSegments(buf)
  const valid: ScoredJpegSegment[] = []

  for (const seg of segments) {
    try {
      const sub = buf.subarray(seg.offset, seg.offset + seg.size)
      const meta = await sharp(sub).metadata()
      if (meta.width && meta.height) {
        valid.push({
          offset: seg.offset,
          size: seg.size,
          width: meta.width,
          height: meta.height,
        })
      }
    } catch {
      // not a valid JPEG, skip
    }
  }
  return valid
}

function selectBestSegment(
  valid: ScoredJpegSegment[],
  targetSize?: number,
): ScoredJpegSegment | null {
  if (valid.length === 0) return null
  if (targetSize) {
    const ascending = [...valid].sort(
      (a, b) => Math.max(a.width, a.height) - Math.max(b.width, b.height),
    )
    for (const v of ascending) {
      if (Math.max(v.width, v.height) >= targetSize) {
        return v
      }
    }
  }

  // For full previews, and when no candidate reaches targetSize, prefer the
  // candidate with the greatest pixel area. Byte size alone can select an
  // unrelated or unusually-compressed JPEG segment inside a RAW container.
  return [...valid].sort(
    (a, b) => (b.width * b.height) - (a.width * a.height) || b.size - a.size,
  )[0]
}

async function readFileRange(
  filepath: string,
  offset: number,
  size: number,
): Promise<Buffer | null> {
  try {
    const handle = await fsp.open(filepath, 'r')
    try {
      const buffer = Buffer.allocUnsafe(size)
      const { bytesRead } = await handle.read(buffer, 0, size, offset)
      return bytesRead === size ? buffer : null
    } finally {
      await handle.close()
    }
  } catch {
    return null
  }
}

async function extractEmbeddedPreview(filepath: string): Promise<Buffer | null> {
  const tags = ['JpgFromRaw', 'PreviewImage', 'ThumbnailImage'] as const
  for (const tag of tags) {
    try {
      const buffer = await exiftool.extractBinaryTagToBuffer(tag, filepath)
      const metadata = await sharp(buffer).metadata()
      if (metadata.width && metadata.height) return buffer
    } catch {
      // This RAW does not expose the requested embedded-preview tag.
    }
  }
  return null
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
