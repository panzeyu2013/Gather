import * as fs from 'fs'
import * as fsp from 'fs/promises'
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
  private accessesSincePersist = 0
  private readonly ready: Promise<void>
  private persistQueue: Promise<void> = Promise.resolve()
  private evictionQueue: Promise<void> = Promise.resolve()

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
    this.ready = this.load()
  }

  async waitUntilReady(): Promise<void> {
    await this.ready
  }

  onAccess(hash: string): void {
    const entry = this.meta.entries[hash]
    if (!entry) return
    entry.lastAccess = Date.now()
    entry.accessCount++
    this.accessesSincePersist++
    if (this.accessesSincePersist >= 32) {
      this.accessesSincePersist = 0
      void this.queuePersist()
    }
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

  async evictIfNeeded(): Promise<void> {
    const queued = this.evictionQueue.then(() => this.performEviction())
    this.evictionQueue = queued.catch(() => undefined)
    await queued
  }

  private async performEviction(): Promise<void> {
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
        if (this.totalSize <= this.maxSizeBytes) break
        const entry = this.meta.entries[hash]
        if (!entry) continue
        const filePath = path.join(this.cacheDir, `${hash}.jpg`)
        try {
          await fsp.unlink(filePath)
        } catch {
          // file may already be gone
        }
        this.totalSize -= entry.fileSize
        delete this.meta.entries[hash]
        evicted++
      }
    }

    if (evicted > 0) {
      await this.queuePersist()
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

  private queuePersist(): Promise<void> {
    const snapshot = JSON.stringify(this.meta)
    this.persistQueue = this.persistQueue
      .then(async () => {
        await fsp.writeFile(this.metaTmpPath, snapshot, 'utf-8')
        await fsp.rename(this.metaTmpPath, this.metaPath)
      })
      .catch((e) => {
        console.warn('DiskCache: metadata write failed', e)
      })
    return this.persistQueue
  }

  private async load(): Promise<void> {
    this.totalSize = 0
    this.meta = { entries: {} }

    try {
      const raw = await fsp.readFile(this.metaPath, 'utf-8')
      this.meta = JSON.parse(raw)
    } catch {
      this.meta = { entries: {} }
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
      }
    }

    await this.queuePersist()
  }
}
