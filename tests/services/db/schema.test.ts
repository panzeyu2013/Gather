import { describe, expect, it } from 'vitest'
import {
  INDEX_SQL,
  SCHEMA_SQL,
  UNIQUE_PHOTO_PATH_INDEX_SQL,
} from '../../../desktop/src/main/db/schema'

describe('database schema migration boundaries', () => {
  it('creates migration-dependent indexes only after migrations', () => {
    expect(INDEX_SQL).toContain('idx_face_clusters_matched_person')
    expect(INDEX_SQL).not.toContain('idx_photos_session_filepath')
    expect(UNIQUE_PHOTO_PATH_INDEX_SQL).toContain(
      'UNIQUE INDEX IF NOT EXISTS idx_photos_session_filepath',
    )
  })

  it('includes the color label cache column for new databases', () => {
    expect(SCHEMA_SQL).toMatch(/rating INTEGER DEFAULT 0,\s+label TEXT,/)
  })

  it('persists the source folder used to create a session', () => {
    expect(SCHEMA_SQL).toMatch(/import_source TEXT NOT NULL DEFAULT 'unknown',\s+source_path TEXT NOT NULL DEFAULT '',/)
  })

  it('tracks source fingerprints for perceptual-hash invalidation', () => {
    expect(SCHEMA_SQL).toMatch(/hash_hex TEXT NOT NULL,\s+file_size INTEGER NOT NULL DEFAULT 0,\s+file_mtime_ms REAL NOT NULL DEFAULT 0/)
    expect(INDEX_SQL).toContain('idx_similarity_hashes_session_photo')
  })

  it('tracks source and model fingerprints for incremental face analysis', () => {
    expect(SCHEMA_SQL).toMatch(/source_file_size INTEGER NOT NULL DEFAULT 0,\s+source_file_mtime_ms REAL NOT NULL DEFAULT 0,\s+analysis_signature TEXT NOT NULL DEFAULT ''/)
    expect(SCHEMA_SQL).toContain('CREATE TABLE IF NOT EXISTS face_analysis_state')
    expect(INDEX_SQL).toContain('idx_face_analysis_state_session')
    expect(SCHEMA_SQL).toContain('CREATE TABLE IF NOT EXISTS face_cluster_state')
  })

  it('materializes similarity memberships and supports atomic culling upserts', () => {
    expect(SCHEMA_SQL).toContain('CREATE TABLE IF NOT EXISTS similarity_result_members')
    expect(INDEX_SQL).toContain('idx_similarity_members_session_photo')
    expect(INDEX_SQL).toContain('idx_culling_session_photo_unique')
  })
})
