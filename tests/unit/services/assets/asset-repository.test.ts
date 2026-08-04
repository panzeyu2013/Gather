import BetterSqlite3 from 'better-sqlite3'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { SCHEMA_SQL, INDEX_SQL } from '../../../../desktop/src/main/db/schema'
import { AssetRepository } from '../../../../desktop/src/main/db/repositories/asset.repo'

const databases: BetterSqlite3.Database[] = []
const temporaryDirectories: string[] = []

function fixture(status: 'pending' | 'rejected' = 'pending') {
  const sqlite = new BetterSqlite3(':memory:')
  databases.push(sqlite)
  sqlite.pragma('foreign_keys = ON')
  sqlite.exec(SCHEMA_SQL)
  sqlite.exec(INDEX_SQL)
  const timestamp = '2026-07-30T12:00:00.000Z'
  sqlite.prepare(`
    INSERT INTO sessions (
      id, name, status, analysis_status, writeback_status, import_source,
      source_path, photo_count, failed_writeback_count, created_at, updated_at
    ) VALUES ('session', 'Pair', 'photos_loaded', 'idle', 'idle',
      'folder', '/shoot', 2, 0, ?, ?)
  `).run(timestamp, timestamp)
  for (const [assetId, fileId, photoId, filename, role] of [
    ['raw-asset', 'raw-file', 'raw-photo', 'A001.NEF', 'raw'],
    ['jpg-asset', 'jpg-file', 'jpg-photo', 'A001.JPG', 'camera_jpeg'],
  ]) {
    sqlite.prepare(
      "INSERT INTO assets (id, status, created_at, updated_at) VALUES (?, 'active', ?, ?)",
    ).run(assetId, timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO asset_files (
        id, volume_id, normalized_path, filename, extension, media_type,
        online_status, created_at, updated_at
      ) VALUES (?, 'dev:1', ?, ?, ?, ?, 'online', ?, ?)
    `).run(
      fileId,
      `/shoot/${filename}`,
      filename,
      filename.toLowerCase().endsWith('.nef') ? '.nef' : '.jpg',
      role === 'raw' ? 'raw' : 'image',
      timestamp,
      timestamp,
    )
    sqlite.prepare(`
      INSERT INTO asset_members (asset_id, file_id, member_role, is_primary)
      VALUES (?, ?, ?, 1)
    `).run(assetId, fileId, role)
    sqlite.prepare(`
      INSERT INTO session_assets (session_id, asset_id, display_file_id, added_at)
      VALUES ('session', ?, ?, ?)
    `).run(assetId, fileId, timestamp)
    sqlite.prepare(`
      INSERT INTO photos (
        id, session_id, filepath, filename, checksum, status, metadata, result,
        asset_id, asset_file_id, width, height, created_at, updated_at
      ) VALUES (?, 'session', ?, ?, '', 'pending', '{}', '{}', ?, ?, 100, 80, ?, ?)
    `).run(photoId, `/shoot/${filename}`, filename, assetId, fileId, timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO photo_metadata_cache (
        photo_id, session_id, date_taken, camera_model, keywords, cached_at, updated_at
      ) VALUES (?, 'session', '2026-07-30T12:00:00.000Z', 'Camera A', '[]', ?, ?)
    `).run(photoId, timestamp, timestamp)
  }
  sqlite.prepare(`
    INSERT INTO asset_backfill_state (session_id, status, updated_at)
    VALUES ('session', 'completed', ?)
  `).run(timestamp)
  sqlite.prepare(`
    INSERT INTO asset_link_candidates (
      id, left_file_id, right_file_id, relation_type, confidence,
      evidence_json, status, created_at, updated_at
    ) VALUES ('candidate', 'raw-file', 'jpg-file', 'raw_jpeg', 0.85, '{}', ?, ?, ?)
  `).run(status, timestamp, timestamp)
  return {
    sqlite,
    repository: new AssetRepository({
      prepare: (sql: string) => sqlite.prepare(sql),
      transaction: <T>(operation: () => T) => sqlite.transaction(operation),
    } as never),
  }
}

afterEach(() => {
  for (const database of databases.splice(0)) database.close()
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true })
  }
})

describe('AssetRepository RAW/JPEG evidence', () => {
  it('automatically and reversibly links a unique fully evidenced pair', () => {
    const { sqlite, repository } = fixture()
    expect(repository.reconcileRawJpegLinks('session')).toBe(1)
    expect(
      sqlite.prepare('SELECT COUNT(DISTINCT asset_id) AS count FROM photos').get(),
    ).toEqual({ count: 1 })
    expect(
      sqlite.prepare("SELECT status FROM asset_link_candidates WHERE id = 'candidate'").get(),
    ).toEqual({ status: 'accepted' })
    repository.rejectCandidate('candidate')
    expect(
      sqlite.prepare('SELECT COUNT(DISTINCT asset_id) AS count FROM photos').get(),
    ).toEqual({ count: 2 })
  })

  it('never revives a pair the user explicitly rejected', () => {
    const { sqlite, repository } = fixture('rejected')
    expect(repository.reconcileRawJpegLinks('session')).toBe(0)
    expect(
      sqlite.prepare('SELECT COUNT(DISTINCT asset_id) AS count FROM photos').get(),
    ).toEqual({ count: 2 })
  })

  it('stores a numeric import order when backfilling legacy photos', () => {
    const { sqlite, repository } = fixture()
    const timestamp = '2026-07-30T12:00:01.000Z'
    sqlite.prepare(`
      INSERT INTO photos (
        id, session_id, filepath, filename, checksum, status, metadata, result,
        width, height, created_at, updated_at
      ) VALUES (
        'legacy-photo', 'session', '/offline/A002.NEF', 'A002.NEF', '',
        'pending', '{}', '{}', 100, 80, ?, ?
      )
    `).run(timestamp, timestamp)

    repository.backfillSession('session')

    const row = sqlite.prepare(`
      SELECT sa.import_order, typeof(sa.import_order) AS storage_type
      FROM session_assets sa
      JOIN photos p ON p.asset_id = sa.asset_id
      WHERE p.id = 'legacy-photo'
    `).get()
    expect(row).toMatchObject({ storage_type: 'integer' })
    expect(Number((row as { import_order: number }).import_order)).toBeGreaterThan(0)
  })

  it('moves pending XMP recovery state together with a relocated photo', () => {
    const { sqlite, repository } = fixture()
    const timestamp = '2026-07-30T12:05:00.000Z'
    sqlite.prepare(`
      INSERT INTO metadata_outbox (
        xmp_path, owner_session_id, created_by_session_id, photo_path,
        patch_json, dirty_fields, revision, persisted_revision,
        base_fingerprint, base_values_json, backup_path, status,
        attempt_count, error_message, updated_at
      ) VALUES (
        '/shoot/A001.xmp', 'session', 'session', '/shoot/A001.NEF',
        '{"keywords":["person"]}', '["keywords"]', 1, 0,
        'baseline', '{}', '', 'failed', 3, 'temporary error', ?
      )
    `).run(timestamp)
    sqlite.prepare(`
      INSERT INTO metadata_outbox_sessions
        (xmp_path, session_id, confirmed_at, linked_at)
      VALUES ('/shoot/A001.xmp', 'session', '', ?)
    `).run(timestamp)
    sqlite.prepare(`
      INSERT INTO metadata_keyword_origins
        (xmp_path, source, keyword, active, created_at, updated_at)
      VALUES ('/shoot/A001.xmp', 'face-keyword', 'person', 1, ?, ?)
    `).run(timestamp, timestamp)
    sqlite.prepare(`
      INSERT INTO writeback_items (
        photo_id, session_id, module, keywords, photo_path, xmp_path, created_at
      ) VALUES (
        'raw-photo', 'session', 'face_kw', '["person"]',
        '/shoot/A001.NEF', '/shoot/A001.xmp', ?
      )
    `).run(timestamp)

    const relocated = (
      repository as unknown as {
        relocateMetadataState(oldPhoto: string, newPhoto: string, at: string): string | null
      }
    ).relocateMetadataState('/shoot/A001.NEF', '/new/A001.NEF', timestamp)

    expect(relocated).toBe('/new/A001.xmp')
    expect(sqlite.prepare(`
      SELECT xmp_path, photo_path, status, attempt_count, error_message
      FROM metadata_outbox
    `).get()).toEqual({
      xmp_path: '/new/A001.xmp',
      photo_path: '/new/A001.NEF',
      status: 'pending',
      attempt_count: 0,
      error_message: '',
    })
    expect(sqlite.prepare(
      'SELECT xmp_path FROM metadata_keyword_origins',
    ).get()).toEqual({ xmp_path: '/new/A001.xmp' })
    expect(sqlite.prepare(
      'SELECT photo_path, xmp_path FROM writeback_items',
    ).get()).toEqual({
      photo_path: '/new/A001.NEF',
      xmp_path: '/new/A001.xmp',
    })
  })

  it('merges compatible sidecar bindings when a file moves beside an existing pair', () => {
    const { sqlite, repository } = fixture()
    const timestamp = '2026-07-30T12:05:00.000Z'
    for (const [id, xmpPath, fileId] of [
      ['old-binding', '/shoot/A001.xmp', 'raw-file'],
      ['new-binding', '/new/A001.xmp', 'jpg-file'],
    ]) {
      sqlite.prepare(`
        INSERT INTO sidecar_bindings (
          id, xmp_path, normalized_xmp_path, binding_rule, created_at, updated_at
        ) VALUES (?, ?, ?, 'same_basename', ?, ?)
      `).run(id, xmpPath, xmpPath, timestamp, timestamp)
      sqlite.prepare(`
        INSERT INTO sidecar_binding_files (sidecar_binding_id, file_id)
        VALUES (?, ?)
      `).run(id, fileId)
    }

    ;(repository as unknown as {
      relocateSidecarBinding(oldPhoto: string, newPhoto: string, at: string): void
    }).relocateSidecarBinding('/shoot/A001.NEF', '/new/A001.NEF', timestamp)

    expect(sqlite.prepare(`
      SELECT sidecar_binding_id, file_id
      FROM sidecar_binding_files ORDER BY file_id
    `).all()).toEqual([
      { sidecar_binding_id: 'new-binding', file_id: 'jpg-file' },
      { sidecar_binding_id: 'new-binding', file_id: 'raw-file' },
    ])
  })

  it('moves the session source path together with a relinked root', () => {
    const { sqlite, repository } = fixture()
    const oldRoot = mkdtempSync(path.join(os.tmpdir(), 'gather-relink-old-'))
    const newRoot = mkdtempSync(path.join(os.tmpdir(), 'gather-relink-new-'))
    temporaryDirectories.push(oldRoot, newRoot)
    mkdirSync(path.join(newRoot, 'nested'), { recursive: true })
    writeFileSync(path.join(newRoot, 'A001.NEF'), 'raw')
    writeFileSync(path.join(newRoot, 'A001.JPG'), 'jpg')

    sqlite.prepare('UPDATE sessions SET source_path = ? WHERE id = ?')
      .run(path.join(oldRoot, 'nested'), 'session')
    for (const [fileId, filename] of [['raw-file', 'A001.NEF'], ['jpg-file', 'A001.JPG']]) {
      sqlite.prepare('UPDATE asset_files SET normalized_path = ? WHERE id = ?')
        .run(path.join(oldRoot, filename), fileId)
      sqlite.prepare('UPDATE photos SET filepath = ? WHERE asset_file_id = ?')
        .run(path.join(oldRoot, filename), fileId)
    }

    expect(repository.relinkRoot(oldRoot, newRoot)).toBe(2)
    expect(sqlite.prepare('SELECT source_path FROM sessions WHERE id = ?').get('session'))
      .toEqual({ source_path: path.join(newRoot, 'nested') })
  })
})
