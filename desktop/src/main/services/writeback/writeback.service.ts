import { existsSync, unlinkSync } from 'fs'
import { WritebackRepository, type WritebackItemInput, type WritebackItemRow } from '../../db/repositories/writeback.repo'
import { XmpWriter } from '../xmp/xmp-writer'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { SessionRepository } from '../../db/repositories/session.repo'
import type { WritebackPreview, WritebackResult, WritebackItem, CleanupResult, WritebackOptions } from '@gather/shared'

function rowToItem(row: WritebackItemRow): WritebackItem {
  return {
    id: row.id,
    photoId: row.photo_id,
    sessionId: row.session_id,
    module: row.module,
    keywords: JSON.parse(row.keywords) as string[],
    xmpPath: row.xmp_path,
    backupPath: row.backup_path,
    xmpStatus: row.xmp_status,
    errorMessage: row.error_message,
    attemptCount: row.attempt_count,
    lastAttemptAt: row.last_attempt_at,
  }
}

export class WritebackService {
  constructor(
    private writebackRepo: WritebackRepository,
    private xmpWriter: XmpWriter,
    private photoRepo: PhotoRepository,
    private sessionRepo: SessionRepository,
  ) {}

  async preview(sessionId: string, module: string, _options: WritebackOptions): Promise<WritebackPreview> {
    const photos = this.photoRepo.getBySession(sessionId)

    const items: WritebackItemInput[] = photos.map((photo) => {
      const xmpPath = photo.filepath + '.xmp'
      const backupPath = xmpPath + '.bak'
      let existingKeywords: string[] = []
      try {
        existingKeywords = this.xmpWriter.readKeywords(xmpPath)
      } catch {
        // corrupt or missing XMP, start empty
      }
      return {
        photoId: photo.id,
        module,
        keywords: existingKeywords,
        xmpPath,
        backupPath,
      }
    })

    const ids = this.writebackRepo.saveItems(sessionId, items)
    const savedRows = this.writebackRepo.getItems(sessionId, module)

    return {
      items: savedRows.map(rowToItem),
      totalCount: savedRows.length,
      affectedPhotos: photos.length,
    }
  }

  async execute(sessionId: string, _module: string, items: WritebackItem[]): Promise<WritebackResult> {
    let written = 0
    let failed = 0
    let skipped = 0
    const errors: string[] = []
    const failedItems: WritebackItem[] = []

    for (const item of items) {
      const itemId = item.id
      if (!itemId) {
        skipped++
        continue
      }

      try {
        const backupPath = this.xmpWriter.backupXmp(item.xmpPath)
        this.writebackRepo.updateBackupPath(itemId, backupPath)
        this.xmpWriter.writeKeywords(item.xmpPath, item.keywords)
        this.writebackRepo.updateStatus(itemId, 'written')
        written++
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        this.writebackRepo.updateStatus(itemId, 'failed', message)
        errors.push(`${item.xmpPath}: ${message}`)
        failedItems.push(item)
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

  async confirmSync(sessionId: string): Promise<void> {
    this.sessionRepo.updateWritebackStatus(sessionId, 'done')
  }

  async cleanup(sessionId: string): Promise<CleanupResult> {
    const items = this.writebackRepo.getItems(sessionId)
    let deletedCount = 0
    const errors: string[] = []

    for (const item of items) {
      try {
        if (item.backup_path && existsSync(item.backup_path)) {
          unlinkSync(item.backup_path)
          deletedCount++
        }
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        errors.push(`${item.backup_path}: ${message}`)
      }
    }

    this.writebackRepo.deleteItems(sessionId)
    this.sessionRepo.updateWritebackStatus(sessionId, 'cleaned')

    return { deletedCount, errors }
  }
}
