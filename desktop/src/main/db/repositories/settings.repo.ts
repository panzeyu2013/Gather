import { getDatabase } from '../database'

export interface SettingsRow {
  key: string
  value: string
}

export class SettingsRepository {
  getAll(): SettingsRow[] {
    const db = getDatabase()
    return db.prepare('SELECT key, value FROM app_settings').all() as SettingsRow[]
  }

  get(key: string): SettingsRow | undefined {
    const db = getDatabase()
    return db.prepare('SELECT key, value FROM app_settings WHERE key = ?').get(key) as SettingsRow | undefined
  }

  upsert(key: string, value: string): void {
    const db = getDatabase()
    db.prepare('INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(key, value)
  }

  batchUpsert(entries: { key: string; value: string }[]): void {
    const db = getDatabase()
    const stmt = db.prepare('INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    const batch = db.transaction(() => {
      for (const e of entries) stmt.run(e.key, e.value)
    })
    batch()
  }
}
