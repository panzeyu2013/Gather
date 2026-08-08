import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it } from 'vitest'
import { SCHEMA_SQL, INDEX_SQL } from '../../../../desktop/src/main/db/schema'
import {
  NavigationService,
  validateNavigationParameters,
} from '../../../../desktop/src/main/services/navigation/navigation.service'

const databases: BetterSqlite3.Database[] = []

function fixture(): { db: BetterSqlite3.Database; service: NavigationService } {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.pragma('foreign_keys = ON')
  db.exec(SCHEMA_SQL)
  db.exec(INDEX_SQL)
  const now = '2026-07-30T10:00:00.000Z'
  db.prepare(`
    INSERT INTO sessions (
      id, name, status, analysis_status, writeback_status, import_source,
      source_path, photo_count, failed_writeback_count, created_at, updated_at
    ) VALUES ('session', 'Navigation', 'photos_loaded', 'idle', 'idle',
      'folder', '/photos', 3, 0, ?, ?)
  `).run(now, now)
  const insertPhoto = db.prepare(`
    INSERT INTO photos (
      id, session_id, filepath, filename, checksum, status, metadata, result,
      width, height, created_at, updated_at
    ) VALUES (?, 'session', ?, ?, '', 'pending', '{}', '{}', 100, 80, ?, ?)
  `)
  const insertMetadata = db.prepare(`
    INSERT INTO photo_metadata_cache (
      photo_id, session_id, date_taken, camera_model, rating, keywords,
      cached_at, updated_at
    ) VALUES (?, 'session', ?, 'Camera A', ?, '[]', ?, ?)
  `)
  const insertHash = db.prepare(`
    INSERT INTO similarity_hashes (
      session_id, photo_id, hash_hex, file_size, file_mtime_ms
    ) VALUES ('session', ?, ?, 10, 1)
  `)
  const captures = [
    ['p1', 'IMG_0001.JPG', '2026-07-30T10:00:00.000Z', 0],
    ['p2', 'IMG_0002.JPG', '2026-07-30T10:00:01.000Z', 5],
    ['p3', 'IMG_0003.JPG', '2026-07-30T10:00:20.000Z', 0],
  ] as const
  for (const [id, filename, capturedAt, rating] of captures) {
    insertPhoto.run(id, `/photos/${filename}`, filename, now, now)
    insertMetadata.run(id, capturedAt, rating, now, now)
    insertHash.run(id, '0000000000000000')
  }
  return {
    db,
    service: new NavigationService({
      prepare: (sql: string) => db.prepare(sql),
      transaction: <T>(operation: () => T) => db.transaction(operation),
    } as never),
  }
}

afterEach(() => {
  for (const db of databases.splice(0)) db.close()
})

describe('NavigationService', () => {
  it('rejects unsafe or inverted grouping intervals', () => {
    expect(() => validateNavigationParameters(Number.NaN, 100)).toThrow()
    expect(() => validateNavigationParameters(2, 1)).toThrow()
    expect(() => validateNavigationParameters(2, 86_401)).toThrow()
    expect(() => validateNavigationParameters(2, 1_800)).not.toThrow()
  })

  it('recomputes when thresholds change and explains the rating-only lead fallback', () => {
    const { service } = fixture()
    const initial = service.analyze('session', 2, 1_800)
    const burst = initial.find(group => group.type === 'burst')
    const scene = initial.find(group => group.type === 'scene')
    expect(burst?.photoIds).toEqual(['p1', 'p2'])
    expect(scene?.photoIds).toEqual(['p1', 'p2', 'p3'])
    expect(burst?.leadPhotoId).toBe('p2')
    expect(burst?.explanation).toBe('NAV_RECOMMEND_RATING')

    const tighter = service.analyze('session', 0.5, 1_800)
    expect(tighter.some(group => group.type === 'burst')).toBe(false)
    expect(tighter.some(group => group.type === 'scene')).toBe(true)
  })

  it('keeps manual overrides scoped to their own navigation type', () => {
    const { db, service } = fixture()
    const groups = service.analyze('session', 2, 1_800)
    const burst = groups.find(group => group.type === 'burst')!
    service.split('session', burst.id, 'p2')

    db.prepare(
      "UPDATE similarity_hashes SET hash_hex = '0000000000000001' WHERE photo_id = 'p3'",
    ).run()
    const refreshed = service.analyze('session', 2, 1_800)
    expect(refreshed.some(group =>
      group.type === 'scene' && group.photoIds.includes('p1') && group.photoIds.includes('p2'),
    )).toBe(true)
    expect(
      db.prepare(`
        SELECT COUNT(*) AS count FROM navigation_groups
        WHERE session_id = 'session' AND group_type = 'burst' AND source = 'manual'
      `).get(),
    ).toEqual({ count: 2 })
  })

  it('penalizes the current heuristic closed-eye warning when choosing a lead', () => {
    const { db, service } = fixture()
    const now = '2026-07-30T10:00:00.000Z'
    db.prepare(`
      INSERT INTO assets (id, capture_fingerprint, status, created_at, updated_at)
      VALUES ('asset-1', '', 'active', ?, ?), ('asset-2', '', 'active', ?, ?)
    `).run(now, now, now, now)
    const insertFile = db.prepare(`
      INSERT INTO asset_files (
        id, normalized_path, filename, extension, media_type,
        created_at, updated_at
      ) VALUES (?, ?, ?, '.JPG', 'image/jpeg', ?, ?)
    `)
    insertFile.run('file-1', '/photos/IMG_0001.JPG', 'IMG_0001.JPG', now, now)
    insertFile.run('file-2', '/photos/IMG_0002.JPG', 'IMG_0002.JPG', now, now)
    db.prepare("UPDATE photos SET asset_id = 'asset-1', asset_file_id = 'file-1' WHERE id = 'p1'").run()
    db.prepare("UPDATE photos SET asset_id = 'asset-2', asset_file_id = 'file-2' WHERE id = 'p2'").run()
    const insertAnalysis = db.prepare(`
      INSERT INTO asset_analysis (
        photo_id, asset_file_id, analysis_type, result_json, warnings_json,
        model_id, model_version, input_fingerprint, created_at, updated_at
      ) VALUES (?, ?, 'technical_quality', ?, ?, 'test', '1', ?, ?, ?)
    `)
    insertAnalysis.run(
      'p1',
      'file-1',
      JSON.stringify({
        status: 'succeeded',
        qualityScore: 0.9,
        warnings: ['closed_eye_risk_heuristic'],
      }),
      JSON.stringify(['closed_eye_risk_heuristic']),
      'p1',
      now,
      now,
    )
    insertAnalysis.run(
      'p2',
      'file-2',
      JSON.stringify({ status: 'succeeded', qualityScore: 0.8, warnings: [] }),
      '[]',
      'p2',
      now,
      now,
    )

    const burst = service.analyze('session', 2, 1_800, true)
      .find(group => group.type === 'burst')
    expect(burst?.leadPhotoId).toBe('p2')
  })
})
