import { existsSync } from 'fs'
import { unlink } from 'fs/promises'
import { WritebackRepository, type WritebackItemRow } from '../../db/repositories/writeback.repo'
import { MetadataCacheRepository } from '../../db/repositories/metadata-cache.repo'
import { MetadataWriterRouter } from '../xmp/metadata-writer-router'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import { batchAsync, parseKeywords } from '../../utils/async'
import type { WritebackPreview, WritebackResult, WritebackItem, CleanupResult, WritebackOptions } from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'

function rowToItem(row: WritebackItemRow): WritebackItem {
  let attributes: Record<string, unknown> = {}
  try {
    attributes = JSON.parse(row.attributes_json || '{}')
  } catch { /* ignore */ }

  return {
    id: row.id,
    photoId: row.photo_id,
    photoPath: row.photo_path,
    sessionId: row.session_id,
    module: row.module,
    keywords: parseKeywords(row.keywords),
    attributes: Object.keys(attributes).length > 0 ? attributes as WritebackItem['attributes'] : undefined,
    xmpPath: row.xmp_path,
    backupPath: row.backup_path,
    xmpStatus: row.xmp_status,
    errorMessage: row.error_message,
    attemptCount: row.attempt_count,
    lastAttemptAt: row.last_attempt_at,
  }
}

@injectable()
export class WritebackService {
  constructor(
    @inject(DI_TOKENS.WRITEBACK_REPO) private writebackRepo: WritebackRepository,
    @inject(DI_TOKENS.WRITER_ROUTER) private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.METADATA_CACHE_REPO) private metadataCacheRepo: MetadataCacheRepository,
  ) {}

  private assertNoActiveOtherModule(sessionId: string, module: string): void {
    const activeOtherModule = this.writebackRepo
      .getItems(sessionId)
      .find(item =>
        item.module !== module &&
        (item.xmp_status === 'written' || item.xmp_status === 'synced'),
      )
    if (activeOtherModule) {
      throw new Error(
        `请先完成 ${activeOtherModule.module} 的 Capture One 同步和清理，再开始新的写回`,
      )
    }
  }

  async preview(
    sessionId: string,
    module: string,
    _options: WritebackOptions,
    photoIds?: Set<string>,
    keywordAdditions?: ReadonlyMap<string, string[]>,
  ): Promise<WritebackPreview> {
    this.assertNoActiveOtherModule(sessionId, module)

    const photos = this.photoRepo.getBySession(sessionId)
    const filtered = photoIds ? photos.filter(p => photoIds.has(p.id)) : photos
    const additionsBySidecar = new Map<string, string[]>()
    const uniquePhotos = new Map<string, (typeof filtered)[number]>()
    for (const photo of filtered) {
      const sidecarPath = getXmpSidecarPath(photo.filepath)
      if (!uniquePhotos.has(sidecarPath)) uniquePhotos.set(sidecarPath, photo)
      additionsBySidecar.set(sidecarPath, [
        ...new Set([
          ...(additionsBySidecar.get(sidecarPath) ?? []),
          ...(keywordAdditions?.get(photo.id) ?? []),
        ]),
      ])
    }

    const items = await batchAsync([...uniquePhotos.values()], async (photo) => {
      const writer = this.writerRouter.selectSidecar()
      const sidecarPath = getXmpSidecarPath(photo.filepath)
      let existingKeywords: string[] = []
      try {
        existingKeywords = await writer.readKeywords(photo.filepath)
      } catch {
        // corrupt or missing, start empty
      }
      return {
        photoId: photo.id,
        photoPath: photo.filepath,
        module,
        keywords: [...new Set([
          ...existingKeywords,
          ...(additionsBySidecar.get(sidecarPath) ?? []),
        ])],
        xmpPath: sidecarPath,
        // Filled during execute only when an original sidecar really existed.
        backupPath: '',
      }
    }, 10)

    this.writebackRepo.saveItems(sessionId, module, items)
    const failedCount = this.writebackRepo.getFailedCount(sessionId)
    this.sessionRepo.updateFailedWritebackCount(sessionId, failedCount)
    this.sessionRepo.updateWritebackStatus(sessionId, failedCount > 0 ? 'partial' : 'idle')
    const savedRows = this.writebackRepo.getItems(sessionId, module, 'pending')

    return {
      items: savedRows.map(rowToItem),
      totalCount: savedRows.length,
      affectedPhotos: filtered.length,
    }
  }

  async execute(sessionId: string, _module: string, items: WritebackItem[]): Promise<WritebackResult> {
    this.assertNoActiveOtherModule(sessionId, _module)
    let written = 0
    let failed = 0
    let skipped = 0
    const errors: string[] = []
    const failedItems: WritebackItem[] = []
    const persistedRows = this.writebackRepo.getItems(sessionId, _module)
    const rowById = new Map(persistedRows.map(row => [row.id, row]))
    const activeBackupByXmpPath = new Map(
      persistedRows
        .filter(row => row.xmp_status === 'written' || row.xmp_status === 'synced')
        .map(row => [row.xmp_path, row.backup_path]),
    )

    for (const item of items) {
      const itemId = item.id
      if (itemId == null) {
        skipped++
        continue
      }

      const dbRow = rowById.get(itemId)
      if (!dbRow || dbRow.session_id !== sessionId || dbRow.module !== _module) {
        skipped++
        continue
      }
      if (dbRow.xmp_status !== 'pending' && dbRow.xmp_status !== 'failed') {
        skipped++
        continue
      }

      const photoPath = dbRow.photo_path || (dbRow.xmp_path ? dbRow.xmp_path.replace(/\.xmp$/i, '') : '')
      if (!photoPath) {
        const message = 'Missing photo path for writeback item'
        this.writebackRepo.updateStatus(itemId, 'failed', message)
        errors.push(`${itemId}: ${message}`)
        failedItems.push({ ...item, photoPath: '' })
        failed++
        continue
      }
      const writer = this.writerRouter.selectSidecar()
      const persistedItem = rowToItem(dbRow)

      let backupPath = ''
      try {
        const priorBackupPath = activeBackupByXmpPath.get(dbRow.xmp_path)
        backupPath = priorBackupPath !== undefined
          ? priorBackupPath
          : await writer.backup(photoPath)
        if (backupPath) {
          this.writebackRepo.updateBackupPath(itemId, backupPath)
        }
        const writeAttrs = persistedItem.attributes
          ? { keywords: persistedItem.keywords, ...persistedItem.attributes }
          : { keywords: persistedItem.keywords }
        await writer.writeAttributes(photoPath, writeAttrs as Record<string, unknown> as Parameters<typeof writer.writeAttributes>[1])
        this.writebackRepo.updateStatus(itemId, 'written')
        activeBackupByXmpPath.set(dbRow.xmp_path, backupPath)
        const attrs = writeAttrs as Record<string, unknown>
        if (typeof attrs.rating === 'number') {
          try { this.metadataCacheRepo.updateRating(dbRow.photo_id, attrs.rating as number) } catch { /* best effort */ }
        }
        if (typeof attrs.label === 'string') {
          try { this.metadataCacheRepo.updateLabel(dbRow.photo_id, attrs.label) } catch { /* best effort */ }
        }
        if (Array.isArray(attrs.keywords)) {
          try { this.metadataCacheRepo.updateKeywords(dbRow.photo_id, attrs.keywords as string[]) } catch { /* best effort */ }
        }
        written++
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        this.writebackRepo.updateStatus(itemId, 'failed', message)
        try {
          if (backupPath) {
            await writer.restore(photoPath, backupPath)
          }
        } catch (restoreErr) {
          console.warn(`Failed to restore backup for ${photoPath}:`, restoreErr instanceof Error ? restoreErr.message : restoreErr)
        }
        errors.push(`${photoPath}: ${message}`)
        failedItems.push(persistedItem)
        failed++
      }
    }

    const failedCount = this.writebackRepo.getFailedCount(sessionId)
    this.sessionRepo.updateWritebackStatus(sessionId, failedCount > 0 ? 'partial' : 'done')
    this.sessionRepo.updateFailedWritebackCount(sessionId, failedCount)

    return {
      totalAffected: written + failed + skipped,
      written,
      failed,
      skipped,
      errors,
      failedItems,
      report: `Written: ${written}, Failed: ${failed}, Skipped: ${skipped}`,
    }
  }

  async retryFailed(sessionId: string, module: string): Promise<WritebackResult> {
    const failedRows = this.writebackRepo.getItems(sessionId, module, 'failed')
    const items = failedRows.map(rowToItem)

    if (items.length === 0) {
      return {
        totalAffected: 0,
        written: 0,
        failed: 0,
        skipped: 0,
        errors: [],
        failedItems: [],
        report: 'No failed items to retry',
      }
    }

    return this.execute(sessionId, module, items)
  }

  async confirmSync(sessionId: string, module: string): Promise<void> {
    if (this.writebackRepo.getFailedCount(sessionId, module) > 0) {
      throw new Error('仍有 XMP 写入失败项，请先重试或处理失败项')
    }
    this.writebackRepo.markWrittenAsSynced(sessionId, module)
    this.sessionRepo.updateWritebackStatus(
      sessionId,
      this.writebackRepo.getFailedCount(sessionId) > 0 ? 'partial' : 'done',
    )
  }

  persistAttributes(items: WritebackItem[]): void {
    this.writebackRepo.updateAttributesMany(
      items.flatMap(item => item.id != null && item.attributes
        ? [{ id: item.id, attributes: item.attributes as Record<string, unknown> }]
        : []),
    )
  }

  persistKeywords(items: WritebackItem[]): void {
    this.writebackRepo.updateKeywordsMany(
      items.flatMap(item => item.id != null
        ? [{ id: item.id, keywords: item.keywords }]
        : []),
    )
  }

  getItems(sessionId: string, module: string, status?: string): WritebackItem[] {
    return this.writebackRepo.getItems(sessionId, module, status).map(rowToItem)
  }

  async cleanup(sessionId: string, module: string): Promise<CleanupResult> {
    const allItems = this.writebackRepo.getItems(sessionId, module)
    const items = allItems.filter(item => item.xmp_status === 'synced')
    if (items.length === 0 && allItems.length > 0) {
      throw new Error('请先在 Capture One 中加载元数据并确认同步，再执行清理')
    }

    let deletedCount = 0
    const errors: string[] = []

    const uniqueItems = new Map(items.map(item => [item.xmp_path, item]))
    for (const item of uniqueItems.values()) {
      try {
        if (item.backup_path) {
          if (!existsSync(item.backup_path)) {
            throw new Error(`原始 XMP 备份不存在，已停止清理以避免误删：${item.backup_path}`)
          }
          await this.writerRouter.selectSidecar().restore(item.photo_path, item.backup_path)
          deletedCount++
        } else if (item.xmp_path && existsSync(item.xmp_path)) {
          await unlink(item.xmp_path)
          deletedCount++
        }
        this.writebackRepo.updateStatusByXmpPath(
          sessionId,
          module,
          item.xmp_path,
          'cleaned',
        )
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        errors.push(`${item.backup_path}: ${message}`)
      }
    }

    if (errors.length === 0) {
      this.writebackRepo.deleteItems(sessionId, module)
      const remainingItems = this.writebackRepo.getItems(sessionId)
      this.sessionRepo.updateWritebackStatus(
        sessionId,
        remainingItems.length === 0
          ? 'cleaned'
          : this.writebackRepo.getFailedCount(sessionId) > 0 ? 'partial' : 'done',
      )
    } else {
      this.sessionRepo.updateWritebackStatus(sessionId, 'partial')
    }

    return { deletedCount, errors }
  }
}
