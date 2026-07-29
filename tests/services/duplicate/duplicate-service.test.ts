import { describe, expect, it, vi } from 'vitest'
import sharp from 'sharp'
import {
  computeVisualHashes,
  excludeExactDuplicateHashes,
} from '../../../desktop/src/main/services/duplicate/duplicate.service'
import type { ImageService } from '../../../desktop/src/main/services/image'

describe('duplicate scan grouping', () => {
  it('does not place exact duplicates into visual groups', () => {
    const rows = [
      { photo_id: 'exact-a', hash_hex: '0000' },
      { photo_id: 'exact-b', hash_hex: '0000' },
      { photo_id: 'visual-a', hash_hex: '0001' },
      { photo_id: 'visual-b', hash_hex: '0002' },
    ]

    expect(
      excludeExactDuplicateHashes(
        rows,
        new Set(['exact-a', 'exact-b']),
      ),
    ).toEqual([
      { photo_id: 'visual-a', hash_hex: '0001' },
      { photo_id: 'visual-b', hash_hex: '0002' },
    ])
  })

  it('computes visual hashes during a standalone duplicate scan', async () => {
    const preview = await sharp({
      create: {
        width: 16,
        height: 16,
        channels: 3,
        background: { r: 80, g: 80, b: 80 },
      },
    }).jpeg().toBuffer()

    const imageService = {
      getThumbnail: vi.fn().mockResolvedValue({
        buffer: preview,
        format: 'jpeg',
        width: 16,
        height: 16,
      }),
    } as unknown as ImageService

    const result = await computeVisualHashes([
      { id: 'first', filepath: '/first.raw' },
      { id: 'second', filepath: '/second.raw' },
    ], imageService)

    expect(result.get('first')).toBe(result.get('second'))
    expect(imageService.getThumbnail).toHaveBeenCalledTimes(2)
  })
})
