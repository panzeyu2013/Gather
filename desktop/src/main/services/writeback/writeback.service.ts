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
import type { PhotoAssetResolver } from '../assets/photo-asset-resolver'

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
    @inject(DI_TOKENS.PHOTO_ASSET_RESOLVER)
    private assetResolver?: PhotoAssetResolver,
  ) {}

  private assertNoActiveOtherModule(sessionId: string, module: string): void {
    // The outbox is the single writeback state machine. Written/synced work from
    // another module must be confirmed in Capture One and cleaned up first.
    // Outbox rows store the mutation-source name (e.g. 'face-keyword' for the
    // face_kw module), so compare using the same mapping used to write them.
    if (
      this.metadataOutboxRepo?.hasActiveOtherModule(
        sessionId,
        mutationSource(module),
      )
    ) {
      throw new Error('WRITEBACK_OTHER_MODULE_ACTIVE')
    }
    // Legacy fallback for callers constructed without the outbox repository.
    // Mirrors the outbox gate: interactive culling sync is continuous and
    // must never block a batch writeback, so culling rows are excluded here
    // too (the outbox-side check already excludes them).
    const activeOtherModule = this.writebackRepo
      .getItems(sessionId)
      .find(item =>
        item.module !== module &&
        item.module !== 'culling' &&
        (item.xmp_status === 'written' || item.xmp_status === 'synced'),
      )
    if (activeOtherModule) {
      throw new Error(
        'WRITEBACK_OTHER_MODULE_ACTIVE',
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

    // A new preview supersedes the module's earlier intent: rebuilds
    // writeback_items below, so any pending/failed outbox rows of this module
    // from a previous round must go too — otherwise the next execute merges
    // the stale patch (old keywords) into the new one via mergePatch.
    // Excluded for culling: it is a continuous-sync module whose pending
    // outbox rows may carry interactive rating/label edits that the keyword
    // preview has nothing to do with — deleting them would silently lose work.
    if (module !== 'culling') {
      this.metadataOutboxRepo?.discardModulePending(sessionId, mutationSource(module))
    }

    const photos = this.photoRepo.getBySession(sessionId)
    const filtered = photoIds ? photos.filter(p => photoIds.has(p.id)) : photos

    // Resolve the asset (and its sidecar) exactly like execute does: with
    // asset_read_mode='asset' and relinked files, the photo row's legacy
    // filepath/sidecar differ from what PhotoAssetResolver.resolve() returns,
    // and a preview/execute mismatch made every item fail permanently (the
    // execute summary lookup keys on the resolved xmp path).
    const resolveTarget = (photo: (typeof filtered)[number]): { filepath: string; xmpPath: string } => {
      if (this.assetResolver) {
        try {
          const resolved = this.assetResolver.resolve(sessionId, photo.id)
          return { filepath: resolved.filepath, xmpPath: resolved.xmpPath }
        } catch {
          // Unlinked or incomplete asset migration: keep the legacy path so
          // preview still works for legacy sessions.
        }
      }
      return { filepath: photo.filepath, xmpPath: getXmpSidecarPath(photo.filepath) }
    }
    const resolvedByPhoto = new Map(filtered.map(photo => [photo.id, resolveTarget(photo)]))
    const additionsBySidecar = new Map<string, string[]>()
    const sharedCounts = new Map<string, number>()
    const uniquePhotos = new Map<string, (typeof filtered)[number]>()
    for (const photo of filtered) {
      const { xmpPath: sidecarPath } = resolvedByPhoto.get(photo.id)!
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
      const { filepath, xmpPath: sidecarPath } = resolvedByPhoto.get(photo.id)!
      let existingKeywords: string[] = []
      try {
        existingKeywords = await writer.readKeywords(filepath)
      } catch {
        // corrupt or missing, start empty
      }
      return {
        photoId: photo.id,
        photoPath: filepath,
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
    const failedCount = this.writebackRepo.getFailedCount(sessionId, module)
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
    // Phase 1: prepare every item (merged keywords, mutation queued) before
    // any flush. The old per-item flushSession rewrote the whole session
    // queue once per item — O(items) XMP rewrites for RAW+JPEG pairs sharing
    // one sidecar. Mutations are queued now and flushed once below.
    const prepared: Array<{
      itemId: number
      dbRow: WritebackItemRow
      persistedItem: WritebackItem
      photoPath: string
      writeAttrs: Record<string, unknown>
      keywordsBeforeWrite: string[]
    }> = []
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
          writeAttrs,
          mutationSource(_module),
        )
        prepared.push({ itemId, dbRow, persistedItem, photoPath, writeAttrs, keywordsBeforeWrite })
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        this.writebackRepo.updateStatus(itemId, 'failed', message)
        errors.push(`${photoPath}: ${message}`)
        failedItems.push(persistedItem)
        failed++
      }
    }

    // Phase 2: one flush for the whole session queue, then verify each
    // prepared item against its summary entry.
    let summary: Awaited<ReturnType<MetadataSyncCoordinator['flushSession']>> | null = null
    if (prepared.length > 0) {
      try {
        summary = await this.metadataSync.flushSession(sessionId)
      } catch (e: unknown) {
        const message = e instanceof Error ? e.message : 'Unknown error'
        for (const entry of prepared) {
          this.writebackRepo.updateStatus(entry.itemId, 'failed', message)
          errors.push(`${entry.photoPath}: ${message}`)
          failedItems.push(entry.persistedItem)
          failed++
        }
        summary = null
      }
    }
    if (summary) {
      for (const entry of prepared) {
        // The outbox keyed the mutation by the xmp path resolved at execute
        // time. If the asset migration completed between preview and execute,
        // that path differs from the preview snapshot (dbRow.xmp_path); match
        // the live resolution as well so a written item is not reported as
        // failed with the XMP already on disk.
        let resolvedXmpPath = entry.dbRow.xmp_path
        if (this.assetResolver) {
          try {
            resolvedXmpPath = this.assetResolver.resolve(sessionId, entry.dbRow.photo_id).xmpPath
          } catch {
            // Resolution failure falls back to the stored preview path.
          }
        }
        const syncItem = summary.items.find(candidate =>
          candidate.xmpPath === entry.dbRow.xmp_path ||
          candidate.xmpPath === resolvedXmpPath,
        )
        if (!syncItem || !['written', 'synced'].includes(syncItem.status)) {
          const message = syncItem?.errorMessage || `XMP write ended in ${syncItem?.status ?? 'unknown'} state`
          this.writebackRepo.updateStatus(entry.itemId, 'failed', message)
          errors.push(`${entry.photoPath}: ${message}`)
          failedItems.push(entry.persistedItem)
          failed++
          continue
        }
        this.writebackRepo.updateStatus(entry.itemId, 'written')
        const attrs = entry.writeAttrs
        if (typeof attrs.rating === 'number') {
          try { this.metadataCacheRepo.updateRating(entry.dbRow.photo_id, attrs.rating as number) } catch { /* best effort */ }
        }
        if (typeof attrs.label === 'string') {
          try { this.metadataCacheRepo.updateLabel(entry.dbRow.photo_id, attrs.label) } catch { /* best effort */ }
        }
        if (Array.isArray(attrs.keywords)) {
          try { this.metadataCacheRepo.updateKeywords(entry.dbRow.photo_id, attrs.keywords as string[]) } catch { /* best effort */ }
          if (_module === 'face_kw') {
            // keywordsBeforeWrite is the pre-flush snapshot captured in
            // phase 1: keywords that were not on the file before our write
            // are the ones this module introduced.
            const existing = new Set(entry.keywordsBeforeWrite)
            this.keywordOrigins?.markIntroduced(
              entry.dbRow.xmp_path,
              'face-keyword',
              (attrs.keywords as string[]).filter(keyword => !existing.has(keyword)),
            )
          }
        }
        written++
      }
    }

    const failedCount = this.writebackRepo.getFailedCount(sessionId, _module)
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
          'WRITEBACK_UNDO_FACE_FAILED',
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
      throw new Error('WRITEBACK_FAILURES_PENDING')
    }
    // The outbox stores the mutation-source name (face_kw -> 'face-keyword'),
    // so the module-aware outbox confirm must use the mapped name; otherwise
    // face_kw rows would never transition to synced and every later cleanup
    // (and every other module's writeback) would be blocked forever.
    this.metadataSync.confirmSync(sessionId, mutationSource(module))
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
    const syncedItems = allItems.filter(item => item.xmp_status === 'synced')
    if (syncedItems.length === 0 && allItems.length > 0) {
      throw new Error('XMP_CLEANUP_REQUIRES_LOADED')
    }

    const result = await this.metadataSync.cleanup(sessionId, mutationSource(module))
    if (result.errors.length > 0) return result
    // Delete only the confirmed/synced rows: a re-preview after confirm
    // created a new pending round whose rows (and outbox entries) are still
    // live — wiping them here would let the background coordinator write
    // unconfirmed keywords to XMP with no UI record.
    this.writebackRepo.deleteItemsByIds(
      sessionId,
      module,
      syncedItems.flatMap(item => item.id != null ? [item.id] : []),
    )
    const remainingItems = this.writebackRepo.getItems(sessionId)
    this.sessionRepo.updateWritebackStatus(
      sessionId,
      remainingItems.length === 0
        ? 'cleaned'
        : remainingItems.some(item => item.xmp_status === 'failed') ? 'partial' : 'done',
    )
    return result
  }
}
