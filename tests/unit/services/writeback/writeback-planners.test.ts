import { describe, expect, it } from 'vitest'
import {
  buildCullingWritebackPlan,
  buildSimilarityKeywordPlan,
} from '../../../../desktop/src/main/services/writeback/writeback-planners'

describe('writeback planners', () => {
  it('maps culling decisions to XMP attributes without IPC knowledge', () => {
    const plan = buildCullingWritebackPlan([
      { photo_id: 'keep', decision: 'keep' },
      { photo_id: 'reject', decision: 'reject' },
      { photo_id: 'pending', decision: 'pending' },
    ], 'rating')

    expect(plan).toEqual(new Map([
      ['keep', { rating: 5 }],
      ['reject', { rating: 1 }],
    ]))
  })

  it('merges keywords for photos sharing one Capture One sidecar', () => {
    const result = buildSimilarityKeywordPlan([
      {
        id: 1,
        label: 'one',
        count: 2,
        images: [
          { path: '/photos/IMG_1.NEF', representative: true },
          { path: '/photos/IMG_1.jpg', representative: false },
        ],
      },
    ], [{ groupId: 1, keywords: ['portrait'] }])

    expect(result.keywordsBySidecar.get('/photos/IMG_1.xmp')).toEqual(['portrait'])
    expect(result.affectedPaths.size).toBe(2)
  })
})
