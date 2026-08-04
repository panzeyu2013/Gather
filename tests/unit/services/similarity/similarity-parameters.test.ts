import { describe, expect, it } from 'vitest'
import {
  collapseSimilarityAssets,
  validateSimilarityParameters,
} from '../../../../desktop/src/main/services/similarity/similarity.service'

describe('similarity parameter validation', () => {
  it.each([
    [Number.NaN, 2],
    [-1, 2],
    [65, 2],
    [10.5, 2],
    [10, 1],
    [10, 2.5],
  ])('rejects invalid threshold=%s minGroupSize=%s', (threshold, minGroupSize) => {
    expect(() => validateSimilarityParameters(threshold, minGroupSize)).toThrow()
  })

  it('accepts the full dHash threshold range and a valid group size', () => {
    expect(() => validateSimilarityParameters(0, 2)).not.toThrow()
    expect(() => validateSimilarityParameters(64, 10)).not.toThrow()
  })

  it('analyzes one representative per linked RAW/JPEG asset', () => {
    const rows = [
      { id: 'jpeg', asset_id: 'asset', filename: 'A001.JPG' },
      { id: 'raw', asset_id: 'asset', filename: 'A001.NEF' },
      { id: 'standalone', asset_id: null, filename: 'A002.JPG' },
    ] as never

    expect(collapseSimilarityAssets(rows).map(photo => photo.id)).toEqual([
      'raw',
      'standalone',
    ])
  })
})
