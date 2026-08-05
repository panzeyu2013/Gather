import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import sharp from 'sharp'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SimilarityService } from '../../../../desktop/src/main/services/similarity/similarity.service'

const temporaryDirectories: string[] = []

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    fs.rmSync(directory, { recursive: true, force: true })
  }
})

describe('SimilarityService cancellation', () => {
  it('keeps the session occupied until the cancelled analysis actually exits', async () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-sim-cancel-'))
    temporaryDirectories.push(directory)
    const filepath = path.join(directory, 'photo.jpg')
    fs.writeFileSync(filepath, 'fixture')
    const imageBuffer = await sharp({
      create: {
        width: 16,
        height: 16,
        channels: 3,
        background: '#808080',
      },
    }).jpeg().toBuffer()

    let releaseThumbnail!: () => void
    let thumbnailStarted!: () => void
    const started = new Promise<void>(resolve => { thumbnailStarted = resolve })
    const thumbnail = new Promise<{ buffer: Buffer }>(resolve => {
      releaseThumbnail = () => resolve({ buffer: imageBuffer })
    })
    const service = new SimilarityService(
      {
        getBySession: vi.fn(() => [{
          id: 'photo',
          filepath,
          filename: 'photo.jpg',
          asset_id: null,
        }]),
      } as never,
      { updateAnalysisStatus: vi.fn() } as never,
      { replace: vi.fn() } as never,
      { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
      {
        getThumbnail: vi.fn(() => {
          thumbnailStarted()
          return thumbnail
        }),
      } as never,
      {
        prepare: vi.fn(() => ({
          all: vi.fn(() => []),
          get: vi.fn(() => undefined),
          run: vi.fn(),
        })),
        transaction: vi.fn((operation: (...args: never[]) => unknown) => operation),
      } as never,
    )

    const first = service.analyze('session')
    await started
    await service.cancel('session')

    await expect(service.analyze('session')).rejects.toThrow(
      'Similarity analysis is already running',
    )

    releaseThumbnail()
    await first
  })
})
