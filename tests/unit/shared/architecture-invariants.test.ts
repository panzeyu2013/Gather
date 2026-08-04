// tests/shared/architecture-invariants.test.ts
// 架构不变量：防止索引 DDL 在迁移版本块与全局 INDEX_SQL 之间重复，
// 并保证 schema 内每个索引名只被定义一次。
import fs from 'fs'
import path from 'path'
import {
  INDEX_SQL,
  SCHEMA_SQL,
  UNIQUE_PHOTO_PATH_INDEX_SQL,
} from '../../../desktop/src/main/db/schema'

function findIndexNames(sql: string): Set<string> {
  const names = new Set<string>()
  for (const match of sql.matchAll(/CREATE (?:UNIQUE )?INDEX (?:IF NOT EXISTS )?([\w.]+)/g)) {
    names.add(match[1])
  }
  return names
}

function desktopRoot(): string {
  return path.basename(process.cwd()) === 'desktop'
    ? process.cwd()
    : path.resolve(process.cwd(), 'desktop')
}

describe('architecture invariants', () => {
  it('keeps permanent indexes out of migration version blocks', () => {
    // runMigrationsUnsafe always ends with db.exec(INDEX_SQL), so any index also
    // created inside a migration version block is redundant DDL and will be
    // created a second time on every fresh database.
    const source = fs.readFileSync(
      path.join(desktopRoot(), 'src/main/db/migrations.ts'),
      'utf8',
    )
    const migrationIndexes = findIndexNames(source)
    const globalIndexes = findIndexNames(INDEX_SQL)
    const redundant = [...migrationIndexes]
      .filter(name => globalIndexes.has(name))
      .sort()
    expect(redundant).toEqual([])
  })

  it('defines every index name at most once across schema and migrations', () => {
    const occurrences = new Map<string, number>()
    const migrationsSource = fs.readFileSync(
      path.join(desktopRoot(), 'src/main/db/migrations.ts'),
      'utf8',
    )
    for (const name of [
      ...findIndexNames(SCHEMA_SQL),
      ...findIndexNames(INDEX_SQL),
      ...findIndexNames(UNIQUE_PHOTO_PATH_INDEX_SQL),
      ...findIndexNames(migrationsSource),
    ]) {
      occurrences.set(name, (occurrences.get(name) ?? 0) + 1)
    }
    const duplicated = [...occurrences.entries()]
      .filter(([, count]) => count > 1)
      .map(([name]) => name)
      .sort()
    expect(duplicated).toEqual([])
  })
})
