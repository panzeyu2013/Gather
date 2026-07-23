import BetterSqlite3 from 'better-sqlite3'
import path from 'path'
import { app } from 'electron'
import { injectable } from '../di/container'

@injectable()
export class Database {
  private db: BetterSqlite3.Database | null = null

  private getDb(): BetterSqlite3.Database {
    if (this.db) return this.db

    const dbPath = path.join(app.getPath('userData'), 'gather.db')
    this.db = new BetterSqlite3(dbPath)

    this.db.pragma('journal_mode = WAL')
    this.db.pragma('synchronous = NORMAL')
    this.db.pragma('cache_size = -64000')
    this.db.pragma('foreign_keys = ON')

    return this.db
  }

  prepare(sql: string): BetterSqlite3.Statement {
    return this.getDb().prepare(sql)
  }

  transaction<TArgs extends unknown[], TResult>(fn: (...args: TArgs) => TResult): (...args: TArgs) => TResult {
    return this.getDb().transaction(fn) as (...args: TArgs) => TResult
  }

  pragma(sql: string): void {
    this.getDb().pragma(sql)
  }

  close(): void {
    if (this.db) {
      this.db.close()
      this.db = null
    }
  }

  get rawDb(): BetterSqlite3.Database {
    return this.getDb()
  }
}
