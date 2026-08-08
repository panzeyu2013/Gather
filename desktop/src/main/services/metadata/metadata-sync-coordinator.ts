import { existsSync } from 'fs'
import { unlink } from 'fs/promises'
import type {
  CleanupResult,
  MetadataConflict,
  MetadataConflictChoice,
  MetadataField,
  MetadataOrphan,
  MetadataSyncItem,
  MetadataSyncSummary,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import {
  MetadataOutboxRepository,
  type MetadataOutboxRow,
} from '../../db/repositories/metadata-outbox.repo'
import { WritebackRepository } from '../../db/repositories/writeback.repo'
import { MetadataWriterRouter } from '../xmp/metadata-writer-router'
import type { MetadataWriteAttributes } from './metadata-writer.interface'
import { getXmpSidecarPath } from '../xmp/xmp-sidecar-writer'
import { SettingsService } from '../settings/settings.service'
import {
  contentFingerprint,
} from './metadata-fingerprint'
import {
  fieldConflicts,
  hasFieldConflict,
  parseDirtyFields,
  tryParseDirtyFields,
} from './metadata-conflict-fields'
import { batchAsync } from '../../utils/async'

const MAX_CONCURRENCY = 2
const MAX_AUTOMATIC_ATTEMPTS = 5
const RETRY_DELAYS_MS = [1_000, 2_000, 5_000, 15_000, 30_000]
/** Coalescing window for background per-row summary pushes. */
const SUMMARY_EMIT_THROTTLE_MS = 100
/** Force a summary push once this many rows completed inside one window. */
const SUMMARY_EMIT_BURST_THRESHOLD = 50

type EventSink = (summary: MetadataSyncSummary) => void

function safeObject(value: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value)
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : {}
  } catch {
    return {}
  }
}

function attributesMatchPatch(
  current: MetadataWriteAttributes,
  patch: Record<string, unknown>,
): boolean {
  if (patch.rating !== undefined && current.rating !== patch.rating) return false
  if (patch.label !== undefined && (current.label ?? '') !== patch.label) return false
  if (
    Array.isArray(patch.keywords) &&
    JSON.stringify(current.keywords ?? []) !== JSON.stringify(patch.keywords)
  ) {
    return false
  }
  return true
}

const CULLING_COLOR_LABELS = new Set([
  'None',
  'Red',
  'Orange',
  'Yellow',
  'Green',
  'Blue',
  'Pink',
  'Purple',
])

function sanitizeCullingLabel(value: unknown): string {
  return typeof value === 'string' && CULLING_COLOR_LABELS.has(value) ? value : 'None'
}

function clampRating(value: unknown): number {
  const num = typeof value === 'number' ? value : 0
  return Math.min(5, Math.max(0, Math.round(num)))
}

@injectable()
export class MetadataSyncCoordinator {
  private timers = new Map<string, NodeJS.Timeout>()
  private queued = new Set<string>()
  private active = new Map<string, Promise<void>>()
  private activeCount = 0
  private slotWaiters: Array<() => void> = []
  private baselineTasks = new Map<string, Promise<void>>()
  private stopped = false
  private eventSink: EventSink | null = null
  private summaryEmitTimers = new Map<string, NodeJS.Timeout>()
  private summaryEmitCounts = new Map<string, number>()

  constructor(
    @inject(DI_TOKENS.METADATA_OUTBOX_REPO)
    private outboxRepo: MetadataOutboxRepository,
    @inject(DI_TOKENS.WRITEBACK_REPO)
    private writebackRepo: WritebackRepository,
    @inject(DI_TOKENS.WRITER_ROUTER)
    private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.SETTINGS_SERVICE)
    private settings: SettingsService,
    @inject(DI_TOKENS.DB)
    private db: Database,
  ) {}

  start(eventSink?: EventSink): void {
    this.stopped = false
    this.eventSink = eventSink ?? null
    // Orphans (rows whose creating Session was deleted) are intentionally
    // retained: they are recoverable XMP work exposed through the global
    // recovery UI, not garbage to purge. They must NOT be auto-retried here
    // though — a deleted session's pending work would otherwise keep writing
    // XMP in the background with no UI record. Orphan rows are retried only
    // through the explicit resolveOrphan('retry') action.
    this.outboxRepo.recoverInterrupted()
    for (const row of this.outboxRepo.getRecoverableActive()) {
      this.schedule(row.xmp_path, 0)
    }
  }

  schedule(xmpPath: string, delayMs?: number): void {
    if (this.stopped) return
    // Every schedule() is new write activity (rows were just inserted or
    // transitioned to pending/writing/failed by the caller): the session's
    // previous reload ack no longer covers this file. Invalidate it BEFORE
    // the row can become written/synced, so the renderer gate and the
    // confirm/cleanup guards can never see a stale ack (data-loss fix:
    // cleanup must not restore backups Capture One never loaded).
    this.clearReloadAckForXmpPath(xmpPath)
    void this.ensureBaseline(xmpPath)
    const existing = this.timers.get(xmpPath)
    if (existing) clearTimeout(existing)
    const delay = delayMs ?? Math.max(
      0,
      this.settings.getNumber('metadata_write_debounce_ms', 500),
    )
    this.timers.set(xmpPath, setTimeout(() => {
      this.timers.delete(xmpPath)
      void this.ensureBaseline(xmpPath).finally(() => {
        this.queued.add(xmpPath)
        this.drain()
      })
    }, delay))
  }

  getSummary(sessionId: string): MetadataSyncSummary {
    // Light projection: summary consumers only read the columns the items
    // carry (the renderer updates per-xmpPath status, writeback verifies
    // error_message), never the patch/base-values JSON blobs. getBySession
    // remains the fallback for legacy repo mocks.
    const rows = typeof this.outboxRepo.getSummaryRowsBySession === 'function'
      ? this.outboxRepo.getSummaryRowsBySession(sessionId)
      : this.outboxRepo.getBySession(sessionId)
    const items: MetadataSyncItem[] = rows.map(row => ({
      xmpPath: row.xmp_path,
      revision: row.revision,
      persistedRevision: row.persisted_revision,
      status: row.status,
      attemptCount: row.attempt_count,
      errorMessage: row.error_message,
      updatedAt: row.updated_at,
    }))
    // One grouped COUNT query instead of re-filtering the item array once per
    // status; the filter fallback keeps legacy repo mocks working.
    const counts = typeof this.outboxRepo.countBySession === 'function'
      ? this.outboxRepo.countBySession(sessionId)
      : {}
    const count = (status: MetadataSyncItem['status']): number =>
      counts[status] ?? items.filter(item => item.status === status).length
    return {
      sessionId,
      pending: count('pending'),
      writing: count('writing'),
      written: count('written'),
      failed: count('failed'),
      conflict: count('conflict'),
      synced: count('synced'),
      items,
    }
  }

  async getConflicts(sessionId: string): Promise<MetadataConflict[]> {
    const rows = this.outboxRepo.getBySession(sessionId)
      .filter(row => row.status === 'conflict')
    // Each conflict read hits the sidecar on disk; bound the parallelism to
    // the same concurrency the writer pipeline uses.
    return batchAsync(rows, async row => {
      const current = await this.writerRouter.selectSidecar().readAttributes(row.photo_path)
      const base = safeObject(row.base_values_json)
      const local = safeObject(row.patch_json)
      const dirtyFields = parseDirtyFields(row.dirty_fields)
      const fields = fieldConflicts(base, local, current, dirtyFields)
      return {
        xmpPath: row.xmp_path,
        photoPath: row.photo_path,
        revision: row.revision,
        fields,
      }
    }, MAX_CONCURRENCY)
  }

  async resolveConflict(
    sessionId: string,
    xmpPath: string,
    choices: Partial<Record<MetadataField, MetadataConflictChoice>>,
  ): Promise<MetadataSyncSummary> {
    const row = this.outboxRepo.getBySession(sessionId)
      .find(candidate => candidate.xmp_path === xmpPath)
    if (!row || row.status !== 'conflict') throw new Error('XMP_CONFLICT_NOT_FOUND')
    const conflict = (await this.getConflicts(sessionId))
      .find(candidate => candidate.xmpPath === xmpPath)
    if (!conflict || conflict.fields.length === 0) {
      throw new Error('XMP_CONFLICT_DETAILS_UNAVAILABLE')
    }
    for (const field of conflict.fields) {
      if (!choices[field.field]) {
        console.warn('Missing conflict choice for field', field.field)
        throw new Error('XMP_CHOICE_MISSING')
      }
    }
    const current = await this.writerRouter.selectSidecar().readAttributes(row.photo_path)
    const patch = safeObject(row.patch_json)
    let dirtyFields = tryParseDirtyFields(row.dirty_fields)
    if (!dirtyFields) {
      throw new Error('XMP_CONFLICT_DETAILS_INVALID')
    }
    for (const [field, choice] of Object.entries(choices) as Array<[MetadataField, MetadataConflictChoice]>) {
      if (choice === 'use_remote') {
        delete patch[field]
        dirtyFields = dirtyFields.filter(candidate => candidate !== field)
      }
    }
    const acceptRemote = dirtyFields.length === 0
    if (acceptRemote) {
      this.writebackRepo.discardPendingByXmpPath(xmpPath)
      // Keep the metadata cache and culling decisions in sync with the values
      // the user chose to keep, otherwise the UI keeps showing the local
      // rating/label/keywords indefinitely.
      this.syncAcceptedRemoteValues(row.photo_path, current)
    }
    this.outboxRepo.resolveConflict(
      xmpPath,
      patch,
      dirtyFields,
      await contentFingerprint(xmpPath) || '__missing__',
      { ...current },
      acceptRemote,
    )
    if (!acceptRemote) this.schedule(xmpPath, 0)
    return this.emitSummary(sessionId)
  }

  listOrphans(): MetadataOrphan[] {
    return this.outboxRepo.getOrphans().map(row => ({
      xmpPath: row.xmp_path,
      photoPath: row.photo_path,
      status: row.status,
      revision: row.revision,
      errorMessage: row.error_message,
      updatedAt: row.updated_at,
    }))
  }

  private syncAcceptedRemoteValues(
    photoPath: string,
    remote: MetadataWriteAttributes,
  ): void {
    try {
      // A corrupt sidecar makes readAttributes() return an empty object.
      // Mirror the metadata.service guard: don't let the empty read clear
      // previously valid cached values.
      if (
        Object.keys(remote).length === 0 &&
        existsSync(getXmpSidecarPath(photoPath))
      ) {
        return
      }
      const photos = this.db.prepare(
        'SELECT id, session_id FROM photos WHERE filepath = ?',
      ).all(photoPath) as Array<{ id: string; session_id: string }>
      const now = new Date().toISOString()
      const keywords = Array.isArray(remote.keywords) ? remote.keywords : []
      // Clamp to the culling_decisions CHECK constraints so a non-standard
      // external label/rating does not roll back the whole transaction.
      const rating = clampRating(remote.rating)
      const label = sanitizeCullingLabel(remote.label)
      const write = this.db.transaction(() => {
        for (const photo of photos) {
          try {
            this.db.prepare(`
              INSERT INTO photo_metadata_cache
                (photo_id, session_id, keywords, rating, label, cached_at)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(photo_id) DO UPDATE SET
                keywords = excluded.keywords,
                rating = excluded.rating,
                label = excluded.label,
                cached_at = excluded.cached_at
            `).run(photo.id, photo.session_id, JSON.stringify(keywords), rating, label, now)
            this.db.prepare(`
              UPDATE culling_decisions
              SET rating = ?, color_label = ?, updated_at = ?
              WHERE photo_id = ? AND session_id = ?
            `).run(rating, label, now, photo.id, photo.session_id)
          } catch (error) {
            // A single photo must not block the rest of the batch.
            console.warn('Failed to sync accepted remote values for photo', photo.id, error)
          }
        }
      })
      write()
    } catch (error) {
      console.warn('Failed to sync accepted remote metadata values', error)
    }
  }

  async resolveOrphan(
    xmpPath: string,
    action: 'keep' | 'restore' | 'retry',
  ): Promise<MetadataOrphan[]> {
    const row = this.outboxRepo.getOrphans().find(candidate => candidate.xmp_path === xmpPath)
    if (!row) throw new Error('XMP_ORPHAN_NOT_FOUND')
    if (action === 'retry') {
      if (row.status === 'conflict') {
        throw new Error('XMP_CONFLICT_RESOLUTION_REQUIRED')
      }
      if (row.status === 'failed') this.outboxRepo.resetForRetry(xmpPath)
      else if (row.status !== 'pending') throw new Error('XMP_ORPHAN_NOT_RETRYABLE')
      this.schedule(xmpPath, 0)
      return this.listOrphans()
    }
    await this.waitForIdle(xmpPath)
    if (action === 'restore') {
      if (row.backup_path) {
        if (!existsSync(row.backup_path)) {
          console.warn('XMP backup is missing for orphan restore:', row.backup_path)
          throw new Error('XMP_BACKUP_MISSING')
        }
        await this.writerRouter.selectSidecar().restore(row.photo_path, row.backup_path)
      } else if (existsSync(row.xmp_path)) {
        await unlink(row.xmp_path)
      }
    } else if (row.backup_path && existsSync(row.backup_path)) {
      await unlink(row.backup_path)
    }
    this.outboxRepo.delete(xmpPath)
    return this.listOrphans()
  }

  async flushSession(sessionId: string): Promise<MetadataSyncSummary> {
    const paths = this.outboxRepo.getBySession(sessionId)
      .filter(row => ['pending', 'writing', 'failed'].includes(row.status))
      .map(row => row.xmp_path)
    for (const path of paths) {
      const timer = this.timers.get(path)
      if (timer) clearTimeout(timer)
      this.timers.delete(path)
    }
    await Promise.all(paths.map(path => this.runPath(path)))
    return this.getSummary(sessionId)
  }

  async retrySession(sessionId: string): Promise<MetadataSyncSummary> {
    for (const row of this.outboxRepo.getBySession(sessionId)) {
      if (row.status === 'failed') {
        this.outboxRepo.resetForRetry(row.xmp_path)
        this.clearReloadAckForXmpPath(row.xmp_path)
      }
    }
    return this.flushSession(sessionId)
  }

  confirmSync(sessionId: string, sourceModule: string): MetadataSyncSummary {
    const summary = this.getSummary(sessionId)
    if (
      summary.pending > 0 ||
      summary.writing > 0 ||
      summary.failed > 0 ||
      summary.conflict > 0
    ) {
      throw new Error('XMP_CONFIRM_INCOMPLETE')
    }
    // Main-side guard closing the renderer-stale-view race: confirming sync
    // promotes rows to synced (which unlocks cleanup), so Capture One must
    // have loaded the metadata — i.e. a reload ack must exist. Without it,
    // cleanup could restore XMP backups the user never loaded.
    this.requireReloadAck(sessionId)
    this.outboxRepo.markSessionSynced(sessionId, sourceModule)
    return this.emitSummary(sessionId)
  }

  async cleanup(sessionId: string, sourceModule: string): Promise<CleanupResult> {
    const rows = this.outboxRepo.getBySession(sessionId)
    // Only restore rows written by the confirming module: a batch module's
    // cleanup must not restore XMP written by another module that has not
    // been confirmed in Capture One yet.
    const eligible = rows.filter(row =>
      row.status === 'synced' && row.source_module === sourceModule)
    if (eligible.length === 0 && rows.length > 0) {
      throw new Error('XMP_CLEANUP_REQUIRES_LOADED')
    }
    // Cleanup restores backups, so it may only run after Capture One loaded
    // the metadata (the same reload-ack gate as confirmSync). A new write
    // batch that landed after the last confirm invalidates the ack, so this
    // guard rejects the stale-view cleanup instead of restoring XMP that
    // Capture One never loaded.
    if (eligible.length > 0) {
      this.requireReloadAck(sessionId)
    }
    // The per-row sequence (wait for idle → verify fingerprint → restore or
    // unlink → mark cleaned) is order-sensitive only within one row, so
    // unrelated rows may run in parallel.
    const results = await batchAsync(eligible, async (row): Promise<{ deleted: boolean; error?: string }> => {
      try {
        // A new mutation may have been queued after the snapshot was taken.
        // Wait for any in-flight write and re-verify the row is still synced
        // before restoring/deleting the file, so a concurrent edit is not
        // silently reverted.
        await this.waitForIdle(row.xmp_path)
        const latest = this.outboxRepo.get(row.xmp_path)
        if (!latest || latest.status !== 'synced') return { deleted: false }
        const currentFingerprint = await contentFingerprint(row.xmp_path)
        if (
          latest.base_fingerprint &&
          currentFingerprint !== latest.base_fingerprint
        ) {
          this.outboxRepo.markStatus(
            row.xmp_path,
            'conflict',
            'XMP_CLEANUP_ABORTED_EXTERNAL_EDIT',
          )
          throw new Error('XMP_EXTERNALLY_MODIFIED')
        }
        if (latest.backup_path) {
          if (!existsSync(latest.backup_path)) {
            throw new Error('XMP_BACKUP_MISSING')
          }
          await this.writerRouter
            .selectSidecar()
            .restore(latest.photo_path, latest.backup_path)
        } else if (existsSync(latest.xmp_path)) {
          await unlink(latest.xmp_path)
        }
        this.outboxRepo.markStatus(latest.xmp_path, 'cleaned')
        this.outboxRepo.delete(latest.xmp_path)
        return { deleted: true }
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        return { deleted: false, error: `${row.xmp_path}: ${message}` }
      }
    }, MAX_CONCURRENCY)
    let deletedCount = 0
    const errors: string[] = []
    for (const result of results) {
      if (result.deleted) deletedCount++
      else if (result.error) errors.push(result.error)
    }
    this.emitSummary(sessionId)
    return { deletedCount, errors }
  }

  async finalizeSession(sessionId: string): Promise<MetadataSyncSummary> {
    const rows = this.outboxRepo.getBySession(sessionId)
    const eligible = rows.filter(row => row.status === 'synced')
    if (eligible.length === 0 && rows.length > 0) {
      throw new Error('XMP_CONFIRM_REQUIRES_SYNC')
    }
    // The per-row sequence below is order-sensitive only within one row
    // (backup removal before the revision-guarded delete), so unrelated rows
    // may run in parallel.
    await batchAsync(eligible, async (row) => {
      // A new mutation may have been queued after the snapshot was taken.
      // Wait for any in-flight write, then remove the backup BEFORE deleting
      // the row: an unlink failure must leave the row intact so the finalize
      // can be retried instead of leaking the .gather-backup file forever.
      // The row delete is revision-guarded: a mutation that lands while the
      // backup is being removed bumps the revision, so only the exact
      // finalized row is deleted and the fresh transaction survives. A
      // surviving row must not keep pointing at the removed backup (its
      // future writes would skip creating a fresh backup and cleanup would
      // fail on the dangling path), so the stale reference is cleared.
      await this.waitForIdle(row.xmp_path)
      const latest = this.outboxRepo.get(row.xmp_path)
      if (!latest || latest.status !== 'synced') return
      const backupPath = latest.backup_path
      if (backupPath && existsSync(backupPath)) {
        await unlink(backupPath)
      }
      this.outboxRepo.deleteByRevision(latest.xmp_path, latest.revision)
      if (backupPath) {
        this.outboxRepo.clearBackupPath(latest.xmp_path, backupPath)
      }
    }, MAX_CONCURRENCY)
    return this.emitSummary(sessionId)
  }

  async shutdown(): Promise<void> {
    this.stopped = true
    for (const timer of this.timers.values()) clearTimeout(timer)
    this.timers.clear()
    // Cancel pending coalesced summary pushes; direct emitSummary callers
    // (confirmSync/cleanup/finalizeSession) already pushed their own updates.
    for (const timer of this.summaryEmitTimers.values()) clearTimeout(timer)
    this.summaryEmitTimers.clear()
    this.summaryEmitCounts.clear()
    this.queued.clear()
    // Tasks can be added to `active` after the snapshot: a slot waiter is
    // released when a task finishes (starting its own task), and a concurrent
    // flushSession can call runPath directly. Keep waiting until active is
    // empty AND no waiter is parked, so no new task can start on the closing
    // database after shutdown returns.
    for (;;) {
      await Promise.allSettled([
        ...this.baselineTasks.values(),
        ...this.active.values(),
      ])
      if (this.active.size === 0 && this.slotWaiters.length === 0) break
      await new Promise<void>(resolve => setTimeout(resolve, 20))
    }
  }

  async waitForIdle(xmpPath: string, timeoutMs = 5_000): Promise<void> {
    const deadline = Date.now() + timeoutMs
    for (;;) {
      const active = this.active.get(xmpPath)
      if (active) await active
      const row = this.outboxRepo.get(xmpPath)
      if (!row || row.status !== 'writing') return
      if (Date.now() >= deadline) {
        console.warn('Timed out waiting for metadata writer:', xmpPath)
        throw new Error('XMP_WRITER_TIMEOUT')
      }
      await new Promise<void>(resolve => setTimeout(resolve, 20))
    }
  }

  private drain(): void {
    while (!this.stopped && this.queued.size > 0) {
      const xmpPath = this.queued.values().next().value as string
      this.queued.delete(xmpPath)
      void this.runPath(xmpPath)
    }
  }

  private runPath(xmpPath: string): Promise<void> {
    if (this.stopped) return Promise.resolve()
    const existing = this.active.get(xmpPath)
    if (existing) return existing
    const task = this.withSlot(() => this.processUntilCurrent(xmpPath))
      .catch(error => {
        console.error(
          `Metadata sync failed for ${xmpPath}:`,
          error instanceof Error ? error.message : error,
        )
      })
      .finally(() => {
        this.active.delete(xmpPath)
        this.drain()
      })
    this.active.set(xmpPath, task)
    return task
  }

  private async withSlot<T>(operation: () => Promise<T>): Promise<T> {
    if (this.activeCount >= MAX_CONCURRENCY) {
      await new Promise<void>(resolve => this.slotWaiters.push(resolve))
    }
    this.activeCount++
    try {
      return await operation()
    } finally {
      this.activeCount--
      this.slotWaiters.shift()?.()
    }
  }

  private async processUntilCurrent(xmpPath: string): Promise<void> {
    for (;;) {
      if (this.stopped) return
      await this.ensureBaseline(xmpPath)
      const row = this.outboxRepo.get(xmpPath)
      if (!row || !['pending', 'writing', 'failed'].includes(row.status)) return
      const shouldContinue = await this.processRow(row)
      if (!shouldContinue) return
      const latest = this.outboxRepo.get(xmpPath)
      if (!latest || latest.status !== 'pending') return
    }
  }

  private async processRow(row: MetadataOutboxRow): Promise<boolean> {
    if (!this.outboxRepo.claim(row.xmp_path, row.revision)) return false
    // The row is now writing: any surviving reload ack (crash window between
    // queue and claim) is invalidated before the row can reach written.
    this.clearReloadAckForXmpPath(row.xmp_path)

    try {
      const currentFingerprint = await contentFingerprint(row.xmp_path)
      const currentFingerprintToken = currentFingerprint || '__missing__'
      // A crash between the atomic rename and markWritten leaves the file
      // containing our own write while the baseline still describes the
      // original content. Detect that case and complete the transaction
      // instead of reporting a fake external conflict.
      if (
        row.backup_path &&
        row.base_fingerprint &&
        currentFingerprintToken !== row.base_fingerprint
      ) {
        const current = await this.writerRouter.selectSidecar().readAttributes(row.photo_path)
        if (attributesMatchPatch(current, safeObject(row.patch_json))) {
          this.outboxRepo.markWritten(
            row.xmp_path,
            row.revision,
            currentFingerprintToken,
            { ...current },
            row.backup_path,
          )
          this.emitPathSummaries(row.xmp_path)
          return true
        }
      }
      if (
        row.base_fingerprint &&
        currentFingerprintToken !== row.base_fingerprint &&
        await this.hasDirtyFieldConflict(row)
      ) {
        this.outboxRepo.markStatus(
          row.xmp_path,
          'conflict',
          'XMP_EXTERNAL_EDIT_CONFLICT',
        )
        this.emitPathSummaries(row.xmp_path)
        return false
      }

      const writer = this.writerRouter.selectSidecar()
      const backupPath = row.backup_path || await writer.backup(row.photo_path)
      if (!row.backup_path) {
        this.outboxRepo.setBackupPath(row.xmp_path, backupPath)
      }
      const patch = safeObject(row.patch_json)
      await writer.writeAttributes(row.photo_path, {
        keywords: Array.isArray(patch.keywords)
          ? patch.keywords.filter((value): value is string => typeof value === 'string')
          : undefined,
        rating: typeof patch.rating === 'number' ? patch.rating : undefined,
        label: typeof patch.label === 'string' ? patch.label : undefined,
      })
      const persistedValues = await writer.readAttributes(row.photo_path)
      this.outboxRepo.markWritten(
        row.xmp_path,
        row.revision,
        await contentFingerprint(row.xmp_path),
        { ...persistedValues },
        backupPath,
      )
      this.emitPathSummaries(row.xmp_path)
      return true
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      this.outboxRepo.markStatus(row.xmp_path, 'failed', message)
      const latest = this.outboxRepo.get(row.xmp_path)
      if (latest && latest.attempt_count < MAX_AUTOMATIC_ATTEMPTS) {
        const retryIndex = Math.min(
          latest.attempt_count - 1,
          RETRY_DELAYS_MS.length - 1,
        )
        this.schedule(row.xmp_path, RETRY_DELAYS_MS[Math.max(0, retryIndex)])
      }
      this.emitPathSummaries(row.xmp_path)
      return false
    }
  }

  private async hasDirtyFieldConflict(row: MetadataOutboxRow): Promise<boolean> {
    const current = await this.writerRouter
      .selectSidecar()
      .readAttributes(row.photo_path)
    const base = safeObject(row.base_values_json)
    const dirtyFields = tryParseDirtyFields(row.dirty_fields)
    // Corrupt stored dirty-fields are treated conservatively as a conflict;
    // a legitimately empty list means there is nothing in conflict.
    if (!dirtyFields) return true
    return hasFieldConflict(base, current, dirtyFields)
  }

  private ensureBaseline(xmpPath: string): Promise<void> {
    const existingTask = this.baselineTasks.get(xmpPath)
    if (existingTask) return existingTask
    const task = (async () => {
      const row = this.outboxRepo.get(xmpPath)
      if (!row || row.base_fingerprint) return
      const baselineFingerprint = await contentFingerprint(row.xmp_path)
      let baselineValues: Record<string, unknown> = {}
      try {
        baselineValues = {
          ...await this.writerRouter
            .selectSidecar()
            .readAttributes(row.photo_path),
        }
      } catch {
        // A corrupt sidecar is fingerprinted here and rejected by the writer.
      }
      this.outboxRepo.initializeBaseline(
        xmpPath,
        baselineFingerprint || '__missing__',
        baselineValues,
      )
    })().finally(() => {
      this.baselineTasks.delete(xmpPath)
    })
    this.baselineTasks.set(xmpPath, task)
    return task
  }

  private emitSummary(sessionId: string): MetadataSyncSummary {
    const summary = this.getSummary(sessionId)
    this.eventSink?.(summary)
    return summary
  }

  private getOutboxSessionIds(xmpPath: string): string[] {
    return typeof this.outboxRepo.getSessionIds === 'function'
      ? this.outboxRepo.getSessionIds(xmpPath)
      : [this.outboxRepo.get(xmpPath)?.owner_session_id].filter(
        (value): value is string => typeof value === 'string',
      )
  }

  /**
   * New write activity invalidates the session's reload ack: Capture One
   * loaded the previous generation of metadata, so a fresh reload (and a
   * fresh ack) is required before confirm/cleanup may run again. This is the
   * durable half of the safeToCleanup gate (data-loss fix): cleanup restores
   * XMP backups, and a stale ack would let it restore files Capture One
   * never loaded.
   */
  private clearReloadAck(sessionId: string): void {
    this.db.prepare(
      'UPDATE sessions SET reload_acked_at = NULL, updated_at = ? WHERE id = ? AND reload_acked_at IS NOT NULL',
    ).run(new Date().toISOString(), sessionId)
  }

  private clearReloadAckForXmpPath(xmpPath: string): void {
    for (const sessionId of this.getOutboxSessionIds(xmpPath)) {
      this.clearReloadAck(sessionId)
    }
  }

  /**
   * Main-side guard (complements the renderer button gate): confirm and
   * cleanup are only allowed while the session's reload ack exists. Throws a
   * code the renderer translates, so a stale renderer view (which still shows
   * the old acked state) cannot confirm or clean up against a fresh ack.
   * The ack is written by the Capture One reload bridge, which cannot run in
   * e2e; the gate itself is unit-tested (reload-ack-invalidation.test.ts),
   * so the e2e workflow bypasses it under an explicit test-only env flag.
   */
  private requireReloadAck(sessionId: string): void {
    if (process.env.GATHER_TEST_SKIP_RELOAD_ACK === '1') return
    const row = this.db.prepare(
      'SELECT reload_acked_at FROM sessions WHERE id = ?',
    ).get(sessionId) as { reload_acked_at: string | null } | undefined
    if (!row?.reload_acked_at) throw new Error('XMP_RELOAD_NOT_ACKED')
  }

  private emitPathSummaries(xmpPath: string): void {
    const sessionIds = this.getOutboxSessionIds(xmpPath)
    for (const sessionId of sessionIds) {
      // Coalesce the per-row pushes of a busy write burst: rows finishing
      // inside the same window emit a single fresh summary per session. A
      // long uninterrupted burst (hundreds of rows) must still show
      // progress, so the window is short and once enough rows completed
      // inside it the summary is pushed immediately; the replaced timer
      // still guarantees the final state is never lost.
      const count = (this.summaryEmitCounts.get(sessionId) ?? 0) + 1
      this.summaryEmitCounts.set(sessionId, count)
      const existing = this.summaryEmitTimers.get(sessionId)
      if (existing) clearTimeout(existing)
      if (count >= SUMMARY_EMIT_BURST_THRESHOLD) {
        this.summaryEmitCounts.set(sessionId, 0)
        if (this.stopped) continue
        this.emitSummary(sessionId)
        continue
      }
      this.summaryEmitTimers.set(sessionId, setTimeout(() => {
        this.summaryEmitTimers.delete(sessionId)
        this.summaryEmitCounts.set(sessionId, 0)
        if (this.stopped) return
        this.emitSummary(sessionId)
      }, SUMMARY_EMIT_THROTTLE_MS))
    }
  }
}
