import * as path from 'path'
import { ExifTool } from 'exiftool-vendored'
import type { MetadataReader, MetadataWriteAttributes } from '../metadata/metadata-writer.interface'

const READ_ONLY_FORMATS = new Set(['.3fr'])

/** Formats the in-process exifr reader is verified to parse (XMP + IPTC). */
const EXIFR_READ_EXTENSIONS = new Set(['.jpg', '.jpeg'])

/** Dedicated exiftool pool for formats exifr cannot parse (TIFF/PNG/WebP/HEIC/…). */
const EXIFTOOL_POOL_SIZE = 4

// exiftool-vendored queues every call on a single child process
// (maxProcs = max(1, cpus / 4)), so a big session serializes thousands of
// embedded reads behind one subprocess. Reads for non-exifr formats get a
// dedicated pool instead of the shared default instance. The pool is also
// self-healing (mirroring sharp-decoder): a hung exiftool child is force
// killed after a timeout and the pool is recreated on the next call,
// otherwise every non-JPEG embedded read would stall forever.
let exiftoolPool: ExifTool | null = null
let exiftoolPoolResetInFlight: Promise<void> | null = null

const EXIFTOOL_POOL_READ_TIMEOUT_MS = 60_000

function getExiftoolPool(): ExifTool {
  exiftoolPool ??= new ExifTool({ maxProcs: EXIFTOOL_POOL_SIZE })
  return exiftoolPool
}

function resetExiftoolPool(): void {
  if (exiftoolPoolResetInFlight) return
  exiftoolPoolResetInFlight = (async () => {
    const stale = exiftoolPool
    // Swap first so concurrent callers lazily spawn a fresh pool instead of
    // piling onto the hung one; end() force-kills the hung children and
    // rejects the stale pool's queued tasks instead of leaving them hanging.
    exiftoolPool = null
    if (stale) await stale.end(false)
  })()
    .catch(error => console.warn('Failed to reset exiftool pool', error))
    .finally(() => { exiftoolPoolResetInFlight = null })
}

async function withPoolTimeout<T>(promise: Promise<T>): Promise<T> {
  let timer: NodeJS.Timeout | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('Timed out')), EXIFTOOL_POOL_READ_TIMEOUT_MS)
      }),
    ])
  } catch (error) {
    // A timed-out read means a hung exiftool child occupying a pool slot;
    // reset the whole pool so a fresh process is spawned on the next call.
    if (error instanceof Error && error.message === 'Timed out') {
      resetExiftoolPool()
    }
    throw error
  } finally {
    if (timer) clearTimeout(timer)
  }
}

async function readWithPool<T>(task: (pool: ExifTool) => Promise<T>): Promise<T> {
  try {
    return await withPoolTimeout(task(getExiftoolPool()))
  } catch (error) {
    // A concurrent read may have timed out and ended this pool while this
    // call was still queued; retry once on the freshly spawned pool.
    if (error instanceof Error && error.message.includes('has ended')) {
      return withPoolTimeout(task(getExiftoolPool()))
    }
    throw error
  }
}

async function getExifr() {
  try {
    return await import('exifr')
  } catch {
    return null
  }
}

/** Normalizes exifr keyword lists (single values arrive as scalars). */
function normalizeKeywordList(value: unknown): string[] | undefined {
  const list = Array.isArray(value) ? value : value === undefined || value === null ? [] : [value]
  const strings = list
    .filter((item): item is string | number => typeof item === 'string' || typeof item === 'number')
    .map(item => String(item))
  return strings.length > 0 ? strings : undefined
}

/**
 * Reads metadata embedded in deliverable formats (JPEG/TIFF/PNG/…).
 *
 * Write support was intentionally removed: the durable writeback pipeline is
 * sidecar-only so source images stay untouched. This type only provides reads.
 */
export class EmbeddedWriter implements MetadataReader {
  supportsFormat(ext: string): boolean {
    return !READ_ONLY_FORMATS.has(ext.toLowerCase())
  }

  async readKeywords(photoPath: string): Promise<string[]> {
    const attributes = await this.readAttributes(photoPath)
    return attributes.keywords ?? []
  }

  async readAttributes(photoPath: string): Promise<MetadataWriteAttributes> {
    const exifrAttributes = await this.readExifrAttributes(photoPath)
    if (exifrAttributes) return exifrAttributes
    const tags = await readWithPool(pool => pool.read(photoPath, {
      readArgs: ['Keywords', 'Rating', 'Label'],
    }))
    const keywords = tags.Keywords
      ? Array.isArray(tags.Keywords) ? tags.Keywords : [tags.Keywords]
      : undefined
    const rawRating = tags.Rating
    const rating = typeof rawRating === 'number'
      ? rawRating
      : typeof rawRating === 'string' && Number.isFinite(Number(rawRating))
        ? Number(rawRating)
        : undefined
    return {
      keywords,
      rating,
      label: typeof tags.Label === 'string' ? tags.Label : undefined,
    }
  }

  /**
   * In-process read for the hot JPEG path, keeping embedded rating/label/
   * keywords off the exiftool subprocess pool. Semantics mirror the exiftool
   * path: XMP dc:subject wins over IPTC Keywords, xmp:Rating (or the EXIF
   * 0x4746 rating) is coerced to a number. Returns null when the format or
   * the file is not parseable in-process so the caller falls back to the pool.
   */
  private async readExifrAttributes(photoPath: string): Promise<MetadataWriteAttributes | null> {
    if (!EXIFR_READ_EXTENSIONS.has(path.extname(photoPath).toLowerCase())) return null
    const exifr = await getExifr()
    if (!exifr) return null
    try {
      // The ambient exifr.d.ts only types the 1-arg parse; the full module
      // accepts options (xmp/iptc are off by default, so they must be asked
      // for explicitly).
      const parseWithOptions = exifr.parse as unknown as (
        filePath: string,
        options: Record<string, unknown>,
      ) => Promise<Record<string, unknown> | null>
      const parsed = await parseWithOptions(photoPath, {
        xmp: true,
        iptc: true,
        mergeOutput: false,
      })
      if (!parsed) return null
      const xmp = parsed.xmp as Record<string, unknown> | undefined
      const dc = parsed.dc as Record<string, unknown> | undefined
      const iptc = parsed.iptc as Record<string, unknown> | undefined
      const ifd0 = parsed.ifd0 as Record<string, unknown> | undefined
      const rawRating = xmp?.Rating ?? ifd0?.Rating
      const rating = typeof rawRating === 'number'
        ? rawRating
        : typeof rawRating === 'string' && Number.isFinite(Number(rawRating))
          ? Number(rawRating)
          : undefined
      const keywords = normalizeKeywordList(dc?.subject)
      if (keywords === undefined && iptc?.Keywords !== undefined) {
        // exifr's IPTC parser only walks Application Record (record 2)
        // datasets and decodes every value with a fixed charset, ignoring
        // the IPTC 1:90 CodedCharacterSet declaration (exifr has no API for
        // record 1 at all). Keywords that exist only in IPTC are therefore
        // unreliable through exifr — UTF-8 content declared via 1:90 comes
        // back as mojibake, and un-declared GBK/Latin-1 files are wrong too.
        // Fall back to the exiftool pool, which honors 1:90.
        return null
      }
      return {
        keywords: keywords ?? normalizeKeywordList(iptc?.Keywords),
        rating,
        label: typeof xmp?.Label === 'string' ? xmp.Label : undefined,
      }
    } catch {
      // Corrupt or unsupported files fall back to the exiftool pool.
      return null
    }
  }

  async shutdown(): Promise<void> {
    if (exiftoolPool) {
      const pool = exiftoolPool
      exiftoolPool = null
      try {
        await pool.end()
      } catch { /* ignore */ }
    }
  }
}
