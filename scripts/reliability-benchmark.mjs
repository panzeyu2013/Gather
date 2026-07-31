import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import { execFileSync } from 'node:child_process'

const sizes = [500, 5_000, 10_000, 100_000]

function benchmark(count) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-reliability-'))
  const dbPath = path.join(root, 'index.db')
  const rows = Array.from({ length: count }, (_, index) => ({
    id: `synthetic-photo-${index + 1}`,
    filepath: `/synthetic/Gather/${index + 1}.jpg`,
    size: 1024 + index,
    mtimeMs: 1_700_000_000_000 + index,
  }))
  const beforeRss = process.memoryUsage().rss
  const sqlPath = path.join(root, 'import.sql')
  const statements = [`
    PRAGMA journal_mode = WAL;
    CREATE TABLE asset_files (
      id TEXT PRIMARY KEY,
      normalized_path TEXT NOT NULL UNIQUE,
      file_size INTEGER NOT NULL,
      file_mtime_ms REAL NOT NULL
    );
    BEGIN IMMEDIATE;
  `]
  for (const row of rows) {
    statements.push(
      `INSERT INTO asset_files VALUES ('${row.id}', '${row.filepath}', ${row.size}, ${row.mtimeMs});`,
    )
  }
  statements.push('COMMIT;', 'PRAGMA wal_checkpoint(TRUNCATE);')
  fs.writeFileSync(sqlPath, statements.join('\n'))
  const importStarted = performance.now()
  execFileSync('sqlite3', [dbPath, `.read ${sqlPath}`], {
    stdio: 'ignore',
    maxBuffer: 64 * 1024 * 1024,
  })
  const importMs = performance.now() - importStarted

  const reopenStarted = performance.now()
  const queryResult = execFileSync(
    'sqlite3',
    [dbPath, 'SELECT COUNT(*), SUM(file_size), SUM(file_mtime_ms) FROM asset_files;'],
    { encoding: 'utf8' },
  ).trim()
  const reopenAndReadMs = performance.now() - reopenStarted
  if (!queryResult.startsWith(`${count}|`)) throw new Error(`SQLite index lost rows at ${count}`)

  const result = {
    importMs,
    reopenAndReadMs,
    coordinatorRssDeltaBytes: Math.max(0, process.memoryUsage().rss - beforeRss),
    sqliteBytes: fs.statSync(dbPath).size,
  }
  fs.rmSync(root, { recursive: true, force: true })
  return result
}

const result = Object.fromEntries(sizes.map(size => [size, benchmark(size)]))
console.log(JSON.stringify({
  generatedAt: new Date().toISOString(),
  note: 'Synthetic SQLite CLI transaction and indexed reopen/aggregate benchmark; image decoding, SQLite child peak RSS, and renderer timing are measured separately.',
  result,
}, null, 2))
