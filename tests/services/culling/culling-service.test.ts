import { describe, expect, it, vi } from 'vitest'
import { CullingService } from '../../../desktop/src/main/services/culling/culling.service'

describe('CullingService batch decisions', () => {
  it('loads and materializes group membership only once for a batch', () => {
    const photoRepo = {
      getBySession: vi.fn(() => [
        { id: 'p1', filepath: '/a.jpg' },
        { id: 'p2', filepath: '/b.jpg' },
      ]),
    }
    const cullingRepo = {
      upsertMany: vi.fn(),
    }
    const similarityRepo = {
      getLatest: vi.fn(() => ({
        id: 9,
        groups_json: JSON.stringify({
          groups: [{ images: [{ path: '/a.jpg' }, { path: '/b.jpg' }] }],
        }),
      })),
      getPhotoGroupMap: vi.fn(() => new Map([
        ['p1', '9:0'],
        ['p2', '9:0'],
      ])),
    }
    const service = new CullingService(
      photoRepo as never,
      cullingRepo as never,
      similarityRepo as never,
    )

    service.batchDecide('session', ['p1', 'p2'], 'keep')

    expect(similarityRepo.getLatest).toHaveBeenCalledTimes(1)
    expect(similarityRepo.getPhotoGroupMap).toHaveBeenCalledTimes(1)
    expect(cullingRepo.upsertMany).toHaveBeenCalledWith('session', [
      { photoId: 'p1', groupId: '9:0', decision: 'keep' },
      { photoId: 'p2', groupId: '9:0', decision: 'keep' },
    ])
  })
})
