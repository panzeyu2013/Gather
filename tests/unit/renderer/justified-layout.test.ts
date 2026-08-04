import { describe, expect, it } from 'vitest'
import {
  layoutJustifiedRows,
  type GalleryAspectItem,
} from '../../../desktop/src/renderer/pages/SessionDetail/justified-layout'

function photo(aspectRatio: number): GalleryAspectItem {
  return { width: aspectRatio * 1000, height: 1000 }
}

describe('layoutJustifiedRows', () => {
  it('places mixed landscape and portrait photos into one equal-height row', () => {
    const rows = layoutJustifiedRows(
      [photo(1.5), photo(2 / 3), photo(1.5), photo(1.5)],
      1000,
      220,
      8,
    )

    expect(rows).toHaveLength(1)
    expect(rows[0].justified).toBe(true)
    expect(rows[0].items.map((item) => item.index)).toEqual([0, 1, 2, 3])

    const occupiedWidth = rows[0].items.reduce((sum, item) => sum + item.width, 0)
      + 8 * (rows[0].items.length - 1)
    expect(occupiedWidth).toBeCloseTo(1000, 5)
    expect(rows[0].items[1].width).toBeLessThan(rows[0].items[0].width)
  })

  it('does not stretch an incomplete final row', () => {
    const rows = layoutJustifiedRows(
      [photo(1.5), photo(2 / 3)],
      1000,
      220,
      8,
    )

    expect(rows).toHaveLength(1)
    expect(rows[0].justified).toBe(false)
    expect(rows[0].height).toBe(220)

    const occupiedWidth = rows[0].items.reduce((sum, item) => sum + item.width, 0) + 8
    expect(occupiedWidth).toBeLessThan(1000)
  })

  it('preserves source order across multiple rows', () => {
    const source = [
      photo(1.5),
      photo(2 / 3),
      photo(1.2),
      photo(1.8),
      photo(0.75),
      photo(1.5),
      photo(1),
      photo(1.4),
    ]
    const rows = layoutJustifiedRows(source, 800, 180, 8)

    expect(rows.flatMap((row) => row.items.map((item) => item.index))).toEqual(
      source.map((_, index) => index),
    )
  })

  it('uses a stable square fallback for missing dimensions', () => {
    const rows = layoutJustifiedRows(
      [{ width: 0, height: 0 }],
      800,
      200,
      8,
    )

    expect(rows[0].height).toBe(200)
    expect(rows[0].items[0].width).toBe(200)
  })

  it('returns no rows until the container has a measurable width', () => {
    expect(layoutJustifiedRows([photo(1.5)], 0, 220, 8)).toEqual([])
  })
})
