import { afterEach, describe, expect, it } from 'vitest'
import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import BetterSqlite3 from 'better-sqlite3'
import {
  DiskCacheManager,
  EvictionPolicy,
  type CacheEntry,
  type CacheMetadata,
} from '../../../../desktop/src/main/services/image/disk-cache'

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true })
})

// Deterministic PRNG (mulberry32) so the random-value eviction probe is
// reproducible across runs and CI machines.
function mulberry32(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function policyValue(policy: EvictionPolicy, entry: CacheEntry): number {
  if (policy === EvictionPolicy.FIFO) return entry.createdAt
  if (policy === EvictionPolicy.LFU) return entry.accessCount
  return entry.lastAccess
}

// Reference implementation: the batch must be the `limit` entries with the
// smallest policy values, ties broken by hash, ascending.
function referenceEvictionBatch(
  metadata: CacheMetadata,
  policy: EvictionPolicy,
  limit: number,
): string[] {
  return Object.entries(metadata.entries)
    .sort(([ha, a], [hb, b]) => {
      const va = policyValue(policy, a)
      const vb = policyValue(policy, b)
      if (va !== vb) return va - vb
      return ha < hb ? -1 : ha > hb ? 1 : 0
    })
    .slice(0, limit)
    .map(([hash]) => hash)
}

function createManager(maxSizeBytes: number, policy = EvictionPolicy.LRU): { dir: string; manager: DiskCacheManager } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-disk-cache-'))
  dirs.push(dir)
  const manager = new DiskCacheManager(dir, maxSizeBytes, policy)
  return { dir, manager }
}

async function writeEntry(dir: string, manager: DiskCacheManager, hash: string, size: number): Promise<void> {
  fs.writeFileSync(path.join(dir, `${hash}.jpg`), Buffer.alloc(size))
  manager.onSet(hash, size)
}

describe('DiskCacheManager stats and metadata', () => {
  it('tracks total size and file count across onSet and onAccess', async () => {
    const { dir, manager } = createManager(1024 * 1024)
    await manager.waitUntilReady()

    await writeEntry(dir, manager, 'aaaa', 10)
    await writeEntry(dir, manager, 'bbbb', 20)
    await writeEntry(dir, manager, 'cccc', 30)

    expect(manager.getStats().totalSize).toBe(60)
    expect(manager.getStats().fileCount).toBe(3)

    manager.onAccess('aaaa')
    manager.onAccess('aaaa')
    const entry = manager.getMetadata().entries['aaaa']
    expect(entry.accessCount).toBe(3)
    expect(manager.getStats().totalSize).toBe(60)
    expect(manager.getStats().fileCount).toBe(3)

    manager.onSet('aaaa', 5)
    expect(manager.getStats().totalSize).toBe(55)
    expect(manager.getMetadata().entries['aaaa'].fileSize).toBe(5)
    await manager.flush()
  })

  it('evicts down to the configured budget', async () => {
    const { dir, manager } = createManager(25)
    await manager.waitUntilReady()

    for (const [hash, size] of [['aaaa', 10], ['bbbb', 10], ['cccc', 10]] as const) {
      await writeEntry(dir, manager, hash, size)
    }

    await manager.evictIfNeeded()

    expect(manager.getStats().totalSize).toBeLessThanOrEqual(25)
    expect(manager.getStats().fileCount).toBe(2)
  })

  it('serializes concurrent eviction requests and preserves size accounting', async () => {
    const { dir, manager } = createManager(15)
    await manager.waitUntilReady()

    for (const hash of ['one', 'two', 'three']) {
      await writeEntry(dir, manager, hash, 10)
    }
    await Promise.all([
      manager.evictIfNeeded(),
      manager.evictIfNeeded(),
      manager.evictIfNeeded(),
    ])

    expect(manager.getStats().totalSize).toBeLessThanOrEqual(15)
    expect(manager.getStats().fileCount).toBe(1)
  })

  it('evicts the oldest entries first under FIFO policy', async () => {
    const { dir, manager } = createManager(25, EvictionPolicy.FIFO)
    await manager.waitUntilReady()

    // Deliberately different createdAt values (LFU/LRU would tie on the same
    // millisecond, making the assertion order-dependent).
    for (const [hash, size, delayMs] of [['aaaa', 10, 0], ['bbbb', 10, 2], ['cccc', 10, 4]] as const) {
      await new Promise(resolve => setTimeout(resolve, delayMs))
      await writeEntry(dir, manager, hash, size)
    }

    await manager.evictIfNeeded()

    expect(manager.getStats().fileCount).toBe(2)
    expect(manager.getMetadata().entries['aaaa']).toBeUndefined()
    expect(manager.getMetadata().entries['bbbb']).toBeDefined()
    expect(manager.getMetadata().entries['cccc']).toBeDefined()
  })

  it('evicts exactly the smallest policy values when values are random (deterministic probe)', async () => {
    // Regression probe for the bounded-heap selection: with more entries than
    // the first eviction batch limit (>= 200), the replacement branch fires
    // and previously retained the wrong entries under random values. A fixed
    // seed makes the probe fully deterministic.
    const n = 401
    const size = 10
    const policies = [EvictionPolicy.LRU, EvictionPolicy.FIFO, EvictionPolicy.LFU]
    const limits = [50, 100, 200]
    const hashes = Array.from({ length: n }, (_, i) => `h${String(i).padStart(3, '0')}`)

    let combo = 0
    for (const policy of policies) {
      for (const limit of limits) {
        combo++
        const { dir, manager } = createManager((n - limit) * size, policy)
        await manager.waitUntilReady()

        for (const hash of hashes) {
          await writeEntry(dir, manager, hash, size)
        }

        // Randomize the policy values through the public API so the updates
        // are tracked as dirty (un-flushed) exactly like real mutations, and
        // the eviction window sees them. accessCount has no direct setter:
        // repeated onAccess calls approximate distinct values within a small
        // domain, which exercises tie-breaking as well.
        const rng = mulberry32(0x9e3779b9 + combo)
        for (const hash of hashes) {
          const val = Math.floor(rng() * 1_000_001)
          if (policy === EvictionPolicy.LFU) {
            const count = 1 + (val % 63)
            for (let k = 0; k < count; k++) manager.onAccess(hash)
          } else if (policy === EvictionPolicy.FIFO) {
            manager.onSet(hash, 10, val)
          } else {
            manager.onAccess(hash, val)
          }
        }

        const evicted = new Set(referenceEvictionBatch(manager.getMetadata(), policy, limit))

        await manager.evictIfNeeded()

        const remaining = Object.keys(manager.getMetadata().entries).sort()
        expect(manager.getStats().fileCount).toBe(n - limit)
        expect(manager.getStats().totalSize).toBe((n - limit) * size)
        expect(remaining).toEqual(hashes.filter(hash => !evicted.has(hash)))
      }
    }
  })

  it('evicts the smallest lastAccess values under LRU regardless of set order', async () => {
    const { dir, manager } = createManager(30, EvictionPolicy.LRU)
    await manager.waitUntilReady()

    for (const hash of ['aaaa', 'bbbb', 'cccc', 'dddd', 'eeee']) {
      await writeEntry(dir, manager, hash, 10)
    }
    for (const [hash, at] of [['aaaa', 500], ['bbbb', 100], ['cccc', 400], ['dddd', 200], ['eeee', 300]] as const) {
      manager.onAccess(hash, at)
    }

    await manager.evictIfNeeded()

    expect(manager.getStats().fileCount).toBe(3)
    expect(Object.keys(manager.getMetadata().entries).sort()).toEqual(['aaaa', 'cccc', 'eeee'])
  })
})

describe('DiskCacheManager persistence', () => {
  it('restores onSet metadata (lastAccess, fileSize, accessCount) after restart', async () => {
    const { dir, manager } = createManager(1024)
    await manager.waitUntilReady()

    const before = Date.now()
    await writeEntry(dir, manager, 'aaaa', 12)
    manager.onAccess('aaaa')
    await manager.flush()

    const restarted = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
    dirs.push(dir)
    await restarted.waitUntilReady()

    const restored = restarted.getMetadata().entries['aaaa']
    expect(restored).toBeDefined()
    expect(restored?.fileSize).toBe(12)
    expect(restored?.accessCount).toBe(2)
    expect(restored?.lastAccess).toBeGreaterThanOrEqual(before)
    expect(restarted.getStats().totalSize).toBe(12)
    expect(restarted.getStats().fileCount).toBe(1)
  })

  it('restores eviction results after restart', async () => {
    const { dir, manager } = createManager(25)
    await manager.waitUntilReady()

    for (const [hash, size] of [['aaaa', 10], ['bbbb', 10], ['cccc', 10]] as const) {
      await writeEntry(dir, manager, hash, size)
    }
    await manager.evictIfNeeded()
    expect(manager.getStats().fileCount).toBe(2)

    const restarted = new DiskCacheManager(dir, 25, EvictionPolicy.LRU)
    await restarted.waitUntilReady()

    expect(restarted.getStats().fileCount).toBe(2)
    expect(restarted.getStats().totalSize).toBe(20)
    expect(fs.readdirSync(dir).filter(file => file.endsWith('.jpg'))).toHaveLength(2)
  })

  it('reconciles metadata with the filesystem on startup and removes the legacy json file', async () => {
    const { dir, manager } = createManager(1024)
    await manager.waitUntilReady()

    // Seed metadata for a file we will delete while stopped, then simulate a
    // leftover from the pre-SQLite format plus a file added while stopped.
    await writeEntry(dir, manager, 'aaaa', 8)
    await manager.flush()
    fs.writeFileSync(path.join(dir, 'cache-meta.json'), JSON.stringify({ entries: {} }))
    fs.writeFileSync(path.join(dir, 'orphan.jpg'), Buffer.alloc(8))
    fs.rmSync(path.join(dir, 'aaaa.jpg'))

    const restarted = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
    await restarted.waitUntilReady()

    expect(fs.existsSync(path.join(dir, 'cache-meta.json'))).toBe(false)
    expect(restarted.getMetadata().entries['aaaa']).toBeUndefined()
    expect(restarted.getMetadata().entries['orphan']).toBeDefined()
    expect(restarted.getMetadata().entries['orphan'].fileSize).toBe(8)
    expect(restarted.getStats().fileCount).toBe(1)
    expect(restarted.getStats().totalSize).toBe(8)
    await restarted.flush()

    const third = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
    await third.waitUntilReady()
    expect(third.getStats().fileCount).toBe(1)
    expect(third.getMetadata().entries['orphan']).toBeDefined()
  })
})

describe('DiskCacheManager corruption resilience', () => {
  it('quarantines a corrupt metadata DB and rebuilds an empty one that persists', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-disk-cache-'))
    dirs.push(dir)
    fs.writeFileSync(path.join(dir, 'cache-meta.db'), Buffer.alloc(4096, 0x42))

    const manager = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
    await manager.waitUntilReady()

    expect(manager.getStats().totalSize).toBe(0)
    expect(manager.getStats().fileCount).toBe(0)
    const quarantined = fs.readdirSync(dir).filter(file => file.startsWith('cache-meta.db.corrupt-'))
    expect(quarantined).toHaveLength(1)

    await writeEntry(dir, manager, 'aaaa', 12)
    await manager.flush()

    const restarted = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
    await restarted.waitUntilReady()
    expect(restarted.getMetadata().entries['aaaa']?.fileSize).toBe(12)
    expect(restarted.getStats().totalSize).toBe(12)
  })

  it('degrades to in-memory metadata when the DB cannot be recreated (read-only dir)', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-disk-cache-'))
    dirs.push(dir)
    const dbPath = path.join(dir, 'cache-meta.db')
    fs.writeFileSync(dbPath, Buffer.alloc(4096, 0x42))
    fs.chmodSync(dbPath, 0o400)
    fs.chmodSync(dir, 0o500)
    try {
      const manager = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
      manager.onSet('aaaa', 12, 1000)
      await manager.waitUntilReady()

      expect(manager.getStats()).toEqual(expect.objectContaining({ totalSize: 12, fileCount: 1 }))
      expect(manager.getMetadata().entries['aaaa']).toEqual({
        lastAccess: 1000,
        createdAt: 1000,
        accessCount: 1,
        fileSize: 12,
      })
      await manager.flush()
      expect(fs.existsSync(dbPath)).toBe(true)
      expect(fs.readdirSync(dir).some(file => file.startsWith('cache-meta.db.corrupt-'))).toBe(false)
    } finally {
      fs.chmodSync(dir, 0o700)
      fs.chmodSync(dbPath, 0o600)
    }
  })

  it('degrades to in-memory metadata when a healthy DB sits in a read-only directory', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-disk-cache-'))
    dirs.push(dir)
    const dbPath = path.join(dir, 'cache-meta.db')
    fs.writeFileSync(dbPath, Buffer.alloc(0))
    fs.chmodSync(dir, 0o500)
    try {
      const manager = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
      await manager.waitUntilReady()
      expect(manager.getStats()).toEqual(expect.objectContaining({ totalSize: 0, fileCount: 0 }))
      manager.onSet('bbbb', 5)
      await manager.flush()
      expect(manager.getStats().totalSize).toBe(5)
      expect(fs.readdirSync(dir).some(file => file.startsWith('cache-meta.db.corrupt-'))).toBe(false)
    } finally {
      fs.chmodSync(dir, 0o700)
    }
  })
})

describe('DiskCacheManager load concurrency', () => {
  it('does not lose onSet/onAccess updates that arrive while load is streaming rows', async () => {
    const { dir, manager } = createManager(1024 * 1024)
    await manager.waitUntilReady()

    const seedCount = 10001
    for (let i = 0; i < seedCount; i++) {
      manager.onSet(`s${String(i).padStart(5, '0')}`, 10)
    }
    await manager.flush()

    const restarted = new DiskCacheManager(dir, 1024 * 1024, EvictionPolicy.LRU)
    fs.writeFileSync(path.join(dir, 'zzzz.jpg'), Buffer.alloc(77))
    restarted.onSet('zzzz', 77, 1000)
    restarted.onAccess('zzzz', 5000)
    await restarted.waitUntilReady()

    expect(restarted.getMetadata().entries['zzzz']).toEqual({
      lastAccess: 5000,
      createdAt: 1000,
      accessCount: 2,
      fileSize: 77,
    })
    expect(restarted.getStats()).toEqual(expect.objectContaining({ totalSize: 77, fileCount: 1 }))
    expect(restarted.getMetadata().entries['s00000']).toBeUndefined()

    await restarted.flush()
    const third = new DiskCacheManager(dir, 1024 * 1024, EvictionPolicy.LRU)
    await third.waitUntilReady()
    expect(third.getMetadata().entries['zzzz']?.accessCount).toBe(2)
    expect(third.getMetadata().entries['zzzz']?.fileSize).toBe(77)
  })
})

describe('DiskCacheManager eviction re-set race', () => {
  it('keeps a hash that was onSet again while its unlink was queued', async () => {
    const { dir, manager } = createManager(100, EvictionPolicy.FIFO)
    await manager.waitUntilReady()

    const hashes: string[] = []
    for (let i = 0; i < 60; i++) {
      const hash = `h${String(i).padStart(2, '0')}`
      hashes.push(hash)
      fs.writeFileSync(path.join(dir, `${hash}.jpg`), Buffer.alloc(10))
      manager.onSet(hash, 10)
      if (i < 59) await new Promise(resolve => setTimeout(resolve, 2))
    }

    const evicting = manager.evictIfNeeded()
    manager.onSet('h40', 10)
    await evicting

    expect(manager.getMetadata().entries['h40']).toBeDefined()
    expect(manager.getMetadata().entries['h40']?.fileSize).toBe(10)
    expect(fs.existsSync(path.join(dir, 'h40.jpg'))).toBe(true)
    expect(fs.existsSync(path.join(dir, 'h05.jpg'))).toBe(false)
    expect(manager.getStats().totalSize).toBe(100)
    expect(manager.getStats().fileCount).toBe(10)

    await manager.flush()
    const db = new BetterSqlite3(path.join(dir, 'cache-meta.db'))
    try {
      const row = db.prepare('SELECT file_size, access_count FROM cache_meta WHERE hash = ?').get('h40')
      expect(row).toEqual({ file_size: 10, access_count: 1 })
    } finally {
      db.close()
    }

    const restarted = new DiskCacheManager(dir, 1024, EvictionPolicy.LRU)
    await restarted.waitUntilReady()
    expect(restarted.getMetadata().entries['h40']?.fileSize).toBe(10)
    expect(restarted.getMetadata().entries['h40']?.accessCount).toBe(1)
    expect(fs.existsSync(path.join(dir, 'h40.jpg'))).toBe(true)
  })
})
