import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import BetterSqlite3 from 'better-sqlite3'
import { SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'
import { SettingsRepository } from '../../../../desktop/src/main/db/repositories/settings.repo'
import {
  SettingsService,
  getDefaults,
} from '../../../../desktop/src/main/services/settings/settings.service'

describe('face decode concurrency setting', () => {
  let directory: string
  let database: BetterSqlite3.Database
  let service: SettingsService

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-face-settings-'))
    database = new BetterSqlite3(path.join(directory, 'test.db'))
    database.exec(SCHEMA_SQL)
    const db = {
      prepare: (sql: string) => database.prepare(sql),
      transaction: <T>(operation: () => T) => database.transaction(operation),
    } as never
    service = new SettingsService(new SettingsRepository(db))
  })

  afterEach(() => {
    database.close()
    fs.rmSync(directory, { recursive: true, force: true })
  })

  it('registers face_decode_concurrency as a default setting', () => {
    expect(getDefaults()).toHaveProperty('face_decode_concurrency')
    expect(Number(getDefaults().face_decode_concurrency)).toBeGreaterThanOrEqual(1)
  })

  it('accepts face_decode_concurrency in settings.set (registered key)', () => {
    expect(() => service.set('face_decode_concurrency', '6')).not.toThrow()
    expect(service.getNumber('face_decode_concurrency', 4)).toBe(6)
  })

  it('falls back to the default when the key is not persisted', () => {
    expect(service.getNumber('face_decode_concurrency', 4)).toBe(4)
  })

  it('includes the key in getAll()', () => {
    expect(service.getAll()).toHaveProperty('face_decode_concurrency')
  })
})
