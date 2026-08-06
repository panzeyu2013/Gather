import { describe, it, expect } from 'vitest'
import { DI_TOKENS } from '../../../../desktop/src/main/di/container'

const EXPECTED_TOKEN_KEYS = [
  'DB',
  'PHOTO_REPO',
  'ASSET_REPO',
  'SESSION_REPO',
  'FACE_REPO',
  'PERSON_REPO',
  'CULLING_DECISION_REPO',
  'CULLING_HISTORY_REPO',
  'SIMILARITY_RESULT_REPO',
  'WRITEBACK_REPO',
  'METADATA_OUTBOX_REPO',
  'METADATA_CACHE_REPO',
  'METADATA_KEYWORD_ORIGIN_REPO',
  'SMART_ALBUM_REPO',
  'SETTINGS_REPO',
  'SETTINGS_SERVICE',
  'CULLING_SERVICE',
  'DUPLICATE_SERVICE',
  'EXPORT_SERVICE',
  'REPORT_SERVICE',
  'SESSION_SERVICE',
  'SIMILARITY_SERVICE',
  'FACE_KW_SERVICE',
  'METADATA_SERVICE',
  'WRITEBACK_SERVICE',
  'TEMPLATE_SERVICE',
  'FILTER_ENGINE',
  'IMAGE_SERVICE',
  'METADATA_SYNC_COORDINATOR',
  'METADATA_MUTATION_SERVICE',
  'ANALYSIS_JOB_REPO',
  'JOB_SERVICE',
  'INDEX_SERVICE',
  'QUALITY_SERVICE',
  'NAVIGATION_SERVICE',
  'PHOTO_ASSET_RESOLVER',
  'WRITER_ROUTER',
  'THUMBNAIL_CACHE',
  'IMAGE_DECODERS',
]

describe('DI tokens', () => {
  it('exports every expected token so a removed binding cannot go unnoticed', () => {
    for (const key of EXPECTED_TOKEN_KEYS) {
      expect(DI_TOKENS, `DI_TOKENS.${key}`).toHaveProperty(key)
    }
  })

  it('keeps every token a unique symbol', () => {
    const values = Object.values(DI_TOKENS)
    expect(values.length).toBe(Object.keys(DI_TOKENS).length)
    for (const value of values) {
      expect(typeof value).toBe('symbol')
    }
    expect(new Set(values).size).toBe(values.length)
  })
})
