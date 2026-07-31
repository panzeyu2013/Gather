import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it } from 'vitest'
import type { QualityResult } from '@gather/shared'
import { INDEX_SQL, SCHEMA_SQL } from '../../../desktop/src/main/db/schema'
import {
  QualityService,
  metricFromPixels,
} from '../../../desktop/src/main/services/quality/quality.service'

const databases: BetterSqlite3.Database[] = []

afterEach(() => {
  for (const database of databases.splice(0)) database.close()
})

describe('technical quality metrics', () => {
  it('scores a flat image as low sharpness but valid exposure', () => {
    const result = metricFromPixels(new Uint8Array(16).fill(128), 4, 4)
    expect(result.sharpness).toBe(0)
    expect(result.exposure).toBe(1)
  })

  it('detects both edges and exposure problems deterministically', () => {
    const pixels = new Uint8Array([
      0, 0, 255, 255,
      0, 0, 255, 255,
      0, 0, 255, 255,
      0, 0, 255, 255,
    ])
    const result = metricFromPixels(pixels, 4, 4)
    expect(result.sharpness).toBeGreaterThan(0)
    expect(result.exposure).toBeCloseTo(0.996, 3)
  })

  it('assigns relative ranks only inside persisted similarity groups', () => {
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
      ) VALUES ('session', 'Quality', 'photos_loaded', 'idle', 'idle',
        'folder', '/photos', 3, 0, ?, ?)
    `).run(now, now)
    const insertPhoto = db.prepare(`
      INSERT INTO photos (
        id, session_id, filepath, filename, checksum, status, metadata, result,
        width, height, created_at, updated_at
      ) VALUES (?, 'session', ?, ?, '', 'ready', '{}', '{}', 100, 80, ?, ?)
    `)
    for (const id of ['p1', 'p2', 'p3']) {
      insertPhoto.run(id, `/photos/${id}.JPG`, `${id}.JPG`, now, now)
    }
    const result = db.prepare(`
      INSERT INTO similarity_results (
        session_id, groups_json, stats_json, param_threshold,
        param_min_group_size, created_at
      ) VALUES ('session', '[]', '{}', 8, 2, ?)
    `).run(now)
    const insertMember = db.prepare(`
      INSERT INTO similarity_result_members (
        result_id, session_id, group_index, photo_id
      ) VALUES (?, 'session', 0, ?)
    `)
    insertMember.run(result.lastInsertRowid, 'p1')
    insertMember.run(result.lastInsertRowid, 'p2')

    const service = new QualityService(
      {
        prepare: (sql: string) => db.prepare(sql),
      } as never,
      {} as never,
      {} as never,
    )
    const results: QualityResult[] = [
      {
        photoId: 'p1',
        status: 'succeeded',
        qualityScore: 0.4,
        sharpness: 0.4,
        exposure: 1,
        warnings: [],
        modelId: 'test',
        modelVersion: '1',
        inputFingerprint: '1',
        updatedAt: now,
      },
      {
        photoId: 'p2',
        status: 'succeeded',
        qualityScore: 0.9,
        sharpness: 0.9,
        exposure: 1,
        warnings: [],
        modelId: 'test',
        modelVersion: '1',
        inputFingerprint: '2',
        updatedAt: now,
      },
      {
        photoId: 'p3',
        status: 'succeeded',
        qualityScore: 1,
        sharpness: 1,
        exposure: 1,
        warnings: [],
        modelId: 'test',
        modelVersion: '1',
        inputFingerprint: '3',
        updatedAt: now,
      },
    ]
    const rank = service as unknown as {
      applyRelativeRanks(sessionId: string, values: QualityResult[]): void
    }
    rank.applyRelativeRanks('session', results)

    expect(results.find(item => item.photoId === 'p2')?.relativeRank).toBe(1)
    expect(results.find(item => item.photoId === 'p1')?.relativeRank).toBe(2)
    expect(results.find(item => item.photoId === 'p3')?.relativeRank).toBeUndefined()
  })
})
