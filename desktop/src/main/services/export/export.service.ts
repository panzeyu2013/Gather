import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import type { PhotoRow } from '../../db/repositories/photo.repo'
import type { ExportOptions, ExportPreview, ExportResult, ExportProgressData, ReportData } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import sharp from 'sharp'
import * as fs from 'fs'
import * as path from 'path'
import { randomUUID } from 'node:crypto'
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
  if (
    options.variantPolicy !== undefined &&
    !['preferred', 'raw', 'jpeg', 'all'].includes(options.variantPolicy)
  ) {
    throw new Error('导出变体策略无效')
  }
  if (options.format === 'original' && (options.maxDimension || options.watermark)) {
    throw new Error('保持原格式仅复制文件，不能同时调整尺寸或添加水印')
  }
  if (!options.naming?.pattern?.trim()) {
    throw new Error('文件命名规则不能为空')
  }
  if (
    options.naming.pattern.includes('/') ||
    options.naming.pattern.includes('\\') ||
    options.naming.pattern.includes('\0')
  ) {
    throw new Error('文件命名规则不能包含路径分隔符或空字符')
  }
  if (
    options.quality !== undefined &&
    (!Number.isInteger(options.quality) || options.quality < 1 || options.quality > 100)
  ) {
    throw new Error('JPEG 质量必须是 1 到 100 之间的整数')
  }
  if (
    options.maxDimension !== undefined &&
    (!Number.isInteger(options.maxDimension) || options.maxDimension < 1)
  ) {
    throw new Error('最长边必须是大于等于 1 的整数')
  }
  if (
    options.naming.counterStart !== undefined &&
    (!Number.isInteger(options.naming.counterStart) || options.naming.counterStart < 0)
  ) {
    throw new Error('起始序号必须是大于等于 0 的整数')
  }
  if (options.watermark) {
    if (options.watermark.type !== 'text') {
      throw new Error('当前版本仅支持文字水印')
    }
    if (!options.watermark.content.trim()) throw new Error('水印文字不能为空')
    if (
      !Number.isFinite(options.watermark.opacity) ||
      options.watermark.opacity < 0 ||
      options.watermark.opacity > 1
    ) {
      throw new Error('水印不透明度必须在 0 到 1 之间')
    }
    if (
      options.watermark.fontSize !== undefined &&
      (!Number.isFinite(options.watermark.fontSize) ||
        options.watermark.fontSize < 1 ||
        options.watermark.fontSize > 1000)
    ) {
      throw new Error('水印字号必须在 1 到 1000 之间')
    }
  }
}

function sanitizeFilenameComponent(name: string): string {
  return path.basename(name.replace(/[<>:"/\\|?*]/g, '_'))
}

function isWithinDirectory(candidate: string, directory: string): boolean {
  if (!directory) return false
  const resolvedCandidate = canonicalPath(candidate)
  const resolvedDirectory = canonicalPath(directory)
  const relative = path.relative(resolvedDirectory, resolvedCandidate)
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative))
}

/**
 * Resolve a path with symlinks followed, falling back to a lexical resolution
 * (with macOS /var and /tmp -> /private aliasing) when the path does not exist.
 * Mirrors the indexer's canonicalization so a destination reached through a
 * symlink (e.g. /tmp on macOS) cannot bypass the source-directory guard.
 */
function canonicalPath(value: string): string {
  try {
    return fs.realpathSync.native(value)
  } catch {
    const resolved = path.resolve(value)
    if (process.platform === 'darwin' && (resolved === '/var' || resolved.startsWith('/var/'))) {
      return `/private${resolved}`
    }
    if (process.platform === 'darwin' && (resolved === '/tmp' || resolved.startsWith('/tmp/'))) {
      return `/private${resolved}`
    }
    return resolved
  }
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
  return -1
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

  /**
   * Exporting into the session's watched source directory (or a subdirectory
   * of it) would produce new copies that the index watcher immediately
   * re-imports as duplicates. Reject it server-side, not just in the UI.
   */
  private assertDestinationOutsideSource(sessionId: string, destination: string): void {
    const session = this.sessionRepo.get(sessionId)
    if (!session?.source_path) return
    if (isWithinDirectory(destination, session.source_path)) {
      throw new Error('不能导出到工作区导入目录或其子目录，导出的文件会被重新导入当前工作区')
    }
  }

  private async copyExclusive(source: string, destination: string): Promise<void> {
    await fs.promises.copyFile(source, destination, fs.constants.COPYFILE_EXCL)
  }

  private async copyXmpSafely(source: string, destination: string): Promise<void> {
    try {
      await this.copyExclusive(source, destination)
      return
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
    const [sourceBytes, destinationBytes] = await Promise.all([
      fs.promises.readFile(source),
      fs.promises.readFile(destination),
    ])
    if (!sourceBytes.equals(destinationBytes)) {
      throw new Error(`目标 XMP 已存在且内容不同：${destination}`)
    }
  }

  /**
   * Copies the sidecar when present. An XMP failure must not delete the image
   * that was just exported successfully, so it is recorded as a non-fatal
   * error instead of propagating to the catch block that unlinks destPath.
   */
  private async copyXmpBestEffort(
    photoPath: string,
    destPath: string,
    errors: string[],
    filename: string,
    includeXmp: boolean,
  ): Promise<void> {
    if (!includeXmp) return
    const xmpPath = getXmpSidecarPath(photoPath)
    if (!fs.existsSync(xmpPath)) return
    try {
      await this.copyXmpSafely(xmpPath, getXmpSidecarPath(destPath))
    } catch (error) {
      const message = error instanceof Error ? error.message : '未知错误'
      errors.push(`${filename}: ${message}（图像已导出，仅 XMP 未复制）`)
    }
  }

  async preview(sessionId: string, options: ExportOptions): Promise<ExportPreview> {
    validateExportOptions(options)
    this.assertDestinationOutsideSource(sessionId, options.destination)
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
    resume?: {
      destinations?: Record<string, string>
      completedPhotoIds?: ReadonlySet<string>
      signal?: AbortSignal
      onPlanned?: (photoId: string, destinationName: string) => void
      onPlanReady?: () => void
      onCompleted?: (photoId: string) => void
    },
  ): Promise<ExportResult> {
    this.cancelFlags.set(sessionId, false)
    if (resume?.signal?.aborted) this.cancelFlags.set(sessionId, true)
    validateExportOptions(options)
    this.assertDestinationOutsideSource(sessionId, options.destination)
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
      let destName = resume?.destinations?.[photo.id]
      const completedDestination = Boolean(
        destName &&
        resume?.completedPhotoIds?.has(photo.id) &&
        fs.existsSync(path.join(destination, destName)),
      )
      if (
        !destName ||
        (!completedDestination && fs.existsSync(path.join(destination, destName)))
      ) {
        destName = this.resolveNaming(
          photo,
          options,
          (options.naming.counterStart ?? 1) + index,
          sessionName,
        )
        const ext = path.extname(destName)
        const base = destName.slice(0, -ext.length)
        let dedupeIdx = 2
        while (
          usedNames.has(destName.toLocaleLowerCase()) ||
          fs.existsSync(path.join(destination, destName))
        ) {
          destName = `${base}_${dedupeIdx}${ext}`
          dedupeIdx++
        }
        resume?.onPlanned?.(photo.id, destName)
      }
      usedNames.add(destName.toLocaleLowerCase())
      return {
        index,
        photo,
        destName,
        destPath: path.join(destination, destName),
      }
    })
    resume?.onPlanReady?.()
    let completed = 0
    const concurrency = options.format === 'original' ? 4 : 2
    await batchAsync(plans, async ({ photo, destName, destPath }) => {
      if (resume?.completedPhotoIds?.has(photo.id) && fs.existsSync(destPath)) {
        exported++
        completed++
        onProgress?.({
          sessionId,
          current: completed,
          total,
          fileName: destName,
          bytesWritten: 0,
          status: 'done',
        })
        return
      }
      if (resume?.signal?.aborted || this.cancelFlags.get(sessionId)) {
        skipped++
        return
      }
      let destinationCreated = false
      try {
        const resolvedDest = path.resolve(destPath)
        if (!resolvedDest.startsWith(destination + path.sep) && resolvedDest !== destination) {
          throw new Error(`${photo.filename} 的导出路径无效`)
        }

        if (options.format === 'original') {
          await this.copyExclusive(photo.filepath, destPath)
          destinationCreated = true
          await this.copyXmpBestEffort(photo.filepath, destPath, errors, photo.filename, options.includeXmp)
        } else {
          const temporaryPath = path.join(
            destination,
            `.${destName}.gather-export-${process.pid}-${randomUUID()}`,
          )
          try {
            await heavyTaskScheduler.run(
              () => this.convertAndExport(photo.filepath, temporaryPath, options),
              1,
            )
            await this.copyExclusive(temporaryPath, destPath)
            destinationCreated = true
          } finally {
            await fs.promises.unlink(temporaryPath).catch(() => undefined)
          }
          if (options.includeXmp) {
            await this.copyXmpBestEffort(photo.filepath, destPath, errors, photo.filename, options.includeXmp)
          }
        }

        const destinationStat = await fs.promises.stat(destPath)
        exported++
        completed++
        resume?.onCompleted?.(photo.id)

        onProgress?.({
          sessionId,
          current: completed,
          total,
          fileName: destName,
          bytesWritten: destinationStat.size,
          status: 'done',
        })
      } catch (e: unknown) {
        if (destinationCreated) {
          await fs.promises.unlink(destPath).catch(() => undefined)
        }
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
    let scoped: PhotoRow[]
    if (options.scope === 'session') {
      scoped = photos.filter((p) => p.status !== 'removed')
    } else if (options.scope === 'selected' || options.scope === 'filtered') {
      throw new Error(`暂不支持导出范围“${options.scope}”，请导出当前工作区的全部照片。`)
    } else {
      throw new Error(`未知导出范围：${options.scope}`)
    }
    const policy = options.variantPolicy ?? 'preferred'
    if (policy === 'all') return scoped
    const groups = new Map<string, PhotoRow[]>()
    for (const photo of scoped) {
      const key = photo.asset_id ?? photo.id
      const variants = groups.get(key) ?? []
      variants.push(photo)
      groups.set(key, variants)
    }
    const rawExtensions = new Set([
      '.3fr', '.arw', '.cr2', '.cr3', '.dng', '.fff', '.gpr', '.iiq',
      '.mos', '.nef', '.nrw', '.orf', '.pef', '.raf', '.raw', '.rw2',
      '.rwl', '.sr2', '.srf', '.srw', '.x3f',
    ])
    const jpegExtensions = new Set(['.jpg', '.jpeg'])
    const isRaw = (photo: PhotoRow) => rawExtensions.has(path.extname(photo.filename).toLowerCase())
    const isJpeg = (photo: PhotoRow) => jpegExtensions.has(path.extname(photo.filename).toLowerCase())
    return [...groups.values()].flatMap(variants => {
      if (policy === 'raw') return variants.find(isRaw) ?? []
      if (policy === 'jpeg') return variants.find(isJpeg) ?? []
      return variants.find(isRaw) ?? variants.find(isJpeg) ?? variants[0]
    })
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
