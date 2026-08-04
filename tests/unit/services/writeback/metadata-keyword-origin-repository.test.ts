import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import BetterSqlite3 from 'better-sqlite3'
import { INDEX_SQL, SCHEMA_SQL } from '../../../../desktop/src/main/db/schema'
import { MetadataKeywordOriginRepository } from '../../../../desktop/src/main/db/repositories/metadata-keyword-origin.repo'

describe('MetadataKeywordOriginRepository', () => {
  let directory: string
  let database: BetterSqlite3.Database
  let repository: MetadataKeywordOriginRepository

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-keyword-origin-'))
    database = new BetterSqlite3(path.join(directory, 'test.db'))
    database.exec(SCHEMA_SQL)
    database.exec(INDEX_SQL)
    repository = new MetadataKeywordOriginRepository({
      prepare: (sql: string) => database.prepare(sql),
      transaction: <T>(operation: () => T) => database.transaction(operation),
    } as never)
  })

  afterEach(() => {
    database.close()
    fs.rmSync(directory, { recursive: true, force: true })
  })

  it('only returns active keywords introduced by the requested source', () => {
    repository.markIntroduced('/photos/IMG_0001.xmp', 'face-keyword', [
      'Alice',
      'portrait',
      'Alice',
    ])
    repository.markIntroduced('/photos/IMG_0001.xmp', 'template', ['portrait'])

    expect(repository.getActiveIntroduced(
      '/photos/IMG_0001.xmp',
      'face-keyword',
      ['Alice', 'portrait', 'manual'],
    )).toEqual(expect.arrayContaining(['Alice', 'portrait']))
    expect(repository.getActiveIntroduced(
      '/photos/IMG_0001.xmp',
      'face-keyword',
      ['manual'],
    )).toEqual([])
  })

  it('deactivates only the requested source ownership and supports reactivation', () => {
    const xmpPath = '/photos/IMG_0002.xmp'
    repository.markIntroduced(xmpPath, 'face-keyword', ['Alice'])
    repository.markIntroduced(xmpPath, 'template', ['Alice'])
    repository.deactivate(xmpPath, 'face-keyword', ['Alice'])

    expect(repository.getActiveIntroduced(xmpPath, 'face-keyword', ['Alice'])).toEqual([])
    expect(repository.getActiveIntroduced(xmpPath, 'template', ['Alice'])).toEqual(['Alice'])

    repository.markIntroduced(xmpPath, 'face-keyword', ['Alice'])
    expect(repository.getActiveIntroduced(xmpPath, 'face-keyword', ['Alice'])).toEqual(['Alice'])
  })
})
