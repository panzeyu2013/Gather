import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-outbox-repo-'))

vi.mock('electron', () => ({
  app: {
    getPath: () => userDataDir,
  },
}))

import { Database } from '../../../../desktop/src/main/db/database'
import { runMigrations } from '../../../../desktop/src/main/db/migrations'
import { MetadataOutboxRepository } from '../../../../desktop/src/main/db/repositories/metadata-outbox.repo'

let db: Database
let repo: MetadataOutboxRepository

function insertSession(id: string): void {
  const now = new Date().toISOString()
  db.prepare(`
    INSERT INTO sessions (id, name, status, analysis_status, writeback_status, import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
    VALUES (?, '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
  `).run(id, now, now)
}

beforeEach(async () => {
  for (const suffix of ['', '-wal', '-shm']) {
    fs.rmSync(path.join(userDataDir, `gather.db${suffix}`), { force: true })
  }
  db = new Database()
  await runMigrations(db)
  repo = new MetadataOutboxRepository(db)
})

afterEach(() => {
  db.close()
})

describe('MetadataOutboxRepository — module provenance', () => {
  it('persists the mutation-source module on mergePatch', () => {
    insertSession('session-1')

    repo.mergePatch('/photos/A001.xmp', 'session-1', '/photos/A001.NEF', { rating: 4, source: 'face-keyword' }, ['rating'])

    const row = repo.get('/photos/A001.xmp')
    expect(row?.source_module).toBe('face-keyword')
    // Patches without a source fall back to manual.
    repo.mergePatch('/photos/A002.xmp', 'session-1', '/photos/A002.NEF', { rating: 3 }, ['rating'])
    expect(repo.get('/photos/A002.xmp')?.source_module).toBe('manual')
  })

  it('gates batch workflows while excluding interactive and manual edits', () => {
    insertSession('session-2')

    repo.mergePatch('/photos/B001.xmp', 'session-2', '/photos/B001.NEF', { rating: 4, source: 'culling' }, ['rating'])
    repo.mergePatch('/photos/B002.xmp', 'session-2', '/photos/B002.NEF', { rating: 3 }, ['rating'])
    repo.markStatus('/photos/B001.xmp', 'written')
    repo.markStatus('/photos/B002.xmp', 'written')

    // Interactive culling and manual edits must never block a writeback.
    expect(repo.hasActiveOtherModule('session-2', 'similarity')).toBe(false)
    expect(repo.hasActiveOtherModule('session-2', 'face-keyword')).toBe(false)

    repo.mergePatch('/photos/B003.xmp', 'session-2', '/photos/B003.NEF', { rating: 5, source: 'face-keyword' }, ['rating'])
    repo.markStatus('/photos/B003.xmp', 'written')

    // A same-module re-writeback is fine, other batch modules are blocked.
    expect(repo.hasActiveOtherModule('session-2', 'face-keyword')).toBe(false)
    expect(repo.hasActiveOtherModule('session-2', 'similarity')).toBe(true)
    expect(repo.hasActiveOtherModule('session-2', 'template')).toBe(true)
  })

  it('only considers written or synced rows as blocking', () => {
    insertSession('session-3')
    repo.mergePatch('/photos/C001.xmp', 'session-3', '/photos/C001.NEF', { rating: 4, source: 'similarity' }, ['rating'])

    // pending rows do not block yet.
    expect(repo.hasActiveOtherModule('session-3', 'face-keyword')).toBe(false)
    repo.markStatus('/photos/C001.xmp', 'written')
    expect(repo.hasActiveOtherModule('session-3', 'face-keyword')).toBe(true)
  })
})

describe('MetadataOutboxRepository — claim and write lifecycle', () => {
  it('claims only pending or failed rows at the expected revision', () => {
    insertSession('session-4')
    repo.mergePatch('/photos/D001.xmp', 'session-4', '/photos/D001.NEF', { rating: 5 }, ['rating'])

    expect(repo.claim('/photos/D001.xmp', 1)).toBe(true)
    const claimed = repo.get('/photos/D001.xmp')
    expect(claimed?.status).toBe('writing')
    expect(claimed?.attempt_count).toBe(1)

    // Already writing: claim must fail.
    expect(repo.claim('/photos/D001.xmp', 1)).toBe(false)
    // Stale revision: claim must fail.
    repo.markStatus('/photos/D001.xmp', 'failed')
    expect(repo.claim('/photos/D001.xmp', 0)).toBe(false)
    expect(repo.claim('/photos/D001.xmp', 1)).toBe(true)
  })

  it('marks written only when the revision matches, keeping the backup values', () => {
    insertSession('session-5')
    repo.mergePatch('/photos/E001.xmp', 'session-5', '/photos/E001.NEF', { rating: 4 }, ['rating'])
    repo.mergePatch('/photos/E001.xmp', 'session-5', '/photos/E001.NEF', { rating: 5 }, ['rating'])
    const revision = repo.get('/photos/E001.xmp')!.revision

    repo.claim('/photos/E001.xmp', revision)
    repo.markWritten('/photos/E001.xmp', revision, 'fp-123', { rating: 3 }, '/bak/E001.xmp')

    expect(repo.get('/photos/E001.xmp')).toMatchObject({
      status: 'written',
      persisted_revision: revision,
      base_fingerprint: 'fp-123',
      backup_path: '/bak/E001.xmp',
    })

    // A local edit bumps the revision past what the stale writer knew, so its
    // markWritten with the old revision must not report written.
    repo.mergePatch('/photos/E001.xmp', 'session-5', '/photos/E001.NEF', { rating: 4 }, ['rating'])
    const newRevision = repo.get('/photos/E001.xmp')!.revision
    repo.claim('/photos/E001.xmp', newRevision)
    repo.markWritten('/photos/E001.xmp', revision, 'fp-stale', {}, '')
    expect(repo.get('/photos/E001.xmp')?.status).toBe('pending')
  })

  it('resets only failed rows for retry', () => {
    insertSession('session-6')
    repo.mergePatch('/photos/F001.xmp', 'session-6', '/photos/F001.NEF', { rating: 4 }, ['rating'])
    repo.markStatus('/photos/F001.xmp', 'failed', 'boom')

    repo.resetForRetry('/photos/F001.xmp')
    expect(repo.get('/photos/F001.xmp')).toMatchObject({ status: 'pending', attempt_count: 0, error_message: '' })

    repo.resetForRetry('/photos/F001.xmp')
    repo.markStatus('/photos/F001.xmp', 'written')
    repo.resetForRetry('/photos/F001.xmp')
    expect(repo.get('/photos/F001.xmp')?.status).toBe('written')
  })
})

describe('MetadataOutboxRepository — conflict resolution', () => {
  function setupConflictRow(): string {
    insertSession('session-7')
    repo.mergePatch('/photos/G001.xmp', 'session-7', '/photos/G001.NEF', { rating: 5 }, ['rating'])
    repo.claim('/photos/G001.xmp', repo.get('/photos/G001.xmp')!.revision)
    repo.markStatus('/photos/G001.xmp', 'conflict')
    return '/photos/G001.xmp'
  }

  it('resolves only conflict rows, preserving the persisted revision', () => {
    const xmpPath = setupConflictRow()

    repo.resolveConflict(xmpPath, { rating: 4 }, ['rating'], 'fp-new', { rating: 5 }, false)

    const row = repo.get(xmpPath)!
    expect(row.status).toBe('pending')
    expect(row.revision).toBe(2)
    expect(row.persisted_revision).toBe(0)
    expect(row.patch_json).toBe(JSON.stringify({ rating: 4 }))
    expect(row.base_fingerprint).toBe('fp-new')
  })

  it('never resolves a row that is not in conflict', () => {
    insertSession('session-8')
    repo.mergePatch('/photos/H001.xmp', 'session-8', '/photos/H001.NEF', { rating: 5 }, ['rating'])

    repo.resolveConflict('/photos/H001.xmp', { rating: 1 }, ['rating'], 'fp', {}, false)

    const row = repo.get('/photos/H001.xmp')!
    expect(row.status).toBe('pending')
    expect(row.revision).toBe(1)
    expect(row.patch_json).toBe(JSON.stringify({ rating: 5 }))
  })

  it('deletes the row when accepting all remote values', () => {
    const xmpPath = setupConflictRow()
    repo.resolveConflict(xmpPath, {}, [], '', {}, true)
    expect(repo.get(xmpPath)).toBeNull()
  })

  it('transitions written rows to synced once every session confirmed them', () => {
    insertSession('session-9')
    repo.mergePatch('/photos/I001.xmp', 'session-9', '/photos/I001.NEF', { rating: 5, source: 'face-keyword' }, ['rating'])
    repo.claim('/photos/I001.xmp', repo.get('/photos/I001.xmp')!.revision)
    repo.markWritten('/photos/I001.xmp', 1, 'fp', {}, '')
    expect(repo.get('/photos/I001.xmp')?.status).toBe('written')

    repo.markSessionSynced('session-9')
    expect(repo.get('/photos/I001.xmp')?.status).toBe('synced')
    expect(repo.hasActiveOtherModule('session-9', 'similarity')).toBe(true)
  })
})
