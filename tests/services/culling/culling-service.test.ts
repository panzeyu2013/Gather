import { describe, expect, it, vi } from 'vitest'
import { CullingService } from '../../../desktop/src/main/services/culling/culling.service'

describe('CullingService batch decisions', () => {
  it('loads photos and materializes similarity membership only once for a batch', () => {
    const photoRepo = {
      getBySession: vi.fn(() => [
        { id: 'p1', filepath: '/a.jpg' },
        { id: 'p2', filepath: '/b.jpg' },
      ]),
    }
    const cullingRepo = {
      getDecision: vi.fn(() => undefined),
      getByPhotoIds: vi.fn(() => []),
      upsertState: vi.fn(),
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
    const metadataCacheRepo = {
      getBatch: vi.fn(() => []),
      updateRating: vi.fn(),
      updateLabel: vi.fn(),
    }
    const outboxRepo = {
      get: vi.fn(() => null),
      mergePatch: vi.fn(),
    }
    const db = {
      transaction: vi.fn((operation: () => void) => operation),
    }
    const metadataSync = { schedule: vi.fn() }
    const settings = { getNumber: vi.fn((_key: string, fallback: number) => fallback) }
    const service = new CullingService(
      photoRepo as never,
      cullingRepo as never,
      similarityRepo as never,
      metadataCacheRepo as never,
      outboxRepo as never,
      db as never,
      metadataSync as never,
      { queuePhotoValues: vi.fn() } as never,
      settings as never,
    )

    service.batchDecide('session', ['p1', 'p2'], 'keep')

    expect(photoRepo.getBySession).toHaveBeenCalledTimes(1)
    expect(similarityRepo.getLatest).toHaveBeenCalledTimes(1)
    expect(similarityRepo.getPhotoGroupMap).toHaveBeenCalledTimes(1)
    expect(cullingRepo.upsertState).toHaveBeenNthCalledWith(
      1,
      'session',
      'p1',
      '9:0',
      expect.objectContaining({ decision: 'keep', revision: 1 }),
    )
    expect(cullingRepo.upsertState).toHaveBeenNthCalledWith(
      2,
      'session',
      'p2',
      '9:0',
      expect.objectContaining({ decision: 'keep', revision: 1 }),
    )
  })

  it('coalesces shared RAW/JPEG metadata into one XMP operation', () => {
    const photoRepo = {
      getBySession: vi.fn(() => [
        { id: 'raw', filepath: '/shoot/A001.NEF' },
        { id: 'jpeg', filepath: '/shoot/A001.jpg' },
      ]),
    }
    const cullingRepo = {
      getDecision: vi.fn(() => undefined),
      getByPhotoIds: vi.fn(() => []),
      upsertState: vi.fn(),
    }
    const similarityRepo = {
      getLatest: vi.fn(() => null),
    }
    const metadataCacheRepo = {
      getBatch: vi.fn(() => []),
      updateRating: vi.fn(),
      updateLabel: vi.fn(),
    }
    const outboxRepo = {
      get: vi.fn(() => ({ status: 'pending' })),
      mergePatch: vi.fn(),
    }
    const db = {
      transaction: vi.fn((operation: () => void) => operation),
    }
    const metadataSync = { schedule: vi.fn() }
    const metadataMutations = { queuePhotoValues: vi.fn() }
    const settings = { getNumber: vi.fn((_key: string, fallback: number) => fallback) }
    const service = new CullingService(
      photoRepo as never,
      cullingRepo as never,
      similarityRepo as never,
      metadataCacheRepo as never,
      outboxRepo as never,
      db as never,
      metadataSync as never,
      metadataMutations as never,
      settings as never,
    )

    const results = service.batchUpdate('session', ['raw', 'jpeg'], { rating: 5 })

    expect(results).toHaveLength(1)
    expect(cullingRepo.upsertState).toHaveBeenCalledTimes(2)
    expect(metadataMutations.queuePhotoValues).toHaveBeenCalledTimes(1)
  })

  it('coalesces pick updates for two variants of the same asset', () => {
    const photoRepo = {
      getBySession: vi.fn(() => [
        { id: 'raw', filepath: '/shoot/A001.NEF', asset_id: 'asset-1' },
        { id: 'jpeg', filepath: '/shoot/A001.jpg', asset_id: 'asset-1' },
      ]),
    }
    const cullingRepo = {
      getDecision: vi.fn(() => undefined),
      getByPhotoIds: vi.fn(() => []),
      upsertState: vi.fn(),
    }
    const service = new CullingService(
      photoRepo as never,
      cullingRepo as never,
      { getLatest: vi.fn(() => null) } as never,
      { getBatch: vi.fn(() => []) } as never,
      { get: vi.fn(() => null) } as never,
      { transaction: vi.fn((operation: () => unknown) => operation) } as never,
      { schedule: vi.fn() } as never,
      { queuePhotoValues: vi.fn() } as never,
      { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
    )

    const results = service.batchUpdate(
      'session',
      ['raw', 'jpeg'],
      { pickState: 'picked' },
    )

    expect(results).toHaveLength(1)
    expect(cullingRepo.upsertState).toHaveBeenCalledTimes(2)
  })

  it('atomically keeps an arbitrary K selection and rejects the rest of the similarity group', () => {
    const photos = ['p1', 'p2', 'p3', 'p4'].map(id => ({
      id,
      filepath: `/${id}.jpg`,
    }))
    const photoRepo = {
      getBySession: vi.fn(() => photos),
    }
    const cullingRepo = {
      getDecision: vi.fn(() => undefined),
      getByPhotoIds: vi.fn(() => []),
      upsertState: vi.fn(),
    }
    const similarityRepo = {
      getLatest: vi.fn(() => ({ id: 12 })),
      getPhotoGroupMap: vi.fn(() => new Map(
        photos.map(photo => [photo.id, '12:0']),
      )),
    }
    const metadataCacheRepo = {
      getBatch: vi.fn(() => []),
      updateRating: vi.fn(),
      updateLabel: vi.fn(),
    }
    const outboxRepo = {
      get: vi.fn(() => null),
      mergePatch: vi.fn(),
    }
    const db = {
      transaction: vi.fn((operation: () => unknown) => operation),
    }
    const service = new CullingService(
      photoRepo as never,
      cullingRepo as never,
      similarityRepo as never,
      metadataCacheRepo as never,
      outboxRepo as never,
      db as never,
      { schedule: vi.fn() } as never,
      { queuePhotoValues: vi.fn() } as never,
      { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
    )

    const results = service.decideSimilarityGroup(
      'session',
      '12:0',
      ['p1', 'p3'],
    )

    expect(results).toHaveLength(4)
    expect(cullingRepo.upsertState).toHaveBeenCalledWith(
      'session',
      'p1',
      '12:0',
      expect.objectContaining({ decision: 'keep' }),
    )
    expect(cullingRepo.upsertState).toHaveBeenCalledWith(
      'session',
      'p3',
      '12:0',
      expect.objectContaining({ decision: 'keep' }),
    )
    expect(cullingRepo.upsertState).toHaveBeenCalledWith(
      'session',
      'p2',
      '12:0',
      expect.objectContaining({ decision: 'reject' }),
    )
    expect(cullingRepo.upsertState).toHaveBeenCalledWith(
      'session',
      'p4',
      '12:0',
      expect.objectContaining({ decision: 'reject' }),
    )
  })

  it('rejects stale photo ids instead of silently applying a partial batch', () => {
    const service = new CullingService(
      { getBySession: vi.fn(() => [{ id: 'known', filepath: '/known.jpg' }]) } as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
      {} as never,
    )

    expect(() => service.batchUpdate(
      'session',
      ['known', 'stale'],
      { rating: 5 },
    )).toThrow('部分照片不属于当前工作区')
  })
})
