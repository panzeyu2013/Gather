import { exiftool } from 'exiftool-vendored'
import type { MetadataReader, MetadataWriteAttributes } from '../metadata/metadata-writer.interface'

const READ_ONLY_FORMATS = new Set(['.3fr'])

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
    const tags = await exiftool.read(photoPath, ['Keywords'])
    const kw = tags.Keywords
    if (!kw) return []
    return Array.isArray(kw) ? kw : [kw]
  }

  async readAttributes(photoPath: string): Promise<MetadataWriteAttributes> {
    const tags = await exiftool.read(photoPath, ['Keywords', 'Rating', 'Label'])
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

  async shutdown(): Promise<void> {
    try {
      await exiftool.end()
    } catch { /* ignore */ }
  }
}
