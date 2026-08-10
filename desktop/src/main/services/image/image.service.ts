import * as crypto from 'crypto'
import * as fs from 'fs'
import * as nodePath from 'path'
import { app } from 'electron'
import { SettingsService } from '../settings/settings.service'
import { DecoderRegistry } from './registry'
import { readDimensions } from './decoders/fast-dimensions'
import { DiskCacheManager, EvictionPolicy } from './disk-cache'
import type { DecodeResult, ImageDecoder } from './decoder'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { heavyTaskScheduler } from '../../utils/heavy-task-scheduler'
import { IMAGE_CONFIG } from './image-config'
import { invoke } from '../helper/helper-client'

// ── Native helper routing (Phase 2.1) ──

// helper 尺寸读取只路由到与 fast-dimensions 语义完全一致的非 RAW 格式。
// RAW 扩展在 sharp-decoder 中会对 fast-dimensions 结果叠加 EXIF 方向交换
// （orientation 5-8 时交换宽高），该逻辑没有进 helper，RAW 保持原路径。
const HELPER_DIMENSIONS_EXTENSIONS = new Set(
  IMAGE_CONFIG.sharp.supportedExtensions.filter(
    ext => !IMAGE_CONFIG.sharp.rawExtensions.includes(ext),
  ),
)
// helper 解码（thumbnail/preview）路由：RAWDecoder 覆盖 sharp.supportedExtensions
// 全集（含 RAW），全部走 helper；失败/不可用一律回退原解码器链。
const HELPER_DECODE_EXTENSIONS = new Set(IMAGE_CONFIG.sharp.supportedExtensions)
// 与 sharp-decoder 的 HEADER_READ_SIZE 一致，保证喂给 helper 的输入字节与
// 原 fast-dimensions 路径完全相同，语义零漂移（JPEG SOF 常落在 EXIF APP1
// 段之后，256 字节往往不够；TIFF IFD 也可能超出 256 字节）。
const HELPER_HEADER_READ_BYTES = 65536

// 探测 helper 可用性：GATHER_CORE_HELPER=1 显式启用，且
// GATHER_CORE_HELPER_PATH 指向存在的二进制（与 helper-client 的路径约定一致）。
function helperDimensionsEnabled(): boolean {
  if (process.env.GATHER_CORE_HELPER !== '1') return false
  const helperPath = process.env.GATHER_CORE_HELPER_PATH
  return helperPath !== undefined && helperPath !== '' && fs.existsSync(helperPath)
}

async function readFileHeader(filePath: string, size: number): Promise<Buffer | null> {
  try {
    const fd = await fs.promises.open(filePath, 'r')
    try {
      const buffer = Buffer.alloc(size)
      const { bytesRead } = await fd.read(buffer, 0, size, 0)
      return buffer.subarray(0, bytesRead)
    } finally {
      await fd.close()
    }
  } catch {
    return null
  }
}

// ── Cache interface ──

export interface ThumbnailCache {
  get(key: string): Promise<DecodeResult | null>
  set(key: string, value: DecodeResult): Promise<void>
  /** Write into the in-memory tier only, skipping any persistent tier. Used
   * by analysis passes that decode large previews (e.g. 2048px face
   * detection) but should not fill the disk cache. Optional so single-tier
   * caches can ignore it. */
  setMemoryOnly?(key: string, value: DecodeResult): Promise<void>
  flush(): Promise<void>
}

// ── In-memory LRU cache ──

export class MemoryThumbnailCache implements ThumbnailCache {
  private map = new Map<string, DecodeResult>()
  private readonly maxSize: number
  private readonly maxBytes: number
  private totalBytes = 0

  constructor(settings: SettingsService) {
    this.maxSize = Math.max(
      1,
      Math.min(100_000, Math.floor(settings.getNumber('memory_cache_size', 10_000))),
    )
    this.maxBytes = Math.max(
      32,
      settings.getNumber('memory_cache_max_size_mb', 192),
    ) * 1024 * 1024
  }

  async flush(): Promise<void> {
    // Nothing to persist: this tier is process-local.
  }

  async setMemoryOnly(key: string, value: DecodeResult): Promise<void> {
    await this.set(key, value)
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

// Cap on cached thumbnail reads: thumbnails are resized to <=2048px JPEGs
// (single-digit MB at most); guarding the read keeps a corrupt/foreign file
// from being loaded fully into memory and SOF-scanned on the main thread.
const DISK_CACHE_READ_CAP_BYTES = 64 * 1024 * 1024

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
      // A corrupt or foreign oversized file must not be read wholesale into
      // memory and scanned on the main thread: thumbnails never exceed a few
      // MB, so anything larger than the cap is treated as a cache miss.
      const source = await fs.promises.stat(filePath)
      if (source.size > DISK_CACHE_READ_CAP_BYTES) return null
      const buffer = await fs.promises.readFile(filePath)
      const hash = this.hashKey(key)
      const dimensions = readDimensions(buffer, '.jpg')
      if (!dimensions) return null
      this.manager.onAccess(hash)
      return {
        buffer,
        format: 'jpeg',
        width: dimensions.width,
        height: dimensions.height,
      }
    } catch {
      return null
    }
  }

  async set(key: string, value: DecodeResult): Promise<void> {
    await this.manager.waitUntilReady()
    const filePath = this.cachePath(key)
    const tempPath = `${filePath}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`
    try {
      await fs.promises.writeFile(tempPath, value.buffer, { flag: 'wx' })
      await fs.promises.rename(tempPath, filePath)
      const hash = this.hashKey(key)
      this.manager.onSet(hash, value.buffer.length)
      await this.manager.evictIfNeeded()
    } catch {
      // disk write failed — silently skip
    } finally {
      try { await fs.promises.unlink(tempPath) } catch { /* already renamed or never created */ }
    }
  }

  private hashKey(key: string): string {
    return crypto.createHash('sha256').update(key).digest('hex').slice(0, 16)
  }

  private cachePath(key: string): string {
    return nodePath.join(this.dir, `${this.hashKey(key)}.jpg`)
  }

  async flush(): Promise<void> {
    await this.manager.flush()
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

  async setMemoryOnly(key: string, value: DecodeResult): Promise<void> {
    await this.l1.set(key, value)
  }

  async flush(): Promise<void> {
    await this.l2.flush()
  }
}

// ── Cache key helpers ──

// stat() results are memoized briefly: thumbnail browsing re-requests the
// same filepaths many times per second (scrolling), and each stat on a
// network drive or cold cache is a full round-trip. The 1s TTL is well below
// the file watcher debounce, so a file replaced within the window at worst
// serves one stale frame — the same trade-off the disk cache already makes.
const STAT_TTL_MS = 1000
const STAT_CACHE_MAX = 10_000
const statCache = new Map<string, { size: number; mtimeMs: number; expires: number }>()

async function buildCacheKey(filePath: string, variant: string): Promise<string> {
  const now = Date.now()
  const cached = statCache.get(filePath)
  if (cached && cached.expires > now) {
    return `${filePath}::${variant}@${cached.size}@${cached.mtimeMs}`
  }
  try {
    const stat = await fs.promises.stat(filePath)
    if (statCache.size >= STAT_CACHE_MAX) statCache.clear()
    statCache.set(filePath, {
      size: stat.size,
      mtimeMs: Math.round(stat.mtimeMs),
      expires: now + STAT_TTL_MS,
    })
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
    @inject(DI_TOKENS.IMAGE_DECODERS) decoders: ImageDecoder[],
  ) {
    for (const decoder of decoders) {
      this.registry.register(decoder)
    }
    this.thumbnailCache = cache
    this.decodeLimiter = new DecodeLimiter(() => {
      const configured = Math.floor(this.settings.getNumber('thumbnail_concurrency', 4))
      return Math.max(1, Math.min(8, configured))
    })
  }

  async getPreview(
    path: string,
    maxDimension?: number,
    priority = 0,
    persistDisk = true,
  ): Promise<DecodeResult> {
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
            () => this.decodeWithHelper(path, 'preview', resolvedDimension),
          ), priority),
          priority,
        )
        if (persistDisk) {
          await this.thumbnailCache.set(key, result)
        } else {
          await this.thumbnailCache.setMemoryOnly?.(key, result)
        }
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
    persistDisk = true,
  ): Promise<DecodeResult> {
    const resolvedSize = canonicalImageSize(size)
    const cacheKey = await buildCacheKey(path, `t${resolvedSize}`)
    const existing = this.thumbnailInFlight.get(cacheKey)
    if (existing) return existing

    const pending = this.loadOrCreateThumbnail(path, resolvedSize, cacheKey, priority, persistDisk)
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
    // writes, concurrency limits, and the registered-decoder fallback chain.
    await this.getThumbnail(path, size, 0)
  }

  preloadThumbnails(paths: string[], size = this.settings.getNumber('thumbnail_size', 1024)): void {
    void Promise.allSettled(
      paths.map(path => this.getThumbnail(path, size, 2)),
    )
  }

  async buildThumbnails(
    paths: string[],
    size: number,
    signal?: AbortSignal,
    onProgress?: (current: number, total: number) => void,
  ): Promise<void> {
    const concurrency = Math.max(
      1,
      Math.min(8, Math.floor(this.settings.getNumber('thumbnail_concurrency', 4))),
    )
    let completed = 0
    for (let index = 0; index < paths.length; index += concurrency) {
      if (signal?.aborted) throw new Error('Thumbnail build cancelled')
      await Promise.allSettled(
        paths.slice(index, index + concurrency)
          .map(path => this.getThumbnail(path, size, 2)),
      )
      completed = Math.min(paths.length, index + concurrency)
      onProgress?.(completed, paths.length)
    }
  }

  preloadPreviews(paths: string[], maxDimension = 2048): void {
    void Promise.allSettled(
      paths.map(path => this.getPreview(path, maxDimension, 1)),
    )
  }

  async getDimensions(path: string): Promise<{ width: number; height: number }> {
    const existing = this.dimensionsInFlight.get(path)
    if (existing) return existing

    // helper 路由层优先（仅 GATHER_CORE_HELPER=1 且二进制存在时生效）；
    // 任何失败/不可用都回退原解码器链，保持既有行为。
    const pending = this.readDimensionsWithHelper(path)
      .catch(() => null)
      .then(async (helperDims) => {
        if (helperDims) return helperDims
        return this.decodeDimensionsWithFallback(path)
      })
    this.dimensionsInFlight.set(path, pending)
    try {
      return await pending
    } finally {
      if (this.dimensionsInFlight.get(path) === pending) {
        this.dimensionsInFlight.delete(path)
      }
    }
  }

  /** 原实现（默认路径）：解码器链（fast-dimensions → sharp/sips）取尺寸。 */
  private async decodeDimensionsWithFallback(path: string): Promise<{ width: number; height: number }> {
    return this.decodeLimiter.run(
      () => heavyTaskScheduler.run(() => this.decodeWithFallback(
        path,
        'dimensions',
        (decoder) => decoder.getDimensions(path),
      ), 1),
      1,
    )
  }

  /** helper 路由：读文件头 + ext 调 helper image:dimensions；
   * 未启用/不可用/失败/尺寸不可读一律返回 null，由调用方回退原路径。 */
  private async readDimensionsWithHelper(path: string): Promise<{ width: number; height: number } | null> {    if (!helperDimensionsEnabled()) return null
    const ext = nodePath.extname(path).toLowerCase()
    if (!HELPER_DIMENSIONS_EXTENSIONS.has(ext)) return null
    const header = await readFileHeader(path, HELPER_HEADER_READ_BYTES)
    if (!header) return null
    const response = await invoke('image:dimensions', JSON.stringify({
      ext,
      dataBase64: header.toString('base64'),
    }))
    if (!response.ok || response.payload === undefined || response.payload === '') return null
    let parsed: unknown
    try {
      parsed = JSON.parse(response.payload)
    } catch {
      return null
    }
    if (typeof parsed !== 'object' || parsed === null) return null
    const dims = parsed as { width?: unknown; height?: unknown }
    if (
      typeof dims.width !== 'number' || typeof dims.height !== 'number' ||
      !Number.isInteger(dims.width) || !Number.isInteger(dims.height) ||
      dims.width <= 0 || dims.height <= 0
    ) {
      return null
    }
    return { width: dims.width, height: dims.height }
  }

  private async loadOrCreateThumbnail(
    path: string,
    size: number,
    cacheKey: string,
    priority: number,
    persistDisk: boolean,
  ): Promise<DecodeResult> {
    const cached = await this.thumbnailCache.get(cacheKey)
    if (cached) return cached

    const result = await this.decodeLimiter.run(
      () => heavyTaskScheduler.run(() => this.decodeWithFallback(
        path,
        'thumbnail',
        (decoder) => decoder.getThumbnail(path, size),
        () => this.decodeWithHelper(path, 'thumbnail', size),
      ), priority),
      priority,
    )
    if (persistDisk) {
      await this.thumbnailCache.set(cacheKey, result)
    } else {
      await this.thumbnailCache.setMemoryOnly?.(cacheKey, result)
    }
    return result
  }

  private async decodeWithFallback<T>(
    path: string,
    operation: string,
    decode: (decoder: ImageDecoder) => Promise<T>,
    decodeViaHelper?: () => Promise<T>,
  ): Promise<T> {
    // helper 路由层优先（仅 GATHER_CORE_HELPER=1 且二进制存在时生效）；
    // 任何失败/不可用都回退原解码器链，保持既有行为。
    if (decodeViaHelper) {
      try {
        return await decodeViaHelper()
      } catch {
        // helper 失败（文件损坏/格式不支持/helper 进程异常）→ 回退。
      }
    }
    // Try every registered decoder that claims the extension, in registration
    // order. The composition root decides which decoders exist per platform,
    // so this core never branches on process.platform.
    const candidates = this.registry.resolveAll(path)
    const errors: unknown[] = []
    for (const decoder of candidates) {
      try {
        return await decode(decoder)
      } catch (error) {
        errors.push(error)
      }
    }
    // Only log once, when the whole chain failed: per-attempt warnings would
    // spam for repeatedly requested corrupt files even when a later decoder
    // succeeds.
    console.warn(
      `[ImageService] all ${candidates.length} decoder(s) failed for ${operation}: ${path}`,
      new AggregateError(
        errors,
        `Unable to decode ${path} for ${operation} with any of: ${candidates.map(d => d.name).join(', ')}`,
      ),
    )
    throw new AggregateError(
      errors,
      `Unable to decode ${path} for ${operation} with any of: ${candidates.map(d => d.name).join(', ')}`,
    )
  }

  /** helper 解码路由（Phase 2.1 剩余，macOS）：thumbnail/preview 走
   * gather-core-helper（ImageIO/CoreImage，含 RAW）。未启用/扩展名不在
   * 路由集/失败一律抛错，由 decodeWithFallback 回退原解码器链。 */
  private async decodeWithHelper(
    path: string,
    operation: 'thumbnail' | 'preview',
    size: number,
  ): Promise<DecodeResult> {
    if (!helperDimensionsEnabled()) {
      throw new Error('helper decode disabled')
    }
    const ext = nodePath.extname(path).toLowerCase()
    if (!HELPER_DECODE_EXTENSIONS.has(ext)) {
      throw new Error(`extension not routed to helper: ${ext}`)
    }
    const command = operation === 'thumbnail' ? 'image:thumbnail' : 'image:preview'
    const response = await invoke(command, JSON.stringify({ path, scale: size }))
    if (!response.ok || response.payload === undefined || response.payload === '') {
      throw new Error(response.error ?? `helper ${command} failed`)
    }
    let parsed: unknown
    try {
      parsed = JSON.parse(response.payload)
    } catch {
      throw new Error(`helper ${command} returned unparseable payload`)
    }
    if (typeof parsed !== 'object' || parsed === null) {
      throw new Error(`helper ${command} returned non-object payload`)
    }
    const result = parsed as {
      bufferBase64?: unknown
      format?: unknown
      width?: unknown
      height?: unknown
    }
    if (
      typeof result.bufferBase64 !== 'string' ||
      typeof result.format !== 'string' ||
      typeof result.width !== 'number' ||
      typeof result.height !== 'number' ||
      !Number.isInteger(result.width) || !Number.isInteger(result.height) ||
      result.width <= 0 || result.height <= 0
    ) {
      throw new Error(`helper ${command} returned invalid decode result`)
    }
    const buffer = Buffer.from(result.bufferBase64, 'base64')
    if (buffer.length === 0) {
      throw new Error(`helper ${command} returned empty buffer`)
    }
    return {
      buffer,
      format: result.format as DecodeResult['format'],
      width: result.width,
      height: result.height,
    }
  }
}
