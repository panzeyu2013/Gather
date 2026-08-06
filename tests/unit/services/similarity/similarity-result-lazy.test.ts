import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SimilarityService } from '../../../../desktop/src/main/services/similarity/similarity.service'
import { SimilarityResultRepository } from '../../../../desktop/src/main/db/repositories/similarity-result.repo'
import { PhotoRepository } from '../../../../desktop/src/main/db/repositories/photo.repo'

const databases: BetterSqlite3.Database[] = []

function createDb(): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.pragma('foreign_keys = ON')
  db.exec(`
    CREATE TABLE photos (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      filepath TEXT NOT NULL,
      filename TEXT NOT NULL,
      checksum TEXT NOT NULL DEFAULT '',
      checksum_file_size INTEGER NOT NULL DEFAULT 0,
      checksum_file_mtime_ms INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'pending',
      metadata TEXT NOT NULL DEFAULT '{}',
      result TEXT NOT NULL DEFAULT '{}',
      asset_id TEXT,
      asset_file_id TEXT,
      width INTEGER NOT NULL DEFAULT 0,
      height INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE similarity_results (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      groups_json TEXT NOT NULL,
      stats_json TEXT NOT NULL DEFAULT '{}',
      param_threshold INTEGER NOT NULL,
      param_min_group_size INTEGER NOT NULL DEFAULT 2,
      created_at TEXT NOT NULL
    );
    CREATE TABLE similarity_result_members (
      result_id INTEGER NOT NULL REFERENCES similarity_results(id) ON DELETE CASCADE,
      session_id TEXT NOT NULL,
      group_index INTEGER NOT NULL,
      photo_id TEXT NOT NULL,
      PRIMARY KEY (result_id, photo_id)
    );
  `)
  return db
}

function wrap(db: BetterSqlite3.Database): never {
  return {
    prepare: (sql: string) => db.prepare(sql),
    transaction: <T>(operation: () => T) => db.transaction(operation),
  } as never
}

function addPhoto(
  db: BetterSqlite3.Database,
  id: string,
  sessionId: string,
  filepath: string,
  assetId: string | null,
): void {
  db.prepare(`
    INSERT INTO photos (id, session_id, filepath, filename, checksum, status, metadata,
      result, asset_id, asset_file_id, width, height, created_at, updated_at)
    VALUES (?, ?, ?, ?, 'checksum-${id}', 'pending', '{"make":"Nikon"}', '{"sharpness":1}',
      ?, 'af-${id}', 100, 100, ?, ?)
  `).run(id, sessionId, filepath, filepath.split('/').pop() ?? id, assetId, '2025-01-01T00:00:00.000Z', '2025-01-01T00:00:00.000Z')
}

afterEach(() => {
  for (const db of databases.splice(0)) db.close()
})

function buildService(db: BetterSqlite3.Database): {
  service: SimilarityService
  photoRepo: PhotoRepository
  resultRepo: SimilarityResultRepository
} {
  const photoRepo = new PhotoRepository(wrap(db))
  const resultRepo = new SimilarityResultRepository(wrap(db))
  const service = new SimilarityService(
    photoRepo,
    { updateAnalysisStatus: vi.fn() } as never,
    resultRepo,
    { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
    {} as never,
    wrap(db),
  )
  return { service, photoRepo, resultRepo }
}

describe('PhotoRepository.getBySessionProjection', () => {
  it('drops only the heavy JSON columns and keeps the rest', () => {
    const db = createDb()
    addPhoto(db, 'p1', 'session', '/shoot/a.jpg', null)
    const repo = new PhotoRepository(wrap(db))

    const rows = repo.getBySessionProjection('session')

    expect(rows).toHaveLength(1)
    expect(rows[0]).not.toHaveProperty('metadata')
    expect(rows[0]).not.toHaveProperty('result')
    expect(rows[0]).toMatchObject({
      id: 'p1',
      session_id: 'session',
      filepath: '/shoot/a.jpg',
      filename: 'a.jpg',
      checksum: 'checksum-p1',
      checksum_file_size: 0,
      checksum_file_mtime_ms: 0,
      status: 'pending',
      asset_id: null,
      asset_file_id: 'af-p1',
      width: 100,
      height: 100,
      created_at: '2025-01-01T00:00:00.000Z',
      updated_at: '2025-01-01T00:00:00.000Z',
    })
  })
})

describe('SimilarityService.getResult lazy group assembly', () => {
  it('assembles groups from the members table without parsing groups_json', () => {
    const db = createDb()
    addPhoto(db, 'p1', 'session', '/shoot/p1.jpg', null)
    addPhoto(db, 'a.raw', 'session', '/shoot/a.RAW', 'asset-a')
    addPhoto(db, 'a.jpg', 'session', '/shoot/a.jpg', 'asset-a')
    addPhoto(db, 's', 'session', '/shoot/s.jpg', null)
    addPhoto(db, 'c.raw', 'session', '/shoot/c.RAW', 'asset-c')
    addPhoto(db, 'c.jpg', 'session', '/shoot/c.jpg', 'asset-c')
    const { service, resultRepo } = buildService(db)

    // Members are written sequentially: group 0 members first, then group 1.
    const resultId = resultRepo.replace(
      'session',
      // Garbage JSON proves the members path never parses groups_json.
      'NOT VALID JSON',
      JSON.stringify({
        totalGroups: 2,
        totalUngrouped: 1,
        threshold: 10,
        minGroupSize: 2,
        groupingMode: 'global',
      }),
      10,
      2,
      [
        { photoId: 'p1', groupIndex: 0 },
        { photoId: 'a.raw', groupIndex: 0 },
        { photoId: 's', groupIndex: 1 },
      ],
    )
    expect(resultId).toBeGreaterThan(0)

    const result = service.getResult('session')

    expect(result).not.toBeNull()
    expect(result!.groups.map(group => group.id)).toEqual([1, 2])
    expect(result!.groups).toEqual([
      {
        id: 1,
        label: 'Group 1',
        count: 2,
        images: [
          { path: '/shoot/p1.jpg', representative: true },
          { path: '/shoot/a.RAW', representative: false },
        ],
      },
      {
        id: 2,
        label: 'Group 2',
        count: 1,
        images: [{ path: '/shoot/s.jpg', representative: true }],
      },
    ])
    // Ungrouped mirrors analyze: collapsed logical assets (RAW preferred)
    // outside the members table — the asset-c JPEG variant is excluded.
    expect(result!.ungrouped).toEqual([{ path: '/shoot/c.RAW' }])
    expect(result!.stats).toEqual({
      totalGroups: 2,
      totalUngrouped: 1,
      threshold: 10,
      minGroupSize: 2,
      groupingMode: 'global',
      precomputed: false,
    })
  })

  it('keeps the legacy groups_json path for rows without members', () => {
    const db = createDb()
    addPhoto(db, 'p1', 'session', '/shoot/p1.jpg', null)
    const { service } = buildService(db)

    const legacyId = Number(db.prepare(`
      INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
      VALUES ('session', ?, ?, 10, 2, ?)
    `).run(
      JSON.stringify({
        groups: [
          { id: 1, label: 'Group 1', count: 2, images: [
            { path: '/shoot/p1.jpg', representative: true },
            { path: '/shoot/legacy.jpg', representative: false },
          ] },
        ],
        ungrouped: [{ path: '/shoot/alone.jpg' }],
      }),
      JSON.stringify({ totalGroups: 1, totalUngrouped: 1, threshold: 10, minGroupSize: 2, groupingMode: 'sequential' }),
      '2025-01-01T00:00:00.000Z',
    ).lastInsertRowid)

    const result = service.getResult('session')

    expect(result).not.toBeNull()
    // The legacy row (no members) parses groups_json verbatim.
    expect(result!.groups[0].images).toEqual([
      { path: '/shoot/p1.jpg', representative: true },
      { path: '/shoot/legacy.jpg', representative: false },
    ])
    expect(result!.ungrouped).toEqual([{ path: '/shoot/alone.jpg' }])
    expect(result!.stats.groupingMode).toBe('sequential')
    expect(result!.stats.precomputed).toBe(false)
    expect(legacyId).toBeGreaterThan(0)
  })

  it('resolves threshold tiers without regressing the default row', () => {
    const db = createDb()
    addPhoto(db, 'p1', 'session', '/shoot/p1.jpg', null)
    addPhoto(db, 'p2', 'session', '/shoot/p2.jpg', null)
    const { service, resultRepo } = buildService(db)

    resultRepo.replace(
      'session',
      '{"groups":[]}',
      JSON.stringify({ totalGroups: 1, totalUngrouped: 1, threshold: 10, minGroupSize: 2, groupingMode: 'global' }),
      10,
      2,
      [{ photoId: 'p1', groupIndex: 0 }],
    )
    resultRepo.replaceForThreshold(
      'session',
      '{"groups":[]}',
      JSON.stringify({ totalGroups: 1, totalUngrouped: 1, threshold: 6, minGroupSize: 2, groupingMode: 'global', precomputed: true }),
      6,
      2,
      [{ photoId: 'p2', groupIndex: 0 }],
    )

    const main = service.getResult('session')
    expect(main?.stats.threshold).toBe(10)
    expect(main?.stats.precomputed).toBe(false)
    expect(main?.groups[0].images.map(image => image.path)).toEqual(['/shoot/p1.jpg'])

    const tier = service.getResult('session', 6)
    expect(tier?.stats.threshold).toBe(6)
    expect(tier?.stats.precomputed).toBe(true)
    expect(tier?.groups[0].images.map(image => image.path)).toEqual(['/shoot/p2.jpg'])

    expect(service.getResult('session', 99)).toBeNull()
  })
})
