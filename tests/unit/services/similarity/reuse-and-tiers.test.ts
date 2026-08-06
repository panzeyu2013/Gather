import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it } from 'vitest'
import { reuseSimilarityHashes } from '../../../../desktop/src/main/services/similarity/similarity.service'
import { SimilarityResultRepository } from '../../../../desktop/src/main/db/repositories/similarity-result.repo'

const databases: BetterSqlite3.Database[] = []

function createDb(): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.pragma('foreign_keys = ON')
  db.exec(`
    CREATE TABLE photos (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      asset_file_id TEXT,
      filepath TEXT NOT NULL DEFAULT '',
      filename TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE similarity_hashes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      photo_id TEXT NOT NULL,
      hash_hex TEXT NOT NULL,
      file_size INTEGER NOT NULL DEFAULT 0,
      file_mtime_ms REAL NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX idx_similarity_hashes_session_photo
      ON similarity_hashes(session_id, photo_id);
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

function addPhoto(db: BetterSqlite3.Database, id: string, sessionId: string, assetFileId: string | null): void {
  db.prepare(
    'INSERT INTO photos (id, session_id, asset_file_id, filepath, filename) VALUES (?, ?, ?, ?, ?)',
  ).run(id, sessionId, assetFileId, `/path/${id}.jpg`, `${id}.jpg`)
}

function addHash(
  db: BetterSqlite3.Database,
  sessionId: string,
  photoId: string,
  hashHex: string,
  fileSize: number,
  fileMtimeMs: number,
): void {
  db.prepare(
    'INSERT INTO similarity_hashes (session_id, photo_id, hash_hex, file_size, file_mtime_ms) VALUES (?, ?, ?, ?, ?)',
  ).run(sessionId, photoId, hashHex, fileSize, fileMtimeMs)
}

afterEach(() => {
  for (const db of databases.splice(0)) db.close()
})

describe('reuseSimilarityHashes batch reuse', () => {
  it('reuses hashes from sibling asset files in a single batch, including cross-session sources', () => {
    const db = createDb()
    addPhoto(db, 'p1', 'session', 'asset-a')
    addPhoto(db, 'p2', 'session', 'asset-a')
    addPhoto(db, 'p3', 'session', 'asset-b')
    addPhoto(db, 'px', 'other-session', 'asset-a')
    addHash(db, 'other-session', 'px', 'a1b2c3d4e5f60718', 100, 1000)

    const stats = new Map([
      ['p1', { size: 100, mtimeMs: 1000 }],
      ['p2', { size: 100, mtimeMs: 1000 }],
      ['p3', { size: 100, mtimeMs: 1000 }],
    ])
    const existing = new Map<string, string>()
    const reused = reuseSimilarityHashes(
      wrap(db),
      'session',
      [{ id: 'p1' }, { id: 'p2' }, { id: 'p3' }],
      stats,
      existing,
    )

    expect(reused).toBe(2)
    expect(existing.get('p1')).toBe('a1b2c3d4e5f60718')
    expect(existing.get('p2')).toBe('a1b2c3d4e5f60718')
    expect(existing.has('p3')).toBe(false)
    const saved = db.prepare(
      'SELECT photo_id, hash_hex FROM similarity_hashes WHERE session_id = ?',
    ).all('session') as Array<{ photo_id: string; hash_hex: string }>
    expect(saved.sort((a, b) => a.photo_id.localeCompare(b.photo_id))).toEqual([
      { photo_id: 'p1', hash_hex: 'a1b2c3d4e5f60718' },
      { photo_id: 'p2', hash_hex: 'a1b2c3d4e5f60718' },
    ])
  })

  it('never reuses a photo own hash row and skips size/mtime mismatches', () => {
    const db = createDb()
    addPhoto(db, 'q1', 'session', 'asset-c')
    addPhoto(db, 'q2', 'session', 'asset-c')
    addHash(db, 'session', 'q2', 'q2ownhash', 200, 2000)

    const stats = new Map([
      ['q1', { size: 200, mtimeMs: 2000 }],
      ['q2', { size: 200, mtimeMs: 2000 }],
    ])
    const existing = new Map<string, string>()
    const reused = reuseSimilarityHashes(
      wrap(db),
      'session',
      [{ id: 'q1' }, { id: 'q2' }],
      stats,
      existing,
    )

    expect(reused).toBe(1)
    expect(existing.get('q1')).toBe('q2ownhash')
    expect(existing.has('q2')).toBe(false)

    // Mismatched file stats yield no reuse.
    const staleStats = new Map([
      ['q1', { size: 999, mtimeMs: 9999 }],
      ['q2', { size: 999, mtimeMs: 9999 }],
    ])
    const existing2 = new Map<string, string>()
    expect(reuseSimilarityHashes(
      wrap(db),
      'session',
      [{ id: 'q1' }, { id: 'q2' }],
      staleStats,
      existing2,
    )).toBe(0)
    expect(existing2.size).toBe(0)
  })

  it('picks the newest candidate hash and crosses the 400-id chunk boundary', () => {
    const db = createDb()
    for (let i = 0; i < 404; i++) {
      addPhoto(db, `r${i}`, 'session', `asset-${i}`)
    }
    // r404 shares the asset of r403 so its candidates live in the second chunk.
    addPhoto(db, 'r404', 'session', 'asset-403')
    addHash(db, 'session', 'r403', 'stalehash', 300, 3000)
    addHash(db, 'session', 'r404', 'freshhash', 300, 3000)

    const stats = new Map([['r403', { size: 300, mtimeMs: 3000 }]])
    const existing = new Map<string, string>()
    const reused = reuseSimilarityHashes(
      wrap(db),
      'session',
      [{ id: 'r403' }],
      stats,
      existing,
    )

    expect(reused).toBe(1)
    expect(existing.get('r403')).toBe('freshhash')
  })

  it('keeps targets already present in existingHashMap untouched', () => {
    const db = createDb()
    addPhoto(db, 's1', 'session', 'asset-e')
    addPhoto(db, 's2', 'session', 'asset-e')
    addHash(db, 'session', 's2', 's2hash', 400, 4000)

    const stats = new Map([
      ['s1', { size: 400, mtimeMs: 4000 }],
      ['s2', { size: 400, mtimeMs: 4000 }],
    ])
    const existing = new Map([['s1', 'already-present']])
    const reused = reuseSimilarityHashes(
      wrap(db),
      'session',
      [{ id: 's1' }, { id: 's2' }],
      stats,
      existing,
    )

    expect(reused).toBe(0)
    expect(existing.get('s1')).toBe('already-present')
  })
})

describe('SimilarityResultRepository multi-threshold tiers', () => {
  it('keeps getLatest on the main row while tiers are stored per threshold', () => {
    const db = createDb()
    const repo = new SimilarityResultRepository(wrap(db))

    const mainId = repo.replace(
      'session',
      '{"groups":[]}',
      '{"threshold":10}',
      10,
      2,
      [{ photoId: 'a', groupIndex: 0 }],
    )
    expect(repo.getLatest('session')?.id).toBe(mainId)
    expect(repo.getLatest('session')?.param_threshold).toBe(10)

    const tierId = repo.replaceForThreshold(
      'session',
      '{"groups":[]}',
      '{"threshold":6,"precomputed":true}',
      6,
      2,
      [{ photoId: 'b', groupIndex: 0 }],
    )
    expect(tierId).toBeGreaterThan(mainId)
    // The precomputed row was inserted after the main row, yet getLatest must
    // still resolve to the latest analysis/recluster result.
    expect(repo.getLatest('session')?.id).toBe(mainId)
    expect(repo.getByThreshold('session', 6)?.id).toBe(tierId)
    expect(repo.getByThreshold('session', 10)?.id).toBe(mainId)
    expect(repo.getByThreshold('session', 7)).toBeUndefined()
  })

  it('replaces an existing tier with the same threshold', () => {
    const db = createDb()
    const repo = new SimilarityResultRepository(wrap(db))

    const first = repo.replaceForThreshold(
      'session',
      '{"groups":[]}',
      '{"precomputed":true}',
      8,
      2,
      [],
    )
    const second = repo.replaceForThreshold(
      'session',
      '{"groups":[]}',
      '{"precomputed":true}',
      8,
      2,
      [],
    )
    expect(second).toBeGreaterThan(first)
    const rows = db.prepare(
      'SELECT id FROM similarity_results WHERE session_id = ? AND param_threshold = ?',
    ).all('session', 8) as Array<{ id: number }>
    expect(rows).toHaveLength(1)
    expect(rows[0].id).toBe(second)
  })

  it('clears all tiers on a fresh replace and handles legacy rows without the marker', () => {
    const db = createDb()
    const repo = new SimilarityResultRepository(wrap(db))

    repo.replaceForThreshold('session', '{}', '{"precomputed":true}', 4, 2, [])
    repo.replaceForThreshold('session', '{}', '{"precomputed":true}', 12, 2, [])

    const newMainId = repo.replace(
      'session',
      '{"groups":[]}',
      '{"threshold":14}',
      14,
      2,
      [],
    )
    expect(repo.getByThreshold('session', 4)).toBeUndefined()
    expect(repo.getByThreshold('session', 12)).toBeUndefined()
    expect(repo.getLatest('session')?.id).toBe(newMainId)

    // Rows written by older versions have no precomputed marker and must keep
    // resolving through getLatest as before.
    const legacyId = Number(db.prepare(
      `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
       VALUES ('other', '{}', '{"threshold":10}', 10, 2, ?)`,
    ).run(new Date().toISOString()).lastInsertRowid)
    expect(repo.getLatest('other')?.id).toBe(legacyId)
  })

  it('cascades member cleanup when a tier row is replaced', () => {
    const db = createDb()
    const repo = new SimilarityResultRepository(wrap(db))

    const first = repo.replaceForThreshold(
      'session',
      '{}',
      '{"precomputed":true}',
      6,
      2,
      [{ photoId: 'member-a', groupIndex: 0 }],
    )
    const membersBefore = db.prepare(
      'SELECT COUNT(*) AS count FROM similarity_result_members WHERE result_id = ?',
    ).get(first) as { count: number }
    expect(membersBefore.count).toBe(1)

    repo.replaceForThreshold('session', '{}', '{"precomputed":true}', 6, 2, [])
    const membersAfter = db.prepare(
      'SELECT COUNT(*) AS count FROM similarity_result_members WHERE result_id = ?',
    ).get(first) as { count: number }
    expect(membersAfter.count).toBe(0)
  })
})
