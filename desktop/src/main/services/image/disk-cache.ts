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
// Lazy eviction: candidates are selected with a single O(n log k) scan
// (bounded max-heap) only when the cache is over budget, instead of sorting
// every entry on every batch of 10. The batch size doubles between passes so
// pathological size distributions stay bounded by O(log n) passes.
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
      )
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

  // Retains the `limit` best (smallest policy value) candidates in a bounded
  // max-heap-by-worst: every parent is worse than (or tied with) its children,
  // so the root is the worst candidate kept. A candidate better than the root
  // replaces it and is sifted down to restore the invariant, so the retained
  // set is always the k smallest values. The result is sorted ascending by val
  // (hash tiebreak) so the caller removes the most urgent entries first.
  private selectEvictionBatch(limit: number): EvictionCandidate[] {
    const heap: EvictionCandidate[] = []
    for (const hash of Object.keys(this.meta.entries)) {
      const entry = this.meta.entries[hash]
      const candidate: EvictionCandidate = {
        hash,
        val: this.entryVal(entry),
        size: entry.fileSize,
      }
      if (heap.length < limit) {
        heap.push(candidate)
        this.heapSiftUp(heap, heap.length - 1)
      } else if (this.isWorseCandidate(heap[0], candidate)) {
        heap[0] = candidate
        this.heapSiftDown(heap, 0)
      }
    }
    heap.sort((a, b) => {
      if (a.val !== b.val) return a.val - b.val
      return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0
    })
    return heap
  }

  private isWorseCandidate(a: EvictionCandidate, b: EvictionCandidate): boolean {
    if (a.val !== b.val) return a.val > b.val
    return a.hash > b.hash
  }

  private heapSiftUp(heap: EvictionCandidate[], index: number): void {
    while (index > 0) {
      const parent = (index - 1) >> 1
      // Max-heap-by-worst: while the child is worse than its parent, swap so
      // the worse element floats toward the root.
      if (!this.isWorseCandidate(heap[index], heap[parent])) break
      const tmp = heap[parent]
      heap[parent] = heap[index]
      heap[index] = tmp
      index = parent
    }
  }

  // Max-heap-by-worst sift-down: promote the worse child while it is worse
  // than the parent, keeping the root as the worst retained candidate.
  private heapSiftDown(heap: EvictionCandidate[], index: number): void {
    const n = heap.length
    while (true) {
      const left = index * 2 + 1
      if (left >= n) break
      const right = left + 1
      let worst = left
      if (right < n && this.isWorseCandidate(heap[right], heap[left])) {
        worst = right
      }
      if (!this.isWorseCandidate(heap[worst], heap[index])) break
      const tmp = heap[worst]
      heap[worst] = heap[index]
      heap[index] = tmp
      index = worst
    }
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
    // no row is skipped or read twice. A read failure (corrupt DB, locked
    // file) degrades to an empty map; the directory scan below reconciles
    // what is actually on disk.
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

    const seen = new Set<string>()
    try {
      const files = await fsp.readdir(this.cacheDir)
      const jpgFiles = files.filter(file => file.endsWith('.jpg'))
      const concurrency = 24
      let cursor = 0
      const scanNext = async (): Promise<void> => {
        while (cursor < jpgFiles.length) {
          const file = jpgFiles[cursor++]
          const hash = file.slice(0, -4)
          seen.add(hash)
          const filePath = path.join(this.cacheDir, file)
          try {
            const stat = await fsp.stat(filePath)
            const existing = this.meta.entries[hash]
            if (existing) {
              if (existing.fileSize !== stat.size) {
                existing.fileSize = stat.size
                this.dirty.add(hash)
              }
            } else {
              this.meta.entries[hash] = {
                lastAccess: stat.atimeMs,
                createdAt: stat.birthtimeMs || stat.mtimeMs,
                accessCount: 0,
                fileSize: stat.size,
              }
              this.fileCount++
              this.dirty.add(hash)
            }
            this.totalSize += stat.size
          } catch (e) {
            console.warn('DiskCache: failed to stat cached file', file, e)
          }
        }
      }
      await Promise.all(
        Array.from({ length: Math.min(concurrency, jpgFiles.length) }, () => scanNext()),
      )
    } catch (e) {
      console.warn('DiskCache: failed to read cache directory', e)
    }

    for (const hash of Object.keys(this.meta.entries)) {
      if (!seen.has(hash)) {
        delete this.meta.entries[hash]
        this.pendingDeletes.add(hash)
        this.fileCount--
      }
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
