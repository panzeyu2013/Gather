import { afterEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  clusterResult: {
    current: null as {
      clusters: Array<Array<{ observationId: number; embedding: number[]; photoId: string }>>
      noise: unknown[]
    } | null,
  },
}))

vi.mock('../../../../desktop/src/main/utils/analysis-worker-client', () => ({
  clusterFacesInWorker: vi.fn(async () => {
    if (mocks.clusterResult.current) return mocks.clusterResult.current
    return { clusters: [], noise: [] }
  }),
}))

import { FaceKwService } from '../../../../desktop/src/main/services/face-kw/face-kw.service'
import type { FaceRepository } from '../../../../desktop/src/main/db/repositories/face.repo'
import type { SettingsService } from '../../../../desktop/src/main/services/settings/settings.service'
import type { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
import type { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import type { ImageService } from '../../../../desktop/src/main/services/image'

const sessionId = 'session-1'

function embeddingBuffer() {
  return Buffer.from(new Float32Array([0.1, 0.2, 0.3]).buffer)
}

function observation(id: number, photoId: string) {
  return {
    id,
    photo_id: photoId,
    session_id: sessionId,
    embedding: embeddingBuffer(),
    bbox_x: 1,
    bbox_y: 2,
    bbox_w: 3,
    bbox_h: 4,
    confidence: 0.9,
    source_file_size: 1,
    source_file_mtime_ms: 1,
    analysis_signature: 'sig',
  }
}

function photo(id: string) {
  return {
    id,
    session_id: sessionId,
    filepath: `/photos/${id}.jpg`,
    filename: `${id}.jpg`,
    checksum: 'x',
    checksum_file_size: 1,
    checksum_file_mtime_ms: 1,
    status: 'pending',
    metadata: '{}',
    result: '{}',
    asset_id: null,
    asset_file_id: null,
    width: 100,
    height: 80,
    created_at: '',
    updated_at: '',
  }
}

function buildService(faceRepoOverrides: Record<string, unknown>) {
  const faceRepo = {
    getObservations: vi.fn(() => [observation(10, 'p1'), observation(11, 'p2')]),
    getBindingsBySession: vi.fn(() => []),
    deleteClustersBySession: vi.fn(),
    saveClusters: vi.fn(() => []),
    updateBinding: vi.fn(),
    upsertClusterSignature: vi.fn(),
    ...faceRepoOverrides,
  } as unknown as FaceRepository

  const service = new FaceKwService(
    { getBySessionProjection: vi.fn(() => [photo('p1'), photo('p2')]) } as unknown as PhotoRepository,
    { get: vi.fn(() => ({ id: sessionId, status: 'pending' })) } as unknown as SessionRepository,
    faceRepo,
    { getPreview: vi.fn() } as unknown as ImageService,
    { get: vi.fn(), getNumber: vi.fn() } as unknown as SettingsService,
    {} as never,
    {} as never,
  )
  return { service, faceRepo }
}

afterEach(() => {
  vi.restoreAllMocks()
  mocks.clusterResult.current = null
})

describe('FaceKwService binding migration across re-clustering', () => {
  it('re-attaches a binding to the new cluster with the largest member overlap', async () => {
    const updateBinding = vi.fn()
    const saveClusters = vi.fn(() => [100, 101])
    const { service } = buildService({
      getBindingsBySession: vi.fn(() => [{
        clusterId: 7,
        roleName: 'Alice',
        keywords: ['kw'],
        memberPhotoIds: ['p1', 'p2'],
      }]),
      saveClusters,
      updateBinding,
    })
    mocks.clusterResult.current = {
      clusters: [
        // New cluster 100 keeps both of Alice's observations.
        [
          { observationId: 10, embedding: [0.1, 0.2, 0.3], photoId: 'p1' },
          { observationId: 11, embedding: [0.1, 0.2, 0.3], photoId: 'p2' },
        ],
        // New cluster 101 is a stranger.
        [
          { observationId: 12, embedding: [0.4, 0.5, 0.6], photoId: 'p3' },
        ],
      ],
      noise: [],
    }

    await service.recluster(sessionId, 0.6, 2)

    expect(saveClusters).toHaveBeenCalled()
    expect(updateBinding).toHaveBeenCalledWith(100, 'Alice', ['kw'])
  })

  it('lets the binding with the larger overlap win when two compete for one cluster', async () => {
    const updateBinding = vi.fn()
    const { service } = buildService({
      getBindingsBySession: vi.fn(() => [
        { clusterId: 1, roleName: 'Alice', keywords: [], memberPhotoIds: ['p1', 'p3'] },
        { clusterId: 2, roleName: 'Bob', keywords: [], memberPhotoIds: ['p2', 'p4'] },
      ]),
      saveClusters: vi.fn(() => [100]),
      updateBinding,
    })
    mocks.clusterResult.current = {
      clusters: [
        // New cluster 100 absorbs Alice (10, 12) and Bob (11) but Bob's
        // second observation vanished, so Alice's overlap of 2 wins.
        [
          { observationId: 10, embedding: [0.1, 0.2, 0.3], photoId: 'p1' },
          { observationId: 11, embedding: [0.1, 0.2, 0.3], photoId: 'p2' },
          { observationId: 12, embedding: [0.1, 0.2, 0.3], photoId: 'p3' },
        ],
      ],
      noise: [],
    }

    await service.recluster(sessionId, 0.6, 2)

    expect(updateBinding).toHaveBeenCalledTimes(1)
    expect(updateBinding).toHaveBeenCalledWith(100, 'Alice', [])
  })

  it('drops a binding whose faces vanished from the new result', async () => {
    const updateBinding = vi.fn()
    const { service } = buildService({
      getBindingsBySession: vi.fn(() => [{
        clusterId: 7,
        roleName: 'Alice',
        keywords: ['kw'],
        memberPhotoIds: ['p1'],
      }]),
      saveClusters: vi.fn(() => [100]),
      updateBinding,
    })
    mocks.clusterResult.current = {
      clusters: [
        [
          { observationId: 11, embedding: [0.4, 0.5, 0.6], photoId: 'p2' },
        ],
      ],
      noise: [],
    }

    await service.recluster(sessionId, 0.6, 2)

    expect(updateBinding).not.toHaveBeenCalled()
  })
})
