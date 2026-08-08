import { opendir, stat } from 'node:fs/promises'
import { createReadStream, realpathSync, watch, type FSWatcher } from 'node:fs'
import { createHash } from 'node:crypto'
import path from 'node:path'
import BetterSqlite3 from 'better-sqlite3'
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
    return textualPath(value)
  }
}

// Cheap textual canonicalization for per-file membership checks: resolves the
// macOS /var -> /private/var and /tmp -> /private/tmp symlinks (the only
// symlinked paths a directory walk can yield — opendir reports symlinks via
// isSymbolicLink, so the walker never descends into them). Avoiding
// realpathSync.native per file removes one syscall from every visited path
// during a full scan (network volumes are 10-100x slower at it).
function textualPath(value: string): string {
  const resolved = path.resolve(value)
  if (process.platform === 'darwin' && (resolved === '/var' || resolved.startsWith('/var/'))) {
    return `/private${resolved}`
  }
  if (process.platform === 'darwin' && (resolved === '/tmp' || resolved.startsWith('/tmp/'))) {
    return `/private${resolved}`
  }
  return resolved
}

function isWithin(candidate: string, canonicalRoot: string): boolean {
  const relative = path.relative(canonicalRoot, textualPath(candidate))
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

// Full-scan traversal is parallelized with bounded concurrency: opendir is
// cheap, but thousands of simultaneous handles still thrash a spinning disk.
// File paths are streamed through a bounded channel so the consumer can
// start analyzing while the walk is still listing the tree (producer/
// consumer overlap) without buffering every path in memory.
const WALK_CONCURRENCY = 6
const WALK_CHANNEL_CAPACITY = 256

// IN-list chunk size: keeps every statement well under SQLite's variable
// bound (32766 on recent builds) for the whole-session id sets a scan can
// accumulate (generated-cache sweeps, missing-photo sweeps, pruning).
const IN_CHUNK_SIZE = 400

// Navigation-group LIKE prefilter cap: photo_ids_json is scanned per
// affected id, so a very large affected set (whole-session reimport) falls
// back to reading all automatic groups once and parsing in JS.
const PRUNE_LIKE_PREFILTER_CAP = 200

/**
 * Bounded async channel used by `walk` to stream file paths to its consumer
 * with backpressure: a producer that outruns the consumer waits instead of
 * buffering the whole tree. `fail` surfaces a root-level error to the
 * consumer; `close` ends the stream normally after draining the buffer.
 */
class BoundedChannel<T> {
  private readonly buffer: T[] = []
  private readonly pullers: Array<{
    resolve: (result: IteratorResult<T>) => void
    reject: (reason: unknown) => void
  }> = []
  private readonly pushers: Array<() => void> = []
  private closed = false
  private failure: unknown = null

  constructor(private readonly capacity: number) {}

  push(value: T): Promise<void> {
    if (this.closed) return Promise.resolve()
    this.buffer.push(value)
    this.drain()
    if (this.buffer.length > this.capacity) {
      return new Promise<void>(resolve => this.pushers.push(resolve))
    }
    return Promise.resolve()
  }

  pull(): Promise<IteratorResult<T>> {
    if (this.buffer.length > 0) {
      const value = this.buffer.shift() as T
      this.drain()
      return Promise.resolve({ value, done: false })
    }
    if (this.closed) {
      if (this.failure !== null) return Promise.reject(this.failure)
      return Promise.resolve({ value: undefined, done: true })
    }
    return new Promise((resolve, reject) => this.pullers.push({ resolve, reject }))
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    this.drain()
    for (const resolve of this.pushers.splice(0)) resolve()
    for (const puller of this.pullers.splice(0)) {
      puller.resolve({ value: undefined, done: true })
    }
  }

  fail(error: unknown): void {
    this.failure = error
    this.closed = true
    this.buffer.length = 0
    for (const resolve of this.pushers.splice(0)) resolve()
    for (const puller of this.pullers.splice(0)) puller.reject(error)
  }

  private drain(): void {
    while (this.pullers.length > 0 && this.buffer.length > 0) {
      const puller = this.pullers.shift() as {
        resolve: (result: IteratorResult<T>) => void
        reject: (reason: unknown) => void
      }
      puller.resolve({ value: this.buffer.shift() as T, done: false })
    }
    while (this.pushers.length > 0 && this.buffer.length <= this.capacity) {
      ;(this.pushers.shift() as () => void)()
    }
  }
}

/**
 * Parallel directory walk. A small pool of workers lists directories from a
 * shared queue (top-level buckets) with bounded concurrency and streams the
 * file paths out through a bounded channel. Semantics match the previous
 * sequential walk: each file is produced exactly once (directory subtrees
 * never overlap), an unreadable non-root directory is reported through
 * `onUnreadableDirectory`, excluded roots are skipped entirely, and an
 * unreadable root throws.
 */
async function* walk(
  root: string,
  excludedRoots: readonly string[],
  onUnreadableDirectory: (directory: string) => void,
): AsyncGenerator<string> {
  const channel = new BoundedChannel<string>(WALK_CHANNEL_CAPACITY)
  const pendingDirs = [root]
  let outstanding = 1
  let rootError: unknown = null
  let ended = false
  const waiters: Array<() => void> = []

  const signal = (): void => {
    for (const waiter of waiters.splice(0)) waiter()
  }

  const finish = (): void => {
    if (ended) return
    if (outstanding > 0) return
    ended = true
    if (rootError !== null) channel.fail(rootError)
    else channel.close()
    signal()
  }

  const traverse = async (dir: string, isRoot: boolean): Promise<void> => {
    try {
      let entries: Awaited<ReturnType<typeof opendir>>
      try {
        entries = await opendir(dir)
      } catch (error) {
        if (isRoot) rootError = error
        else onUnreadableDirectory(dir)
        return
      }
      try {
        for await (const entry of entries) {
          const full = path.join(dir, entry.name)
          if (excludedRoots.some(excluded => isWithin(full, excluded))) continue
          if (entry.isDirectory()) {
            pendingDirs.push(full)
            outstanding++
            signal()
          } else if (SUPPORTED.has(path.extname(entry.name).toLowerCase())) {
            await channel.push(full)
          }
        }
      } catch (error) {
        if (isRoot) rootError = error
        else onUnreadableDirectory(dir)
      }
    } finally {
      outstanding--
      finish()
      signal()
    }
  }

  const run = async (): Promise<void> => {
    for (;;) {
      if (ended) return
      const dir = pendingDirs.shift()
      if (dir === undefined) {
        if (outstanding === 0) return
        await new Promise<void>(resolve => waiters.push(resolve))
        continue
      }
      await traverse(dir, dir === root)
    }
  }
  const runners = Array.from({ length: WALK_CONCURRENCY }, () => run())

  try {
    for (;;) {
      const item = await channel.pull()
      if (item.done) {
        await Promise.all(runners)
        return
      }
      yield item.value
    }
  } finally {
    // Consumer stopped early (break/cancel/error): close the channel so
    // producers drop instead of blocking forever on a full buffer.
    channel.close()
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

// Background checksum backfill: hashing RAW files is I/O bound, so batches are
// small and concurrency modest to avoid disk thrashing during other activity.
const CHECKSUM_BACKFILL_BATCH = 32
const CHECKSUM_BACKFILL_CONCURRENCY = 6

// scanBatch I/O concurrency: stat/dimension reads stay at four simultaneous
// files, matching the old 64-file batches, so the parallel walk and streamed
// processing do not add extra disk thrashing on spinning media.
const SCAN_BATCH_CONCURRENCY = 4

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

  /**
   * Run `callback` over IN-list-sized chunks of `values` so no statement ever
   * exceeds SQLite's variable limit (32766 for recent builds, 999 for older)
   * no matter how large the caller's id set grows.
   */
  private forEachInChunk<T>(values: readonly T[], callback: (chunk: readonly T[]) => void): void {
    for (let offset = 0; offset < values.length; offset += IN_CHUNK_SIZE) {
      callback(values.slice(offset, offset + IN_CHUNK_SIZE))
    }
  }

  /**
   * Delete the per-photo analysis *inputs* for the given photos (per-photo
   * granularity), so the next analysis pass recomputes only the affected
   * photos and reuses the signatures/hashes of every other photo in the
   * session. All of these tables are keyed by photo_id.
   */
  private deletePhotoInputs(photoIds: readonly string[]): void {
    if (photoIds.length === 0) return
    this.forEachInChunk(photoIds, (chunk) => {
      const placeholders = chunk.map(() => '?').join(',')
      this.db.prepare(`DELETE FROM similarity_hashes WHERE photo_id IN (${placeholders})`)
        .run(...chunk)
      this.db.prepare(`DELETE FROM face_observations WHERE photo_id IN (${placeholders})`)
        .run(...chunk)
      this.db.prepare(`DELETE FROM face_analysis_state WHERE photo_id IN (${placeholders})`)
        .run(...chunk)
      this.db.prepare(`DELETE FROM asset_analysis WHERE photo_id IN (${placeholders})`)
        .run(...chunk)
      this.db.prepare(`DELETE FROM photo_metadata_cache WHERE photo_id IN (${placeholders})`)
        .run(...chunk)
    })
  }

  /**
   * Automatic navigation groups are pruned per member: only groups that
   * actually contain an affected photo are removed; the rest of the
   * session's groups are preserved. Members are stored as a JSON array of
   * photo ids in navigation_groups.photo_ids_json, so the groups are read
   * out and filtered in JS before deletion (rows with unreadable JSON are
   * kept rather than deleted on a guess).
   *
   * Photo ids are UUIDs, so the JSON-escaped member `"<uuid>"` is an exact
   * substring: a LIKE prefilter (used when the affected set is small) skips
   * the JSON.parse of every group in the session, which is what made
   * per-file pruning O(changed x groups) on large sessions.
   */
  private pruneAutomaticNavigationGroups(
    sessionId: string,
    photoIds: readonly string[],
  ): void {
    const affected = new Set(photoIds)
    let groups: Array<{ id: string; photo_ids_json: string }> = []
    if (photoIds.length > 0 && photoIds.length <= PRUNE_LIKE_PREFILTER_CAP) {
      const conditions = photoIds.map(() => "photo_ids_json LIKE ? ESCAPE '\\'").join(' OR ')
      const patterns = photoIds.map(id =>
        `%"${id.replace(/[\\%_]/g, match => `\\${match}`)}"%`,
      )
      groups = this.db.prepare(`
        SELECT id, photo_ids_json FROM navigation_groups
        WHERE session_id = ? AND source = 'automatic' AND (${conditions})
      `).all(sessionId, ...patterns) as Array<{ id: string; photo_ids_json: string }>
    } else {
      groups = this.db.prepare(`
        SELECT id, photo_ids_json FROM navigation_groups
        WHERE session_id = ? AND source = 'automatic'
      `).all(sessionId) as Array<{ id: string; photo_ids_json: string }>
    }
    const doomed: string[] = []
    for (const group of groups) {
      try {
        const members = JSON.parse(group.photo_ids_json) as unknown
        if (Array.isArray(members) && members.some(member => affected.has(String(member)))) {
          doomed.push(group.id)
        }
      } catch {
        // Corrupt JSON: keep the group.
      }
    }
    this.forEachInChunk(doomed, (chunk) => {
      const placeholders = chunk.map(() => '?').join(',')
      this.db.prepare(`DELETE FROM navigation_groups WHERE id IN (${placeholders})`)
        .run(...chunk)
    })
  }

  /**
   * Global cluster results (similarity groups, face clusters, cluster
   * members, role bindings) are deliberately invalidated at session scope:
   * there is no incremental clustering facility yet, so a partial
   * invalidation cannot be merged back into the existing global clusters.
   * Neighborhood re-clustering depends on incremental clustering (ROADMAP
   * 1.3); until then the fallback is input-level invalidation (per-photo
   * deletes in deletePhotoInputs) plus a fast re-cluster — similarity
   * re-clustering of ~20k photos takes about 1-2s, and the unchanged
   * photos' signatures/hashes are reused instead of recomputed.
   */
  private deleteGlobalClusterResults(sessionId: string): void {
    this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?').run(sessionId)
  }

  /**
   * Face clustering results also stay session-scoped (see
   * deleteGlobalClusterResults). Members are removed before the observations
   * they reference (face_cluster_members.observation_id -> face_observations).
   */
  private deleteFaceClusterResults(sessionId: string): void {
    this.db.prepare('DELETE FROM face_cluster_state WHERE session_id = ?').run(sessionId)
    this.db.prepare('DELETE FROM face_cluster_members WHERE session_id = ?').run(sessionId)
    this.db.prepare('DELETE FROM role_bindings WHERE session_id = ?').run(sessionId)
    this.db.prepare('DELETE FROM face_clusters WHERE session_id = ?').run(sessionId)
  }

  /**
   * Invalidate analysis for photos whose file path changed (relink) or whose
   * content changed. Inputs are deleted per photo, automatic navigation
   * groups are pruned per member, and global cluster results are dropped at
   * session scope. Callers accumulate every affected photo of a scan batch
   * and invoke this once per batch: the session-wide work (cluster deletes,
   * group parsing) is then O(1) per session instead of O(changed x groups).
   */
  private invalidatePathDependentAnalysis(photoIds: readonly string[]): void {
    if (photoIds.length === 0) return
    const affectedSessions = new Set<string>()
    this.forEachInChunk(photoIds, (chunk) => {
      const placeholders = chunk.map(() => '?').join(',')
      const rows = this.db.prepare(`
        SELECT DISTINCT session_id FROM photos WHERE id IN (${placeholders})
      `).all(...chunk) as Array<{ session_id: string }>
      for (const row of rows) affectedSessions.add(row.session_id)
    })
    // Per-session photo id sets keep pruning targeted at each session.
    const photoIdsBySession = new Map<string, string[]>()
    this.forEachInChunk(photoIds, (chunk) => {
      const placeholders = chunk.map(() => '?').join(',')
      const rows = this.db.prepare(`
        SELECT id, session_id FROM photos WHERE id IN (${placeholders})
      `).all(...chunk) as Array<{ id: string; session_id: string }>
      for (const row of rows) {
        const list = photoIdsBySession.get(row.session_id) ?? []
        list.push(row.id)
        photoIdsBySession.set(row.session_id, list)
      }
    })
    this.db.transaction(() => {
      // Session-scoped cluster results first: their member rows must be gone
      // before the per-photo observation deletes they reference.
      for (const sessionId of affectedSessions) {
        this.deleteFaceClusterResults(sessionId)
        this.deleteGlobalClusterResults(sessionId)
      }
      this.deletePhotoInputs(photoIds)
      for (const [sessionId, sessionPhotoIds] of photoIdsBySession) {
        this.pruneAutomaticNavigationGroups(sessionId, sessionPhotoIds)
      }
    })()
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
    let existing = this.photoRepo.getBySessionProjection(sessionId)
    const generatedCachePhotos = existing.filter(photo =>
      excludedRoots.some(excluded => isWithin(path.resolve(photo.filepath), excluded)),
    )
    if (generatedCachePhotos.length > 0) {
      const photoIds = generatedCachePhotos.map(photo => photo.id)
      const fileIds = generatedCachePhotos.flatMap(photo =>
        photo.asset_file_id ? [photo.asset_file_id] : [],
      )
      this.db.transaction(() => {
        this.forEachInChunk(photoIds, (chunk) => {
          const placeholders = chunk.map(() => '?').join(', ')
          this.db.prepare(`DELETE FROM photos WHERE id IN (${placeholders})`).run(...chunk)
        })
        this.db.prepare(`
          DELETE FROM session_assets
          WHERE session_id = ? AND NOT EXISTS (
            SELECT 1 FROM photos p
            WHERE p.session_id = session_assets.session_id
              AND p.asset_id = session_assets.asset_id
          )
        `).run(sessionId)
        if (fileIds.length > 0) {
          this.forEachInChunk(fileIds, (chunk) => {
            const filePlaceholders = chunk.map(() => '?').join(', ')
            this.db.prepare(`
              DELETE FROM asset_files
              WHERE id IN (${filePlaceholders})
                AND NOT EXISTS (SELECT 1 FROM photos p WHERE p.asset_file_id = asset_files.id)
            `).run(...chunk)
          })
          this.db.prepare(`
            DELETE FROM assets
            WHERE NOT EXISTS (
              SELECT 1 FROM asset_members am WHERE am.asset_id = assets.id
            )
          `).run()
        }
      })()
      const removedIds = new Set(photoIds)
      existing = existing.filter(photo => !removedIds.has(photo.id))
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
      // Lazy mode indexes new/changed files from dimensions alone and defers
      // checksum computation to the background checksum.backfill job.
      const lazyChecksum = this.settings.get('lazy_checksum', 'true') !== 'false'
      const results = await mapConcurrent(filepaths, SCAN_BATCH_CONCURRENCY, async filepath => {
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
            const checksum = lazyChecksum ? '' : await sha256File(filepath)
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
          const needsChecksum = contentChanged || !indexed?.checksum
          const checksum = needsChecksum
            ? (lazyChecksum ? '' : await sha256File(filepath))
            : indexed.checksum
          // Race with the background checksum.backfill job (both run under
          // MAX_CONCURRENT_JOBS=2): the fileStats snapshot above may be stale,
          // showing checksum='' while backfill has already written a hash to
          // photos/asset_files. When the file did NOT change, an empty
          // snapshot checksum must not be treated as "needs a fresh hash" in
          // a way that clears the concurrent write; the scan only computes or
          // clears checksums for files it observed as actually changed.
          const preserveChecksum = lazyChecksum && !contentChanged && !indexed?.checksum
          return {
            kind: 'existing' as const,
            photoId: photo.id,
            assetFileId: photo.asset_file_id,
            dimensions,
            contentChanged,
            source,
            checksum,
            preserveChecksum,
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
      // Photos whose content or location changed within this batch. The
      // session-scoped invalidation (cluster deletes, navigation-group
      // pruning) runs once per batch afterwards instead of per file, so a
      // 1000-file batch costs one pass over the session's groups instead of
      // 1000 (see invalidatePathDependentAnalysis).
      const batchAffectedPhotoIds = new Set<string>()
      // All writes of the batch commit in a single transaction: per-photo
      // transactions used to turn a 64-file batch into 64 fsync'd commits.
      const commitBatch = this.db.transaction((batchResults: typeof results) => {
        for (const result of batchResults) {
        if (result.kind === 'new') {
          let relocated: ReturnType<AssetRepository['relinkMovedFile']>
          try {
            relocated = this.assetRepo.relinkMovedFile(
              result.filepath,
              result.checksum,
              result.source.size,
              result.source.mtimeMs,
              String(result.source.ino),
            )
          } catch (error) {
            // Per-file recoverable failures: the relink user guards (XMP
            // write in progress, conflicting sidecar state) must not roll
            // back the whole batch — the files processed so far were already
            // handled and the previous per-file commits kept them. Mark the
            // file failed and continue; only real database errors abort the
            // batch (classified below by the SqliteError class).
            if (error instanceof BetterSqlite3.SqliteError) throw error
            failed.push(result.filepath)
            continue
          }
          if (relocated && relocated.photoIds.length > 0) {
            for (const photoId of relocated.photoIds) {
              batchAffectedPhotoIds.add(photoId)
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
          // Lazy mode + unchanged file + empty checksum in the (possibly
          // stale) snapshot: keep whatever is stored in photos.checksum.
          // It may be a hash the concurrent backfill just wrote; clearing
          // it to '' would discard that work and force a redundant re-hash
          // on the next round. Real content changes still clear below.
          if (!result.preserveChecksum) {
            this.photoRepo.updateChecksum(
              result.photoId,
              result.checksum,
              result.source.size,
              result.source.mtimeMs,
            )
          }
          if (result.assetFileId) {
            this.db.prepare(`
              UPDATE asset_files
              SET volume_id = ?, file_identity = ?, file_size = ?, file_mtime_ms = ?,
                  checksum = CASE WHEN ? = 1 THEN checksum ELSE ? END,
                  online_status = 'online', last_seen_at = ?, updated_at = ?
              WHERE id = ?
            `).run(
              `dev:${result.source.dev}`,
              String(result.source.ino),
              result.source.size,
              result.source.mtimeMs,
              // Preserve the stored checksum instead of overwriting it
              // when the file was not observed as changed but the snapshot
              // lacked a checksum (see preserveChecksum above).
              result.preserveChecksum ? 1 : 0,
              result.checksum,
              new Date().toISOString(),
              new Date().toISOString(),
              result.assetFileId,
            )
            if (result.contentChanged) {
              const photoIds = (this.db.prepare(
                'SELECT id FROM photos WHERE asset_file_id = ?',
              ).all(result.assetFileId) as Array<{ id: string }>)
                .map(row => row.id)
              for (const photoId of photoIds) {
                batchAffectedPhotoIds.add(photoId)
              }
              // File-level sweep of asset_analysis for orphaned rows whose
              // photo_id was already nulled by a previous photo deletion.
              this.db.prepare('DELETE FROM asset_analysis WHERE asset_file_id = ?')
                .run(result.assetFileId)
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
          }
        } else if (result.kind === 'failed') {
          failed.push(result.filepath)
        } else if (result.kind === 'missing') {
          // Not added to discoveredSet: reconciled as missing by the final pass.
        } else {
          skipped++
        }
        }
      })
      commitBatch(results)
      // One invalidation pass per scan batch, only after the batch committed:
      // cluster results are dropped at session scope and automatic navigation
      // groups pruned per member. A failed commit rolls back every write of
      // the batch, so the photos' checksums and paths are unchanged and their
      // previous analysis inputs and cluster results stay valid — deleting
      // them here would strand analysis results that the next scan would skip
      // re-building (it sees the unchanged checksums as already indexed).
      this.invalidatePathDependentAnalysis([...batchAffectedPhotoIds])
      if (newEntries.length > 0) {
        const inserted = this.photoRepo.addPhotos(sessionId, newEntries, 'index')
        added += inserted.added
        skipped += inserted.skipped
        // addPhotos returns the id of each fresh row, so the checksums are
        // written without re-reading the whole session table — the previous
        // getBySessionProjection here made a first import O(n²) (one full
        // session read per file).
        for (let i = 0; i < newEntries.length; i++) {
          const id = inserted.ids[i]
          if (!id) continue
          this.photoRepo.updateChecksum(
            id,
            newEntries[i].checksum,
            newEntries[i].fileSize,
            newEntries[i].fileMtimeMs,
          )
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
      // Producer/consumer: walk() streams paths through a bounded channel
      // while scanBatch() consumes them, so traversal and analysis overlap
      // instead of the old "accumulate 64 files, then process" double
      // buffering. A fixed window of scanBatches (one file each) stays in
      // flight, preserving the ~4-way I/O concurrency of the old batches
      // without waiting for a full batch to fill.
      let scanError: unknown = undefined
      const inFlight = new Set<Promise<void>>()
      const track = (task: Promise<void>): Promise<void> => {
        inFlight.add(task)
        return task.then(
          () => { inFlight.delete(task) },
          (error: unknown) => {
            inFlight.delete(task)
            scanError = scanError ?? error
          },
        )
      }
      for await (const filepath of walk(
        session.source_path,
        excludedRoots,
        directory => failed.push(directory),
      )) {
        context?.throwIfCancelled()
        discovered++
        context?.updateProgress({
          current: discovered,
          total: 0,
          message: '正在增量扫描文件',
        })
        while (inFlight.size >= SCAN_BATCH_CONCURRENCY) {
          await Promise.race([...inFlight].map(task => task.catch(() => undefined)))
        }
        if (scanError !== undefined) throw scanError
        void track(scanBatch([filepath]))
      }
      await Promise.all([...inFlight].map(task => task.catch(() => undefined)))
      if (scanError !== undefined) throw scanError
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
      this.forEachInChunk(fileIds, (chunk) => {
        const placeholders = chunk.map(() => '?').join(', ')
        this.db.prepare(`
          UPDATE asset_files SET online_status = 'offline', updated_at = ?
          WHERE id IN (${placeholders})
        `).run(new Date().toISOString(), ...chunk)
      })
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

  /**
   * Number of photos in a session that still need a checksum computed
   * (lazy mode leaves them empty). Used by the caller to decide whether a
   * checksum.backfill job is worth creating.
   */
  pendingChecksums(sessionId: string): number {
    return this.photoRepo.getBySessionProjection(sessionId)
      .filter(photo => !photo.checksum && photo.status !== 'missing')
      .length
  }

  /**
   * Background backfill of checksums left empty by lazy indexing. Iterates
   * until no photo still lacks a checksum: photos scanned while this job is
   * running (a queued duplicate job would be deduped away) are picked up by
   * the next pass. Each batch stats the file for fresh size/mtime so the
   * checksum_file_size/mtime columns stay consistent with the hashed content.
   *
   * The same checksum is written to the linked asset_files row, keeping the
   * incremental scan's unchanged-detection (which reads asset_files.checksum)
   * in sync with photos.checksum; otherwise the next full scan would see an
   * empty checksum and trigger yet another backfill.
   *
   * Both writes are guarded with `AND checksum = ''` (optimistic, only fill
   * empty rows) so a concurrent metadata.scan that wrote or cleared a
   * checksum is never overwritten: if the guarded photos update affects zero
   * rows, the hash is skipped instead of clobbering the scan's value.
   *
   * Photos whose file cannot be stat()ed or hashed (deleted, disk offline,
   * permanently unreadable) are recorded in a per-job failed set and excluded
   * from later passes, so the loop terminates instead of retrying them
   * forever; the next full scan marks them missing or a later job can retry.
   */
  async backfillChecksums(
    sessionId: string,
    context?: JobRunContext,
  ): Promise<{ processed: number; backfilled: number; skipped: number }> {
    let processed = 0
    let backfilled = 0
    let skipped = 0
    const failedPhotoIds = new Set<string>()
    for (;;) {
      context?.throwIfCancelled()
      const pending = this.photoRepo.getBySessionProjection(sessionId)
        .filter(photo =>
          !photo.checksum &&
          photo.status !== 'missing' &&
          !failedPhotoIds.has(photo.id),
        )
      if (pending.length === 0) break
      context?.updateProgress({
        current: 0,
        total: pending.length,
        message: '正在后台补齐文件校验和',
      })
      let passBackfilled = 0
      for (let offset = 0; offset < pending.length; offset += CHECKSUM_BACKFILL_BATCH) {
        context?.throwIfCancelled()
        const batch = pending.slice(offset, offset + CHECKSUM_BACKFILL_BATCH)
        const results = await mapConcurrent(
          batch,
          CHECKSUM_BACKFILL_CONCURRENCY,
          async photo => {
            try {
              const source = await this.stat(photo.filepath)
              const checksum = await sha256File(photo.filepath)
              return { photo, checksum, size: source.size, mtimeMs: source.mtimeMs }
            } catch {
              // Deleted or unreadable since the scan; give up on it for this
              // job run so the loop terminates. The next full scan marks it
              // missing or a later backfill job can retry.
              failedPhotoIds.add(photo.id)
              return null
            }
          },
        )
        // The hashing phase above is read-only; all writes of the batch go
        // into one transaction instead of one per photo (32 fsync'd commits
        // per batch under synchronous=FULL).
        const commitBatch = this.db.transaction((batchResults: typeof results) => {
          for (const result of batchResults) {
            if (result) {
              // Optimistic fill: only write when the photo's checksum is
              // still empty. A concurrent scan may have just written a hash
              // (or cleared one for a file it observed as changed); the
              // guard ensures backfill never overwrites the scan's decision,
              // avoiding the scan/backfill ping-pong that used to clear
              // freshly backfilled hashes.
              const photoChanges = this.db.prepare(`
                UPDATE photos
                SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
                    updated_at = ?
                WHERE id = ? AND checksum = ''
              `).run(
                result.checksum,
                result.size,
                result.mtimeMs,
                new Date().toISOString(),
                result.photo.id,
              ).changes
              if (photoChanges === 0) {
                // Another writer already filled (or cleared) this photo's
                // checksum; skip the linked asset_files write as well so
                // photos and asset_files stay consistent.
                skipped++
              } else {
                if (result.photo.asset_file_id) {
                  this.db.prepare(`
                    UPDATE asset_files
                    SET checksum = ?, file_size = ?, file_mtime_ms = ?, updated_at = ?
                    WHERE id = ? AND checksum = ''
                  `).run(
                    result.checksum,
                    result.size,
                    result.mtimeMs,
                    new Date().toISOString(),
                    result.photo.asset_file_id,
                  )
                }
                passBackfilled++
                backfilled++
              }
            } else {
              skipped++
            }
            processed++
          }
        })
        commitBatch(results)
        context?.updateProgress({ current: processed, total: pending.length })
      }
      // Everything still pending either failed or the retry would only repeat
      // failures; stop instead of spinning on permanently unreadable files.
      if (passBackfilled === 0) break
    }
    return { processed, backfilled, skipped }
  }
}
