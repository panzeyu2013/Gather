import * as crypto from 'crypto'
import * as fs from 'fs'
import * as nodePath from 'path'
import { app } from 'electron'
import { SettingsService } from '../settings/settings.service'
import { DecoderRegistry } from './registry'
import { SharpDecoder } from './decoders/sharp-decoder'
import { SipsDecoder } from './decoders/sips-decoder'
import { readDimensions } from './decoders/fast-dimensions'
import { DiskCacheManager, EvictionPolicy } from './disk-cache'
import type { DecodeResult, ImageDecoder } from './decoder'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { heavyTaskScheduler } from '../../utils/heavy-task-scheduler'

// ── Cache interface ──

export interface ThumbnailCache {
  get(key: string): Promise<DecodeResult | null>
  set(key: string, value: DecodeResult): Promise<void>
}

// ── In-memory LRU cache ──

export class MemoryThumbnailCache implements ThumbnailCache {
  private map = new Map<string, DecodeResult>()
  private readonly maxSize: number
  private readonly maxBytes: number
  private totalBytes = 0

  constructor(settings: SettingsService) {
    this.maxSize = settings.getNumber('memory_cache_size', 200)
    this.maxBytes = Math.max(
      32,
      settings.getNumber('memory_cache_max_size_mb', 192),
    ) * 1024 * 1024
  }

  async get(key: string): Promise<DecodeResult | null> {
    const val = this.map.get(key)
    if (val !== undefined) {
      this.map.delete(key)
      this.map.set(key, val)
    }
    return val ?? null
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    if (value.buffer.length > this.maxBytes) return
    if (this.map.has(key)) {
      this.totalBytes -= this.map.get(key)?.buffer.length ?? 0
      this.map.delete(key)
    }
    while (this.map.size >= this.maxSize || this.totalBytes + value.buffer.length > this.maxBytes) {
      const first = this.map.keys().next().value
      if (first === undefined) break
      this.totalBytes -= this.map.get(first)?.buffer.length ?? 0
      this.map.delete(first)
    }
    this.map.set(key, value)
    this.totalBytes += value.buffer.length
  }
}

// ── Disk-backed persistent cache ──

export class DiskThumbnailCache implements ThumbnailCache {
  private dir: string
  private manager: DiskCacheManager

  constructor(settings: SettingsService, cacheDir?: string) {
    const diskDir = cacheDir ?? (settings.get('disk_cache_dir', '') || nodePath.join(app.getPath('userData'), 'thumbnails'))
    this.dir = diskDir
    if (!fs.existsSync(this.dir)) {
      fs.mkdirSync(this.dir, { recursive: true })
    }
    const maxSizeGb = settings.getNumber('disk_cache_max_size_gb', 1)
    const policyStr = settings.get('disk_cache_eviction_policy', 'lru')
    const policy = policyStr === 'fifo' ? EvictionPolicy.FIFO : policyStr === 'lfu' ? EvictionPolicy.LFU : EvictionPolicy.LRU
    this.manager = new DiskCacheManager(this.dir, maxSizeGb * 1024 * 1024 * 1024, policy)
  }

  async get(key: string): Promise<DecodeResult | null> {
    await this.manager.waitUntilReady()
    const filePath = this.cachePath(key)

    try {
      const buffer = await fs.promises.readFile(filePath)
      const hash = this.hashKey(key)
      this.manager.onAccess(hash)
      const dimensions = readDimensions(buffer, '.jpg')
      return {
        buffer,
        format: 'jpeg',
        width: dimensions?.width ?? 0,
        height: dimensions?.height ?? 0,
      }
    } catch {
      return null
    }
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    await this.manager.waitUntilReady()
    const filePath = this.cachePath(key)
    try {
      await fs.promises.writeFile(filePath, value.buffer)
      const hash = this.hashKey(key)
      this.manager.onSet(hash, value.buffer.length)
      await this.manager.evictIfNeeded()
    } catch {
      // disk write failed — silently skip
    }
  }

  private hashKey(key: string): string {
    return crypto.createHash('sha256').update(key).digest('hex').slice(0, 16)
  }

  private cachePath(key: string): string {
    return nodePath.join(this.dir, `${this.hashKey(key)}.jpg`)
  }

}

// ── Two-tier cache (memory → disk → decode) ──

@injectable()
export class TieredThumbnailCache implements ThumbnailCache {
  private l1: MemoryThumbnailCache
  private l2: DiskThumbnailCache

  constructor(@inject(DI_TOKENS.SETTINGS_SERVICE) settings: SettingsService) {
    this.l1 = new MemoryThumbnailCache(settings)
    this.l2 = new DiskThumbnailCache(settings)
  }

  async get(key: string): Promise<DecodeResult | null> {
    const mem = await this.l1.get(key)
    if (mem) return mem

    const disk = await this.l2.get(key)
    if (disk) {
      await this.l1.set(key, disk)
      return disk
    }
    return null
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    await Promise.all([this.l1.set(key, value), this.l2.set(key, value)])
  }
}

// ── Cache key helpers ──

async function buildCacheKey(filePath: string, variant: string): Promise<string> {
  try {
    const stat = await fs.promises.stat(filePath)
    return `${filePath}::${variant}@${stat.size}@${Math.round(stat.mtimeMs)}`
  } catch {
    return `${filePath}::${variant}@missing`
  }
}

function canonicalImageSize(requested: number): number {
  if (requested <= 320) return 256
  if (requested <= 1280) return 1024
  return 2048
}

class DecodeLimiter {
  private active = 0
  private pending: Array<{ priority: number; resolve: () => void }> = []

  constructor(private readonly getLimit: () => number) {}

  async run<T>(task: () => Promise<T>, priority = 1): Promise<T> {
    if (this.active >= this.getLimit()) {
      await new Promise<void>((resolve) => {
        this.pending.push({ priority, resolve })
        this.pending.sort((a, b) => a.priority - b.priority)
      })
    }

    this.active++
    try {
      return await task()
    } finally {
      this.active--
      this.pending.shift()?.resolve()
    }
  }
}

// ── ImageService ──

@injectable()
export class ImageService {
  private registry = new DecoderRegistry()
  private thumbnailCache: ThumbnailCache
  private thumbnailInFlight = new Map<string, Promise<DecodeResult>>()
  private previewInFlight = new Map<string, Promise<DecodeResult>>()
  private dimensionsInFlight = new Map<string, Promise<{ width: number; height: number }>>()
  private decodeLimiter: DecodeLimiter

  constructor(
    @inject(DI_TOKENS.THUMBNAIL_CACHE) cache: ThumbnailCache,
    @inject(DI_TOKENS.SETTINGS_SERVICE) private settings: SettingsService,
  ) {
    this.registry.register(new SharpDecoder(settings))
    if (process.platform === 'darwin') {
      this.registry.register(new SipsDecoder())
    }
    this.thumbnailCache = cache
    this.decodeLimiter = new DecodeLimiter(() => {
      const configured = Math.floor(this.settings.getNumber('thumbnail_concurrency', 4))
      return Math.max(1, Math.min(8, configured))
    })
  }

  async getPreview(path: string, maxDimension?: number, priority = 0): Promise<DecodeResult> {
    const resolvedDimension = maxDimension ? canonicalImageSize(maxDimension) : 2048
    const key = await buildCacheKey(path, `p${resolvedDimension}`)
    const existing = this.previewInFlight.get(key)
    if (existing) return existing

    const pending = this.thumbnailCache.get(key)
      .then(async (diskCached) => {
        if (diskCached) return diskCached
        const result = await this.decodeLimiter.run(
          () => heavyTaskScheduler.run(() => this.decodeWithFallback(
            path,
            'preview',
            (decoder) => decoder.getPreview(path, resolvedDimension),
          ), priority),
          priority,
        )
        await this.thumbnailCache.set(key, result)
        return result
      })
    this.previewInFlight.set(key, pending)
    try {
      return await pending
    } finally {
      if (this.previewInFlight.get(key) === pending) {
        this.previewInFlight.delete(key)
      }
    }
  }

  async getThumbnail(
    path: string,
    size = this.settings.getNumber('thumbnail_size', 1024),
    priority = 1,
  ): Promise<DecodeResult> {
    const resolvedSize = canonicalImageSize(size)
    const cacheKey = await buildCacheKey(path, `t${resolvedSize}`)
    const existing = this.thumbnailInFlight.get(cacheKey)
    if (existing) return existing

    const pending = this.loadOrCreateThumbnail(path, resolvedSize, cacheKey, priority)
    this.thumbnailInFlight.set(cacheKey, pending)
    try {
      return await pending
    } finally {
      if (this.thumbnailInFlight.get(cacheKey) === pending) {
        this.thumbnailInFlight.delete(cacheKey)
      }
    }
  }

  async prioritizeThumbnail(path: string, size = this.settings.getNumber('thumbnail_size', 1024)): Promise<void> {
    // Reuse the normal path so priority requests share in-flight work, cache
    // writes, concurrency limits, and the same Sharp -> sips fallback.
    await this.getThumbnail(path, size, 0)
  }

  preloadThumbnails(paths: string[], size = this.settings.getNumber('thumbnail_size', 1024)): void {
    void Promise.allSettled(
      paths.map(path => this.getThumbnail(path, size, 2)),
    )
  }

  preloadPreviews(paths: string[], maxDimension = 2048): void {
    void Promise.allSettled(
      paths.map(path => this.getPreview(path, maxDimension, 1)),
    )
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const existing = this.dimensionsInFlight.get(path)
    if (existing) return existing

    const pending = this.decodeLimiter.run(
      () => heavyTaskScheduler.run(() => this.decodeWithFallback(
        path,
        'dimensions',
        (decoder) => decoder.getDimensions(path),
      ), 1),
      1,
    )
    this.dimensionsInFlight.set(path, pending)
    try {
      return await pending
    } finally {
      if (this.dimensionsInFlight.get(path) === pending) {
        this.dimensionsInFlight.delete(path)
      }
    }
  }

  private async loadOrCreateThumbnail(
    path: string,
    size: number,
    cacheKey: string,
    priority: number,
  ): Promise<DecodeResult> {
    const cached = await this.thumbnailCache.get(cacheKey)
    if (cached) return cached

    const result = await this.decodeLimiter.run(
      () => heavyTaskScheduler.run(() => this.decodeWithFallback(
        path,
        'thumbnail',
        (decoder) => decoder.getThumbnail(path, size),
      ), priority),
      priority,
    )
    await this.thumbnailCache.set(cacheKey, result)
    return result
  }

  private async decodeWithFallback<T>(
    path: string,
    operation: string,
    decode: (decoder: ImageDecoder) => Promise<T>,
  ): Promise<T> {
    const decoder = this.registry.resolve(path)
    try {
      return await decode(decoder)
    } catch (primaryError) {
      if (!(decoder instanceof SharpDecoder) || process.platform !== 'darwin') {
        throw primaryError
      }

      const fallback = new SipsDecoder()
      if (!fallback.supports(nodePath.extname(path).toLowerCase())) {
        throw primaryError
      }

      console.warn(
        `[ImageService] ${decoder.name} failed for ${operation}: ${path}; falling back to ${fallback.name}`,
        primaryError,
      )
      try {
        return await decode(fallback)
      } catch (fallbackError) {
        throw new AggregateError(
          [primaryError, fallbackError],
          `Unable to decode ${path} for ${operation} with ${decoder.name} or ${fallback.name}`,
        )
      }
    }
  }
}
