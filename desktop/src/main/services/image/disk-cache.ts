import * as fs from 'fs'
import * as path from 'path'

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

export class DiskCacheManager {
  private meta: CacheMetadata = { entries: {} }
  private totalSize = 0
  private metaPath: string
  private metaTmpPath: string

  constructor(
    private cacheDir: string,
    private maxSizeBytes: number,
    private policy: EvictionPolicy,
  ) {
    this.metaPath = path.join(cacheDir, 'cache-meta.json')
    this.metaTmpPath = path.join(cacheDir, 'cache-meta.json.tmp')
    if (!fs.existsSync(cacheDir)) {
      fs.mkdirSync(cacheDir, { recursive: true })
    }
    this.load()
  }

  onAccess(hash: string): void {
    const entry = this.meta.entries[hash]
    if (!entry) return
    entry.lastAccess = Date.now()
    entry.accessCount++
  }

  onSet(hash: string, fileSize: number): void {
    const old = this.meta.entries[hash]
    if (old) {
      this.totalSize -= old.fileSize
    }
    const now = Date.now()
    this.meta.entries[hash] = {
      lastAccess: now,
      createdAt: now,
      accessCount: 1,
      fileSize,
    }
    this.totalSize += fileSize
  }

  private entryVal(entry: CacheEntry): number {
    switch (this.policy) {
      case EvictionPolicy.LRU:
        return entry.lastAccess
      case EvictionPolicy.FIFO:
        return entry.createdAt
      case EvictionPolicy.LFU:
        return entry.accessCount
      default:
        return entry.lastAccess
    }
  }

  evictIfNeeded(): void {
    let evicted = 0
    while (this.totalSize > this.maxSizeBytes) {
      const candidates: Array<{ hash: string; val: number }> = []
      for (const [hash, entry] of Object.entries(this.meta.entries)) {
        candidates.push({ hash, val: this.entryVal(entry) })
      }

      candidates.sort((a, b) => a.val - b.val)

      const batch = candidates.slice(0, 10)
      if (batch.length === 0) break

      for (const { hash } of batch) {
        const entry = this.meta.entries[hash]
        if (!entry) continue
        const filePath = path.join(this.cacheDir, `${hash}.jpg`)
        try {
          fs.unlinkSync(filePath)
        } catch {
          // file may already be gone
        }
        this.totalSize -= entry.fileSize
        delete this.meta.entries[hash]
        evicted++
      }
    }

    if (evicted > 0) {
      this.persist()
    }
  }

  getStats(): { totalSize: number; fileCount: number; maxSize: number; policy: string } {
    return {
      totalSize: this.totalSize,
      fileCount: Object.keys(this.meta.entries).length,
      maxSize: this.maxSizeBytes,
      policy: this.policy,
    }
  }

  getMetadata(): CacheMetadata {
    return this.meta
  }

  persist(): void {
    try {
      const data = JSON.stringify(this.meta)
      fs.writeFileSync(this.metaTmpPath, data, 'utf-8')
      fs.renameSync(this.metaTmpPath, this.metaPath)
    } catch {
      // metadata write failed — carry on
    }
  }

  load(): void {
    this.totalSize = 0
    this.meta = { entries: {} }

    if (fs.existsSync(this.metaPath)) {
      try {
        const raw = fs.readFileSync(this.metaPath, 'utf-8')
        this.meta = JSON.parse(raw)
      } catch {
        this.meta = { entries: {} }
      }
    }

    const seen = new Set<string>()
    try {
      const files = fs.readdirSync(this.cacheDir)
      for (const file of files) {
        if (!file.endsWith('.jpg')) continue
        const hash = file.slice(0, -4)
        seen.add(hash)
        const filePath = path.join(this.cacheDir, file)
        try {
          const stat = fs.statSync(filePath)
          if (this.meta.entries[hash]) {
            this.meta.entries[hash].fileSize = stat.size
            this.totalSize += stat.size
          } else {
            this.meta.entries[hash] = {
              lastAccess: stat.atimeMs,
              createdAt: stat.birthtimeMs || stat.mtimeMs,
              accessCount: 0,
              fileSize: stat.size,
            }
            this.totalSize += stat.size
          }
        } catch {
          // can't stat, skip
        }
      }
    } catch {
      // can't read dir, skip
    }

    for (const hash of Object.keys(this.meta.entries)) {
      if (!seen.has(hash)) {
        delete this.meta.entries[hash]
      }
    }

    this.persist()
  }
}
