import { beforeEach, describe, expect, it, vi } from 'vitest'
import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import sharp from 'sharp'

const decoderMocks = vi.hoisted(() => ({
  sharpPreview: vi.fn(),
  sharpThumbnail: vi.fn(),
  sharpDimensions: vi.fn(),
  helperInvoke: vi.fn(),
}))

vi.mock('electron', () => ({
  app: {
    getPath: () => '/tmp/gather-image-service-test',
  },
}))

vi.mock('../../../../desktop/src/main/services/image/decoders/sharp-decoder', () => ({
  SharpDecoder: class SharpDecoder {
    readonly name = 'Sharp test decoder'
    supports(): boolean { return true }
    getPreview(path: string, maxDimension?: number) {
      return decoderMocks.sharpPreview(path, maxDimension)
    }
    getThumbnail(path: string, size: number) {
      return decoderMocks.sharpThumbnail(path, size)
    }
    getDimensions(path: string) {
      return decoderMocks.sharpDimensions(path)
    }
  },
}))

// helper-client 打桩：不真正 spawn gather-core-helper，由测试控制 invoke 行为。
vi.mock('../../../../desktop/src/main/services/helper/helper-client', () => ({
  invoke: (command: string, payload?: string) =>
    decoderMocks.helperInvoke(command, payload),
}))

import {
  DiskThumbnailCache,
  ImageService,
  MemoryThumbnailCache,
  type ThumbnailCache,
} from '../../../../desktop/src/main/services/image/image.service'
import type { DecodeResult, ImageDecoder } from '../../../../desktop/src/main/services/image/decoder'
import { SharpDecoder } from '../../../../desktop/src/main/services/image/decoders/sharp-decoder'
import { getDefaults } from '../../../../desktop/src/main/services/settings/settings.service'
import type { SettingsService } from '../../../../desktop/src/main/services/settings/settings.service'

const decoded: DecodeResult = {
  buffer: Buffer.from('jpeg'),
  format: 'jpeg',
  width: 1200,
  height: 800,
}

// helper 路由启用需要环境变量指向真实存在的二进制路径（helperDimensionsEnabled
// 会 fs.existsSync 校验）。每次测试临时创建占位文件。
let helperPath = ''

function enableHelper(): void {
  process.env.GATHER_CORE_HELPER = '1'
  process.env.GATHER_CORE_HELPER_PATH = helperPath
}

function disableHelper(): void {
  delete process.env.GATHER_CORE_HELPER
  delete process.env.GATHER_CORE_HELPER_PATH
}

function sharpOnly(settings: SettingsService): ImageDecoder[] {
  return [new SharpDecoder(settings)]
}

function helperDecoded(): DecodeResult {
  return { buffer: Buffer.from('jpeg'), format: 'jpeg', width: 640, height: 480 }
}

function createCache(): ThumbnailCache & { values: Map<string, DecodeResult> } {
  const values = new Map<string, DecodeResult>()
  return {
    values,
    get: vi.fn(async (key: string) => values.get(key) ?? null),
    set: vi.fn(async (key: string, value: DecodeResult) => {
      values.set(key, value)
    }),
  }
}

function createSettings(concurrency = 2): SettingsService {
  return {
    get: (_key: string, fallback = '') => fallback,
    getNumber: (key: string, fallback: number) => {
      if (key === 'thumbnail_concurrency') return concurrency
      return fallback
    },
  } as SettingsService
}

describe('ImageService preview pipeline', () => {
  beforeEach(() => {
    // resetAllMocks 会连 mock 实现与 once 队列一起清掉（clearAllMocks 不清
    // mockResolvedValueOnce 残留，会污染后续测试），随后统一恢复默认实现。
    vi.resetAllMocks()
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-helper-stub-'))
    helperPath = path.join(dir, 'gather-core-helper')
    fs.writeFileSync(helperPath, '')
    decoderMocks.sharpPreview.mockResolvedValue(decoded)
    decoderMocks.sharpThumbnail.mockResolvedValue(decoded)
    decoderMocks.sharpDimensions.mockResolvedValue({ width: 1200, height: 800 })
  })

  afterEach(() => {
    disableHelper()
    fs.rmSync(path.dirname(helperPath), { recursive: true, force: true })
  })

  /// 设置 helper mock 默认成功响应（须在 enableHelper 后调用，避免被 resetAllMocks 清除）。
  function stubHelperOk(): void {
    decoderMocks.helperInvoke.mockResolvedValue({
      id: '1',
      ok: true,
      payload: JSON.stringify({
        bufferBase64: Buffer.from('jpeg').toString('base64'),
        format: 'jpeg',
        width: 640,
        height: 480,
      }),
    })
  }

  it('coalesces concurrent thumbnail requests for the same RAW file', async () => {
    const cache = createCache()
    const settings = createSettings()
    const service = new ImageService(cache, settings, sharpOnly(settings))

    const results = await Promise.all(
      Array.from({ length: 10 }, () => service.getThumbnail('/photos/a.nef', 2880)),
    )

    expect(results).toHaveLength(10)
    expect(decoderMocks.sharpThumbnail).toHaveBeenCalledTimes(1)
    expect(decoderMocks.sharpThumbnail).toHaveBeenCalledWith('/photos/a.nef', 2048)
    expect(cache.set).toHaveBeenCalledTimes(1)
  })

  it('routes thumbnail decode to the native helper when enabled', async () => {
    enableHelper()
    stubHelperOk()
    const service = new ImageService(createCache(), createSettings(), sharpOnly(createSettings()))

    const result = await service.getThumbnail('/photos/a.nef', 2880)

    expect(decoderMocks.helperInvoke).toHaveBeenCalledTimes(1)
    expect(decoderMocks.helperInvoke).toHaveBeenCalledWith(
      'image:thumbnail',
      JSON.stringify({ path: '/photos/a.nef', scale: 2048 }),
    )
    expect(decoderMocks.sharpThumbnail).not.toHaveBeenCalled()
    expect(result.width).toBe(640)
    expect(result.height).toBe(480)
  })

  it('falls back to sharp when the helper decode fails', async () => {
    enableHelper()
    decoderMocks.helperInvoke.mockResolvedValueOnce({ id: '1', ok: false, error: 'unsupported' })
    const service = new ImageService(createCache(), createSettings(), sharpOnly(createSettings()))
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => {})

    try {
      await service.getThumbnail('/photos/a.nef', 2880)

      expect(decoderMocks.helperInvoke).toHaveBeenCalledTimes(1)
      expect(decoderMocks.sharpThumbnail).toHaveBeenCalledTimes(1)
      // A successful fallback must stay quiet: per-attempt warnings would spam
      // for files that are repeatedly requested while a later decoder succeeds.
      expect(warning).not.toHaveBeenCalled()
    } finally {
      warning.mockRestore()
    }
  })

  it('tries every registered decoder before giving up', async () => {
    enableHelper()
    decoderMocks.helperInvoke.mockRejectedValueOnce(new Error('helper failed'))
    decoderMocks.sharpThumbnail.mockRejectedValueOnce(new Error('sharp failed'))
    const service = new ImageService(createCache(), createSettings(), sharpOnly(createSettings()))
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => {})

    try {
      const failure = await service.prioritizeThumbnail('/photos/a.nef', 2880)
        .catch((error: unknown) => error)

      expect(failure).toBeInstanceOf(AggregateError)
      expect((failure as AggregateError).errors).toHaveLength(1)
      expect(decoderMocks.sharpThumbnail).toHaveBeenCalledTimes(1)
      // Only the final aggregate failure is logged, exactly once.
      expect(warning).toHaveBeenCalledTimes(1)
    } finally {
      warning.mockRestore()
    }
  })

  it('applies the same helper-first chain to previews', async () => {
    enableHelper()
    stubHelperOk()
    const service = new ImageService(createCache(), createSettings(), sharpOnly(createSettings()))

    await service.getPreview('/photos/a.nef', 4096)

    expect(decoderMocks.helperInvoke).toHaveBeenCalledTimes(1)
    expect(decoderMocks.helperInvoke).toHaveBeenCalledWith(
      'image:preview',
      JSON.stringify({ path: '/photos/a.nef', scale: 2048 }),
    )
    expect(decoderMocks.sharpPreview).not.toHaveBeenCalled()
  })

  it('routes non-RAW dimensions through the helper and falls back on failure', async () => {
    enableHelper()
    stubHelperOk()
    // helper 路由会先 readFileHeader 读真实文件头，须用真实 JPEG 文件。
    const jpegDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-real-jpeg-'))
    const realJpeg = path.join(jpegDir, 'photo.jpg')
    fs.writeFileSync(realJpeg, Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD//gA7Q1JFQVRPUjogZ2QganBlZyB2MS4wICh1c2luZyBJSkcgSlBFRyB2ODApLCBxdWFsaXR5IDkwCg==', 'base64'))
    try {
      const service = new ImageService(createCache(), createSettings(), sharpOnly(createSettings()))

      // 非 RAW：dimensions 走 image:dimensions helper 路由。
      const dims = await service.getDimensions(realJpeg)

      expect(dims).toEqual({ width: 640, height: 480 })
      expect(decoderMocks.helperInvoke).toHaveBeenCalledTimes(1)
      expect(decoderMocks.helperInvoke).toHaveBeenCalledWith(
        'image:dimensions',
        expect.stringContaining('"ext":".jpg"'),
      )
      expect(decoderMocks.sharpDimensions).not.toHaveBeenCalled()

      decoderMocks.helperInvoke.mockResolvedValueOnce({ id: '2', ok: false, error: 'boom' })
      await service.getDimensions(realJpeg)
      expect(decoderMocks.sharpDimensions).toHaveBeenCalledTimes(1)
    } finally {
      fs.rmSync(jpegDir, { recursive: true, force: true })
    }
  })

  it('coalesces preview and dimensions requests independently', async () => {
    const settings = createSettings()
    const service = new ImageService(createCache(), settings, sharpOnly(settings))

    await Promise.all([
      service.getPreview('/photos/a.nef', 4096),
      service.getPreview('/photos/a.nef', 4096),
      service.getDimensions('/photos/a.nef'),
      service.getDimensions('/photos/a.nef'),
    ])
    await service.getPreview('/photos/a.nef', 4096)

    expect(decoderMocks.sharpPreview).toHaveBeenCalledTimes(1)
    expect(decoderMocks.sharpDimensions).toHaveBeenCalledTimes(1)
  })

  it('reuses a persistent preview cache across service instances', async () => {
    const cache = createCache()
    const settings = createSettings()
    const decoders = sharpOnly(settings)
    await new ImageService(cache, settings, decoders).getPreview('/photos/a.nef', 4096)
    await new ImageService(cache, settings, decoders).getPreview('/photos/a.nef', 4096)

    expect(decoderMocks.sharpPreview).toHaveBeenCalledTimes(1)
    expect(decoderMocks.sharpPreview).toHaveBeenCalledWith('/photos/a.nef', 2048)
  })

  it('routes RAW decode (thumbnail/preview) to the helper', async () => {
    enableHelper()
    stubHelperOk()
    const service = new ImageService(createCache(), createSettings(), sharpOnly(createSettings()))

    await service.getThumbnail('/photos/a.nef', 2880)
    await service.getPreview('/photos/a.nef', 4096)

    const commands = decoderMocks.helperInvoke.mock.calls.map(([command]) => command)
    expect(commands).toEqual(['image:thumbnail', 'image:preview'])
    expect(decoderMocks.sharpThumbnail).not.toHaveBeenCalled()
    expect(decoderMocks.sharpPreview).not.toHaveBeenCalled()
  })

  it('restores display dimensions when loading a thumbnail from disk cache', async () => {
    const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-thumbnail-cache-'))
    try {
      const cache = new DiskThumbnailCache(createSettings(), cacheDir)
      const buffer = await sharp({
        create: {
          width: 90,
          height: 60,
          channels: 3,
          background: '#000000',
        },
      }).jpeg().toBuffer()

      await cache.set('cache-without-source-path', {
        buffer,
        format: 'jpeg',
        width: 90,
        height: 60,
      })

      const restored = await cache.get('cache-without-source-path')
      expect(restored?.width).toBe(90)
      expect(restored?.height).toBe(60)
    } finally {
      fs.rmSync(cacheDir, { recursive: true, force: true })
    }
  })

  it('treats a corrupt persistent thumbnail as a cache miss', async () => {
    const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-thumbnail-cache-'))
    try {
      const key = 'corrupt-cache-entry'
      const hash = (await import('node:crypto'))
        .createHash('sha256')
        .update(key)
        .digest('hex')
        .slice(0, 16)
      fs.writeFileSync(path.join(cacheDir, `${hash}.jpg`), 'not-a-jpeg')
      const cache = new DiskThumbnailCache(createSettings(), cacheDir)

      expect(await cache.get(key)).toBeNull()
    } finally {
      fs.rmSync(cacheDir, { recursive: true, force: true })
    }
  })

  it('limits decode work even when callers bypass the preload queue', async () => {
    const settings = createSettings(2)
    const service = new ImageService(createCache(), settings, sharpOnly(settings))
    let active = 0
    let maxActive = 0
    decoderMocks.sharpThumbnail.mockImplementation(async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await new Promise((resolve) => setTimeout(resolve, 5))
      active--
      return decoded
    })

    await Promise.all(
      Array.from(
        { length: 8 },
        (_, index) => service.getThumbnail(`/photos/${index}.nef`, 2880),
      ),
    )

    expect(maxActive).toBe(2)
    expect(decoderMocks.sharpThumbnail).toHaveBeenCalledTimes(8)
  })
})

describe('MemoryThumbnailCache byte budget', () => {
  function settings(overrides: Record<string, number> = {}): SettingsService {
    return {
      get: (_key: string, fallback = '') => fallback,
      getNumber: (key: string, fallback: number) => overrides[key] ?? fallback,
    } as SettingsService
  }

  function entry(size: number): DecodeResult {
    return { buffer: Buffer.alloc(size), format: 'jpeg', width: 100, height: 100 }
  }

  it('registers a large default entry count so the byte budget dominates eviction', () => {
    expect(getDefaults()).toHaveProperty('memory_cache_size')
    expect(Number(getDefaults().memory_cache_size)).toBe(10_000)
  })

  it('keeps hundreds of previews when the byte budget is not exceeded', async () => {
    const cache = new MemoryThumbnailCache(settings())
    for (let i = 0; i < 500; i++) {
      await cache.set(`k${i}`, entry(1024))
    }
    expect(await cache.get('k0')).not.toBeNull()
    expect(await cache.get('k499')).not.toBeNull()
  })

  it('evicts the oldest entries once the byte budget is exceeded', async () => {
    const cache = new MemoryThumbnailCache(settings())
    for (let i = 0; i < 500; i++) {
      await cache.set(`k${i}`, entry(1024 * 1024))
    }
    expect(await cache.get('k0')).toBeNull()
    expect(await cache.get('k499')).not.toBeNull()
  })

  it('still enforces a configured entry-count ceiling when bytes permit more', async () => {
    const cache = new MemoryThumbnailCache(settings({ memory_cache_size: 3 }))
    for (let i = 0; i < 10; i++) {
      await cache.set(`k${i}`, entry(1024))
    }
    expect(await cache.get('k0')).toBeNull()
    expect(await cache.get('k9')).not.toBeNull()
  })

  it('clamps an undersized configured entry count to at least 1', async () => {
    const cache = new MemoryThumbnailCache(settings({ memory_cache_size: 0 }))
    await cache.set('a', entry(1024))
    await cache.set('b', entry(1024))
    expect(await cache.get('a')).toBeNull()
    expect(await cache.get('b')).not.toBeNull()
  })

  it('clamps an oversized configured entry count to 100_000', async () => {
    const cache = new MemoryThumbnailCache(settings({ memory_cache_size: 1_000_000 }))
    await cache.set('a', entry(1024))
    expect(await cache.get('a')).not.toBeNull()
  })
})
