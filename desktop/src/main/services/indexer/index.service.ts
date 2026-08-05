import { opendir, stat } from 'node:fs/promises'
import { createReadStream, realpathSync, watch, type FSWatcher } from 'node:fs'
import { createHash } from 'node:crypto'
import path from 'node:path'
import { app } from 'electron'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { Database } from '../../db/database'
import { SessionRepository } from '../../db/repositories/session.repo'
import { PhotoRepository } from '../../db/repositories/photo.repo'
import { AssetRepository } from '../../db/repositories/asset.repo'
import type { ImageService } from '../image'
import type { IndexScanResult } from '@gather/shared'
import type { JobRunContext } from '../jobs/job.service'
import { SettingsService } from '../settings/settings.service'

const SUPPORTED = new Set([
  '.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif',
  '.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw',
  '.tif', '.tiff', '.psd',
])

function canonicalPath(value: string): string {
  try {
    return realpathSync.native(value)
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

function isWithin(candidate: string, canonicalRoot: string): boolean {
  const relative = path.relative(canonicalRoot, canonicalPath(candidate))
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative))
}

function managedCacheRoots(settings: SettingsService): string[] {
  const configured = settings.get('disk_cache_dir', '').trim()
  if (configured) return [canonicalPath(configured)]
  try {
    return [canonicalPath(path.resolve(app.getPath('userData'), 'thumbnails'))]
  } catch {
    return []
  }
}

async function* walk(
  root: string,
  excludedRoots: readonly string[],
  onUnreadableDirectory: (directory: string) => void,
  isRoot = true,
): AsyncGenerator<string> {
  let entries
  try {
    entries = await opendir(root)
  } catch (error) {
    if (isRoot) throw error
    onUnreadableDirectory(root)
    return
  }
  try {
    for await (const entry of entries) {
      const full = path.join(root, entry.name)
      if (excludedRoots.some(excluded => isWithin(full, excluded))) continue
      if (entry.isDirectory()) {
        yield* walk(full, excludedRoots, onUnreadableDirectory, false)
      } else if (SUPPORTED.has(path.extname(entry.name).toLowerCase())) {
        yield full
      }
    }
  } catch (error) {
    if (isRoot) throw error
    onUnreadableDirectory(root)
  }
}

async function sha256File(filePath: string): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(filePath)) hash.update(chunk as Buffer)
  return hash.digest('hex')
}

async function mapConcurrent<T, R>(
  items: readonly T[],
  concurrency: number,
  worker: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length)
  let next = 0
  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      for (;;) {
        const index = next++
        if (index >= items.length) return
        results[index] = await worker(items[index])
      }
    },
  )
  await Promise.all(runners)
  return results
}

@injectable()
export class IndexService {
  private watchers = new Map<string, FSWatcher>()
  private watcherRoots = new Map<string, string>()
  private timers = new Map<string, ReturnType<typeof setTimeout>>()
  private pendingWatcherPaths = new Map<string, Set<string>>()
  private watcherNeedsFullScan = new Set<string>()
  private recoveryScanScheduler: ((sessionId: string) => void) | null = null
  private refreshTimer: ReturnType<typeof setInterval> | null = null
  constructor(
    @inject(DI_TOKENS.DB) private db: Database,
    @inject(DI_TOKENS.SESSION_REPO) private sessionRepo: SessionRepository,
    @inject(DI_TOKENS.PHOTO_REPO) private photoRepo: PhotoRepository,
    @inject(DI_TOKENS.ASSET_REPO) private assetRepo: AssetRepository,
    @inject(DI_TOKENS.IMAGE_SERVICE) private imageService: ImageService,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
  ) {}
  /**
   * Test seam: the fs stat used by the incremental scan, overridable to
   * simulate files disappearing between the directory listing and stat().
   */
  public stat: typeof stat = stat

  private invalidatePathDependentAnalysis(photoIds: readonly string[]): void {
    if (photoIds.length === 0) return
    const placeholders = photoIds.map(() => '?').join(',')
    const affectedSessions = this.db.prepare(`
      SELECT DISTINCT session_id FROM photos WHERE id IN (${placeholders})
    `).all(...photoIds) as Array<{ session_id: string }>
    for (const affected of affectedSessions) {
      this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?')
        .run(affected.session_id)
      this.db.prepare(
        "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
      ).run(affected.session_id)
    }
  }

  startWatchers(): void {
    const sessions = this.sessionRepo.list()
    const activeRoots = new Map(
      sessions
        .filter(session => Boolean(session.source_path))
        .map(session => [session.id, session.source_path]),
    )
    for (const [sessionId, watcher] of this.watchers) {
      if (activeRoots.get(sessionId) !== this.watcherRoots.get(sessionId)) {
        watcher.close()
        this.watchers.delete(sessionId)
        this.watcherRoots.delete(sessionId)
        const timer = this.timers.get(sessionId)
        if (timer) clearTimeout(timer)
        this.timers.delete(sessionId)
        this.pendingWatcherPaths.delete(sessionId)
        this.watcherNeedsFullScan.delete(sessionId)
      }
    }
    for (const session of sessions) {
      if (!session.source_path || this.watchers.has(session.id)) continue
      try {
        const watcher = watch(session.source_path, { recursive: true }, (_eventType, filename) => {
          const relative = filename ?? undefined
          if (relative && SUPPORTED.has(path.extname(relative).toLowerCase())) {
            const pending = this.pendingWatcherPaths.get(session.id) ?? new Set<string>()
            pending.add(path.join(session.source_path, relative))
            this.pendingWatcherPaths.set(session.id, pending)
          } else {
            // Directory changes can introduce/remove multiple files, so a
            // complete reconciliation is the only safe fallback.
            this.watcherNeedsFullScan.add(session.id)
          }
          const previous = this.timers.get(session.id)
          if (previous) clearTimeout(previous)
          this.timers.set(session.id, setTimeout(() => {
            this.timers.delete(session.id)
            const changed = [...(this.pendingWatcherPaths.get(session.id) ?? [])]
            this.pendingWatcherPaths.delete(session.id)
            const fullScan = this.watcherNeedsFullScan.delete(session.id)
            if (fullScan && this.recoveryScanScheduler) {
              this.recoveryScanScheduler(session.id)
              return
            }
            const scan = this.scanSession(
              session.id,
              undefined,
              fullScan ? undefined : changed,
            )
            void scan.catch(error => console.warn('Incremental scan failed', error))
          }, 750))
        })
        watcher.on('error', error => {
          console.warn('Index watcher failed; scheduling full reconciliation', error)
          watcher.close()
          this.watchers.delete(session.id)
          this.watcherRoots.delete(session.id)
          if (!this.watcherNeedsFullScan.has(session.id)) {
            this.watcherNeedsFullScan.add(session.id)
            this.recoveryScanScheduler?.(session.id)
          }
        })
        this.watchers.set(session.id, watcher)
        this.watcherRoots.set(session.id, session.source_path)
        if (this.watcherNeedsFullScan.delete(session.id)) {
          this.recoveryScanScheduler?.(session.id)
        }
      } catch (error) {
        console.warn(`Unable to watch session ${session.id}`, error)
        if (!this.watcherNeedsFullScan.has(session.id)) {
          this.watcherNeedsFullScan.add(session.id)
          this.recoveryScanScheduler?.(session.id)
        }
      }
    }
    if (!this.refreshTimer) {
      this.refreshTimer = setInterval(() => this.startWatchers(), 15_000)
    }
  }

  setRecoveryScanScheduler(scheduler: (sessionId: string) => void): void {
    this.recoveryScanScheduler = scheduler
  }

  stopWatchers(): void {
    for (const timer of this.timers.values()) clearTimeout(timer)
    this.timers.clear()
    this.pendingWatcherPaths.clear()
    this.watcherNeedsFullScan.clear()
    for (const watcher of this.watchers.values()) watcher.close()
    this.watchers.clear()
    this.watcherRoots.clear()
    if (this.refreshTimer) clearInterval(this.refreshTimer)
    this.refreshTimer = null
  }

  async scanSession(
    sessionId: string,
    context?: JobRunContext,
    requestedPaths?: string[],
  ): Promise<IndexScanResult> {
    const session = this.sessionRepo.get(sessionId)
    if (!session) throw new Error('Session not found')
    if (!session.source_path) throw new Error('Session has no source directory')
    const excludedRoots = managedCacheRoots(this.settings)
    let existing = this.photoRepo.getBySession(sessionId)
    const generatedCachePhotos = existing.filter(photo =>
      excludedRoots.some(excluded => isWithin(path.resolve(photo.filepath), excluded)),
    )
    if (generatedCachePhotos.length > 0) {
      const photoIds = generatedCachePhotos.map(photo => photo.id)
      const fileIds = generatedCachePhotos.flatMap(photo =>
        photo.asset_file_id ? [photo.asset_file_id] : [],
      )
      const placeholders = photoIds.map(() => '?').join(', ')
      this.db.transaction(() => {
        this.db.prepare(`DELETE FROM photos WHERE id IN (${placeholders})`).run(...photoIds)
        this.db.prepare(`
          DELETE FROM session_assets
          WHERE session_id = ? AND NOT EXISTS (
            SELECT 1 FROM photos p
            WHERE p.session_id = session_assets.session_id
              AND p.asset_id = session_assets.asset_id
          )
        `).run(sessionId)
        if (fileIds.length > 0) {
          const filePlaceholders = fileIds.map(() => '?').join(', ')
          this.db.prepare(`
            DELETE FROM asset_files
            WHERE id IN (${filePlaceholders})
              AND NOT EXISTS (SELECT 1 FROM photos p WHERE p.asset_file_id = asset_files.id)
          `).run(...fileIds)
          this.db.prepare(`
            DELETE FROM assets
            WHERE NOT EXISTS (
              SELECT 1 FROM asset_members am WHERE am.asset_id = assets.id
            )
          `).run()
        }
      })()
      existing = existing.filter(photo => !photoIds.includes(photo.id))
    }
    const existingByPath = new Map(existing.map(photo => [
      path.normalize(path.resolve(photo.filepath)),
      photo,
    ]))
    const fileRows = this.db.prepare(`
      SELECT af.id, af.file_size, af.file_mtime_ms, af.checksum
      FROM asset_files af
      JOIN photos p ON p.asset_file_id = af.id
      WHERE p.session_id = ?
    `).all(sessionId) as Array<{
      id: string
      file_size: number
      file_mtime_ms: number
      checksum: string
    }>
    const fileStats = new Map(fileRows.map(row => [row.id, row]))
    const discoveredSet = new Set<string>()
    const relinkedPhotoIds = new Set<string>()
    const failed: string[] = []
    let discovered = 0
    let added = 0
    let skipped = 0
    const scanBatch = async (filepaths: string[]): Promise<void> => {
      context?.throwIfCancelled()
      // RAW hashing is mostly I/O bound but too many simultaneous streams cause
      // severe disk thrashing. Keep this bounded independently of batch size.
      const results = await mapConcurrent(filepaths, 4, async filepath => {
        const normalized = path.normalize(path.resolve(filepath))
        // Confirm the file exists before counting it as discovered. A file
        // deleted between the directory listing and this stat() must not
        // enter discoveredSet, or the final pass would never mark it missing
        // (ghost photos).
        let source: Awaited<ReturnType<typeof stat>>
        try {
          source = await this.stat(filepath)
        } catch {
          return { kind: 'missing' as const, filepath }
        }
        discoveredSet.add(normalized)
        const photo = existingByPath.get(normalized)
        try {
          if (!photo) {
            const dimensions = await this.imageService.getDimensions(filepath)
            const checksum = await sha256File(filepath)
            return { kind: 'new' as const, filepath, dimensions, source, checksum }
          }
          const indexed = photo.asset_file_id ? fileStats.get(photo.asset_file_id) : undefined
          const contentChanged = !indexed ||
            indexed.file_size !== source.size ||
            Math.abs(indexed.file_mtime_ms - source.mtimeMs) >= 1
          if (!contentChanged && photo.status !== 'missing' && indexed?.checksum) {
            return { kind: 'unchanged' as const }
          }
          const dimensions = await this.imageService.getDimensions(filepath)
          const checksum = contentChanged || !indexed?.checksum
            ? await sha256File(filepath)
            : indexed.checksum
          return {
            kind: 'existing' as const,
            photoId: photo.id,
            assetFileId: photo.asset_file_id,
            dimensions,
            contentChanged,
            source,
            checksum,
          }
        } catch {
          return { kind: 'failed' as const, filepath }
        }
      })
      const newEntries: Array<{
        filepath: string
        width: number
        height: number
        checksum: string
        fileSize: number
        fileMtimeMs: number
      }> = []
      for (const result of results) {
        if (result.kind === 'new') {
          const relocated = this.assetRepo.relinkMovedFile(
            result.filepath,
            result.checksum,
            result.source.size,
            result.source.mtimeMs,
            String(result.source.ino),
          )
          if (relocated && relocated.photoIds.length > 0) {
            this.invalidatePathDependentAnalysis(relocated.photoIds)
            for (const photoId of relocated.photoIds) {
              relinkedPhotoIds.add(photoId)
              this.photoRepo.updateIndexedFile(
                photoId,
                result.dimensions.width,
                result.dimensions.height,
                true,
              )
              this.photoRepo.updateChecksum(
                photoId,
                result.checksum,
                result.source.size,
                result.source.mtimeMs,
              )
            }
            skipped++
          } else {
            newEntries.push({
              filepath: result.filepath,
              width: result.dimensions.width,
              height: result.dimensions.height,
              checksum: result.checksum,
              fileSize: result.source.size,
              fileMtimeMs: result.source.mtimeMs,
            })
          }
        } else if (result.kind === 'existing') {
          this.photoRepo.updateIndexedFile(
            result.photoId,
            result.dimensions.width,
            result.dimensions.height,
            result.contentChanged,
          )
          this.photoRepo.updateChecksum(
            result.photoId,
            result.checksum,
            result.source.size,
            result.source.mtimeMs,
          )
          if (result.assetFileId) {
            this.db.transaction(() => {
              this.db.prepare(`
                UPDATE asset_files
                SET volume_id = ?, file_identity = ?, file_size = ?, file_mtime_ms = ?, checksum = ?,
                    online_status = 'online', last_seen_at = ?, updated_at = ?
                WHERE id = ?
              `).run(
                `dev:${result.source.dev}`,
                String(result.source.ino),
                result.source.size,
                result.source.mtimeMs,
                result.checksum,
                new Date().toISOString(),
                new Date().toISOString(),
                result.assetFileId,
              )
              if (result.contentChanged) {
                const affectedSessions = this.db.prepare(
                  'SELECT DISTINCT session_id FROM photos WHERE asset_file_id = ?',
                ).all(result.assetFileId) as Array<{ session_id: string }>
                for (const affected of affectedSessions) {
                  this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?')
                    .run(affected.session_id)
                  this.db.prepare('DELETE FROM face_cluster_state WHERE session_id = ?')
                    .run(affected.session_id)
                  this.db.prepare('DELETE FROM face_cluster_members WHERE session_id = ?')
                    .run(affected.session_id)
                  this.db.prepare('DELETE FROM role_bindings WHERE session_id = ?')
                    .run(affected.session_id)
                  this.db.prepare('DELETE FROM face_clusters WHERE session_id = ?')
                    .run(affected.session_id)
                  this.db.prepare(
                    "DELETE FROM navigation_groups WHERE session_id = ? AND source = 'automatic'",
                  ).run(affected.session_id)
                }
                this.db.prepare('DELETE FROM asset_analysis WHERE asset_file_id = ?')
                  .run(result.assetFileId)
                this.db.prepare(`
                  DELETE FROM similarity_hashes
                  WHERE photo_id IN (SELECT id FROM photos WHERE asset_file_id = ?)
                `).run(result.assetFileId)
                this.db.prepare(`
                  DELETE FROM face_observations
                  WHERE photo_id IN (SELECT id FROM photos WHERE asset_file_id = ?)
                `).run(result.assetFileId)
                this.db.prepare(`
                  DELETE FROM face_analysis_state
                  WHERE photo_id IN (SELECT id FROM photos WHERE asset_file_id = ?)
                `).run(result.assetFileId)
                this.db.prepare(`
                  DELETE FROM photo_metadata_cache
                  WHERE photo_id IN (SELECT id FROM photos WHERE asset_file_id = ?)
                `).run(result.assetFileId)
                this.db.prepare(`
                  UPDATE photos
                  SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                      width = ?, height = ?, updated_at = ?
                  WHERE asset_file_id = ?
                `).run(
                  result.checksum,
                  result.source.size,
                  result.source.mtimeMs,
                  result.dimensions.width,
                  result.dimensions.height,
                  new Date().toISOString(),
                  result.assetFileId,
                )
              }
            })()
          }
        } else if (result.kind === 'failed') {
          failed.push(result.filepath)
        } else if (result.kind === 'missing') {
          // Not added to discoveredSet: reconciled as missing by the final pass.
        } else {
          skipped++
        }
      }
      const inserted = this.photoRepo.addPhotos(sessionId, newEntries, 'index')
      added += inserted.added
      skipped += inserted.skipped
      if (newEntries.length > 0) {
        const newPaths = new Set(newEntries.map(entry => entry.filepath))
        const byPath = new Map(
          this.photoRepo.getBySession(sessionId)
            .filter(photo => newPaths.has(photo.filepath))
            .map(photo => [photo.filepath, photo]),
        )
        for (const entry of newEntries) {
          const photo = byPath.get(entry.filepath)
          if (photo) {
            this.photoRepo.updateChecksum(
              photo.id,
              entry.checksum,
              entry.fileSize,
              entry.fileMtimeMs,
            )
          }
        }
      }
    }
    if (requestedPaths) {
      const candidates: string[] = []
      for (const filepath of new Set(requestedPaths.map(candidate => path.resolve(candidate)))) {
        if (excludedRoots.some(excluded => isWithin(filepath, excluded))) continue
        try {
          const source = await this.stat(filepath)
          if (source.isFile() && SUPPORTED.has(path.extname(filepath).toLowerCase())) {
            candidates.push(filepath)
            discovered++
          }
        } catch {
          // Missing paths are reconciled below.
        }
      }
      if (candidates.length > 0) await scanBatch(candidates)
    } else {
      let batch: string[] = []
      for await (const filepath of walk(
        session.source_path,
        excludedRoots,
        directory => failed.push(directory),
      )) {
        batch.push(filepath)
        discovered++
        if (batch.length >= 64) {
          await scanBatch(batch)
          batch = []
          context?.updateProgress({
            current: discovered,
            total: 0,
            message: '正在增量扫描文件',
          })
        }
      }
      if (batch.length > 0) await scanBatch(batch)
    }
    const requestedNormalized = requestedPaths
      ? new Set(requestedPaths.map(candidate => path.normalize(path.resolve(candidate))))
      : null
    const missing = existing.filter(photo => {
      const normalized = path.normalize(path.resolve(photo.filepath))
      // Photos relinked to a new path during this scan are re-associated, not
      // missing: their pre-scan path snapshot never appears in discoveredSet.
      return (!requestedNormalized || requestedNormalized.has(normalized)) &&
        !discoveredSet.has(normalized) &&
        !relinkedPhotoIds.has(photo.id)
    })
    this.photoRepo.markMissing(missing.map(photo => photo.id))
    this.assetRepo.backfillSession(sessionId)
    const finalCount = this.photoRepo.countBySession(sessionId)
    this.sessionRepo.updatePhotoCount(sessionId, finalCount)
    if (finalCount > 0 && session.status === 'draft') {
      this.sessionRepo.updateStatus(sessionId, 'photos_loaded')
    }
    if (missing.length > 0) {
      const fileIds = missing.flatMap(photo => photo.asset_file_id ? [photo.asset_file_id] : [])
      if (fileIds.length > 0) {
        const placeholders = fileIds.map(() => '?').join(', ')
        this.db.prepare(`
          UPDATE asset_files SET online_status = 'offline', updated_at = ?
          WHERE id IN (${placeholders})
        `).run(new Date().toISOString(), ...fileIds)
      }
    }
    context?.updateProgress({
      current: discovered,
      total: discovered,
      message: '索引完成',
    })
    return {
      sessionId,
      discovered,
      added,
      skipped,
      missing: missing.length,
      failed,
    }
  }
}
