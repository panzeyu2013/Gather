import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import BetterSqlite3 from 'better-sqlite3'
import { INDEX_SQL, SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'
import { PersonRepository } from '../../../../desktop/src/main/db/repositories/person.repo'

interface MinimalDb {
  prepare: (sql: string) => BetterSqlite3.Statement
  transaction: <T>(operation: () => T) => () => T
}

function now(): string {
  return new Date().toISOString()
}

describe('PersonRepository person-library bridging', () => {
  let directory: string
  let database: BetterSqlite3.Database
  let db: MinimalDb
  let repository: PersonRepository

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-person-repo-'))
    database = new BetterSqlite3(path.join(directory, 'test.db'))
    database.exec(SCHEMA_SQL)
    database.exec(INDEX_SQL)
    db = {
      prepare: (sql: string) => database.prepare(sql),
      transaction: <T>(operation: () => T) => database.transaction(operation),
    } as MinimalDb
    repository = new PersonRepository(db as never)
  })

  afterEach(() => {
    database.close()
    fs.rmSync(directory, { recursive: true, force: true })
  })

  function insertSession(id: string): void {
    db.prepare(`
      INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
      VALUES (?, '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
    `).run(id, now(), now())
  }

  function insertPhoto(id: string, sessionId: string): void {
    db.prepare(`
      INSERT INTO photos (id, session_id, filepath, filename, checksum, checksum_file_size, checksum_file_mtime_ms, status, metadata, result, width, height, created_at, updated_at)
      VALUES (?, ?, ?, ?, '', 0, 0, 'ready', '{}', '{}', 0, 0, ?, ?)
    `).run(id, sessionId, `/photos/${id}.nef`, `${id}.nef`, now(), now())
  }

  function insertCluster(id: number, sessionId: string): void {
    db.prepare(`
      INSERT INTO face_clusters (id, session_id, label, member_count, status, thumbnail_base64, thumbnail_path, created_at, updated_at)
      VALUES (?, ?, ?, ?, 'unbound', '', '', ?, ?)
    `).run(id, sessionId, `Person ${id}`, 0, now(), now())
  }

  function insertBinding(clusterId: number, sessionId: string, roleName: string, keywords: string[]): void {
    db.prepare(`
      INSERT INTO role_bindings (cluster_id, session_id, role_name, keywords, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(clusterId, sessionId, roleName, JSON.stringify(keywords), now(), now())
  }

  function insertMember(clusterId: number, sessionId: string, photoId: string, bbox: number[]): void {
    db.prepare(`
      INSERT INTO face_cluster_members (cluster_id, session_id, photo_id, bbox, confidence, observation_id)
      VALUES (?, ?, ?, ?, 0.9, NULL)
    `).run(clusterId, sessionId, photoId, JSON.stringify(bbox))
  }

  function linkPersonPhotos(personId: string, sessionId: string, photoIds: string[]): void {
    repository.addPhotos(
      personId,
      sessionId,
      photoIds.map(photoId => ({ photoId, faceBbox: [1, 2, 3, 4], confidence: 0.9 })),
    )
  }

  function personPhotoIds(personId: string, sessionId: string): string[] {
    const rows = db.prepare(
      'SELECT photo_id FROM person_photos WHERE person_id = ? AND session_id = ? ORDER BY photo_id',
    ).all(personId, sessionId) as Array<{ photo_id: string }>
    return rows.map(row => row.photo_id)
  }

  it('upserts a person by name and merges keywords on re-bind', () => {
    const first = repository.upsertByName('Alice', ['portrait', 'outdoor'])
    expect(first).toBeTruthy()
    expect(repository.get(first)?.keywords).toBe(JSON.stringify(['portrait', 'outdoor']))

    // Re-binding to the same role name returns the same person and merges the
    // new keywords instead of replacing the stored ones.
    const again = repository.upsertByName('Alice', ['outdoor', 'smile'])
    expect(again).toBe(first)
    expect(repository.get(again)?.keywords).toBe(JSON.stringify(['portrait', 'outdoor', 'smile']))
  })

  it('does not touch keywords when a re-bind carries no new ones', () => {
    const id = repository.upsertByName('Bob', ['a'])
    repository.upsertByName('Bob')
    expect(repository.get(id)?.keywords).toBe(JSON.stringify(['a']))
  })

  it('deduplicates photos on re-binding thanks to the unique index', () => {
    insertSession('session-1')
    insertPhoto('photo-1', 'session-1')
    const personId = repository.upsertByName('Alice')

    linkPersonPhotos(personId, 'session-1', ['photo-1'])
    // A second bind of the same cluster (or a second cluster of the same photo)
    // must not create duplicate person_photos rows.
    linkPersonPhotos(personId, 'session-1', ['photo-1'])
    linkPersonPhotos(personId, 'session-1', ['photo-1'])

    expect(personPhotoIds(personId, 'session-1')).toEqual(['photo-1'])
    expect(repository.countPhotos(personId)).toBe(1)
  })

  it('reconciles the bridge against role bindings after an unbind', () => {
    insertSession('session-1')
    insertPhoto('photo-1', 'session-1')
    insertPhoto('photo-2', 'session-1')
    insertCluster(1, 'session-1')
    insertMember(1, 'session-1', 'photo-1', [1, 2, 3, 4])
    insertMember(1, 'session-1', 'photo-2', [5, 6, 7, 8])
    insertBinding(1, 'session-1', 'Alice', ['kw'])
    const personId = repository.upsertByName('Alice', ['kw'])
    linkPersonPhotos(personId, 'session-1', ['photo-1', 'photo-2'])

    // Simulate unbindCluster: the role binding is removed, then the bridge is
    // recomputed and the orphaned photo links are dropped.
    db.prepare('DELETE FROM role_bindings WHERE cluster_id = ?').run(1)
    repository.reconcileSession('session-1')

    expect(personPhotoIds(personId, 'session-1')).toEqual([])
  })

  it('moves photo links to the target role when clusters are merged', () => {
    insertSession('session-1')
    insertPhoto('photo-1', 'session-1')
    insertPhoto('photo-2', 'session-1')
    insertPhoto('photo-3', 'session-1')
    insertCluster(1, 'session-1')
    insertCluster(2, 'session-1')
    insertMember(1, 'session-1', 'photo-1', [1, 2, 3, 4])
    insertMember(1, 'session-1', 'photo-2', [5, 6, 7, 8])
    insertMember(2, 'session-1', 'photo-3', [9, 10, 11, 12])
    insertBinding(1, 'session-1', 'Alice', ['kw'])
    insertBinding(2, 'session-1', 'Bob', ['kw'])
    const alice = repository.upsertByName('Alice')
    const bob = repository.upsertByName('Bob')
    linkPersonPhotos(alice, 'session-1', ['photo-1', 'photo-2'])
    linkPersonPhotos(bob, 'session-1', ['photo-3'])

    // Simulate mergeClusters: cluster 1 (Alice) is merged into cluster 2 (Bob).
    db.prepare('UPDATE face_cluster_members SET cluster_id = 2 WHERE cluster_id = 1').run()
    db.prepare('DELETE FROM role_bindings WHERE cluster_id = 1').run()
    repository.reconcileSession('session-1')

    expect(personPhotoIds(alice, 'session-1')).toEqual([])
    expect(personPhotoIds(bob, 'session-1')).toEqual(['photo-1', 'photo-2', 'photo-3'])
  })

  it('drops only the removed member photo when a member is taken out', () => {
    insertSession('session-1')
    insertPhoto('photo-1', 'session-1')
    insertPhoto('photo-2', 'session-1')
    insertCluster(1, 'session-1')
    insertMember(1, 'session-1', 'photo-1', [1, 2, 3, 4])
    insertMember(1, 'session-1', 'photo-2', [5, 6, 7, 8])
    insertBinding(1, 'session-1', 'Alice', ['kw'])
    const personId = repository.upsertByName('Alice')
    linkPersonPhotos(personId, 'session-1', ['photo-1', 'photo-2'])

    db.prepare('DELETE FROM face_cluster_members WHERE cluster_id = 1 AND photo_id = ?').run('photo-2')
    repository.reconcileSession('session-1')

    expect(personPhotoIds(personId, 'session-1')).toEqual(['photo-1'])
  })

  it('leaves links from other sessions untouched during reconciliation', () => {
    insertSession('session-1')
    insertSession('session-2')
    insertPhoto('photo-1', 'session-1')
    insertPhoto('photo-9', 'session-2')
    insertCluster(1, 'session-1')
    insertMember(1, 'session-1', 'photo-1', [1, 2, 3, 4])
    insertBinding(1, 'session-1', 'Alice', ['kw'])
    const personId = repository.upsertByName('Alice')
    linkPersonPhotos(personId, 'session-1', ['photo-1'])
    // A link from another flow (e.g. another session) must survive.
    linkPersonPhotos(personId, 'session-2', ['photo-9'])

    db.prepare('DELETE FROM role_bindings WHERE cluster_id = 1').run()
    repository.reconcileSession('session-1')

    expect(personPhotoIds(personId, 'session-1')).toEqual([])
    expect(personPhotoIds(personId, 'session-2')).toEqual(['photo-9'])
  })
})
