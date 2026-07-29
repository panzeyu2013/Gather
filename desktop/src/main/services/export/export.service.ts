import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import type { PhotoRow } from '../../db/repositories/photo.repo'
import type { ExportOptions, ExportPreview, ExportResult, ExportProgressData, ReportData } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import sharp from 'sharp'
import * as fs from 'fs'
import * as path from 'path'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'
import { batchAsync } from '../../utils/async'
import { heavyTaskScheduler } from '../../utils/heavy-task-scheduler'

function escapeCsvField(value: string): string {
  if (value.includes(',') || value.includes('"') || value.includes('\n')) {
    return '"' + value.replace(/"/g, '""') + '"'
  }
  return value
}

function validateDestination(destination: string): void {
  if (!destination || typeof destination !== 'string') {
    throw new Error('导出目录无效')
  }
  if (!path.isAbsolute(destination)) {
    throw new Error('导出目录必须使用绝对路径')
  }
  const resolved = path.resolve(destination)
  if (resolved === path.parse(resolved).root) {
    throw new Error('不能直接导出到磁盘根目录')
  }
}

function validateExportOptions(options: ExportOptions): void {
  validateDestination(options.destination)
  if (!['original', 'jpeg', 'tiff'].includes(options.format)) {
    throw new Error('导出格式无效')
  }
  if (options.format === 'original' && (options.maxDimension || options.watermark)) {
    throw new Error('保持原格式仅复制文件，不能同时调整尺寸或添加水印')
  }
  if (!options.naming?.pattern?.trim()) {
    throw new Error('文件命名规则不能为空')
  }
}

function sanitizeFilenameComponent(name: string): string {
  return path.basename(name.replace(/[<>:"/\\|?*]/g, '_'))
}

async function getFreeSpace(dir: string): Promise<number> {
  try {
    let existingDir = path.resolve(dir)
    while (true) {
      try {
        await fs.promises.access(existingDir)
        break
      } catch {
        // Walk up to the nearest existing parent.
      }
      const parent = path.dirname(existingDir)
      if (parent === existingDir) return 0
      existingDir = parent
    }
    const fileSystem = await fs.promises.statfs(existingDir)
    return Number(fileSystem.bavail) * Number(fileSystem.bsize)
  } catch {
    /* fall through */
  }
  return 0
}

@injectable()
export class ExportService {
  private cancelFlags = new Map<string, boolean>()

  constructor(
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
  ) {}

  cancel(sessionId: string): void {
    this.cancelFlags.set(sessionId, true)
  }

  async preview(sessionId: string, options: ExportOptions): Promise<ExportPreview> {
    validateExportOptions(options)
    const photos = this.photoRepo.getBySession(sessionId)
    const filtered = this.filterPhotos(photos, options)
    const files = await batchAsync(filtered, async (photo) => {
      try {
        const sourceStat = await fs.promises.stat(photo.filepath)
        return { photoId: photo.id, filename: photo.filename, fileSize: sourceStat.size }
      } catch {
        return { photoId: photo.id, filename: photo.filename, fileSize: 0 }
      }
    }, 32)
    const totalSizeBytes = files.reduce((sum, file) => sum + file.fileSize, 0)

    const freeSpaceBytes = await getFreeSpace(options.destination)

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
    onProgress?: (e: ExportProgressData) => void,
  ): Promise<ExportResult> {
    this.cancelFlags.set(sessionId, false)
    validateExportOptions(options)
    const photos = this.photoRepo.getBySession(sessionId)
    const sessionName = this.sessionRepo.get(sessionId)?.name ?? sessionId
    const filtered = this.filterPhotos(photos, options)
    const total = filtered.length
    let exported = 0
    let failed = 0
    let skipped = 0
    const errors: string[] = []
    const usedNames = new Set<string>()

    const destination = path.resolve(options.destination)
    if (!fs.existsSync(destination)) {
      fs.mkdirSync(destination, { recursive: true })
    }

    const plans = filtered.map((photo, index) => {
      let destName = this.resolveNaming(
        photo,
        options,
        (options.naming.counterStart ?? 1) + index,
        sessionName,
      )
      const ext = path.extname(destName)
      const base = destName.slice(0, -ext.length)
      let dedupeIdx = 2
      while (
        usedNames.has(destName) ||
        fs.existsSync(path.join(destination, destName))
      ) {
        destName = `${base}_${dedupeIdx}${ext}`
        dedupeIdx++
      }
      usedNames.add(destName)
      return {
        index,
        photo,
        destName,
        destPath: path.join(destination, destName),
      }
    })
    let completed = 0
    const concurrency = options.format === 'original' ? 4 : 2
    await batchAsync(plans, async ({ photo, destName, destPath }) => {
      if (this.cancelFlags.get(sessionId)) {
        skipped++
        return
      }
      try {
        const resolvedDest = path.resolve(destPath)
        if (!resolvedDest.startsWith(destination + path.sep) && resolvedDest !== destination) {
          throw new Error(`${photo.filename} 的导出路径无效`)
        }

        if (options.format === 'original') {
          if (options.includeXmp) {
            await fs.promises.cp(photo.filepath, destPath)
            const xmpPath = getXmpSidecarPath(photo.filepath)
            if (fs.existsSync(xmpPath)) {
              await fs.promises.cp(xmpPath, getXmpSidecarPath(destPath))
            }
          } else {
            await fs.promises.cp(photo.filepath, destPath)
          }
        } else {
          await heavyTaskScheduler.run(
            () => this.convertAndExport(photo.filepath, destPath, options),
            1,
          )
          if (options.includeXmp) {
            const xmpPath = getXmpSidecarPath(photo.filepath)
            if (fs.existsSync(xmpPath)) {
              await fs.promises.cp(xmpPath, getXmpSidecarPath(destPath))
            }
          }
        }

        const destinationStat = await fs.promises.stat(destPath)
        exported++
        completed++

        onProgress?.({
          sessionId,
          current: completed,
          total,
          fileName: destName,
          bytesWritten: destinationStat.size,
          status: 'done',
        })
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : '未知错误'
        errors.push(`${photo.filename}: ${message}`)
        failed++
        completed++

        onProgress?.({
          sessionId,
          current: completed,
          total,
          fileName: photo.filename,
          bytesWritten: 0,
          status: 'error',
          errorMessage: message,
        })
      }
    }, concurrency)

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
        content = '文件名,文件路径\n'
        content += photos.map((p) => `${escapeCsvField(p.filename)},${escapeCsvField(p.filepath)}`).join('\n')
      } else {
        content = '# 工作区导出报告\n\n'
        content += `照片总数：${photos.length}\n\n`
        content += '| 文件名 | 文件路径 |\n'
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
    if (options.scope === 'session') {
      return photos.filter((p) => p.status !== 'removed')
    }
    if (options.scope === 'selected' || options.scope === 'filtered') {
      throw new Error(`暂不支持导出范围“${options.scope}”，请导出当前工作区的全部照片。`)
    }
    throw new Error(`未知导出范围：${options.scope}`)
  }

  private resolveNaming(photo: PhotoRow, options: ExportOptions, counter: number, sessionName: string): string {
    const now = new Date()
    const dateStr = this.formatDate(now, options.naming.dateFormat ?? 'YYYY-MM-DD')
    const timeStr = now.toTimeString().slice(0, 8).replace(/:/g, '-')
    const ext = path.extname(photo.filename)
    const baseName = sanitizeFilenameComponent(path.basename(photo.filename, ext))
    const safeSessionName = sanitizeFilenameComponent(sessionName)

    let pattern = options.naming.pattern
    pattern = pattern.replace(/\{date\}/g, dateStr)
    pattern = pattern.replace(/\{time\}/g, timeStr)
    pattern = pattern.replace(/\{counter\}/g, String(counter).padStart(4, '0'))
    pattern = pattern.replace(/\{original\}/g, baseName)
    pattern = pattern.replace(/\{session\}/g, safeSessionName)

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
    try {
      await sharp(sourcePath).metadata()
    } catch {
      throw new Error(
        `暂不支持将 ${path.extname(sourcePath) || '此文件类型'} 转换为全分辨率文件，请选择“保持原格式”。`,
      )
    }

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
      throw new Error(`不支持导出格式：${options.format}。可用格式为 JPEG、TIFF 或保持原格式。`)
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
