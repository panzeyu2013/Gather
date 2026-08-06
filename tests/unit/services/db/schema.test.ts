import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it } from 'vitest'
import {
  INDEX_SQL,
  SCHEMA_SQL,
  UNIQUE_PHOTO_PATH_INDEX_SQL,
} from '../../../../desktop/src/main/db/schema'

const databases: BetterSqlite3.Database[] = []

function createSchemaDb(): BetterSqlite3.Database {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  db.exec(SCHEMA_SQL)
  db.exec(INDEX_SQL)
  return db
}

function columnsOf(db: BetterSqlite3.Database, table: string): string[] {
  return (db.pragma(`table_info(${table})`) as Array<{ name: string }>)
    .map(column => column.name)
}

function tablesOf(db: BetterSqlite3.Database): string[] {
  return (db.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  ).all() as Array<{ name: string }>).map(row => row.name)
}

function indexNames(db: BetterSqlite3.Database): string[] {
  return (db.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'index'",
  ).all() as Array<{ name: string }>).map(row => row.name)
}

afterEach(() => {
  for (const db of databases.splice(0)) db.close()
})

// The schema constants are guard-tested against a real SQLite database rather
// than by string-matching the constants themselves: a column or index that is
// renamed here will only be found if the executed schema actually contains it.
describe('database schema migration boundaries', () => {
  it('creates migration-dependent indexes only after migrations', () => {
    expect(INDEX_SQL).toContain('idx_face_clusters_matched_person')
    expect(INDEX_SQL).not.toContain('idx_photos_session_filepath')
    expect(UNIQUE_PHOTO_PATH_INDEX_SQL).toContain(
      'UNIQUE INDEX IF NOT EXISTS idx_photos_session_filepath',
    )
  })

  it('includes the color label cache column for new databases', () => {
    const db = createSchemaDb()
    const columns = columnsOf(db, 'photo_metadata_cache')
    expect(columns).toContain('rating')
    expect(columns).toContain('label')
  })

  it('persists the source folder used to create a session', () => {
    const columns = columnsOf(createSchemaDb(), 'sessions')
    expect(columns).toContain('import_source')
    expect(columns).toContain('source_path')
  })

  it('tracks source fingerprints for perceptual-hash invalidation', () => {
    const db = createSchemaDb()
    const columns = columnsOf(db, 'similarity_hashes')
    expect(columns).toContain('hash_hex')
    expect(columns).toContain('file_size')
    expect(columns).toContain('file_mtime_ms')
    expect(indexNames(db)).toContain('idx_similarity_hashes_session_photo')
  })

  it('tracks source and model fingerprints for incremental face analysis', () => {
    const db = createSchemaDb()
    const columns = columnsOf(db, 'face_analysis_state')
    expect(columns).toContain('source_file_size')
    expect(columns).toContain('source_file_mtime_ms')
    expect(columns).toContain('analysis_signature')
    expect(tablesOf(db)).toContain('face_analysis_state')
    expect(tablesOf(db)).toContain('face_cluster_state')
    expect(indexNames(db)).toContain('idx_face_analysis_state_session')
  })

  it('materializes similarity memberships and supports atomic culling upserts', () => {
    const db = createSchemaDb()
    expect(tablesOf(db)).toContain('similarity_result_members')
    const indexes = indexNames(db)
    expect(indexes).toContain('idx_similarity_members_session_photo')
    expect(indexes).toContain('idx_culling_session_photo_unique')
  })

  it('persists independent culling state and a recoverable metadata outbox', () => {
    const db = createSchemaDb()
    const cullingColumns = columnsOf(db, 'culling_decisions')
    expect(cullingColumns).toContain('rating')
    expect(cullingColumns).toContain('color_label')
    expect(cullingColumns).toContain('revision')
    const outboxColumns = columnsOf(db, 'metadata_outbox')
    expect(outboxColumns).toContain('persisted_revision')
    expect(tablesOf(db)).toContain('metadata_outbox')
    expect(indexNames(db)).toContain('idx_metadata_outbox_session_status')
  })
})
