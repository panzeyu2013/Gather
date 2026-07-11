import Database from 'better-sqlite3'
import path from 'path'
import { app } from 'electron'

let db: Database.Database | null = null

export function getDatabase(): Database.Database {
  if (db) return db

  const dbPath = path.join(app.getPath('userData'), 'gather.db')
  db = new Database(dbPath)

  db.pragma('journal_mode = WAL')
  db.pragma('synchronous = NORMAL')
  db.pragma('cache_size = -64000')
  db.pragma('foreign_keys = ON')

  return db
}

export function closeDatabase(): void {
  if (db) {
    db.close()
    db = null
  }
}
