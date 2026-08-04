import { describe, expect, it } from 'vitest'
import {
  normalizeDatabaseRuntimeSettings,
} from '../../../desktop/src/main/runtime-settings'

describe('database runtime settings', () => {
  it('normalizes supported values', () => {
    expect(normalizeDatabaseRuntimeSettings(' full ', 128.9)).toEqual({
      synchronous: 'FULL',
      cacheSizeMb: 128,
    })
  })

  it('falls back and clamps corrupted persisted settings', () => {
    expect(normalizeDatabaseRuntimeSettings('NORMAL; DROP TABLE photos', Number.NaN))
      .toEqual({ synchronous: 'NORMAL', cacheSizeMb: 64 })
    expect(normalizeDatabaseRuntimeSettings('off', -10).cacheSizeMb).toBe(1)
    expect(normalizeDatabaseRuntimeSettings('extra', 10_000).cacheSizeMb).toBe(4096)
  })
})
