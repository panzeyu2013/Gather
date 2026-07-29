import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import { WritebackService } from '../../../desktop/src/main/services/writeback/writeback.service'
import { XmpSidecarWriter, getXmpSidecarPath } from '../../../desktop/src/main/services/xmp/xmp-sidecar-writer'
import { writeXmpAttributes } from '../../../desktop/src/main/services/xmp/xmp-utils'
import type { WritebackItemInput, WritebackItemRow } from '../../../desktop/src/main/db/repositories/writeback.repo'
import type { WritebackRepository } from '../../../desktop/src/main/db/repositories/writeback.repo'
import type { MetadataWriterRouter } from '../../../desktop/src/main/services/xmp/metadata-writer-router'
import type { PhotoRepository } from '../../../desktop/src/main/db/repositories/photo.repo'
import type { SessionRepository } from '../../../desktop/src/main/db/repositories/session.repo'
import type { MetadataCacheRepository } from '../../../desktop/src/main/db/repositories/metadata-cache.repo'

function makeRepo() {
  let rows: WritebackItemRow[] = []
  let nextId = 1
  return {
    saveItems(sessionId: string, module: string, items: WritebackItemInput[]) {
      rows = rows.filter(row => !(
        row.session_id === sessionId &&
        row.module === module &&
        (row.xmp_status === 'pending' || row.xmp_status === 'failed')
      ))
      rows.push(...items.map(item => ({
        id: nextId++,
        photo_id: item.photoId,
        photo_path: item.photoPath,
        session_id: sessionId,
        module,
        keywords: JSON.stringify(item.keywords),
        attributes_json: JSON.stringify(item.attributes ?? {}),
        xmp_path: item.xmpPath,
        backup_path: item.backupPath,
        xmp_status: 'pending',
        error_message: '',
        attempt_count: 1,
        last_attempt_at: '',
      })))
    },
    getItems(sessionId: string, module?: string, status?: string) {
      return rows.filter(row =>
        row.session_id === sessionId &&
        (!module || row.module === module) &&
        (!status || row.xmp_status === status),
      )
    },
    getItem(itemId: number) {
      return rows.find(row => row.id === itemId)
    },
    updateStatus(itemId: number, status: string, error = '') {
      const row = rows.find(candidate => candidate.id === itemId)
      if (row) {
        row.xmp_status = status
        row.error_message = error
      }
    },
    updateBackupPath(itemId: number, backupPath: string) {
      const row = rows.find(candidate => candidate.id === itemId)
      if (row) row.backup_path = backupPath
    },
    updateKeywords(itemId: number, keywords: string[]) {
      const row = rows.find(candidate => candidate.id === itemId)
      if (row) row.keywords = JSON.stringify(keywords)
    },
    updateAttributes: vi.fn(),
    getFailedCount(sessionId: string, module?: string) {
      return rows.filter(row =>
        row.session_id === sessionId &&
        row.xmp_status === 'failed' &&
        (!module || row.module === module),
      ).length
    },
    markWrittenAsSynced(sessionId: string, module: string) {
      for (const row of rows) {
        if (row.session_id === sessionId && row.module === module && row.xmp_status === 'written') {
          row.xmp_status = 'synced'
        }
      }
    },
    updateStatusByXmpPath(sessionId: string, module: string, xmpPath: string, status: string) {
      for (const row of rows) {
        if (row.session_id === sessionId && row.module === module && row.xmp_path === xmpPath) {
          row.xmp_status = status
        }
      }
    },
    deleteItems(sessionId: string, module?: string) {
      rows = rows.filter(row =>
        row.session_id !== sessionId || (module !== undefined && row.module !== module),
      )
    },
  }
}

describe('WritebackService sidecar workflow', () => {
  let dir: string

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(fs.realpathSync('/tmp'), 'writeback-test-'))
  })

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true })
  })

  it('merges keywords, ignores renderer keyword changes, and restores the original sidecar after sync', async () => {
    const photoPath = path.join(dir, 'IMG_0001.NEF')
    const xmpPath = getXmpSidecarPath(photoPath)
    writeXmpAttributes(xmpPath, { keywords: ['existing'] })

    const repo = makeRepo()
    const writer = new XmpSidecarWriter()
    const sessionRepo = {
      updateWritebackStatus: vi.fn(),
      updateFailedWritebackCount: vi.fn(),
    }
    const service = new WritebackService(
      repo as unknown as WritebackRepository,
      { selectSidecar: () => writer } as unknown as MetadataWriterRouter,
      {
        getBySession: () => [{
          id: 'photo-1',
          session_id: 'session-1',
          filepath: photoPath,
          filename: path.basename(photoPath),
        }],
      } as unknown as PhotoRepository,
      sessionRepo as unknown as SessionRepository,
      {
        updateKeywords: vi.fn(),
        updateRating: vi.fn(),
        updateLabel: vi.fn(),
      } as unknown as MetadataCacheRepository,
    )

    const preview = await service.preview(
      'session-1',
      'similarity',
      {},
      new Set(['photo-1']),
      new Map([['photo-1', ['portrait']]]),
    )
    expect(preview.items[0].keywords).toEqual(['existing', 'portrait'])
    expect(preview.items[0].xmpPath).toBe(xmpPath)

    const result = await service.execute('session-1', 'similarity', [{
      ...preview.items[0],
      keywords: ['forged-renderer-value'],
    }])
    expect(result).toMatchObject({ written: 1, failed: 0 })
    expect(await writer.readKeywords(photoPath)).toEqual(['existing', 'portrait'])

    const repeatedPreview = await service.preview(
      'session-1',
      'similarity',
      {},
      new Set(['photo-1']),
      new Map([['photo-1', ['second-write']]]),
    )
    await service.execute('session-1', 'similarity', repeatedPreview.items)
    expect(await writer.readKeywords(photoPath)).toEqual(['existing', 'portrait', 'second-write'])

    await service.confirmSync('session-1', 'similarity')
    const cleanup = await service.cleanup('session-1', 'similarity')
    expect(cleanup.errors).toEqual([])
    expect(await writer.readKeywords(photoPath)).toEqual(['existing'])
    expect(sessionRepo.updateWritebackStatus).toHaveBeenLastCalledWith('session-1', 'cleaned')
  })

  it('removes a newly created sidecar only after sync confirmation', async () => {
    const photoPath = path.join(dir, 'IMG_0002.JPG')
    const repo = makeRepo()
    const writer = new XmpSidecarWriter()
    const service = new WritebackService(
      repo as unknown as WritebackRepository,
      { selectSidecar: () => writer } as unknown as MetadataWriterRouter,
      {
        getBySession: () => [{
          id: 'photo-2',
          session_id: 'session-2',
          filepath: photoPath,
          filename: path.basename(photoPath),
        }],
      } as unknown as PhotoRepository,
      {
        updateWritebackStatus: vi.fn(),
        updateFailedWritebackCount: vi.fn(),
      } as unknown as SessionRepository,
      {
        updateKeywords: vi.fn(),
        updateRating: vi.fn(),
        updateLabel: vi.fn(),
      } as unknown as MetadataCacheRepository,
    )

    const preview = await service.preview(
      'session-2',
      'face_kw',
      {},
      new Set(['photo-2']),
      new Map([['photo-2', ['Alice']]]),
    )
    await service.execute('session-2', 'face_kw', preview.items)
    const repeatedPreview = await service.preview(
      'session-2',
      'face_kw',
      {},
      new Set(['photo-2']),
      new Map([['photo-2', ['Bob']]]),
    )
    await service.execute('session-2', 'face_kw', repeatedPreview.items)
    await expect(service.cleanup('session-2', 'face_kw')).rejects.toThrow('Capture One')

    await service.confirmSync('session-2', 'face_kw')
    await service.cleanup('session-2', 'face_kw')
    expect(fs.existsSync(getXmpSidecarPath(photoPath))).toBe(false)
  })

  it('replaces stale failed items when a new preview is generated', async () => {
    const photoPath = path.join(dir, 'IMG_FAILED.NEF')
    const repo = makeRepo()
    const writer = new XmpSidecarWriter()
    const service = new WritebackService(
      repo as unknown as WritebackRepository,
      { selectSidecar: () => writer } as unknown as MetadataWriterRouter,
      {
        getBySession: () => [{
          id: 'photo-failed',
          session_id: 'session-failed',
          filepath: photoPath,
          filename: path.basename(photoPath),
        }],
      } as unknown as PhotoRepository,
      {
        updateWritebackStatus: vi.fn(),
        updateFailedWritebackCount: vi.fn(),
      } as unknown as SessionRepository,
      {
        updateKeywords: vi.fn(),
        updateRating: vi.fn(),
        updateLabel: vi.fn(),
      } as unknown as MetadataCacheRepository,
    )

    const first = await service.preview(
      'session-failed',
      'similarity',
      {},
      new Set(['photo-failed']),
      new Map([['photo-failed', ['old-keyword']]]),
    )
    repo.updateStatus(first.items[0].id!, 'failed', 'simulated')

    const second = await service.preview(
      'session-failed',
      'similarity',
      {},
      new Set(['photo-failed']),
      new Map([['photo-failed', ['new-keyword']]]),
    )
    expect(second.items).toHaveLength(1)
    expect(second.items[0].keywords).toEqual(['new-keyword'])
    expect(repo.getItems('session-failed', 'similarity', 'failed')).toHaveLength(0)
  })

  it('creates one writeback item when RAW and JPEG share a Capture One sidecar', async () => {
    const rawPath = path.join(dir, 'IMG_0003.NEF')
    const jpegPath = path.join(dir, 'IMG_0003.JPG')
    const repo = makeRepo()
    const writer = new XmpSidecarWriter()
    const service = new WritebackService(
      repo as unknown as WritebackRepository,
      { selectSidecar: () => writer } as unknown as MetadataWriterRouter,
      {
        getBySession: () => [
          { id: 'raw', session_id: 'session-3', filepath: rawPath, filename: path.basename(rawPath) },
          { id: 'jpeg', session_id: 'session-3', filepath: jpegPath, filename: path.basename(jpegPath) },
        ],
      } as unknown as PhotoRepository,
      {
        updateWritebackStatus: vi.fn(),
        updateFailedWritebackCount: vi.fn(),
      } as unknown as SessionRepository,
      {
        updateKeywords: vi.fn(),
        updateRating: vi.fn(),
        updateLabel: vi.fn(),
      } as unknown as MetadataCacheRepository,
    )

    const preview = await service.preview(
      'session-3',
      'similarity',
      {},
      new Set(['raw', 'jpeg']),
      new Map([['raw', ['raw-keyword']], ['jpeg', ['jpeg-keyword']]]),
    )

    expect(preview.affectedPhotos).toBe(2)
    expect(preview.items).toHaveLength(1)
    expect(preview.items[0].keywords).toEqual(['raw-keyword', 'jpeg-keyword'])
  })

  it('keeps confirmation and cleanup isolated to the requested module', async () => {
    const photoPath = path.join(dir, 'IMG_0004.NEF')
    const repo = makeRepo()
    const writer = new XmpSidecarWriter()
    const sessionRepo = {
      updateWritebackStatus: vi.fn(),
      updateFailedWritebackCount: vi.fn(),
    }
    const service = new WritebackService(
      repo as unknown as WritebackRepository,
      { selectSidecar: () => writer } as unknown as MetadataWriterRouter,
      {
        getBySession: () => [{
          id: 'photo-4',
          session_id: 'session-4',
          filepath: photoPath,
          filename: path.basename(photoPath),
        }],
      } as unknown as PhotoRepository,
      sessionRepo as unknown as SessionRepository,
      {
        updateKeywords: vi.fn(),
        updateRating: vi.fn(),
        updateLabel: vi.fn(),
      } as unknown as MetadataCacheRepository,
    )

    const similarityPreview = await service.preview(
      'session-4',
      'similarity',
      {},
      new Set(['photo-4']),
      new Map([['photo-4', ['similar']]]),
    )
    repo.saveItems('session-4', 'face_kw', [{
      photoId: 'photo-4',
      photoPath,
      module: 'face_kw',
      keywords: ['Alice'],
      xmpPath: getXmpSidecarPath(photoPath),
      backupPath: '',
    }])
    await service.execute('session-4', 'similarity', similarityPreview.items)
    await service.confirmSync('session-4', 'similarity')

    expect(repo.getItems('session-4', 'similarity', 'synced')).toHaveLength(1)
    expect(repo.getItems('session-4', 'face_kw', 'pending')).toHaveLength(1)

    await service.cleanup('session-4', 'similarity')
    expect(repo.getItems('session-4', 'similarity')).toHaveLength(0)
    expect(repo.getItems('session-4', 'face_kw', 'pending')).toHaveLength(1)
  })

  it('does not process an already restored sidecar again after partial cleanup failure', async () => {
    const firstPhotoPath = path.join(dir, 'IMG_0005.NEF')
    const secondPhotoPath = path.join(dir, 'IMG_0006.NEF')
    writeXmpAttributes(getXmpSidecarPath(firstPhotoPath), { keywords: ['first-original'] })
    writeXmpAttributes(getXmpSidecarPath(secondPhotoPath), { keywords: ['second-original'] })

    const repo = makeRepo()
    const writer = new XmpSidecarWriter()
    let failSecondRestore = true
    const router = {
      selectSidecar: () => ({
        readKeywords: (photoPath: string) => writer.readKeywords(photoPath),
        readAttributes: (photoPath: string) => writer.readAttributes(photoPath),
        writeAttributes: (photoPath: string, attributes: Parameters<XmpSidecarWriter['writeAttributes']>[1]) =>
          writer.writeAttributes(photoPath, attributes),
        backup: (photoPath: string) => writer.backup(photoPath),
        getBackupPath: (photoPath: string) => writer.getBackupPath(photoPath),
        restore: async (photoPath: string, backupPath: string) => {
          if (photoPath === secondPhotoPath && failSecondRestore) {
            throw new Error('simulated restore failure')
          }
          await writer.restore(photoPath, backupPath)
        },
        supportsFormat: () => true,
        shutdown: () => Promise.resolve(),
      }),
    }
    const service = new WritebackService(
      repo as unknown as WritebackRepository,
      router as unknown as MetadataWriterRouter,
      {
        getBySession: () => [
          { id: 'photo-5', session_id: 'session-5', filepath: firstPhotoPath, filename: 'IMG_0005.NEF' },
          { id: 'photo-6', session_id: 'session-5', filepath: secondPhotoPath, filename: 'IMG_0006.NEF' },
        ],
      } as unknown as PhotoRepository,
      {
        updateWritebackStatus: vi.fn(),
        updateFailedWritebackCount: vi.fn(),
      } as unknown as SessionRepository,
      {
        updateKeywords: vi.fn(),
        updateRating: vi.fn(),
        updateLabel: vi.fn(),
      } as unknown as MetadataCacheRepository,
    )

    const preview = await service.preview(
      'session-5',
      'similarity',
      {},
      new Set(['photo-5', 'photo-6']),
      new Map([['photo-5', ['first-new']], ['photo-6', ['second-new']]]),
    )
    await service.execute('session-5', 'similarity', preview.items)
    await service.confirmSync('session-5', 'similarity')

    const firstCleanup = await service.cleanup('session-5', 'similarity')
    expect(firstCleanup.errors).toHaveLength(1)
    expect(await writer.readKeywords(firstPhotoPath)).toEqual(['first-original'])
    expect(repo.getItems('session-5', 'similarity', 'cleaned')).toHaveLength(1)

    failSecondRestore = false
    const secondCleanup = await service.cleanup('session-5', 'similarity')
    expect(secondCleanup.errors).toEqual([])
    expect(await writer.readKeywords(firstPhotoPath)).toEqual(['first-original'])
    expect(await writer.readKeywords(secondPhotoPath)).toEqual(['second-original'])
  })
})
