import * as crypto from 'crypto'
import * as fs from 'fs'
import * as nodePath from 'path'
import { app } from 'electron'
import { SettingsService } from '../settings'
import { DecoderRegistry } from './registry'
import { SharpDecoder } from './decoders/sharp-decoder'
import { SipsDecoder } from './decoders/sips-decoder'
import { DiskCacheManager, EvictionPolicy } from './disk-cache'
import type { DecodeResult } from './decoder'

// ── Cache interface ──

export interface ThumbnailCache {
  get(key: string): Promise<DecodeResult | null>
  set(key: string, value: DecodeResult): Promise<void>
}

// ── In-memory LRU cache ──

export class MemoryThumbnailCache implements ThumbnailCache {
  private map = new Map<string, DecodeResult>()

  constructor(private maxSize = SettingsService.getInstance().getNumber('memory_cache_size', 200)) {}

  async get(key: string): Promise<DecodeResult | null> {
    const val = this.map.get(key)
    if (val !== undefined) {
      this.map.delete(key)
      this.map.set(key, val)
    }
    return val ?? null
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    if (this.map.has(key)) {
      this.map.delete(key)
    } else if (this.map.size >= this.maxSize) {
      const first = this.map.keys().next().value
      if (first !== undefined) this.map.delete(first)
    }
    this.map.set(key, value)
  }
}

// ── Disk-backed persistent cache ──

export class DiskThumbnailCache implements ThumbnailCache {
  private dir: string
  private manager: DiskCacheManager

  constructor(cacheDir?: string) {
    const diskDir = cacheDir ?? (SettingsService.getInstance().get('disk_cache_dir', '') || nodePath.join(app.getPath('userData'), 'thumbnails'))
    this.dir = diskDir
    if (!fs.existsSync(this.dir)) {
      fs.mkdirSync(this.dir, { recursive: true })
    }
    const settings = SettingsService.getInstance()
    const maxSizeGb = settings.getNumber('disk_cache_max_size_gb', 1)
    const policyStr = settings.get('disk_cache_eviction_policy', 'lru')
    const policy = policyStr === 'fifo' ? EvictionPolicy.FIFO : policyStr === 'lfu' ? EvictionPolicy.LFU : EvictionPolicy.LRU
    this.manager = new DiskCacheManager(this.dir, maxSizeGb * 1024 * 1024 * 1024, policy)
  }

  async get(key: string): Promise<DecodeResult | null> {
    const filePath = this.cachePath(key)
    if (!fs.existsSync(filePath)) return null

    const sourcePath = decodeSourcePath(key)
    if (sourcePath && !this.isValid(filePath, sourcePath)) return null

    try {
      const buffer = fs.readFileSync(filePath)
      const hash = this.hashKey(key)
      this.manager.onAccess(hash)
      return { buffer, format: 'jpeg', width: 0, height: 0 }
    } catch {
      return null
    }
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    const filePath = this.cachePath(key)
    try {
      fs.writeFileSync(filePath, value.buffer)
      const hash = this.hashKey(key)
      this.manager.onSet(hash, value.buffer.length)
      this.manager.evictIfNeeded()
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

  private isValid(cacheFile: string, sourceFile: string): boolean {
    try {
      const cacheStat = fs.statSync(cacheFile)
      const sourceStat = fs.statSync(sourceFile)
      return sourceStat.mtimeMs <= cacheStat.mtimeMs
    } catch {
      return false
    }
  }
}

// ── Two-tier cache (memory → disk → decode) ──

export class TieredThumbnailCache implements ThumbnailCache {
  constructor(
    private l1: MemoryThumbnailCache = new MemoryThumbnailCache(50),
    private l2: DiskThumbnailCache = new DiskThumbnailCache(),
  ) {}

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

function buildCacheKey(filePath: string, size: number): string {
  return `${filePath}::${size}`
}

function decodeSourcePath(key: string): string | null {
  const idx = key.lastIndexOf('::')
  if (idx === -1) return null
  return key.slice(0, idx)
}

// ── ImageService ──

export class ImageService {
  private registry = new DecoderRegistry()
  private thumbnailCache: ThumbnailCache

  constructor(cache?: ThumbnailCache) {
    this.registry.register(new SharpDecoder())
    if (process.platform === 'darwin') {
      this.registry.register(new SipsDecoder())
    }
    this.thumbnailCache = cache ?? new MemoryThumbnailCache(
      SettingsService.getInstance().getNumber('memory_cache_size', 200)
    )
  }

  async getPreview(path: string, maxDimension?: number): Promise<DecodeResult> {
    const decoder = this.registry.resolve(path)
    try {
      return await decoder.getPreview(path, maxDimension)
    } catch (err) {
      if (decoder instanceof SharpDecoder && process.platform === 'darwin') {
        const sipsDecoder = new SipsDecoder()
        if (sipsDecoder.supports(nodePath.extname(path).toLowerCase())) {
          return sipsDecoder.getPreview(path, maxDimension)
        }
      }
      throw err
    }
  }

  async getThumbnail(path: string, size = SettingsService.getInstance().getNumber('thumbnail_size', 320)): Promise<DecodeResult> {
    const cacheKey = buildCacheKey(path, size)
    const cached = await this.thumbnailCache.get(cacheKey)
    if (cached) return cached
    const decoder = this.registry.resolve(path)
    try {
      const result = await decoder.getThumbnail(path, size)
      await this.thumbnailCache.set(cacheKey, result)
      return result
    } catch (err) {
      if (decoder instanceof SharpDecoder && process.platform === 'darwin') {
        const sipsDecoder = new SipsDecoder()
        if (sipsDecoder.supports(nodePath.extname(path).toLowerCase())) {
          const result = await sipsDecoder.getThumbnail(path, size)
          await this.thumbnailCache.set(cacheKey, result)
          return result
        }
      }
      throw err
    }
  }

  async prioritizeThumbnail(path: string, size = SettingsService.getInstance().getNumber('thumbnail_size', 320)): Promise<void> {
    const cacheKey = buildCacheKey(path, size)
    const cached = await this.thumbnailCache.get(cacheKey)
    if (cached) return
    const decoder = this.registry.resolve(path)
    const result = await decoder.getThumbnail(path, size)
    await this.thumbnailCache.set(cacheKey, result)
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const decoder = this.registry.resolve(path)
    try {
      return await decoder.getDimensions(path)
    } catch (err) {
      if (decoder instanceof SharpDecoder && process.platform === 'darwin') {
        const sipsDecoder = new SipsDecoder()
        if (sipsDecoder.supports(nodePath.extname(path).toLowerCase())) {
          return sipsDecoder.getDimensions(path)
        }
      }
      throw err
    }
  }

  private static instance: ImageService | null = null
  static getInstance(cache?: ThumbnailCache): ImageService {
    if (!ImageService.instance) {
      ImageService.instance = new ImageService(cache)
    }
    return ImageService.instance
  }
}
