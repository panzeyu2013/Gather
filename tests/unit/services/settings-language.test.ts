import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import BetterSqlite3 from 'better-sqlite3'
import { SCHEMA_SQL } from '../../../desktop/src/main/db/schema'
import { SettingsRepository } from '../../../desktop/src/main/db/repositories/settings.repo'
import { SettingsService } from '../../../desktop/src/main/services/settings/settings.service'

describe('ui_language setting persistence', () => {
  let directory: string
  let database: BetterSqlite3.Database
  let service: SettingsService

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-settings-language-'))
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

  it('defaults to unset (empty = follow --lang/system locale)', () => {
    expect(service.get('ui_language', '')).toBe('')
  })

  it('accepts ui_language in settings.set (registered key) and round-trips it', () => {
    expect(() => service.set('ui_language', 'zh-CN')).not.toThrow()
    expect(service.get('ui_language', '')).toBe('zh-CN')
    expect(service.getAll()).toHaveProperty('ui_language', 'zh-CN')
  })

  it('persists across service re-instantiation (survives restart)', () => {
    service.set('ui_language', 'en')
    const restarted = new SettingsService(new SettingsRepository(database as never))
    expect(restarted.get('ui_language', '')).toBe('en')
  })

  it('overwrites the previous value', () => {
    service.set('ui_language', 'zh-CN')
    service.set('ui_language', 'en')
    expect(service.get('ui_language', '')).toBe('en')
  })
})
