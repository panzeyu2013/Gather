import { afterEach, describe, expect, it, vi } from 'vitest'
import crypto from 'crypto'
import fs from 'fs'
import os from 'os'
import path from 'path'
import sharp from 'sharp'

vi.mock('electron', () => ({
  app: {
    getPath: () => os.tmpdir(),
  },
}))

import { SharpDecoder } from '../../../desktop/src/main/services/image/decoders/sharp-decoder'
import type { SettingsService } from '../../../desktop/src/main/services/settings/settings.service'

const tempDirs: string[] = []

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

describe('SharpDecoder RAW preview index', () => {
  it('persists embedded JPEG offsets for subsequent RAW decodes', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-raw-index-'))
    tempDirs.push(dir)
    const cacheDir = path.join(dir, 'cache')
    const sourcePath = path.join(dir, 'photo.NEF')
    const pixels = crypto.randomBytes(640 * 480 * 3)
    const embeddedJpeg = await sharp(pixels, {
      raw: { width: 640, height: 480, channels: 3 },
    }).jpeg({ quality: 90 }).toBuffer()
    fs.writeFileSync(sourcePath, Buffer.concat([
      Buffer.alloc(128),
      embeddedJpeg,
      Buffer.alloc(256),
    ]))

    const settings = {
      get: (key: string, fallback = '') => key === 'disk_cache_dir' ? cacheDir : fallback,
      getNumber: (_key: string, fallback: number) => fallback,
    } as SettingsService

    const first = await new SharpDecoder(settings).getThumbnail(sourcePath, 256)
    expect(first.width).toBe(256)
    expect(first.height).toBe(192)

    const indexDir = path.join(cacheDir, 'raw-index')
    const indexFiles = fs.readdirSync(indexDir)
    expect(indexFiles).toHaveLength(1)
    const index = JSON.parse(
      fs.readFileSync(path.join(indexDir, indexFiles[0]), 'utf8'),
    ) as { segments: Array<{ offset: number; size: number }> }
    expect(index.segments[0]).toMatchObject({
      offset: 128,
      size: embeddedJpeg.length,
    })

    const second = await new SharpDecoder(settings).getThumbnail(sourcePath, 256)
    expect(second.buffer.length).toBeGreaterThan(0)
  })
})
