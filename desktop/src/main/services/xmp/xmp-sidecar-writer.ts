import { existsSync } from 'fs'
import * as path from 'path'
import {
  parseXmpAsync,
  extractKeywords,
  extractXmpAttributes,
  writeXmpAttributesAsync,
  backupXmpFileAsync,
  restoreXmpFileAsync,
} from './xmp-utils'
import type { MetadataWriter, MetadataWriteAttributes } from '../metadata/metadata-writer.interface'

export class XmpSidecarWriter implements MetadataWriter {
  constructor(
    private getColorCompatibility: () => string = () => 'label_and_urgency',
  ) {}

  private xmpPath(photoPath: string): string {
    return getXmpSidecarPath(photoPath)
  }

  async readKeywords(photoPath: string): Promise<string[]> {
    const xp = this.xmpPath(photoPath)
    if (!existsSync(xp)) return []
    const doc = await parseXmpAsync(xp)
    if (!doc) return []
    return extractKeywords(doc)
  }

  async readAttributes(photoPath: string): Promise<MetadataWriteAttributes> {
    const xp = this.xmpPath(photoPath)
    if (!existsSync(xp)) return {}
    const doc = await parseXmpAsync(xp)
    return doc ? extractXmpAttributes(doc) : {}
  }

  async writeAttributes(photoPath: string, tags: MetadataWriteAttributes): Promise<void> {
    await writeXmpAttributesAsync(this.xmpPath(photoPath), {
      keywords: tags.keywords,
      rating: tags.rating,
      label: tags.label,
      dateTaken: tags.dateTaken,
      latitude: tags.latitude,
      longitude: tags.longitude,
      writeUrgency: this.getColorCompatibility() !== 'label_only',
    })
  }

  async backup(photoPath: string): Promise<string> {
    const xmpPath = this.xmpPath(photoPath)
    return existsSync(xmpPath) ? backupXmpFileAsync(xmpPath) : ''
  }

  getBackupPath(photoPath: string): string {
    // backup() returns a unique path for each writeback transaction.
    return this.xmpPath(photoPath) + '.gather-backup'
  }

  async restore(photoPath: string, backupPath: string): Promise<void> {
    await restoreXmpFileAsync(this.xmpPath(photoPath), backupPath)
  }

  supportsFormat(_ext: string): boolean {
    return true
  }

  async shutdown(): Promise<void> {
    // no resources to release
  }
}

/**
 * Capture One associates files by basename: IMG_0001.NEF and IMG_0001.jpg
 * both use IMG_0001.xmp.
 */
export function getXmpSidecarPath(photoPath: string): string {
  const parsed = path.parse(photoPath)
  return path.join(parsed.dir, `${parsed.name}.xmp`)
}
