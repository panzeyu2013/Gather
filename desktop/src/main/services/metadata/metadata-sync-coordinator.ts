import { createHash } from 'crypto'
import { existsSync } from 'fs'
import { readFile, stat, unlink } from 'fs/promises'
import type {
  CleanupResult,
  MetadataSyncItem,
  MetadataSyncSummary,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import {
  MetadataOutboxRepository,
  type MetadataOutboxRow,
} from '../../db/repositories/metadata-outbox.repo'
import { WritebackRepository } from '../../db/repositories/writeback.repo'
import { MetadataWriterRouter } from '../xmp/metadata-writer-router'
import { SettingsService } from '../settings/settings.service'

const MAX_CONCURRENCY = 2
const MAX_AUTOMATIC_ATTEMPTS = 5
const RETRY_DELAYS_MS = [1_000, 2_000, 5_000, 15_000, 30_000]

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

async function fingerprint(path: string): Promise<string> {
  try {
    const info = await stat(path)
    const content = await readFile(path)
    return `${info.size}:${Math.round(info.mtimeMs)}:${createHash('sha256').update(content).digest('hex')}`
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw error
  }
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

  constructor(
    @inject(DI_TOKENS.METADATA_OUTBOX_REPO)
    private outboxRepo: MetadataOutboxRepository,
    @inject(DI_TOKENS.WRITEBACK_REPO)
    private writebackRepo: WritebackRepository,
    @inject(DI_TOKENS.WRITER_ROUTER)
    private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.SETTINGS_SERVICE)
    private settings: SettingsService,
  ) {}

  start(eventSink?: EventSink): void {
    this.stopped = false
    this.eventSink = eventSink ?? null
    this.outboxRepo.purgeOrphans()
    this.outboxRepo.recoverInterrupted()
    for (const row of this.outboxRepo.getRecoverable()) {
      this.schedule(row.xmp_path, 0)
    }
  }

  schedule(xmpPath: string, delayMs?: number): void {
    if (this.stopped) return
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
    const rows = this.outboxRepo.getBySession(sessionId)
    const items: MetadataSyncItem[] = rows.map(row => ({
      xmpPath: row.xmp_path,
      revision: row.revision,
      persistedRevision: row.persisted_revision,
      status: row.status,
      attemptCount: row.attempt_count,
      errorMessage: row.error_message,
      updatedAt: row.updated_at,
    }))
    return {
      sessionId,
      pending: items.filter(item => item.status === 'pending').length,
      writing: items.filter(item => item.status === 'writing').length,
      written: items.filter(item => item.status === 'written').length,
      failed: items.filter(item => item.status === 'failed').length,
      conflict: items.filter(item => item.status === 'conflict').length,
      synced: items.filter(item => item.status === 'synced').length,
      items,
    }
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
      }
    }
    return this.flushSession(sessionId)
  }

  confirmSync(sessionId: string): MetadataSyncSummary {
    const summary = this.getSummary(sessionId)
    if (
      summary.pending > 0 ||
      summary.writing > 0 ||
      summary.failed > 0 ||
      summary.conflict > 0
    ) {
      throw new Error('仍有未完成、失败或冲突的 XMP 项目，不能确认同步')
    }
    this.outboxRepo.markSessionSynced(sessionId)
    return this.emitSummary(sessionId)
  }

  async cleanup(sessionId: string): Promise<CleanupResult> {
    const rows = this.outboxRepo.getBySession(sessionId)
    const eligible = rows.filter(row => row.status === 'synced')
    if (eligible.length === 0 && rows.length > 0) {
      throw new Error('请先在 Capture One 中加载元数据并确认同步，再执行清理')
    }
    let deletedCount = 0
    const errors: string[] = []
    for (const row of eligible) {
      try {
        const currentFingerprint = await fingerprint(row.xmp_path)
        if (
          row.base_fingerprint &&
          currentFingerprint !== row.base_fingerprint
        ) {
          this.outboxRepo.markStatus(
            row.xmp_path,
            'conflict',
            'XMP 在 Capture One 加载后又被修改，已停止清理以保护外部更改',
          )
          throw new Error('XMP 已被其他软件修改，不能自动恢复或删除')
        }
        if (row.backup_path) {
          if (!existsSync(row.backup_path)) {
            throw new Error(`原始 XMP 备份不存在：${row.backup_path}`)
          }
          await this.writerRouter
            .selectSidecar()
            .restore(row.photo_path, row.backup_path)
        } else if (existsSync(row.xmp_path)) {
          await unlink(row.xmp_path)
        }
        this.outboxRepo.markStatus(row.xmp_path, 'cleaned')
        this.outboxRepo.delete(row.xmp_path)
        deletedCount++
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error)
        errors.push(`${row.xmp_path}: ${message}`)
      }
    }
    this.emitSummary(sessionId)
    return { deletedCount, errors }
  }

  async finalizeSession(sessionId: string): Promise<MetadataSyncSummary> {
    const rows = this.outboxRepo.getBySession(sessionId)
    const eligible = rows.filter(row => row.status === 'synced')
    if (eligible.length === 0 && rows.length > 0) {
      throw new Error('请先在 Capture One 中加载元数据并确认同步')
    }
    for (const row of eligible) {
      if (row.backup_path && existsSync(row.backup_path)) {
        await unlink(row.backup_path)
      }
      this.outboxRepo.delete(row.xmp_path)
    }
    return this.emitSummary(sessionId)
  }

  async shutdown(): Promise<void> {
    this.stopped = true
    for (const timer of this.timers.values()) clearTimeout(timer)
    this.timers.clear()
    this.queued.clear()
    await Promise.allSettled([
      ...this.baselineTasks.values(),
      ...this.active.values(),
    ])
  }

  async waitForIdle(xmpPath: string, timeoutMs = 5_000): Promise<void> {
    const deadline = Date.now() + timeoutMs
    for (;;) {
      const active = this.active.get(xmpPath)
      if (active) await active
      const row = this.outboxRepo.get(xmpPath)
      if (!row || row.status !== 'writing') return
      if (Date.now() >= deadline) {
        throw new Error(`Timed out waiting for metadata writer: ${xmpPath}`)
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
    if (this.writebackRepo.hasActiveForXmpPath(row.xmp_path)) {
      this.outboxRepo.markStatus(
        row.xmp_path,
        'pending',
        '等待显式写回事务释放该 XMP 文件',
      )
      this.schedule(row.xmp_path, 5_000)
      return false
    }
    if (!this.outboxRepo.claim(row.xmp_path, row.revision)) return false

    try {
      const currentFingerprint = await fingerprint(row.xmp_path)
      const currentFingerprintToken = currentFingerprint || '__missing__'
      if (
        row.base_fingerprint &&
        currentFingerprintToken !== row.base_fingerprint &&
        await this.hasDirtyFieldConflict(row)
      ) {
        this.outboxRepo.markStatus(
          row.xmp_path,
          'conflict',
          'XMP 已被其他软件修改，且与 Gather 待写字段冲突',
        )
        this.emitSummary(row.owner_session_id)
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
        await fingerprint(row.xmp_path),
        { ...persistedValues },
        backupPath,
      )
      this.emitSummary(row.owner_session_id)
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
      this.emitSummary(row.owner_session_id)
      return false
    }
  }

  private async hasDirtyFieldConflict(row: MetadataOutboxRow): Promise<boolean> {
    const current = await this.writerRouter
      .selectSidecar()
      .readAttributes(row.photo_path)
    const base = safeObject(row.base_values_json)
    let dirtyFields: string[] = []
    try {
      const parsed = JSON.parse(row.dirty_fields)
      dirtyFields = Array.isArray(parsed)
        ? parsed.filter((value): value is string => typeof value === 'string')
        : []
    } catch {
      return true
    }
    return dirtyFields.some(field => {
      if (field === 'rating') return current.rating !== base.rating
      if (field === 'label') return (current.label ?? '') !== (base.label ?? '')
      if (field === 'keywords') {
        return JSON.stringify(current.keywords ?? []) !== JSON.stringify(base.keywords ?? [])
      }
      return true
    })
  }

  private ensureBaseline(xmpPath: string): Promise<void> {
    const existingTask = this.baselineTasks.get(xmpPath)
    if (existingTask) return existingTask
    const task = (async () => {
      const row = this.outboxRepo.get(xmpPath)
      if (!row || row.base_fingerprint) return
      const baselineFingerprint = await fingerprint(row.xmp_path)
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
}
