import { PhotoRepository } from '../../db/repositories/photo.repo'
import type { PhotoRow } from '../../db/repositories/photo.repo'
import type { ExportOptions, ExportPreview, ExportResult, ExportProgressEvent, ReportData } from '@gather/shared'
import sharp from 'sharp'
import * as fs from 'fs'
import * as path from 'path'
import * as os from 'os'

function escapeCsvField(value: string): string {
  if (value.includes(',') || value.includes('"') || value.includes('\n')) {
    return '"' + value.replace(/"/g, '""') + '"'
  }
  return value
}

function validateDestination(destination: string): void {
  if (!destination || typeof destination !== 'string') {
    throw new Error('Invalid destination path')
  }
  const resolved = path.resolve(destination)
  const home = os.homedir()
  const picturesDir = path.join(home, 'Pictures')
  const documentsDir = path.join(home, 'Documents')
  const desktopDir = path.join(home, 'Desktop')
  const allowedRoots = [picturesDir, documentsDir, desktopDir, home]
  const isAllowed = allowedRoots.some((root) => resolved.startsWith(root + path.sep) || resolved === root)
  if (!isAllowed) {
    throw new Error('Export destination must be under your home directory (Documents, Pictures, Desktop)')
  }
}

function sanitizeFilenameComponent(name: string): string {
  return path.basename(name.replace(/[<>:"/\\|?*]/g, '_'))
}

function getFreeSpace(dir: string): number {
  try {
    if (process.platform === 'win32') {
      const { execSync } = require('child_process')
      const result = execSync(`wmic logicaldisk where "DeviceID='${dir.charAt(0)}:'" get FreeSpace /value`, { timeout: 5000 }).toString()
      const match = result.match(/FreeSpace=(\d+)/)
      return match ? parseInt(match[1], 10) : 0
    } else {
      const { execSync } = require('child_process')
      const result = execSync(`df -k "${dir}" | tail -1`, { timeout: 5000 }).toString()
      const parts = result.trim().split(/\s+/)
      if (parts.length >= 4) {
        return parseInt(parts[3], 10) * 1024
      }
    }
  } catch {
    /* fall through */
  }
  return 0
}

export class ExportService {
  private cancelFlags = new Map<string, boolean>()
  private photoRepo = new PhotoRepository()

  cancel(sessionId: string): void {
    this.cancelFlags.set(sessionId, true)
  }

  preview(sessionId: string, options: ExportOptions): ExportPreview {
    validateDestination(options.destination)
    const photos = this.photoRepo.getBySession(sessionId)
    const filtered = this.filterPhotos(photos, options)
    const files: { photoId: string; filename: string; fileSize: number }[] = []
    let totalSizeBytes = 0

    for (const photo of filtered) {
      try {
        const stat = fs.statSync(photo.filepath)
        files.push({ photoId: photo.id, filename: photo.filename, fileSize: stat.size })
        totalSizeBytes += stat.size
      } catch {
        files.push({ photoId: photo.id, filename: photo.filename, fileSize: 0 })
      }
    }

    const freeSpaceBytes = getFreeSpace(options.destination)

    return {
      totalFiles: files.length,
      totalSizeBytes,
      freeSpaceBytes,
      files,
    }
  }

  async execute(
    sessionId: string,
    options: ExportOptions,
    onProgress?: (e: ExportProgressEvent) => void,
  ): Promise<ExportResult> {
    this.cancelFlags.set(sessionId, false)
    validateDestination(options.destination)
    const photos = this.photoRepo.getBySession(sessionId)
    const filtered = this.filterPhotos(photos, options)
    const total = filtered.length
    let exported = 0
    let failed = 0
    let skipped = 0
    const errors: string[] = []
    let counter = options.naming.counterStart ?? 1
    const usedNames = new Set<string>()

    const destination = path.resolve(options.destination)
    if (!fs.existsSync(destination)) {
      fs.mkdirSync(destination, { recursive: true })
    }

    for (let i = 0; i < filtered.length; i++) {
      if (this.cancelFlags.get(sessionId)) {
        skipped += filtered.length - i
        break
      }

      const photo = filtered[i]
      try {
        let destName = this.resolveNaming(photo, options, counter)
        const destPath = path.join(destination, destName)
        const resolvedDest = path.resolve(destPath)
        if (!resolvedDest.startsWith(destination + path.sep) && resolvedDest !== destination) {
          throw new Error(`Invalid destination path for ${photo.filename}`)
        }

        if (!usedNames.has(destName)) {
          usedNames.add(destName)
        } else {
          const ext = path.extname(destName)
          const base = destName.slice(0, -ext.length)
          let dedupeIdx = 2
          let candidate = `${base}_${dedupeIdx}${ext}`
          while (usedNames.has(candidate)) {
            dedupeIdx++
            candidate = `${base}_${dedupeIdx}${ext}`
          }
          destName = candidate
          usedNames.add(destName)
        }

        if (options.format === 'original') {
          if (options.includeXmp) {
            await fs.promises.cp(photo.filepath, destPath)
            const xmpPath = photo.filepath + '.xmp'
            if (fs.existsSync(xmpPath)) {
              await fs.promises.cp(xmpPath, destPath + '.xmp')
            }
          } else {
            await fs.promises.cp(photo.filepath, destPath)
          }
        } else {
          await this.convertAndExport(photo.filepath, destPath, options)
          if (options.includeXmp) {
            const xmpPath = photo.filepath + '.xmp'
            if (fs.existsSync(xmpPath)) {
              await fs.promises.cp(xmpPath, destPath + '.xmp')
            }
          }
        }

        const stat = fs.statSync(destPath)
        exported++
        counter++

        onProgress?.({
          current: i + 1,
          total,
          fileName: destName,
          bytesWritten: stat.size,
          status: 'done',
        })
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        errors.push(`${photo.filename}: ${message}`)
        failed++

        onProgress?.({
          current: i + 1,
          total,
          fileName: photo.filename,
          bytesWritten: 0,
          status: 'error',
          errorMessage: message,
        })
      }
    }

    return {
      totalFiles: total,
      exported,
      failed,
      skipped,
      errors,
    }
  }

  generateReport(sessionId: string, reportType: string, format?: string): ReportData {
    const photos = this.photoRepo.getBySession(sessionId)
    const reportFormat = (format === 'md' ? 'md' : 'csv') as 'csv' | 'md'
    let content = ''

    if (reportType === 'session_summary') {
      if (reportFormat === 'csv') {
        content = 'filename,filepath\n'
        content += photos.map((p) => `${escapeCsvField(p.filename)},${escapeCsvField(p.filepath)}`).join('\n')
      } else {
        content = '# Session Export Report\n\n'
        content += `Total photos: ${photos.length}\n\n`
        content += '| Filename | Filepath |\n'
        content += '|----------|----------|\n'
        content += photos.map((p) => `| ${p.filename.replace(/\|/g, '\\|')} | ${p.filepath.replace(/\|/g, '\\|')} |`).join('\n')
      }
    }

    return {
      path: '',
      content,
      format: reportFormat,
    }
  }

  private filterPhotos(photos: PhotoRow[], options: ExportOptions): PhotoRow[] {
    if (options.scope === 'session') return photos
    if (options.skipRemoved) {
      return photos.filter((p) => p.status !== 'removed')
    }
    return photos
  }

  private resolveNaming(photo: PhotoRow, options: ExportOptions, counter: number): string {
    const now = new Date()
    const dateStr = this.formatDate(now, options.naming.dateFormat ?? 'YYYY-MM-DD')
    const timeStr = now.toTimeString().slice(0, 8).replace(/:/g, '-')
    const ext = path.extname(photo.filename)
    const baseName = sanitizeFilenameComponent(path.basename(photo.filename, ext))
    const sessionName = sanitizeFilenameComponent(photo.session_id)

    let pattern = options.naming.pattern
    pattern = pattern.replace(/\{date\}/g, dateStr)
    pattern = pattern.replace(/\{time\}/g, timeStr)
    pattern = pattern.replace(/\{counter\}/g, String(counter).padStart(4, '0'))
    pattern = pattern.replace(/\{original\}/g, baseName)
    pattern = pattern.replace(/\{session\}/g, sessionName)

    const targetExt = options.format === 'jpeg' ? '.jpg' : options.format === 'tiff' ? '.tiff' : ext
    return pattern + targetExt
  }

  private formatDate(date: Date, dateFormat: string): string {
    const y = date.getFullYear()
    const m = String(date.getMonth() + 1).padStart(2, '0')
    const d = String(date.getDate()).padStart(2, '0')
    return dateFormat
      .replace('YYYY', String(y))
      .replace('MM', m)
      .replace('DD', d)
  }

  private async convertAndExport(
    sourcePath: string,
    destPath: string,
    options: ExportOptions,
  ): Promise<void> {
    let pipeline = sharp(sourcePath)

    if (options.maxDimension) {
      pipeline = pipeline.resize(options.maxDimension, options.maxDimension, {
        fit: 'inside',
        withoutEnlargement: true,
      })
    }

    if (options.watermark) {
      const svg = this.buildWatermarkSvg(options.watermark)
      const overlay = Buffer.from(svg)
      const overlayMeta = await sharp(overlay).metadata()

      const gravity = options.watermark.position === 'center' ? 'centre'
        : options.watermark.position === 'bottom-right' ? 'southeast'
        : 'southwest'

      pipeline = pipeline.composite([
        {
          input: overlay,
          gravity,
          blend: 'over',
        },
      ])
    }

    if (options.format === 'jpeg') {
      pipeline = pipeline.jpeg({ quality: options.quality ?? 85 })
    } else if (options.format === 'tiff') {
      const compression = options.tiffCompression ?? 'lzw'
      const compMap: Record<string, 'lzw' | 'deflate' | 'none'> = {
        none: 'none',
        lzw: 'lzw',
        deflate: 'deflate',
      }
      pipeline = pipeline.tiff({ compression: compMap[compression] ?? 'lzw' })
    } else {
      throw new Error(`Unsupported export format: ${options.format}. Supported: jpeg, tiff, original`)
    }

    await pipeline.toFile(destPath)
  }

  private buildWatermarkSvg(watermark: NonNullable<ExportOptions['watermark']>): string {
    const opacity = Math.round((watermark.opacity ?? 0.5) * 255)
      .toString(16)
      .padStart(2, '0')
    const fontSize = watermark.fontSize ?? 24
    const content = watermark.content.slice(0, 256)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')

    return `<svg width="400" height="80" xmlns="http://www.w3.org/2000/svg">
  <text x="200" y="50" text-anchor="middle" font-family="Arial" font-size="${fontSize}" fill="#ffffff${opacity}" stroke="#000000${opacity}" stroke-width="1">${content}</text>
</svg>`
  }
}
