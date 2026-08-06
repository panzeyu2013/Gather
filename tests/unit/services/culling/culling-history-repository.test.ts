import BetterSqlite3 from 'better-sqlite3'
import { afterEach, describe, expect, it } from 'vitest'
import { SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'
import { CullingHistoryRepository } from '../../../../desktop/src/main/db/repositories/culling-history.repo'

const databases: BetterSqlite3.Database[] = []

function fixture(): CullingHistoryRepository {
  const db = new BetterSqlite3(':memory:')
  databases.push(db)
  // Use the production schema so a column the repository depends on cannot
  // silently diverge from the inline fixture table.
  db.exec(SCHEMA_SQL)
  db.prepare(`
    INSERT INTO sessions (id, name, status, analysis_status, writeback_status,
      import_source, source_path, photo_count, failed_writeback_count, created_at, updated_at)
    VALUES ('session', '', 'draft', 'idle', 'idle', 'manual', '', 0, 0, ?, ?)
  `).run(new Date().toISOString(), new Date().toISOString())
  return new CullingHistoryRepository({
    prepare: (sql: string) => db.prepare(sql),
    transaction: <T>(operation: () => T) => db.transaction(operation),
  } as never)
}

const entry = (photoId: string) => [{
  photoId,
  before: { pickState: 'unreviewed' as const, rating: 0, colorLabel: 'None' as const },
  after: { pickState: 'picked' as const, rating: 0, colorLabel: 'None' as const },
  expectedRevision: 1,
  fields: ['pickState' as const],
}]

afterEach(() => {
  for (const db of databases.splice(0)) db.close()
})

describe('CullingHistoryRepository', () => {
  it('enforces stack order for undo and redo across persisted operations', () => {
    const repository = fixture()
    const first = repository.append('session', entry('p1'))
    const second = repository.append('session', entry('p2'))

    expect(() => repository.setUndone('session', first.id, true))
      .toThrow('只能撤销最近一次')
    repository.setUndone('session', second.id, true)
    repository.setUndone('session', first.id, true)
    expect(() => repository.setUndone('session', second.id, false))
      .toThrow('必须按原顺序重做')
    repository.setUndone('session', first.id, false)
    repository.setUndone('session', second.id, false)

    expect(repository.list('session').map(operation => operation.undone))
      .toEqual([false, false])
  })

  it('drops the redo branch when a new operation is appended after undo', () => {
    const repository = fixture()
    repository.append('session', entry('p1'))
    const abandoned = repository.append('session', entry('p2'))
    repository.setUndone('session', abandoned.id, true)
    const replacement = repository.append('session', entry('p3'))

    expect(repository.get('session', abandoned.id)).toBeNull()
    expect(repository.list('session').map(operation => operation.id))
      .toEqual([replacement.id, 1])
  })
})
