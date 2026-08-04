import { afterEach, describe, expect, it } from 'vitest'
import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import { DiskCacheManager, EvictionPolicy } from '../../../../desktop/src/main/services/image/disk-cache'

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true })
})

describe('DiskCacheManager concurrency', () => {
  it('serializes concurrent eviction requests and preserves size accounting', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-disk-cache-'))
    dirs.push(dir)
    const manager = new DiskCacheManager(dir, 15, EvictionPolicy.LRU)
    await manager.waitUntilReady()

    for (const hash of ['one', 'two', 'three']) {
      fs.writeFileSync(path.join(dir, `${hash}.jpg`), Buffer.alloc(10))
      manager.onSet(hash, 10)
    }
    await Promise.all([
      manager.evictIfNeeded(),
      manager.evictIfNeeded(),
      manager.evictIfNeeded(),
    ])

    expect(manager.getStats().totalSize).toBeLessThanOrEqual(15)
    expect(manager.getStats().fileCount).toBe(1)
  })
})
