import { existsSync } from 'fs'
import { parseXmp, extractKeywords, writeXmpAttributes, backupXmpFile, restoreXmpFile } from './xmp-utils'
import type { MetadataWriter, MetadataWriteAttributes } from '../metadata/metadata-writer.interface'

export class XmpSidecarWriter implements MetadataWriter {
  private xmpPath(photoPath: string): string {
    return photoPath + '.xmp'
  }

  async readKeywords(photoPath: string): Promise<string[]> {
    const xp = this.xmpPath(photoPath)
    if (!existsSync(xp)) return []
    const doc = parseXmp(xp)
    if (!doc) return []
    return extractKeywords(doc)
  }

  async writeAttributes(photoPath: string, tags: MetadataWriteAttributes): Promise<void> {
    writeXmpAttributes(this.xmpPath(photoPath), {
      keywords: tags.keywords,
      rating: tags.rating,
      dateTaken: tags.dateTaken,
      latitude: tags.latitude,
      longitude: tags.longitude,
    })
  }

  async backup(photoPath: string): Promise<string> {
    return backupXmpFile(this.xmpPath(photoPath))
  }

  getBackupPath(photoPath: string): string {
    return this.xmpPath(photoPath) + '.bak'
  }

  async restore(photoPath: string, backupPath: string): Promise<void> {
    restoreXmpFile(this.xmpPath(photoPath), backupPath)
  }

  supportsFormat(_ext: string): boolean {
    return true
  }

  async shutdown(): Promise<void> {
    // no resources to release
  }
}
