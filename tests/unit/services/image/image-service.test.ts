import { beforeEach, describe, expect, it, vi } from 'vitest'
import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import sharp from 'sharp'

const decoderMocks = vi.hoisted(() => ({
  sharpPreview: vi.fn(),
  sharpThumbnail: vi.fn(),
  sharpDimensions: vi.fn(),
  sipsPreview: vi.fn(),
  sipsThumbnail: vi.fn(),
  sipsDimensions: vi.fn(),
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

vi.mock('../../../../desktop/src/main/services/image/decoders/sips-decoder', () => ({
  SipsDecoder: class SipsDecoder {
    readonly name = 'Sips test decoder'
    supports(): boolean { return true }
    getPreview(path: string, maxDimension?: number) {
      return decoderMocks.sipsPreview(path, maxDimension)
    }
    getThumbnail(path: string, size: number) {
      return decoderMocks.sipsThumbnail(path, size)
    }
    getDimensions(path: string) {
      return decoderMocks.sipsDimensions(path)
    }
  },
}))

import {
  DiskThumbnailCache,
  ImageService,
  type ThumbnailCache,
} from '../../../../desktop/src/main/services/image/image.service'
import type { DecodeResult, ImageDecoder } from '../../../../desktop/src/main/services/image/decoder'
import { SharpDecoder } from '../../../../desktop/src/main/services/image/decoders/sharp-decoder'
import { SipsDecoder } from '../../../../desktop/src/main/services/image/decoders/sips-decoder'
import { IMAGE_CONFIG } from '../../../../desktop/src/main/services/image/image-config'
import type { SettingsService } from '../../../../desktop/src/main/services/settings/settings.service'

const decoded: DecodeResult = {
  buffer: Buffer.from('jpeg'),
  format: 'jpeg',
  width: 1200,
  height: 800,
}

function sharpOnly(settings: SettingsService): ImageDecoder[] {
  return [new SharpDecoder(settings)]
}

function sharpThenSips(settings: SettingsService): ImageDecoder[] {
  return [new SharpDecoder(settings), new SipsDecoder()]
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
    vi.clearAllMocks()
    decoderMocks.sharpPreview.mockResolvedValue(decoded)
    decoderMocks.sharpThumbnail.mockResolvedValue(decoded)
    decoderMocks.sharpDimensions.mockResolvedValue({ width: 1200, height: 800 })
    decoderMocks.sipsPreview.mockResolvedValue(decoded)
    decoderMocks.sipsThumbnail.mockResolvedValue(decoded)
    decoderMocks.sipsDimensions.mockResolvedValue({ width: 1200, height: 800 })
  })

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

  it('falls back to the next registered decoder for priority requests', async () => {
    const cache = createCache()
    const settings = createSettings()
    const service = new ImageService(cache, settings, sharpThenSips(settings))
    decoderMocks.sharpThumbnail.mockRejectedValueOnce(new Error('unsupported image'))
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => {})

    try {
      await service.prioritizeThumbnail('/photos/a.nef', 2880)

      expect(decoderMocks.sharpThumbnail).toHaveBeenCalledTimes(1)
      expect(decoderMocks.sipsThumbnail).toHaveBeenCalledTimes(1)
      expect(cache.values.size).toBe(1)
      // A successful fallback must stay quiet: per-attempt warnings would spam
      // for files that are repeatedly requested while a later decoder succeeds.
      expect(warning).not.toHaveBeenCalled()
    } finally {
      warning.mockRestore()
    }
  })

  it('tries every registered decoder before giving up', async () => {
    const cache = createCache()
    const settings = createSettings()
    const service = new ImageService(cache, settings, sharpThenSips(settings))
    decoderMocks.sharpThumbnail.mockRejectedValueOnce(new Error('sharp failed'))
    decoderMocks.sipsThumbnail.mockRejectedValueOnce(new Error('sips failed'))
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => {})

    try {
      const failure = await service.prioritizeThumbnail('/photos/a.nef', 2880)
        .catch((error: unknown) => error)

      expect(failure).toBeInstanceOf(AggregateError)
      expect((failure as AggregateError).errors).toHaveLength(2)
      expect(decoderMocks.sharpThumbnail).toHaveBeenCalledTimes(1)
      expect(decoderMocks.sipsThumbnail).toHaveBeenCalledTimes(1)
      // Only the final aggregate failure is logged, exactly once.
      expect(warning).toHaveBeenCalledTimes(1)
    } finally {
      warning.mockRestore()
    }
  })

  it('applies the same fallback chain to previews', async () => {
    const settings = createSettings()
    const service = new ImageService(createCache(), settings, sharpThenSips(settings))
    decoderMocks.sharpPreview.mockRejectedValueOnce(new Error('preview failed'))

    await service.getPreview('/photos/a.nef', 4096)

    expect(decoderMocks.sharpPreview).toHaveBeenCalledTimes(1)
    expect(decoderMocks.sipsPreview).toHaveBeenCalledTimes(1)
  })

  it('applies the same fallback chain to dimensions', async () => {
    const settings = createSettings()
    const service = new ImageService(createCache(), settings, sharpThenSips(settings))
    decoderMocks.sharpDimensions.mockRejectedValueOnce(new Error('dimensions failed'))

    await service.getDimensions('/photos/a.nef')

    expect(decoderMocks.sharpDimensions).toHaveBeenCalledTimes(1)
    expect(decoderMocks.sipsDimensions).toHaveBeenCalledTimes(1)
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

  it('tries embedded-preview extraction before sips for every configured RAW format', () => {
    const sharpRaw = new Set(IMAGE_CONFIG.sharp.rawExtensions)
    const sharpSupported = new Set(IMAGE_CONFIG.sharp.supportedExtensions)

    for (const extension of IMAGE_CONFIG.sips.rawExtensions) {
      expect(sharpRaw.has(extension)).toBe(true)
      expect(sharpSupported.has(extension)).toBe(true)
    }
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
