import * as crypto from 'crypto'
import * as fs from 'fs'
import * as path from 'path'
import { app } from 'electron'
import { SettingsService } from '../settings'
import { DecoderRegistry } from './registry'
import { SharpDecoder } from './decoders/sharp-decoder'
import { SipsDecoder } from './decoders/sips-decoder'
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

  constructor(cacheDir?: string) {
    const diskDir = cacheDir ?? SettingsService.getInstance().get('disk_cache_dir', '') || path.join(app.getPath('userData'), 'thumbnails')
    this.dir = diskDir
    if (!fs.existsSync(this.dir)) {
      fs.mkdirSync(this.dir, { recursive: true })
    }
  }

  async get(key: string): Promise<DecodeResult | null> {
    const filePath = this.cachePath(key)
    if (!fs.existsSync(filePath)) return null

    const sourcePath = decodeSourcePath(key)
    if (sourcePath && !this.isValid(filePath, sourcePath)) return null

    try {
      const buffer = fs.readFileSync(filePath)
      return { buffer, format: 'jpeg', width: 0, height: 0 }
    } catch {
      return null
    }
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    try {
      fs.writeFileSync(this.cachePath(key), value.buffer)
    } catch {
      // disk write failed — silently skip
    }
  }

  private cachePath(key: string): string {
    const hash = crypto.createHash('sha256').update(key).digest('hex').slice(0, 16)
    return path.join(this.dir, `${hash}.jpg`)
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

  async getPreview(path: string, maxDimension = SettingsService.getInstance().getNumber('preview_max_dimension', 1920)): Promise<DecodeResult> {
    const decoder = this.registry.resolve(path)
    return decoder.getPreview(path, maxDimension)
  }

  async getThumbnail(path: string, size = SettingsService.getInstance().getNumber('thumbnail_size', 320)): Promise<DecodeResult> {
    const cacheKey = buildCacheKey(path, size)
    const cached = await this.thumbnailCache.get(cacheKey)
    if (cached) return cached
    const decoder = this.registry.resolve(path)
    const result = await decoder.getThumbnail(path, size)
    await this.thumbnailCache.set(cacheKey, result)
    return result
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const decoder = this.registry.resolve(path)
    return decoder.getDimensions(path)
  }
}
