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
const MAX_FALLBACK_FULL_READ_BYTES = 192 * 1024 * 1024

export class SharpDecoder implements ImageDecoder {
  readonly name = 'Sharp (JPEG/PNG/TIFF/WebP + RAW embedded preview)'

  private static SUPPORTED = new Set(IMAGE_CONFIG.sharp.supportedExtensions)

  private static RAW_EXTENSIONS = new Set(IMAGE_CONFIG.sharp.rawExtensions)

  private settings: SettingsService
  private rawIndexDir: string
  private rawExtractionInFlight = new Map<
    string,
    Promise<{ jpeg: Buffer; orientation: number } | null>
  >()

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
      let pipeline = applyOrientation(sharp(raw.jpeg), raw.orientation)
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
      let pipeline = applyOrientation(sharp(raw.jpeg), raw.orientation)
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
    if (w <= 0 || h <= 0) {
      throw new Error(`Unable to determine image dimensions: ${path}`)
    }
    return { width: w, height: h }
  }

  // ── RAW file extraction ──

  private async extractFromRaw(filepath: string, targetSize?: number): Promise<{ jpeg: Buffer; orientation: number } | null> {
    const ext = filepath.slice(filepath.lastIndexOf('.')).toLowerCase()
    if (!SharpDecoder.RAW_EXTENSIONS.has(ext)) return null
    const existing = this.rawExtractionInFlight.get(filepath)
    if (existing) return existing
    const pending = this.extractFromRawUncoalesced(filepath, targetSize)
    this.rawExtractionInFlight.set(filepath, pending)
    try {
      return await pending
    } finally {
      if (this.rawExtractionInFlight.get(filepath) === pending) {
        this.rawExtractionInFlight.delete(filepath)
      }
    }
  }

  private async extractFromRawUncoalesced(
    filepath: string,
    targetSize?: number,
  ): Promise<{ jpeg: Buffer; orientation: number } | null> {
    const cached = await this.readRawIndex(filepath)
    if (cached) {
      const selected = selectBestSegment(cached.segments, targetSize)
      if (selected) {
        const jpeg = await readFileRange(filepath, selected.offset, selected.size)
        if (jpeg) return { jpeg, orientation: cached.orientation }
      }
      if (cached.segments.length === 0) return null
    }

    // Prefer container-aware extraction. For common camera RAW formats this
    // reads the embedded JPEG directly without loading and scanning the full
    // RAW file or invoking the much more expensive sips renderer.
    const extracted = await extractEmbeddedPreview(filepath)
    if (extracted) {
      // Persist the located segment so later thumbnail/preview/dimension
      // requests skip the repeated ExifTool probes. Failing to index means
      // every request re-runs three subprocess extractions.
      await this.persistIndexFromExtractedPreview(filepath, extracted)
      return extracted
    }

    // Compatibility fallback for synthetic, unusual, or partially supported
    // TIFF-based RAW containers whose JPEG segment ExifTool does not expose.
    // Bound the full read so a large or corrupt RAW cannot pull hundreds of
    // MB into the main process heap; returning null just falls through to the
    // next decoder (sharp path / sips on macOS).
    let buf: Buffer
    try {
      const fileStat = await fsp.stat(filepath)
      if (fileStat.size > MAX_FALLBACK_FULL_READ_BYTES) return null
      buf = await fsp.readFile(filepath)
    } catch {
      return null
    }

    const orientation = readTiffOrientation(buf)
    const segments = await findJpegSegmentsWithDimensions(buf)
    const selected = selectBestSegment(segments, targetSize)
    // Persist empty results as well. Without a negative index, each thumbnail,
    // dimension and preview request would repeat three ExifTool probes and a
    // full RAW read before falling back to sips.
    await this.writeRawIndex(filepath, orientation, segments)
    if (selected) {
      return {
        jpeg: buf.subarray(selected.offset, selected.offset + selected.size),
        orientation,
      }
    }

    return null
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

  private async persistIndexFromExtractedPreview(
    filepath: string,
    extracted: { jpeg: Buffer; orientation: number },
  ): Promise<void> {
    try {
      const buf = await fsp.readFile(filepath)
      const segments = await findJpegSegmentsWithDimensions(buf)
      const match = segments.find(segment => {
        const sub = buf.subarray(segment.offset, segment.offset + segment.size)
        if (sub.equals(extracted.jpeg)) return true
        // The embedded preview may carry trailing padding inside the tag.
        if (
          extracted.jpeg.length <= sub.length &&
          extracted.jpeg.equals(sub.subarray(0, extracted.jpeg.length))
        ) {
          return true
        }
        return false
      })
      if (match) {
        await this.writeRawIndex(filepath, extracted.orientation, [match])
      }
    } catch {
      // Indexing is an optimization; decoding must still succeed without it.
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

function findEoi(buf: Buffer, start: number, end: number): number {
  for (let j = start; j < end - 1; j++) {
    if (buf[j] === 0xFF && buf[j + 1] === 0xD9) return j + 2
  }
  return -1
}

// Single-pass segment scan. A SOI without any EOI ahead of it means there is
// no complete JPEG segment anywhere later in the buffer, so scanning stops
// there; this keeps the worst case linear instead of O(n²).
export function findJpegSegments(buf: Buffer): JpegSegment[] {
  const segments: JpegSegment[] = []
  const len = buf.length
  let i = 0
  while (i < len - 1) {
    if (buf[i] !== 0xFF || buf[i + 1] !== 0xD8) {
      i++
      continue
    }
    const end = findEoi(buf, i + 2, len)
    if (end < 0) break
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

async function extractEmbeddedPreview(
  filepath: string,
): Promise<{ jpeg: Buffer; orientation: number } | null> {
  const tags = ['JpgFromRaw', 'PreviewImage', 'ThumbnailImage'] as const
  for (const tag of tags) {
    try {
      const buffer = await withTimeout(
        exiftool.extractBinaryTagToBuffer(tag, filepath),
        EXIFTOOL_EXTRACT_TIMEOUT_MS,
      )
      const metadata = await sharp(buffer).metadata()
      if (metadata.width && metadata.height) {
        return { jpeg: buffer, orientation: metadata.orientation ?? 1 }
      }
    } catch {
      // This RAW does not expose the requested embedded-preview tag.
    }
  }
  return null
}

const EXIFTOOL_EXTRACT_TIMEOUT_MS = 120_000

let exiftoolResetInFlight: Promise<void> | null = null

function resetExiftoolPool(): void {
  if (exiftoolResetInFlight) return
  exiftoolResetInFlight = exiftool.end()
    .catch(error => console.warn('Failed to reset exiftool pool', error))
    .finally(() => { exiftoolResetInFlight = null })
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('Timed out')), timeoutMs)
      }),
    ])
  } catch (error) {
    // Promise.race alone would abandon the hung exiftool task, permanently
    // occupying one of the shared exiftool pool slots (two of which stalls
    // every exiftool operation, including embedded writes). Reset the pool so
    // a fresh process is spawned on the next call.
    if (error instanceof Error && error.message === 'Timed out') {
      resetExiftoolPool()
    }
    throw error
  } finally {
    if (timer) clearTimeout(timer)
  }
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

function applyOrientation(
  pipeline: sharp.Sharp,
  orientation: number,
): sharp.Sharp {
  switch (orientation) {
    case 2: return pipeline.flop()
    case 3: return pipeline.rotate(180)
    case 4: return pipeline.flip()
    case 5: return pipeline.rotate(90).flop()
    case 6: return pipeline.rotate(90)
    case 7: return pipeline.rotate(90).flip()
    case 8: return pipeline.rotate(270)
    default: return pipeline
  }
}
