import { exiftool } from 'exiftool-vendored'
import { existsSync, unlinkSync } from 'fs'
import { copyFile } from 'fs/promises'
import type { MetadataWriter, MetadataWriteAttributes } from '../metadata/metadata-writer.interface'

const READ_ONLY_FORMATS = new Set(['.3fr'])

export class EmbeddedWriter implements MetadataWriter {
  supportsFormat(ext: string): boolean {
    return !READ_ONLY_FORMATS.has(ext.toLowerCase())
  }

  async readKeywords(photoPath: string): Promise<string[]> {
    const tags = await exiftool.read(photoPath, ['Keywords'])
    const kw = tags.Keywords
    if (!kw) return []
    return Array.isArray(kw) ? kw : [kw]
  }

  async writeAttributes(photoPath: string, tags: MetadataWriteAttributes): Promise<void> {
    const writeTags: Record<string, unknown> = {}
    if (tags.keywords !== undefined) writeTags.Keywords = tags.keywords
    if (tags.rating !== undefined) writeTags.Rating = tags.rating
    if (tags.dateTaken !== undefined) writeTags.DateTimeOriginal = tags.dateTaken
    if (tags.latitude !== undefined && tags.longitude !== undefined) {
      writeTags.GPSLatitude = tags.latitude
      writeTags.GPSLatitudeRef = tags.latitude >= 0 ? 'N' : 'S'
      writeTags.GPSLongitude = tags.longitude
      writeTags.GPSLongitudeRef = tags.longitude >= 0 ? 'E' : 'W'
    }
    await exiftool.write(photoPath, writeTags, ['-overwrite_original'])
  }

  async backup(photoPath: string): Promise<string> {
    if (!existsSync(photoPath)) return ''
    const backupPath = this.getBackupPath(photoPath)
    await copyFile(photoPath, backupPath)
    return backupPath
  }

  getBackupPath(photoPath: string): string {
    return photoPath + '.gather_bak'
  }

  async restore(photoPath: string, backupPath: string): Promise<void> {
    if (existsSync(backupPath)) {
      await copyFile(backupPath, photoPath)
      unlinkSync(backupPath)
    }
  }

  async shutdown(): Promise<void> {
    try {
      await exiftool.end()
    } catch { /* ignore */ }
  }
}
