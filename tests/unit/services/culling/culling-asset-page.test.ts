import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'
import type { Database } from '../../../../desktop/src/main/db/database'
import { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'
import { CullingService } from '../../../../desktop/src/main/services/culling/culling.service'

const NOW = '2025-01-01T00:00:00.000Z'

const databases: BetterSqlite3.Database[] = []

interface Fixture {
  db: BetterSqlite3.Database
  service: CullingService
  photoRepo: PhotoRepository
  decisions: ReturnType<typeof vi.fn>
  cullingRepo: { getByPhotoIds: ReturnType<typeof vi.fn>; getBySession: ReturnType<typeof vi.fn> }
}

function fixture(): Fixture {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  // Foreign keys stay ON: the fixture seeds the referenced sessions/assets/
  // asset_files rows so a service regression that produces FK-invalid writes
  // fails the tests instead of being masked.
  db.exec(SCHEMA_SQL)
  db.prepare(`
    INSERT INTO sessions (id, name, status, analysis_status, writeback_status,
      import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
    VALUES ('s', '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
  `).run(NOW, NOW)
  db.prepare(`
    INSERT INTO assets (id, status, created_at, updated_at)
    VALUES ('asset-1', 'active', ?, ?)
  `).run(NOW, NOW)
  const insertFile = db.prepare(`
    INSERT INTO asset_files (id, volume_id, normalized_path, filename, extension,
      media_type, file_size, file_mtime_ms, online_status, created_at, updated_at)
    VALUES (?, 'vol-1', ?, ?, ?, 'raw', 1024, 1000, 'online', ?, ?)
  `)
  for (const fileId of ['af-raw', 'af-jpeg', 'af-bad', 'af-mixed', 'af-good']) {
    insertFile.run(fileId, `/shoot/${fileId}.nef`, `${fileId}.nef`, '.nef', NOW, NOW)
  }
  const database = {
    prepare: (sql: string) => db.prepare(sql),
    transaction: (operation: (...args: never[]) => unknown) => db.transaction(operation),
  } as unknown as Database
  const photoRepo = new PhotoRepository(database)
  const decisions = vi.fn(() => [])
  const cullingRepo = {
    getByPhotoIds: decisions,
    getBySession: vi.fn(() => []),
    getDecision: vi.fn(() => undefined),
    upsertState: vi.fn(),
  }
  const service = new CullingService(
    photoRepo,
    cullingRepo as never,
    { getLatest: vi.fn(() => undefined), getPhotoGroupMap: vi.fn(() => new Map()) } as never,
    { getBatch: vi.fn(() => []), updateRating: vi.fn(), updateLabel: vi.fn() } as never,
    { get: vi.fn(() => null), getBySession: vi.fn(() => []) } as never,
    database as never,
    { schedule: vi.fn() } as never,
    { queuePhotoValues: vi.fn() } as never,
    { getNumber: vi.fn(() => 640) } as never,
  )
  return { db, service, photoRepo, decisions, cullingRepo }
}

function insertPhoto(
  db: BetterSqlite3.Database,
  photo: {
    id: string
    filepath: string
    filename: string
    assetId?: string
    assetFileId?: string
  },
): void {
  db.prepare(`
    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
      result, asset_id, asset_file_id, width, height, created_at, updated_at)
    VALUES (?, 's', ?, ?, '', 'pending', '{}', '{}', ?, ?, 100, 100, ?, ?)
  `).run(
    photo.id,
    photo.filepath,
    photo.filename,
    photo.assetId ?? null,
    photo.assetFileId ?? null,
    NOW,
    NOW,
  )
}

function insertDecision(db: BetterSqlite3.Database, photoId: string, decision: string): void {
  db.prepare(`
    INSERT INTO culling_decisions (session_id, photo_id, group_id, decision, rating,
      color_label, decision_source, revision, created_at, updated_at)
    VALUES ('s', ?, 'ungrouped', ?, 0, 'None', 'manual', 1, ?, ?)
  `).run(photoId, decision, NOW, NOW)
}

function insertAnalysis(
  db: BetterSqlite3.Database,
  row: {
    photoId: string
    assetFileId: string
    resultJson: string
    updatedAt: string
    fingerprint: string
  },
): void {
  db.prepare(`
    INSERT INTO asset_analysis (photo_id, asset_file_id, analysis_type, result_json,
      input_fingerprint, created_at, updated_at)
    VALUES (?, ?, 'technical_quality', ?, ?, ?, ?)
  `).run(row.photoId, row.assetFileId, row.resultJson, row.fingerprint, NOW, row.updatedAt)
}

function walkAllPages(
  service: CullingService,
  params: { scope: 'all' | 'filtered' | 'similarity_group'; filters?: unknown; groupId?: string },
) {
  const assets: Array<{ photo: { id: string } }> = []
  let cursor: number | undefined
  let total: number | undefined
  for (let pageCount = 0; pageCount < 20; pageCount++) {
    const page = service.listPage(
      's',
      params.scope,
      params.filters as never,
      params.groupId,
      cursor,
      1,
    )
    assets.push(...page.assets)
    total = page.total
    if (page.nextRowId == null) break
    cursor = page.nextRowId
  }
  return { assets, total }
}

afterEach(() => {
  for (const db of databases.splice(0)) db.close()
})

describe('CullingService asset-grouped pagination (real SQLite)', () => {
  it('never splits RAW/JPEG variants across pages and totals logical assets', () => {
    const { db, service } = fixture()
    insertPhoto(db, { id: 'raw', filepath: '/shoot/A001.NEF', filename: 'A001.NEF', assetId: 'asset-1', assetFileId: 'af-raw' })
    insertPhoto(db, { id: 'jpeg', filepath: '/shoot/A001.jpg', filename: 'A001.jpg', assetId: 'asset-1', assetFileId: 'af-jpeg' })
    insertPhoto(db, { id: 'single1', filepath: '/shoot/B001.jpg', filename: 'B001.jpg' })
    insertPhoto(db, { id: 'single2', filepath: '/shoot/C001.jpg', filename: 'C001.jpg' })

    const first = service.listPage('s', 'all', undefined, undefined, undefined, 1)
    expect(first.assets).toHaveLength(1)
    expect(first.assets[0].photo.id).toBe('raw')
    expect(first.assets[0].photo.variantCount).toBe(2)
    expect(first.assets[0].linkedVariantCount).toBe(2)
    expect(first.assets[0].photo.variants.map(variant => variant.photoId)).toEqual(['raw', 'jpeg'])
    // Cursor: first rowid of the last asset group of the page.
    expect(first.nextRowId).toBe(1)
    // Total counts logical assets, not physical photo rows (4 rows, 3 assets).
    expect(first.total).toBe(3)

    const second = service.listPage('s', 'all', undefined, undefined, first.nextRowId ?? undefined, 1)
    expect(second.assets.map(asset => asset.photo.id)).toEqual(['single1'])
    expect(second.nextRowId).toBe(3)

    const third = service.listPage('s', 'all', undefined, undefined, second.nextRowId ?? undefined, 1)
    expect(third.assets.map(asset => asset.photo.id)).toEqual(['single2'])
    expect(third.nextRowId).toBe(4)

    const fourth = service.listPage('s', 'all', undefined, undefined, third.nextRowId ?? undefined, 1)
    expect(fourth.assets).toHaveLength(0)
    expect(fourth.nextRowId).toBeNull()

    const walk = walkAllPages(service, { scope: 'all' })
    expect(walk.assets).toHaveLength(3)
    expect(new Set(walk.assets.map(asset => asset.photo.id)).size).toBe(3)
    expect(walk.total).toBe(3)
  })

  it('keeps RAW/JPEG assets complete when only the RAW matches a filtered page', () => {
    const { db, service, decisions } = fixture()
    insertPhoto(db, { id: 'raw', filepath: '/shoot/A001.NEF', filename: 'A001.NEF', assetId: 'asset-1', assetFileId: 'af-raw' })
    insertPhoto(db, { id: 'jpeg', filepath: '/shoot/A001.jpg', filename: 'A001.jpg', assetId: 'asset-1', assetFileId: 'af-jpeg' })
    insertDecision(db, 'raw', 'keep')
    decisions.mockReturnValue([{
      photo_id: 'raw',
      decision: 'keep',
      rating: 0,
      color_label: 'None',
      decision_source: 'manual',
      revision: 1,
      updated_at: NOW,
    }])

    const page = service.listPage('s', 'filtered', { pickStates: ['picked'] })

    expect(page.assets).toHaveLength(1)
    const asset = page.assets[0]
    expect(asset.photo.id).toBe('raw')
    expect(asset.photo.variantCount).toBe(2)
    expect(asset.photo.variants.map(variant => variant.photoId)).toEqual(['raw', 'jpeg'])
    expect(page.total).toBe(1)
    expect(page.nextRowId).toBe(1)
  })
})

describe('CullingService quality filter JSON guard (real SQLite)', () => {
  it('skips malformed asset_analysis rows instead of failing the page query', () => {
    const { db, service } = fixture()
    insertPhoto(db, { id: 'bad', filepath: '/shoot/bad.jpg', filename: 'bad.jpg', assetFileId: 'af-bad' })
    insertPhoto(db, { id: 'mixed', filepath: '/shoot/mixed.jpg', filename: 'mixed.jpg', assetFileId: 'af-mixed' })
    insertPhoto(db, { id: 'good', filepath: '/shoot/good.jpg', filename: 'good.jpg', assetFileId: 'af-good' })
    // af-bad has only a malformed row; af-mixed has a malformed row that is
    // NEWER than its valid row (the guard must still pick the valid one).
    insertAnalysis(db, { photoId: 'bad', assetFileId: 'af-bad', resultJson: 'not json', updatedAt: '2025-01-03T00:00:00.000Z', fingerprint: 'f-bad' })
    insertAnalysis(db, { photoId: 'mixed', assetFileId: 'af-mixed', resultJson: 'not json', updatedAt: '2025-01-03T00:00:00.000Z', fingerprint: 'f-mixed-new' })
    insertAnalysis(db, { photoId: 'mixed', assetFileId: 'af-mixed', resultJson: '{"status":"succeeded","qualityScore":0.8}', updatedAt: '2025-01-01T00:00:00.000Z', fingerprint: 'f-mixed-old' })
    insertAnalysis(db, { photoId: 'good', assetFileId: 'af-good', resultJson: '{"status":"succeeded","qualityScore":0.9}', updatedAt: '2025-01-01T00:00:00.000Z', fingerprint: 'f-good' })

    let page
    expect(() => {
      page = service.listPage('s', 'filtered', { qualityStatus: 'analysed' })
    }).not.toThrow()

    const ids = page!.assets.map(asset => asset.photo.id)
    expect(ids).toContain('mixed')
    expect(ids).toContain('good')
    expect(ids).not.toContain('bad')
    expect(page!.total).toBe(2)

    // A photo with only a malformed row is not counted as failed either, and
    // the page query does not raise on the non-JSON text.
    expect(() => {
      service.listPage('s', 'filtered', { qualityStatus: 'failed' })
    }).not.toThrow()
  })
})

function decisionRow(photoId: string, decision: string) {
  return {
    photo_id: photoId,
    decision,
    rating: 0,
    color_label: 'None',
    decision_source: 'manual',
    revision: 1,
    updated_at: NOW,
  }
}

describe('CullingService preferred-variant semantics (real SQLite)', () => {
  it('never duplicates an asset across pages when only the preferred RAW variant matches the filter', () => {
    const { db, service, decisions } = fixture()
    // JPEG is inserted first (rowid 1, pending); RAW second (rowid 2, keep).
    insertPhoto(db, { id: 'jpeg', filepath: '/shoot/A001.jpg', filename: 'A001.jpg', assetId: 'asset-1', assetFileId: 'af-jpeg' })
    insertPhoto(db, { id: 'raw', filepath: '/shoot/A001.NEF', filename: 'A001.NEF', assetId: 'asset-1', assetFileId: 'af-raw' })
    insertPhoto(db, { id: 'other', filepath: '/shoot/B001.jpg', filename: 'B001.jpg' })
    insertDecision(db, 'raw', 'keep')
    insertDecision(db, 'other', 'keep')
    decisions.mockReturnValue([decisionRow('raw', 'keep'), decisionRow('other', 'keep')])

    const walk = walkAllPages(service, {
      scope: 'filtered',
      filters: { pickStates: ['picked'] },
    })

    const ids = walk.assets.map(asset => asset.photo.id)
    // The group-query first_rowid (the RAW's rowid 2) is the cursor; walking
    // every page must select the asset exactly once even though its JPEG
    // variant row (rowid 1) sits below the cursor.
    expect(ids).toContain('raw')
    expect(ids).toContain('other')
    expect(new Set(ids).size).toBe(ids.length)
    expect(ids.filter(id => id === 'raw')).toHaveLength(1)
    expect(walk.assets.find(asset => asset.photo.id === 'raw')!.photo.variantCount).toBe(2)
    expect(walk.total).toBe(2)
  })

  it('excludes an asset when only the non-preferred JPEG variant matches the filter', () => {
    const { db, service, decisions, cullingRepo } = fixture()
    insertPhoto(db, { id: 'jpeg', filepath: '/shoot/A001.jpg', filename: 'A001.jpg', assetId: 'asset-1', assetFileId: 'af-jpeg' })
    insertPhoto(db, { id: 'raw', filepath: '/shoot/A001.NEF', filename: 'A001.NEF', assetId: 'asset-1', assetFileId: 'af-raw' })
    insertPhoto(db, { id: 'single', filepath: '/shoot/B001.jpg', filename: 'B001.jpg' })
    insertDecision(db, 'jpeg', 'keep')
    insertDecision(db, 'single', 'keep')
    const rows = [decisionRow('jpeg', 'keep'), decisionRow('single', 'keep')]
    decisions.mockReturnValue(rows)
    cullingRepo.getBySession.mockReturnValue(rows)

    const page = service.listPage('s', 'filtered', { pickStates: ['picked'] })

    expect(page.assets.map(asset => asset.photo.id)).toEqual(['single'])
    expect(page.total).toBe(1)
    expect(page.nextRowId).toBe(3)

    // list() (JS-side filtering on the preferred variant) agrees: the asset
    // whose non-preferred JPEG alone matches is absent from both views.
    expect(service.list('s', 'filtered', { pickStates: ['picked'] }).map(asset => asset.photo.id))
      .toEqual(['single'])
  })

  it('keeps an asset complete when its preferred RAW variant matches the filter', () => {
    const { db, service, decisions } = fixture()
    // JPEG first (rowid 1, pending), RAW second (rowid 2, keep): the cursor
    // is the RAW's rowid, and both variants must still be present.
    insertPhoto(db, { id: 'jpeg', filepath: '/shoot/A001.jpg', filename: 'A001.jpg', assetId: 'asset-1', assetFileId: 'af-jpeg' })
    insertPhoto(db, { id: 'raw', filepath: '/shoot/A001.NEF', filename: 'A001.NEF', assetId: 'asset-1', assetFileId: 'af-raw' })
    insertDecision(db, 'raw', 'keep')
    decisions.mockReturnValue([decisionRow('raw', 'keep')])

    const page = service.listPage('s', 'filtered', { pickStates: ['picked'] })

    expect(page.assets).toHaveLength(1)
    const asset = page.assets[0]
    expect(asset.photo.id).toBe('raw')
    expect(asset.photo.variantCount).toBe(2)
    expect(asset.photo.variants.map(variant => variant.photoId)).toEqual(['jpeg', 'raw'])
    expect(page.total).toBe(1)
    expect(page.nextRowId).toBe(2)
  })
})

describe('CullingService unanalysed filter JSON parity (real SQLite)', () => {
  it('treats photos with only malformed analysis rows as unanalysed', () => {
    const { db, service } = fixture()
    insertPhoto(db, { id: 'bad', filepath: '/shoot/bad.jpg', filename: 'bad.jpg', assetFileId: 'af-bad' })
    insertPhoto(db, { id: 'good', filepath: '/shoot/good.jpg', filename: 'good.jpg', assetFileId: 'af-good' })
    // af-bad has only a malformed row; af-good has a valid succeeded row.
    insertAnalysis(db, { photoId: 'bad', assetFileId: 'af-bad', resultJson: 'not json', updatedAt: '2025-01-03T00:00:00.000Z', fingerprint: 'f-bad' })
    insertAnalysis(db, { photoId: 'good', assetFileId: 'af-good', resultJson: '{"status":"succeeded","qualityScore":0.9}', updatedAt: '2025-01-01T00:00:00.000Z', fingerprint: 'f-good' })

    const page = service.listPage('s', 'filtered', { qualityStatus: 'unanalysed' })

    expect(page.assets.map(asset => asset.photo.id)).toEqual(['bad'])
    expect(page.total).toBe(1)
    // list() (JS try/catch on result_json) agrees.
    expect(service.list('s', 'filtered', { qualityStatus: 'unanalysed' }).map(asset => asset.photo.id))
      .toEqual(['bad'])
  })
})
