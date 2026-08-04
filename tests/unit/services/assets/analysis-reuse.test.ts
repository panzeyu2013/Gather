import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it } from 'vitest'
import { SCHEMA_SQL, INDEX_SQL } from '../../../../desktop/src/main/db/schema'
import { FaceRepository } from '../../../../desktop/src/main/db/repositories/face.repo'
import { reuseSimilarityHashes } from '../../../../desktop/src/main/services/similarity/similarity.service'

const databases: BetterSqlite3.Database[] = []

function fixture() {
  const sqlite = new BetterSqlite3(':memory:')
  databases.push(sqlite)
  sqlite.pragma('foreign_keys = ON')
  sqlite.exec(SCHEMA_SQL)
  sqlite.exec(INDEX_SQL)
  const timestamp = '2026-07-30T12:00:00.000Z'
  for (const sessionId of ['source-session', 'target-session']) {
    sqlite.prepare(`
      INSERT INTO sessions (
        id, name, status, analysis_status, writeback_status, import_source,
        source_path, photo_count, failed_writeback_count, created_at, updated_at
      ) VALUES (?, ?, 'photos_loaded', 'idle', 'idle', 'folder', '/shoot', 1, 0, ?, ?)
    `).run(sessionId, sessionId, timestamp, timestamp)
  }
  sqlite.prepare(`
    INSERT INTO assets (id, status, created_at, updated_at)
    VALUES ('asset', 'active', ?, ?)
  `).run(timestamp, timestamp)
  sqlite.prepare(`
    INSERT INTO asset_files (
      id, volume_id, normalized_path, filename, extension, media_type,
      file_size, file_mtime_ms, online_status, created_at, updated_at
    ) VALUES ('file', 'dev:1', '/shoot/A001.NEF', 'A001.NEF', '.nef', 'raw',
      1024, 1234, 'online', ?, ?)
  `).run(timestamp, timestamp)
  sqlite.prepare(`
    INSERT INTO asset_members (asset_id, file_id, member_role, is_primary)
    VALUES ('asset', 'file', 'raw', 1)
  `).run()
  for (const [photoId, sessionId] of [
    ['source-photo', 'source-session'],
    ['target-photo', 'target-session'],
  ]) {
    sqlite.prepare(`
      INSERT INTO photos (
        id, session_id, filepath, filename, checksum, status, metadata, result,
        asset_id, asset_file_id, width, height, created_at, updated_at
      ) VALUES (?, ?, '/shoot/A001.NEF', 'A001.NEF', 'checksum', 'pending',
        '{}', '{}', 'asset', 'file', 100, 80, ?, ?)
    `).run(photoId, sessionId, timestamp, timestamp)
  }
  const db = {
    prepare: (sql: string) => sqlite.prepare(sql),
    transaction: <TArgs extends unknown[], TResult>(
      operation: (...args: TArgs) => TResult,
    ) => sqlite.transaction(operation),
  }
  return { sqlite, db }
}

afterEach(() => {
  for (const database of databases.splice(0)) database.close()
})

describe('cross-session reusable analysis', () => {
  it('copies face observations, including a valid zero-face state, by AssetFile', () => {
    const { sqlite, db } = fixture()
    const repository = new FaceRepository(db as never, {} as never)
    repository.saveObservations('source-session', [{
      photoId: 'source-photo',
      bboxX: 1,
      bboxY: 2,
      bboxW: 3,
      bboxH: 4,
      embedding: [0.25, 0.5],
      confidence: 0.9,
      sourceFileSize: 1024,
      sourceFileMtimeMs: 1234,
      analysisSignature: 'face-v1',
    }])
    repository.upsertAnalysisState(
      'source-session',
      'source-photo',
      1024,
      1234,
      'face-v1',
    )

    expect(repository.reuseObservationsForAssetFile(
      'target-session',
      'target-photo',
      1024,
      1234,
      'face-v1',
    )).toEqual({ reused: true, faceCount: 1 })
    expect(repository.getObservations('target-session')).toHaveLength(1)
    expect(repository.getAnalysisStates('target-session').has('target-photo')).toBe(true)

    sqlite.prepare(
      "DELETE FROM face_observations WHERE photo_id IN ('source-photo', 'target-photo')",
    ).run()
    sqlite.prepare("DELETE FROM face_analysis_state WHERE photo_id = 'target-photo'").run()
    expect(repository.reuseObservationsForAssetFile(
      'target-session',
      'target-photo',
      1024,
      1234,
      'face-v1',
    )).toEqual({ reused: true, faceCount: 0 })
  })

  it('copies a valid similarity hash by AssetFile without decoding again', () => {
    const { sqlite, db } = fixture()
    sqlite.prepare(`
      INSERT INTO similarity_hashes
        (session_id, photo_id, hash_hex, file_size, file_mtime_ms)
      VALUES ('source-session', 'source-photo', '0123456789abcdef', 1024, 1234)
    `).run()
    const hashes = new Map<string, string>()
    expect(reuseSimilarityHashes(
      db as never,
      'target-session',
      [{ id: 'target-photo' }],
      new Map([['target-photo', { size: 1024, mtimeMs: 1234 }]]),
      hashes,
    )).toBe(1)
    expect(hashes.get('target-photo')).toBe('0123456789abcdef')
    expect(sqlite.prepare(`
      SELECT hash_hex FROM similarity_hashes
      WHERE session_id = 'target-session' AND photo_id = 'target-photo'
    `).get()).toEqual({ hash_hex: '0123456789abcdef' })
  })
})
