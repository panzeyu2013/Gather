import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface SettingsRow {
  key: string
  value: string
}

@injectable()
export class SettingsRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getAll(): SettingsRow[] {
    return this.db.prepare('SELECT key, value FROM app_settings').all() as SettingsRow[]
  }

  get(key: string): SettingsRow | undefined {
    return this.db.prepare('SELECT key, value FROM app_settings WHERE key = ?').get(key) as SettingsRow | undefined
  }

  upsert(key: string, value: string): void {
    this.db.prepare('INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value').run(key, value)
  }

  batchUpsert(entries: { key: string; value: string }[]): void {
    const stmt = this.db.prepare('INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    const batch = this.db.transaction(() => {
      for (const e of entries) stmt.run(e.key, e.value)
    })
    batch()
  }
}
