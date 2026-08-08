import { test, expect, _electron as electron } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

function hasSqliteCli(): boolean {
  try { execFileSync('sqlite3', ['-version'], { stdio: 'ignore' }); return true } catch { return false }
}

// Keep version expectations in one place so a schema bump touches them here only.
const PRE_MIGRATION_VERSION = 14
const CURRENT_SCHEMA_VERSION = '31'
const LEGACY_BACKUP_PREFIX = 'gather.db.pre-v31-'

test('upgrades a legacy schema marker with a pre-migration backup', async () => {
  test.skip(!hasSqliteCli(), 'sqlite3 CLI is required for the legacy database fixture')
  const userDataDir = mkdtempSync(path.join(tmpdir(), 'gather-migration-e2e-'))
  const dbPath = path.join(userDataDir, 'gather.db')
  const now = new Date().toISOString()
  const sql = `
    PRAGMA foreign_keys = ON;
    CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
    INSERT INTO schema_version VALUES (${PRE_MIGRATION_VERSION}, '${now}');
    -- A real v14 sessions table carries the workflow columns since v1; the
    -- migrated DB must be usable by session.list etc., not just structurally
    -- accepted by the migrations themselves.
    CREATE TABLE sessions (
      id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'draft',
      analysis_status TEXT NOT NULL DEFAULT 'idle', writeback_status TEXT NOT NULL DEFAULT 'idle',
      import_source TEXT NOT NULL DEFAULT 'unknown', source_path TEXT NOT NULL DEFAULT '',
      photo_count INTEGER NOT NULL DEFAULT 0, failed_writeback_count INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE photos (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, filepath TEXT NOT NULL, filename TEXT NOT NULL DEFAULT '', checksum TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', metadata TEXT NOT NULL DEFAULT '{}', result TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE metadata_outbox (
      xmp_path TEXT PRIMARY KEY, owner_session_id TEXT NOT NULL, photo_path TEXT NOT NULL,
      patch_json TEXT NOT NULL DEFAULT '{}', dirty_fields TEXT NOT NULL DEFAULT '[]', revision INTEGER NOT NULL DEFAULT 0,
      persisted_revision INTEGER NOT NULL DEFAULT 0, base_fingerprint TEXT NOT NULL DEFAULT '', base_values_json TEXT NOT NULL DEFAULT '{}',
      backup_path TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', attempt_count INTEGER NOT NULL DEFAULT 0,
      error_message TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL
    );
    INSERT INTO sessions (id, name, created_at, updated_at) VALUES ('legacy', 'Legacy', '${now}', '${now}');
    INSERT INTO metadata_outbox (xmp_path, owner_session_id, photo_path, updated_at) VALUES ('/tmp/legacy.xmp', 'legacy', '/tmp/legacy.nef', '${now}');
  `
  execFileSync('sqlite3', [dbPath, sql])
  const app = await electron.launch({
    args: [path.resolve(process.cwd(), 'desktop'), `--user-data-dir=${userDataDir}`],
    cwd: process.cwd(),
    env: { ...process.env, NODE_ENV: 'production' },
  })
  await app.firstWindow()
  await app.close()
  const version = execFileSync('sqlite3', [dbPath, 'SELECT MAX(version) FROM schema_version;']).toString().trim()
  expect(version).toBe(CURRENT_SCHEMA_VERSION)
  expect(existsSync(dbPath)).toBe(true)
  expect(readFileSync(dbPath).length).toBeGreaterThan(0)
  expect(execFileSync('sqlite3', [dbPath, 'PRAGMA integrity_check;']).toString().trim()).toBe('ok')
  expect(execFileSync('sqlite3', [dbPath, 'PRAGMA foreign_key_check;']).toString().trim()).toBe('')
  expect(execFileSync('sqlite3', [dbPath, "SELECT name FROM sessions WHERE id = 'legacy';"]).toString().trim()).toBe('Legacy')
  expect(execFileSync('sqlite3', [dbPath, "SELECT session_id FROM metadata_outbox_sessions WHERE xmp_path = '/tmp/legacy.xmp';"]).toString().trim()).toBe('legacy')
  // The migrated session table must expose the workflow columns the app queries.
  const status = execFileSync('sqlite3', [dbPath, "SELECT status || ':' || analysis_status || ':' || writeback_status FROM sessions WHERE id = 'legacy';"]).toString().trim()
  expect(status).toBe('draft:idle:idle')
  const backupName = readdirSync(userDataDir)
    .find(file => file.startsWith(LEGACY_BACKUP_PREFIX) && file.endsWith('.bak'))
  expect(backupName).toBeTruthy()
  expect(execFileSync('sqlite3', [path.join(userDataDir, backupName!), 'PRAGMA integrity_check;']).toString().trim()).toBe('ok')
  rmSync(userDataDir, { recursive: true, force: true })
})

test('restores the pre-migration database when a migration fails after writing', async () => {
  test.skip(!hasSqliteCli(), 'sqlite3 CLI is required for the migration recovery fixture')
  const userDataDir = mkdtempSync(path.join(tmpdir(), 'gather-migration-rollback-'))
  const dbPath = path.join(userDataDir, 'gather.db')
  execFileSync('sqlite3', [dbPath, `
    CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
    INSERT INTO schema_version VALUES (23, '${new Date().toISOString()}');
  `])

  try {
    const app = await electron.launch({
      args: [path.resolve(process.cwd(), 'desktop'), `--user-data-dir=${userDataDir}`],
      cwd: process.cwd(),
      env: {
        ...process.env,
        NODE_ENV: 'test',
        GATHER_TEST_FAIL_MIGRATION: 'after-migrate',
      },
    })
    if (app.process().exitCode === null) {
      await Promise.race([
        new Promise<void>(resolve => {
          app.process().once('exit', () => resolve())
        }),
        new Promise<void>(resolve => setTimeout(resolve, 10_000)),
      ])
      if (app.process().exitCode === null) await app.close()
    }
  } catch {
    // A failed startup may close the Playwright transport before launch returns.
  }

  expect(
    execFileSync('sqlite3', [dbPath, 'SELECT MAX(version) FROM schema_version;'])
      .toString()
      .trim(),
  ).toBe('23')
  expect(
    execFileSync('sqlite3', [
      dbPath,
      "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'asset_backfill_state';",
    ]).toString().trim(),
  ).toBe('0')
  expect(
    execFileSync('sqlite3', [dbPath, 'PRAGMA integrity_check;']).toString().trim(),
  ).toBe('ok')
  expect(
    readdirSync(userDataDir).some(
      file => file.startsWith(LEGACY_BACKUP_PREFIX) && file.endsWith('.bak'),
    ),
  ).toBe(true)
  rmSync(userDataDir, { recursive: true, force: true })
})
