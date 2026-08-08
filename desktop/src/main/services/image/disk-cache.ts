import * as fs from 'fs'
import * as fsp from 'fs/promises'
import * as path from 'path'
import BetterSqlite3 from 'better-sqlite3'

export enum EvictionPolicy {
  LRU = 'lru',
  FIFO = 'fifo',
  LFU = 'lfu',
}

export interface CacheEntry {
  lastAccess: number
  createdAt: number
  accessCount: number
  fileSize: number
}

export interface CacheMetadata {
  entries: Record<string, CacheEntry>
}

interface DbRow {
  hash: string
  last_access: number
  created_at: number
  access_count: number
  file_size: number
}

interface EvictionCandidate {
  hash: string
  val: number
  size: number
}

// Metadata is persisted to SQLite with a debounced, batched flush so the hot
// paths (onAccess/onSet) only touch the in-memory map and never block the
// main thread on serialization or I/O. A single-row synchronous UPDATE would
// also be fast (µs-level in WAL mode), but a burst of accesses in one frame
// would then serialize dozens of synchronous writes on the main thread.
const PERSIST_DEBOUNCE_MS = 500
const PERSIST_FLUSH_THRESHOLD = 256
// Lazy eviction: candidates are selected only when the cache is over budget.
// The per-policy ORDER BY index in SQLite yields the k smallest persisted
// values in O(log n + k); every in-memory entry whose value can differ from
// the persisted row (un-flushed updates) is tracked in the dirty set, so
// merging those (small) sets — over a window of limit + |dirty| rows — and
// re-sorting on live in-memory values is strictly equivalent to scanning the
// whole map, at a fraction of the cost.
const MIN_EVICTION_BATCH = 100
// Number of metadata rows materialized into the in-memory map per chunk
// while loading; each chunk stays well under the 50ms main-thread budget.
const LOAD_ROW_CHUNK = 10000

export class DiskCacheManager {
  private meta: CacheMetadata = { entries: {} }
  private totalSize = 0
  private fileCount = 0
  private readonly dbPath: string
  private readonly metaJsonPath: string
  private readonly db: BetterSqlite3.Database
  private readonly selectChunkStmt: BetterSqlite3.Statement<[number, number], DbRow>
  private readonly selectEvictLruStmt: BetterSqlite3.Statement<[number], DbRow>
  private readonly selectEvictFifoStmt: BetterSqlite3.Statement<[number], DbRow>
  private readonly selectEvictLfuStmt: BetterSqlite3.Statement<[number], DbRow>
  private readonly upsertStmt: BetterSqlite3.Statement<[string, number, number, number, number]>
  private readonly deleteStmt: BetterSqlite3.Statement<[string]>
  private readonly persistTx: BetterSqlite3.Transaction<(
    rows: Array<[string, CacheEntry]>,
    deletes: Set<string>,
  ) => void>

  private dirty = new Set<string>()
  private pendingDeletes = new Set<string>()
  private persistTimer: NodeJS.Timeout | null = null
  private readonly ready: Promise<void>
  private persistQueue: Promise<void> = Promise.resolve()
  private evictionQueue: Promise<void> = Promise.resolve()
  private loadComplete = false
  // onSet/onAccess calls that arrive while load() is still streaming the
  // previous run's rows. Replayed after load so they are not clobbered by
  // stale rows read from disk (and never double-counted against the rows).
  private preReadySets = new Map<string, {
    fileSize?: number
    createdAt?: number
    at?: number
    accessed?: boolean
  }>()

  constructor(
    private cacheDir: string,
    private maxSizeBytes: number,
    private policy: EvictionPolicy,
  ) {
    try {
      if (!fs.existsSync(cacheDir)) {
        fs.mkdirSync(cacheDir, { recursive: true })
      }
    } catch (e) {
      console.warn('DiskCache: cannot create cache directory, continuing in memory', e)
    }
    this.dbPath = path.join(cacheDir, 'cache-meta.db')
    this.metaJsonPath = path.join(cacheDir, 'cache-meta.json')
    this.db = this.openDb()
    this.selectChunkStmt = this.db.prepare(
      'SELECT hash, last_access, created_at, access_count, file_size FROM cache_meta ORDER BY hash LIMIT ? OFFSET ?',
    )
    // Eviction candidates come from the per-policy index; the hash tiebreak
    // keeps the window deterministic across calls.
    this.selectEvictLruStmt = this.db.prepare(
      'SELECT hash, last_access, created_at, access_count, file_size FROM cache_meta ORDER BY last_access ASC, hash ASC LIMIT ?',
    )
    this.selectEvictFifoStmt = this.db.prepare(
      'SELECT hash, last_access, created_at, access_count, file_size FROM cache_meta ORDER BY created_at ASC, hash ASC LIMIT ?',
    )
    this.selectEvictLfuStmt = this.db.prepare(
      'SELECT hash, last_access, created_at, access_count, file_size FROM cache_meta ORDER BY access_count ASC, hash ASC LIMIT ?',
    )
    this.upsertStmt = this.db.prepare(`
      INSERT INTO cache_meta (hash, last_access, created_at, access_count, file_size)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(hash) DO UPDATE SET
        last_access = excluded.last_access,
        created_at = excluded.created_at,
        access_count = excluded.access_count,
        file_size = excluded.file_size
    `)
    this.deleteStmt = this.db.prepare('DELETE FROM cache_meta WHERE hash = ?')
    this.persistTx = this.db.transaction((
      rows: Array<[string, CacheEntry]>,
      deletes: Set<string>,
    ) => {
      for (const [hash, entry] of rows) {
        this.upsertStmt.run(
          hash,
          entry.lastAccess,
          entry.createdAt,
          entry.accessCount,
          entry.fileSize,
        )
      }
      for (const hash of deletes) {
        this.deleteStmt.run(hash)
      }
    })
    this.ready = this.load()
  }

  private createDb(dbPath: string): BetterSqlite3.Database {
    const db = new BetterSqlite3(dbPath)
    db.pragma('journal_mode = WAL')
    db.pragma('synchronous = NORMAL')
    db.pragma('busy_timeout = 5000')
    db.exec(`
      CREATE TABLE IF NOT EXISTS cache_meta (
        hash TEXT PRIMARY KEY,
        last_access INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        access_count INTEGER NOT NULL,
        file_size INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_cache_meta_last_access ON cache_meta (last_access);
      CREATE INDEX IF NOT EXISTS idx_cache_meta_created_at ON cache_meta (created_at);
      CREATE INDEX IF NOT EXISTS idx_cache_meta_access_count ON cache_meta (access_count);
    `)
    return db
  }

  private openDb(): BetterSqlite3.Database {
    try {
      return this.createDb(this.dbPath)
    } catch (err) {
      console.warn('DiskCache: metadata database is unreadable; quarantining and recreating it', err)
      try {
        fs.renameSync(this.dbPath, `${this.dbPath}.corrupt-${Date.now()}`)
      } catch {
        // rename failed (read-only directory or file gone); keep going
      }
      try { fs.unlinkSync(`${this.dbPath}-wal`) } catch { /* no WAL sidecar */ }
      try { fs.unlinkSync(`${this.dbPath}-shm`) } catch { /* no SHM sidecar */ }
      try {
        return this.createDb(this.dbPath)
      } catch (err2) {
        console.warn(
          'DiskCache: cannot persist metadata (read-only directory?); falling back to in-memory metadata',
          err2,
        )
        return this.createDb(':memory:')
      }
    }
  }

  async waitUntilReady(): Promise<void> {
    await this.ready
  }

  onAccess(hash: string, at = Date.now()): void {
    if (!this.loadComplete) {
      const prev = this.preReadySets.get(hash)
      this.preReadySets.set(hash, { ...prev, at, accessed: true })
      return
    }
    const entry = this.meta.entries[hash]
    if (!entry) return
    entry.lastAccess = at
    entry.accessCount++
    this.markDirty(hash)
  }

  onSet(hash: string, fileSize: number, at = Date.now()): void {
    if (!this.loadComplete) {
      const prev = this.preReadySets.get(hash)
      this.preReadySets.set(hash, { fileSize, createdAt: at, at, accessed: prev?.accessed ?? false })
      return
    }
    const old = this.meta.entries[hash]
    if (old) {
      this.totalSize -= old.fileSize
    } else {
      this.fileCount++
    }
    this.meta.entries[hash] = {
      lastAccess: at,
      createdAt: at,
      accessCount: 1,
      fileSize,
    }
    this.totalSize += fileSize
    this.markDirty(hash)
  }

  private entryVal(entry: CacheEntry): number {
    switch (this.policy) {
      case EvictionPolicy.FIFO:
        return entry.createdAt
      case EvictionPolicy.LFU:
        return entry.accessCount
      case EvictionPolicy.LRU:
      default:
        return entry.lastAccess
    }
  }

  async evictIfNeeded(): Promise<void> {
    const queued = this.evictionQueue.then(() => this.performEviction())
    this.evictionQueue = queued.catch(() => undefined)
    await queued
  }

  /**
   * Flush pending metadata changes to disk immediately. Awaiting this
   * guarantees a later manager constructed on the same directory observes
   * all mutations made so far.
   */
  async flush(): Promise<void> {
    this.clearPersistTimer()
    await this.queuePersist()
  }

  private async performEviction(): Promise<void> {
    // Flush whatever is in flight first: the SQLite rows must reflect the
    // latest in-memory values before the index window can rank them, because
    // queuePersist clears the dirty set the moment it enqueues (not when the
    // write lands). New mutations made while awaiting are merged separately
    // by selectEvictionBatch.
    await this.persistQueue
    let evicted = 0
    let limit = MIN_EVICTION_BATCH
    while (this.totalSize > this.maxSizeBytes && this.fileCount > 0) {
      const avgSize = this.totalSize / this.fileCount
      const needed = this.totalSize - this.maxSizeBytes
      const byEstimate = Math.ceil(needed / avgSize) + 1
      limit = Math.min(
        this.fileCount,
        Math.max(limit * 2, MIN_EVICTION_BATCH, byEstimate),
      )

      const candidates = this.selectEvictionBatch(limit)
      const toRemove: string[] = []
      for (const candidate of candidates) {
        if (this.totalSize <= this.maxSizeBytes) break
        const entry = this.meta.entries[candidate.hash]
        if (!entry) continue
        this.totalSize -= entry.fileSize
        delete this.meta.entries[candidate.hash]
        this.pendingDeletes.add(candidate.hash)
        this.fileCount--
        evicted++
        toRemove.push(candidate.hash)
      }
      if (toRemove.length === 0) break
      // Delete files concurrently so evicting tens of thousands of entries is
      // bound by I/O throughput rather than serialized syscalls. Memory and
      // metadata are already consistent, so in-flight unlinks never block a
      // subsequent pass. A hash that was onSet again after eviction (e.g. the
      // file was rewritten while the unlink was queued) is present in memory
      // again and must not have its fresh file deleted.
      const unlinkConcurrency = 32
      for (let i = 0; i < toRemove.length; i += unlinkConcurrency) {
        await Promise.all(
          toRemove
            .slice(i, i + unlinkConcurrency)
            .filter((hash) => this.meta.entries[hash] === undefined)
            .map((hash) =>
              fsp.unlink(path.join(this.cacheDir, `${hash}.jpg`)).catch(() => undefined),
            ),
        )
      }
    }

    if (evicted > 0) {
      await this.queuePersist()
    }
  }

  private evictRowsForPolicy(): BetterSqlite3.Statement<[number], DbRow> {
    switch (this.policy) {
      case EvictionPolicy.FIFO:
        return this.selectEvictFifoStmt
      case EvictionPolicy.LFU:
        return this.selectEvictLfuStmt
      case EvictionPolicy.LRU:
      default:
        return this.selectEvictLruStmt
    }
  }

  /**
   * Retain the `limit` smallest policy values without scanning the whole
   * in-memory map. Persisted rows whose value equals the live one are ranked
   * by the SQLite index; rows whose value can differ from the persisted row
   * are exactly the dirty set (every mutation goes through markDirty). The
   * window is sized `limit + |dirty|` so that dirty rows that fall inside the
   * index window (persisted value small, live value large) cannot crowd out
   * better clean rows that sit just outside it; merging the dirty entries and
   * re-sorting on live values then yields the same `limit` best candidates as
   * a full scan. The result is sorted ascending by val (hash tiebreak) so the
   * caller removes the most urgent entries first.
   */
  private selectEvictionBatch(limit: number): EvictionCandidate[] {
    const windowSize = limit + this.dirty.size
    const rows = this.evictRowsForPolicy().all(windowSize) as DbRow[]
    const candidates: EvictionCandidate[] = []
    const seen = new Set<string>()
    for (const row of rows) {
      // The row may be stale: evicted in memory but not yet persisted, or
      // superseded by an update that is still dirty. The live entry is
      // authoritative; a missing one is skipped.
      const live = this.meta.entries[row.hash]
      if (!live) continue
      seen.add(row.hash)
      candidates.push({ hash: row.hash, val: this.entryVal(live), size: live.fileSize })
    }
    // Un-flushed rows are not in SQLite yet (fresh writes, or a burst of
    // accesses within the debounce window); merge them so a cache that has
    // never persisted anything cannot fail to evict.
    for (const hash of this.dirty) {
      if (seen.has(hash)) continue
      const entry = this.meta.entries[hash]
      if (!entry) continue
      seen.add(hash)
      candidates.push({ hash, val: this.entryVal(entry), size: entry.fileSize })
    }
    candidates.sort((a, b) => {
      if (a.val !== b.val) return a.val - b.val
      return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0
    })
    return candidates.slice(0, limit)
  }

  getStats(): { totalSize: number; fileCount: number; maxSize: number; policy: string } {
    return {
      totalSize: this.totalSize,
      fileCount: this.fileCount,
      maxSize: this.maxSizeBytes,
      policy: this.policy,
    }
  }

  getMetadata(): CacheMetadata {
    return this.meta
  }

  private markDirty(hash: string): void {
    this.pendingDeletes.delete(hash)
    this.dirty.add(hash)
    if (this.dirty.size >= PERSIST_FLUSH_THRESHOLD) {
      this.clearPersistTimer()
      void this.queuePersist()
    } else if (this.persistTimer === null) {
      this.persistTimer = setTimeout(() => {
        this.persistTimer = null
        void this.queuePersist()
      }, PERSIST_DEBOUNCE_MS)
    }
  }

  private clearPersistTimer(): void {
    if (this.persistTimer !== null) {
      clearTimeout(this.persistTimer)
      this.persistTimer = null
    }
  }

  private queuePersist(): Promise<void> {
    this.clearPersistTimer()
    const dirty = this.dirty
    const deletes = this.pendingDeletes
    this.dirty = new Set()
    this.pendingDeletes = new Set()

    const rows: Array<[string, CacheEntry]> = []
    for (const hash of dirty) {
      const entry = this.meta.entries[hash]
      if (entry) rows.push([hash, entry])
    }
    if (rows.length === 0 && deletes.size === 0) {
      return Promise.resolve()
    }

    this.persistQueue = this.persistQueue
      .then(() => {
        this.persistTx(rows, deletes)
      })
      .catch((e) => {
        console.warn('DiskCache: metadata write failed', e)
      })
    return this.persistQueue
  }

  private async load(): Promise<void> {
    this.totalSize = 0
    this.fileCount = 0
    this.meta = { entries: {} }

    // Legacy JSON metadata is no longer maintained; remove it so it does not
    // accumulate in the cache directory. The directory scan below rebuilds
    // any missing entries from file stats.
    for (const legacyPath of [this.metaJsonPath, `${this.metaJsonPath}.tmp`]) {
      try {
        await fsp.unlink(legacyPath)
      } catch {
        // legacy file already gone
      }
    }

    // Read rows in bounded chunks and yield between chunks so loading a
    // 100k-entry cache never blocks the main thread for a single 50ms+ slice.
    // ORDER BY hash keeps chunk boundaries stable under concurrent writers so
    // no row is skipped or read twice. Sizes are accumulated here, so the
    // reconciliation below only has to stat files that are NOT in the DB.
    // A read failure (corrupt DB, locked file) degrades to an empty map; the
    // directory scan below reconciles what is actually on disk.
    try {
      let offset = 0
      while (true) {
        const rows = this.selectChunkStmt.all(LOAD_ROW_CHUNK, offset)
        for (const row of rows) {
          this.meta.entries[row.hash] = {
            lastAccess: row.last_access,
            createdAt: row.created_at,
            accessCount: row.access_count,
            fileSize: row.file_size,
          }
          this.fileCount++
          this.totalSize += row.file_size
        }
        if (rows.length < LOAD_ROW_CHUNK) break
        offset += LOAD_ROW_CHUNK
        await new Promise(resolve => setImmediate(resolve))
      }
    } catch (e) {
      console.warn('DiskCache: failed to read metadata database; rebuilding from directory scan', e)
      this.meta = { entries: {} }
      this.totalSize = 0
      this.fileCount = 0
    }

    // Reconcile with the filesystem without stat-ing every file:
    //  - DB rows with no backing file are dangling (evicted or manually
    //    removed while stopped); drop them straight from the readdir listing.
    //  - Files with no DB row are leftovers from a partial run or a crash;
    //    only those need a stat for size/timestamps.
    //  - Files present in both are application-generated copies that cannot
    //    change size externally, so the DB row is trusted as-is.
    try {
      const files = await fsp.readdir(this.cacheDir)
      const diskHashes = new Set<string>()
      for (const file of files) {
        if (file.endsWith('.jpg')) diskHashes.add(file.slice(0, -4))
      }
      for (const hash of Object.keys(this.meta.entries)) {
        if (diskHashes.has(hash)) continue
        const entry = this.meta.entries[hash]
        delete this.meta.entries[hash]
        this.pendingDeletes.add(hash)
        this.fileCount--
        this.totalSize -= entry.fileSize
      }
      const orphanHashes = [...diskHashes].filter(hash => !this.meta.entries[hash])
      const concurrency = 24
      let cursor = 0
      const scanNext = async (): Promise<void> => {
        while (cursor < orphanHashes.length) {
          const hash = orphanHashes[cursor++]
          const filePath = path.join(this.cacheDir, `${hash}.jpg`)
          try {
            const stat = await fsp.stat(filePath)
            this.meta.entries[hash] = {
              lastAccess: stat.atimeMs,
              createdAt: stat.birthtimeMs || stat.mtimeMs,
              accessCount: 0,
              fileSize: stat.size,
            }
            this.fileCount++
            this.totalSize += stat.size
            this.dirty.add(hash)
          } catch (e) {
            console.warn('DiskCache: failed to stat cached file', filePath, e)
          }
        }
      }
      await Promise.all(
        Array.from({ length: Math.min(concurrency, orphanHashes.length) }, () => scanNext()),
      )
    } catch (e) {
      console.warn('DiskCache: failed to read cache directory', e)
    }

    // Replay updates that arrived while load was still running so they win
    // over the stale rows read above (onSet/onAccess before load only record
    // into preReadySets and never touched the counters).
    this.loadComplete = true
    for (const [hash, update] of this.preReadySets) {
      if (update.fileSize !== undefined && update.createdAt !== undefined) {
        this.onSet(hash, update.fileSize, update.createdAt)
      }
      if (update.accessed && update.at !== undefined) {
        this.onAccess(hash, update.at)
      }
    }
    this.preReadySets.clear()

    await this.queuePersist()
  }
}
