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
import type { MetadataSyncCoordinator } from '../metadata/metadata-sync-coordinator'
import type { MetadataMutationService } from '../metadata/metadata-mutation.service'
import type { MetadataMutationSource } from '@gather/shared'
import { existsSync } from 'node:fs'
import type { MetadataOutboxRepository } from '../../db/repositories/metadata-outbox.repo'
import type { MetadataKeywordOriginRepository } from '../../db/repositories/metadata-keyword-origin.repo'

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

function mutationSource(module: string): MetadataMutationSource {
  if (module === 'face_kw') return 'face-keyword'
  if (module === 'similarity') return 'similarity'
  if (module === 'template') return 'template'
  if (module === 'culling') return 'culling'
  return 'manual'
}

@injectable()
export class WritebackService {
  constructor(
    @inject(DI_TOKENS.WRITEBACK_REPO) private writebackRepo: WritebackRepository,
    @inject(DI_TOKENS.WRITER_ROUTER) private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.METADATA_CACHE_REPO) private metadataCacheRepo: MetadataCacheRepository,
    @inject(DI_TOKENS.METADATA_SYNC_COORDINATOR)
    private metadataSync: Pick<
      MetadataSyncCoordinator,
      'waitForIdle' | 'flushSession' | 'confirmSync' | 'cleanup'
    >,
    @inject(DI_TOKENS.METADATA_MUTATION_SERVICE)
    private metadataMutations: MetadataMutationService,
    @inject(DI_TOKENS.METADATA_OUTBOX_REPO)
    private metadataOutboxRepo?: MetadataOutboxRepository,
    @inject(DI_TOKENS.METADATA_KEYWORD_ORIGIN_REPO)
    private keywordOrigins?: MetadataKeywordOriginRepository,
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
    const sharedCounts = new Map<string, number>()
    const uniquePhotos = new Map<string, (typeof filtered)[number]>()
    for (const photo of filtered) {
      const sidecarPath = getXmpSidecarPath(photo.filepath)
      if (!uniquePhotos.has(sidecarPath)) uniquePhotos.set(sidecarPath, photo)
      sharedCounts.set(sidecarPath, (sharedCounts.get(sidecarPath) ?? 0) + 1)
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
        preview: {
          dirtyFields: ['keywords' as const],
          before: { keywords: existingKeywords },
          after: {
            keywords: [...new Set([
              ...existingKeywords,
              ...(additionsBySidecar.get(sidecarPath) ?? []),
            ])],
          },
          source: module,
          sharedPhotoCount: sharedCounts.get(sidecarPath) ?? 1,
          externalChanged: this.metadataOutboxRepo?.get(sidecarPath)?.status === 'conflict',
          willCreate: !existsSync(sidecarPath),
        },
      }
    }, 10)

    this.writebackRepo.saveItems(sessionId, module, items)
    const failedCount = this.writebackRepo.getFailedCount(sessionId)
    this.sessionRepo.updateFailedWritebackCount(sessionId, failedCount)
    this.sessionRepo.updateWritebackStatus(sessionId, failedCount > 0 ? 'partial' : 'idle')
    const savedRows = this.writebackRepo.getItems(sessionId, module, 'pending')

    const previewByPath = new Map(items.map(item => [item.xmpPath, item.preview]))
    return {
      items: savedRows.map(row => {
        const item = rowToItem(row)
        return { ...item, preview: previewByPath.get(item.xmpPath) }
      }),
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
      const persistedItem = rowToItem(dbRow)

      try {
        await this.metadataSync.waitForIdle(dbRow.xmp_path)
        const keywordsBeforeWrite = await this.writerRouter
          .selectSidecar()
          .readKeywords(photoPath)
        // Re-merge against the current file state instead of trusting the
        // preview-time snapshot. External software may have added keywords
        // between preview and execute; writing the stale list would silently
        // discard those changes.
        const writeKeywords = [...new Set([
          ...keywordsBeforeWrite,
          ...persistedItem.keywords,
        ])]
        // attributes.keywords (e.g. the culling writeback plan) must be merged
        // too, otherwise the spread below would override the merged list and
        // bypass this protection.
        const mergedKeywords = [...new Set([
          ...writeKeywords,
          ...(Array.isArray(persistedItem.attributes?.keywords)
            ? persistedItem.attributes.keywords
            : []),
        ])]
        const writeAttrs: Record<string, unknown> = persistedItem.attributes
          ? { ...persistedItem.attributes, keywords: mergedKeywords }
          : { keywords: writeKeywords }
        this.metadataMutations.queuePhotoValues(
          sessionId,
          dbRow.photo_id,
          writeAttrs as Record<string, unknown>,
          mutationSource(_module),
        )
        const summary = await this.metadataSync.flushSession(sessionId)
        const syncItem = summary.items.find(candidate => candidate.xmpPath === dbRow.xmp_path)
        if (!syncItem || !['written', 'synced'].includes(syncItem.status)) {
          throw new Error(syncItem?.errorMessage || `XMP write ended in ${syncItem?.status ?? 'unknown'} state`)
        }
        this.writebackRepo.updateStatus(itemId, 'written')
        const attrs = writeAttrs as Record<string, unknown>
        if (typeof attrs.rating === 'number') {
          try { this.metadataCacheRepo.updateRating(dbRow.photo_id, attrs.rating as number) } catch { /* best effort */ }
        }
        if (typeof attrs.label === 'string') {
          try { this.metadataCacheRepo.updateLabel(dbRow.photo_id, attrs.label) } catch { /* best effort */ }
        }
        if (Array.isArray(attrs.keywords)) {
          try { this.metadataCacheRepo.updateKeywords(dbRow.photo_id, attrs.keywords as string[]) } catch { /* best effort */ }
          if (_module === 'face_kw') {
            const existing = new Set(keywordsBeforeWrite)
            this.keywordOrigins?.markIntroduced(
              dbRow.xmp_path,
              'face-keyword',
              (attrs.keywords as string[]).filter(keyword => !existing.has(keyword)),
            )
          }
        }
        written++
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        this.writebackRepo.updateStatus(itemId, 'failed', message)
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

  async removeOwnedFaceKeywords(
    sessionId: string,
    entries: Array<{ photoId: string; xmpPath: string; keywords: string[] }>,
  ): Promise<number> {
    if (!this.keywordOrigins) return 0
    const byPath = new Map<string, { photoId: string; keywords: Set<string> }>()
    for (const entry of entries) {
      const current = byPath.get(entry.xmpPath) ?? {
        photoId: entry.photoId,
        keywords: new Set<string>(),
      }
      entry.keywords.forEach(keyword => current.keywords.add(keyword))
      byPath.set(entry.xmpPath, current)
    }
    const queued: Array<{ xmpPath: string; keywords: string[] }> = []
    for (const [xmpPath, entry] of byPath) {
      const owned = this.keywordOrigins.getActiveIntroduced(
        xmpPath,
        'face-keyword',
        [...entry.keywords],
      )
      if (owned.length === 0) continue
      await this.metadataMutations.queueMutation(
        sessionId,
        entry.photoId,
        { keywords: { op: 'remove', values: owned } },
        'face-keyword',
      )
      queued.push({ xmpPath, keywords: owned })
    }
    if (queued.length === 0) return 0
    const summary = await this.metadataSync.flushSession(sessionId)
    let removed = 0
    for (const item of queued) {
      const result = summary.items.find(candidate => candidate.xmpPath === item.xmpPath)
      if (!result || !['written', 'synced'].includes(result.status)) {
        throw new Error(
          result?.errorMessage ||
          `撤销人脸关键词失败：${item.xmpPath} 处于 ${result?.status ?? 'unknown'} 状态`,
        )
      }
      this.keywordOrigins.deactivate(item.xmpPath, 'face-keyword', item.keywords)
      removed += item.keywords.length
    }
    return removed
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
    this.metadataSync.confirmSync(sessionId)
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

    const result = await this.metadataSync.cleanup(sessionId)
    if (result.errors.length > 0) return result
    this.writebackRepo.deleteItems(sessionId, module)
    const remainingItems = this.writebackRepo.getItems(sessionId)
    this.sessionRepo.updateWritebackStatus(
      sessionId,
      remainingItems.length === 0
        ? 'cleaned'
        : this.writebackRepo.getFailedCount(sessionId) > 0 ? 'partial' : 'done',
    )
    return result
  }
}
