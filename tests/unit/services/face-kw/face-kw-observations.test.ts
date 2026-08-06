import { afterEach, describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const mocks = vi.hoisted(() => ({
  analyzeImpl: {
    current: null as (() => Promise<{ observations: unknown[]; encodingFailures: number }>) | null,
  },
}))

vi.mock('../../../../desktop/src/main/services/face-kw/face-inference-worker-client', () => ({
  FaceInferenceWorker: class {
    async init() {}
    async analyze() {
      if (mocks.analyzeImpl.current) return mocks.analyzeImpl.current()
      throw new Error('no analyze impl')
    }
    async shutdown() {}
  },
}))

vi.mock('../../../../desktop/src/main/utils/analysis-worker-client', () => ({
  clusterFacesInWorker: vi.fn(async () => ({ clusters: [], noise: [] })),
}))

import { FaceKwService } from '../../../../desktop/src/main/services/face-kw/face-kw.service'
import type { FaceRepository } from '../../../../desktop/src/main/db/repositories/face.repo'
import type { SettingsService } from '../../../../desktop/src/main/services/settings/settings.service'
import type { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
import type { SessionRepository } from '../../../../desktop/src/main/db/repositories/session.repo'
import type { ImageService } from '../../../../desktop/src/main/services/image'

const tempDirs: string[] = []
const sessionId = 'session-1'

afterEach(() => {
  vi.restoreAllMocks()
  mocks.analyzeImpl.current = null
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

function createPhoto(filepath: string) {
  return {
    id: 'photo-1',
    session_id: sessionId,
    filepath,
    filename: path.basename(filepath),
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

function buildService(deps: {
  replaceObservationsByPhoto?: ReturnType<typeof vi.fn>
  deleteObservationsByPhoto?: ReturnType<typeof vi.fn>
  upsertAnalysisState?: ReturnType<typeof vi.fn>
}) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-face-kw-'))
  tempDirs.push(tempDir)
  const filepath = path.join(tempDir, 'photo.jpg')
  fs.writeFileSync(filepath, 'fake-image-bytes')

  const photoRepo = {
    getBySessionProjection: vi.fn(() => [createPhoto(filepath)]),
  } as unknown as PhotoRepository

  const sessionRepo = {
    get: vi.fn(() => ({ id: sessionId, status: 'pending' })),
    updateAnalysisStatus: vi.fn(),
  } as unknown as SessionRepository

  const faceRepo = {
    getObservations: vi.fn(() => [
      {
        id: 10,
        photo_id: 'photo-1',
        session_id: sessionId,
        embedding: Buffer.from(new Float32Array([0.1, 0.2, 0.3]).buffer),
        bbox_x: 1,
        bbox_y: 2,
        bbox_w: 3,
        bbox_h: 4,
        confidence: 0.9,
        source_file_size: 1,
        source_file_mtime_ms: 1,
        analysis_signature: 'old',
      },
    ]),
    getAnalysisStates: vi.fn(() => new Map()),
    reuseObservationsForAssetFile: vi.fn(() => ({ reused: false })),
    getClusterSignature: vi.fn(() => ''),
    getClusters: vi.fn(() => []),
    replaceObservationsByPhoto: deps.replaceObservationsByPhoto ?? vi.fn(() => []),
    deleteObservationsByPhoto: deps.deleteObservationsByPhoto ?? vi.fn(),
    upsertAnalysisState: deps.upsertAnalysisState ?? vi.fn(),
    upsertClusterSignature: vi.fn(),
    deleteClustersBySession: vi.fn(),
    saveClusters: vi.fn(() => []),
    getFaceThumbDir: vi.fn(() => tempDir),
    updateClusterThumbnail: vi.fn(),
  } as unknown as FaceRepository

  const imageService = {
    getPreview: vi.fn(async () => ({ buffer: Buffer.from('jpeg'), format: 'jpeg', width: 100, height: 80 })),
  } as unknown as ImageService

  const settings = {
    get: (_key: string, fallback: string) => fallback,
    getNumber: (_key: string, fallback: number) => fallback,
  } as unknown as SettingsService

  const service = new FaceKwService(
    photoRepo,
    sessionRepo,
    faceRepo,
    imageService,
    settings,
    {
      upsertByName: vi.fn(() => 'person-1'),
      addPhotos: vi.fn(),
    } as never,
  )
  return { service, faceRepo, sessionRepo, photoRepo }
}

describe('FaceKwService.analyze observation retention', () => {
  it('keeps previous observations when re-inference for a photo fails', async () => {
    const replace = vi.fn(() => [])
    const deleteObs = vi.fn()
    const upsertState = vi.fn()
    const { service } = buildService({
      replaceObservationsByPhoto: replace,
      deleteObservationsByPhoto: deleteObs,
      upsertAnalysisState: upsertState,
    })

    mocks.analyzeImpl.current = async () => {
      throw new Error('inference failed')
    }

    const result = await service.analyze(sessionId, 'det.onnx', 'enc.onnx')

    expect(result.status).toBe('failed')
    expect(result.detectionFailures).toBe(1)
    // Old observations must survive a failed inference.
    expect(replace).not.toHaveBeenCalled()
    expect(deleteObs).not.toHaveBeenCalled()
    expect(upsertState).not.toHaveBeenCalled()
  })

  it('replaces previous observations atomically after a successful inference', async () => {
    const replace = vi.fn(() => [1, 2])
    const deleteObs = vi.fn()
    const upsertState = vi.fn()
    const { service } = buildService({
      replaceObservationsByPhoto: replace,
      deleteObservationsByPhoto: deleteObs,
      upsertAnalysisState: upsertState,
    })

    mocks.analyzeImpl.current = async () => ({
      observations: [
        {
          bbox: [10, 20, 30, 40],
          embedding: [0.5, 0.6],
          confidence: 0.95,
        },
      ],
      encodingFailures: 0,
    })

    const result = await service.analyze(sessionId, 'det.onnx', 'enc.onnx')

    expect(result.status).toBe('done')
    expect(result.detectionFailures).toBe(0)
    expect(replace).toHaveBeenCalledTimes(1)
    expect(replace).toHaveBeenCalledWith(
      sessionId,
      'photo-1',
      expect.arrayContaining([
        expect.objectContaining({ photoId: 'photo-1', confidence: 0.95 }),
      ]),
    )
    expect(deleteObs).not.toHaveBeenCalled()
    expect(upsertState).toHaveBeenCalledTimes(1)
  })
})

describe('FaceKwService.bindCluster person-library bridging', () => {
  it('links a bound cluster into the person library (best-effort)', async () => {
    const personRepo = {
      upsertByName: vi.fn(() => 'person-1'),
      addPhotos: vi.fn(),
      reconcileSession: vi.fn(),
    }
    const faceRepo = {
      getClusterSessionId: vi.fn(() => sessionId),
      updateBinding: vi.fn(),
      getClusterMembers: vi.fn(() => [
        { photoId: 'photo-1', bbox: [1, 2, 3, 4], confidence: 0.9 },
        { photoId: 'photo-2', bbox: [5, 6, 7, 8], confidence: 0.8 },
      ]),
    } as never

    const service = new FaceKwService(
      { getBySession: vi.fn() } as never,
      { get: vi.fn() } as never,
      faceRepo,
      { getPreview: vi.fn() } as never,
      { get: vi.fn(), getNumber: vi.fn() } as never,
      personRepo,
    )

    await service.bindCluster(sessionId, 7, ' Alice ', ['kw1', 'kw1', ''])

    expect(faceRepo.updateBinding).toHaveBeenCalledWith(7, 'Alice', ['kw1'])
    expect(personRepo.upsertByName).toHaveBeenCalledWith('Alice', ['kw1'])
    expect(personRepo.addPhotos).toHaveBeenCalledWith('person-1', sessionId, [
      { photoId: 'photo-1', faceBbox: [1, 2, 3, 4], confidence: 0.9 },
      { photoId: 'photo-2', faceBbox: [5, 6, 7, 8], confidence: 0.8 },
    ])
  })

  it('keeps the binding when the person-library linkage fails', async () => {
    const personRepo = {
      upsertByName: vi.fn(() => {
        throw new Error('library unavailable')
      }),
      addPhotos: vi.fn(),
      reconcileSession: vi.fn(),
    }
    const faceRepo = {
      getClusterSessionId: vi.fn(() => sessionId),
      updateBinding: vi.fn(),
      getClusterMembers: vi.fn(() => []),
    } as never

    const service = new FaceKwService(
      { getBySession: vi.fn() } as never,
      { get: vi.fn() } as never,
      faceRepo,
      { getPreview: vi.fn() } as never,
      { get: vi.fn(), getNumber: vi.fn() } as never,
      personRepo,
    )

    await expect(service.bindCluster(sessionId, 7, 'Alice', ['kw1'])).resolves.toBeUndefined()

    expect(faceRepo.updateBinding).toHaveBeenCalledWith(7, 'Alice', ['kw1'])
    expect(personRepo.addPhotos).not.toHaveBeenCalled()
  })

  it('reconciles the person library after unbind', async () => {
    const personRepo = {
      upsertByName: vi.fn(() => 'person-1'),
      addPhotos: vi.fn(),
      reconcileSession: vi.fn(),
    }
    const faceRepo = {
      getClusterSessionId: vi.fn(() => sessionId),
      deleteBinding: vi.fn(),
    } as never

    const service = new FaceKwService(
      { getBySession: vi.fn() } as never,
      { get: vi.fn() } as never,
      faceRepo,
      { getPreview: vi.fn() } as never,
      { get: vi.fn(), getNumber: vi.fn() } as never,
      personRepo,
    )

    await service.unbindCluster(sessionId, 7)

    expect(faceRepo.deleteBinding).toHaveBeenCalledWith(7)
    expect(personRepo.reconcileSession).toHaveBeenCalledWith(sessionId)
  })

  it('keeps the unbind when reconciliation fails (best-effort)', async () => {
    const personRepo = {
      upsertByName: vi.fn(() => 'person-1'),
      addPhotos: vi.fn(),
      reconcileSession: vi.fn(() => {
        throw new Error('library unavailable')
      }),
    }
    const faceRepo = {
      getClusterSessionId: vi.fn(() => sessionId),
      deleteBinding: vi.fn(),
    } as never

    const service = new FaceKwService(
      { getBySession: vi.fn() } as never,
      { get: vi.fn() } as never,
      faceRepo,
      { getPreview: vi.fn() } as never,
      { get: vi.fn(), getNumber: vi.fn() } as never,
      personRepo,
    )

    await expect(service.unbindCluster(sessionId, 7)).resolves.toBeUndefined()

    expect(faceRepo.deleteBinding).toHaveBeenCalledWith(7)
  })
})
