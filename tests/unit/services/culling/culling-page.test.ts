import { describe, expect, it, vi } from 'vitest'
import { CullingService } from '../../../../desktop/src/main/services/culling/culling.service'

type Statement = { all: ReturnType<typeof vi.fn>; get: ReturnType<typeof vi.fn>; run: ReturnType<typeof vi.fn> }

/** Per-SQL mock: `rows` feeds `.all()`, `count` feeds the `.get()` of COUNT(*)
 * queries (falling back to `{ count: 7 }` for any other COUNT query). */
type RowHandler = (sql: string) => { rows?: unknown[]; count?: number } | undefined

function createDbMock(rowsBySql?: RowHandler) {
  const calls: string[] = []
  const prepare = vi.fn((sql: string) => {
    calls.push(sql)
    const statement: Statement = {
      all: vi.fn(() => rowsBySql?.(sql)?.rows ?? []),
      get: vi.fn(() => {
        const handled = rowsBySql?.(sql)
        if (handled && handled.count !== undefined) return { count: handled.count }
        return sql.includes('COUNT(*)') ? { count: 7 } : undefined
      }),
      run: vi.fn(),
    }
    return statement
  })
  return { prepare, calls }
}

/** Replaces the db mock with a row-returning implementation while keeping the
 * SQL call log intact. */
function recordCalls(mocks: { db: { calls: string[] } }, rowsBySql?: RowHandler) {
  mocks.db.prepare.mockImplementation((sql: string) => {
    mocks.db.calls.push(sql)
    const statement: Statement = {
      all: vi.fn(() => rowsBySql?.(sql)?.rows ?? []),
      get: vi.fn(() => {
        const handled = rowsBySql?.(sql)
        if (handled && handled.count !== undefined) return { count: handled.count }
        return sql.includes('COUNT(*)') ? { count: 7 } : undefined
      }),
      run: vi.fn(),
    }
    return statement
  })
}

/** Mock rows for the two-step group queries of the paginated culling page. */
function groupRows(groups: Array<{ gid: string; first_rowid: number }>) {
  return { rows: groups }
}

const PAGE_ROWS = [
  {
    rowid: 1,
    id: 'p1',
    session_id: 's',
    filepath: '/shoot/a.jpg',
    filename: 'a.jpg',
    status: 'pending',
    asset_id: null,
    asset_file_id: 'af1',
    width: 100,
    height: 100,
    created_at: '',
    updated_at: '',
  },
  {
    rowid: 2,
    id: 'p2',
    session_id: 's',
    filepath: '/shoot/b.jpg',
    filename: 'b.jpg',
    status: 'pending',
    asset_id: null,
    asset_file_id: 'af2',
    width: 200,
    height: 200,
    created_at: '',
    updated_at: '',
  },
]

/** Handles the two-step SQL page (group query + per-group rows query) and the
 * scope COUNT(*) query for the mocked db. The COUNT branch must be checked
 * first: the count subquery also contains `GROUP BY`. */
function pageHandler(groups: Array<{ gid: string; first_rowid: number }>, rows: unknown[]) {
  return (sql: string) => {
    if (sql.includes('COUNT(*)') && sql.includes('GROUP BY')) return { count: groups.length }
    if (sql.includes('GROUP BY')) return groupRows(groups)
    if (sql.includes('COALESCE(p.asset_id, p.id) IN (')) return { rows }
    return undefined
  }
}

function baseMocks() {
  const photoRepo = {
    getAssetPage: vi.fn(() => ({ rows: PAGE_ROWS, cursor: 2 })),
    getBySession: vi.fn(() => []),
    countAssetsBySession: vi.fn(() => 100),
  }
  const cullingRepo = {
    getByPhotoIds: vi.fn(() => []),
    getBySession: vi.fn(() => []),
    getDecision: vi.fn(() => undefined),
    upsertState: vi.fn(),
  }
  const similarityRepo = {
    getLatest: vi.fn(() => undefined),
    getPhotoGroupMap: vi.fn(() => new Map()),
  }
  const cacheRepo = {
    getBatch: vi.fn(() => []),
    updateRating: vi.fn(),
    updateLabel: vi.fn(),
  }
  const outboxRepo = {
    get: vi.fn(() => null),
    getBySession: vi.fn(() => []),
    mergePatch: vi.fn(),
  }
  const db = createDbMock()
  const settings = { getNumber: vi.fn((_key: string, fallback: number) => fallback) }
  const service = new CullingService(
    photoRepo as never,
    cullingRepo as never,
    similarityRepo as never,
    cacheRepo as never,
    outboxRepo as never,
    db as never,
    { schedule: vi.fn() } as never,
    { queuePhotoValues: vi.fn() } as never,
    settings as never,
  )
  return { photoRepo, cullingRepo, similarityRepo, cacheRepo, outboxRepo, db, settings, service }
}

describe('CullingService.listPage', () => {
  it('loads an asset-grouped light projection page and scopes every rich lookup to the page photo ids', () => {
    const mocks = baseMocks()
    const page = mocks.service.listPage('s', 'all')

    expect(mocks.photoRepo.getAssetPage).toHaveBeenCalledWith('s', undefined, 200)
    expect(mocks.cullingRepo.getByPhotoIds).toHaveBeenCalledWith('s', ['p1', 'p2'])
    expect(mocks.cacheRepo.getBatch).toHaveBeenCalledWith(['p1', 'p2'])
    expect(mocks.db.prepare).toHaveBeenCalledWith(expect.stringContaining('face_observations'))
    const faceSql = mocks.db.calls.find(sql => sql.includes('face_observations'))
    expect(faceSql).toBeDefined()
    expect(faceSql).toContain('photo_id IN (')
    const peopleSql = mocks.db.calls.find(sql => sql.includes('person_photos'))
    expect(peopleSql).toContain('photo_id IN (')
    const outboxSql = mocks.db.calls.find(sql => sql.includes('FROM metadata_outbox o'))
    expect(outboxSql).toContain('o.xmp_path IN (')

    expect(page.assets).toHaveLength(2)
    expect(page.assets.map(asset => asset.photo.id)).toEqual(['p1', 'p2'])
    // Cursor is the first rowid of the last asset group (max of per-asset
    // minimum rowids), not the last physical row.
    expect(page.nextRowId).toBe(2)
    expect(page.total).toBe(100)
  })

  it('continues from afterRowId on subsequent pages', () => {
    const mocks = baseMocks()
    mocks.service.listPage('s', 'all', undefined, undefined, 2)
    expect(mocks.photoRepo.getAssetPage).toHaveBeenCalledWith('s', 2, 200)
  })

  it('filters similarity_group scope through the JS map when the group id is unparseable', () => {
    const mocks = baseMocks()
    mocks.similarityRepo.getLatest.mockReturnValue({ id: 9 })
    mocks.similarityRepo.getPhotoGroupMap.mockReturnValue(new Map([
      ['p1', '9:0'],
      ['p2', '9:0'],
    ]))

    const page = mocks.service.listPage('s', 'similarity_group', undefined, 'stale-group-id')

    // Falls back to the asset-grouped repository keyset query.
    expect(mocks.photoRepo.getAssetPage).toHaveBeenCalledWith('s', undefined, 200)
    expect(page.assets).toHaveLength(0)
    expect(page.total).toBe(0)
    expect(page.nextRowId).toBe(2)
  })

  it('pushes a parseable similarity group id down to SQL and counts group members', () => {
    const mocks = baseMocks()
    mocks.similarityRepo.getLatest.mockReturnValue({ id: 9 })
    mocks.similarityRepo.getPhotoGroupMap.mockReturnValue(new Map([
      ['p1', '9:0'],
      ['p2', '9:0'],
    ]))
    recordCalls(mocks, pageHandler(
      [{ gid: 'p1', first_rowid: 1 }, { gid: 'p2', first_rowid: 2 }],
      PAGE_ROWS,
    ))

    const page = mocks.service.listPage('s', 'similarity_group', undefined, '9:0')

    const similaritySql = mocks.db.calls.find(sql =>
      sql.includes('similarity_result_members') && sql.includes('GROUP BY'))
    expect(similaritySql).toBeDefined()
    expect(similaritySql).toContain('srm.group_index = ?')
    // Membership is evaluated on the preferred row of each asset.
    expect(similaritySql).toContain('SELECT p2.id FROM photos p2')
    // The repository path is skipped for the raw SQL page.
    expect(mocks.photoRepo.getAssetPage).not.toHaveBeenCalled()
    expect(page.assets).toHaveLength(2)
    expect(page.assets.every(asset => asset.similarityGroupId === '9:0')).toBe(true)
    expect(page.total).toBe(2)
    expect(page.nextRowId).toBe(2)
  })

  it('excludes precomputed tier rows from the latest-result predicate of the all-groups scope', () => {
    const mocks = baseMocks()
    mocks.similarityRepo.getLatest.mockReturnValue({ id: 9 })
    mocks.similarityRepo.getPhotoGroupMap.mockReturnValue(new Map([
      ['p1', '9:0'],
      ['p2', '9:0'],
    ]))
    // Tier rows are inserted after the main analysis row, so a naive MAX(id)
    // resolves to the newest tier; its members carry no group id in the JS
    // similarity map and would be dropped, leaving the group scope empty.
    // The fixed predicate must fall back to the main row's members instead.
    recordCalls(mocks, pageHandler(
      [{ gid: 'p1', first_rowid: 1 }, { gid: 'p2', first_rowid: 2 }],
      PAGE_ROWS,
    ))

    const page = mocks.service.listPage('s', 'similarity_group')

    const similaritySql = mocks.db.calls.find(sql =>
      sql.includes('similarity_result_members') && sql.includes('GROUP BY'))
    expect(similaritySql).toBeDefined()
    expect(similaritySql).toContain('stats_json NOT LIKE')
    expect(similaritySql).toContain('"precomputed":true')
    expect(page.assets.map(asset => asset.photo.id)).toEqual(['p1', 'p2'])
    expect(page.assets.every(asset => asset.similarityGroupId === '9:0')).toBe(true)
    expect(page.total).toBe(2)
    expect(page.nextRowId).toBe(2)
  })

  it('pushes pick-state and rating filters down to SQL and counts with the same predicate', () => {
    const mocks = baseMocks()
    mocks.cullingRepo.getByPhotoIds.mockReturnValue([
      { photo_id: 'p1', decision: 'keep', rating: 4, color_label: 'None', decision_source: 'manual', revision: 1, updated_at: '' },
      { photo_id: 'p2', decision: 'keep', rating: 4, color_label: 'None', decision_source: 'manual', revision: 1, updated_at: '' },
    ])
    recordCalls(mocks, sql => {
      if (sql.includes('COUNT(*)') && sql.includes('LEFT JOIN culling_decisions')) return { count: 2 }
      if (sql.includes('GROUP BY') && sql.includes('LEFT JOIN culling_decisions')) {
        return groupRows([{ gid: 'p1', first_rowid: 1 }, { gid: 'p2', first_rowid: 2 }])
      }
      if (sql.includes('COALESCE(p.asset_id, p.id) IN (')) return { rows: PAGE_ROWS }
      return undefined
    })

    const page = mocks.service.listPage(
      's',
      'filtered',
      { pickStates: ['picked'], ratings: [4] },
      undefined,
      undefined,
      200,
    )

    const pageSql = mocks.db.calls.find(sql =>
      sql.includes('LEFT JOIN culling_decisions') && sql.includes('GROUP BY'))
    expect(pageSql).toBeDefined()
    expect(pageSql).toContain("COALESCE(d.decision, 'pending') IN (?)")
    expect(pageSql).toContain('COALESCE(d.rating, c.rating, 0) IN (?)')
    // The preferred-row predicate limits the pushdown to the RAW-first variant.
    expect(pageSql).toContain('SELECT p2.id FROM photos p2')
    expect(pageSql).toContain("LOWER(p2.filename) LIKE '%.nef'")
    const countSql = mocks.db.calls.find(sql => sql.includes('COUNT(*)'))
    expect(countSql).toContain("COALESCE(d.decision, 'pending') IN (?)")
    expect(countSql).toContain('SELECT p2.id FROM photos p2')
    // The repository keyset path is not used for the filtered scope.
    expect(mocks.photoRepo.getAssetPage).not.toHaveBeenCalled()
    expect(page.assets).toHaveLength(2)
    expect(page.total).toBe(2)
  })

  it('pushes quality status filters down to SQL', () => {
    const mocks = baseMocks()
    recordCalls(mocks, sql => {
      if (sql.includes('GROUP BY') && sql.includes('LEFT JOIN culling_decisions')) {
        return groupRows([{ gid: 'p1', first_rowid: 1 }])
      }
      if (sql.includes('COALESCE(p.asset_id, p.id) IN (')) return { rows: PAGE_ROWS }
      return undefined
    })

    mocks.service.listPage('s', 'filtered', { qualityStatus: 'analysed' })

    const pageSql = mocks.db.calls.find(sql =>
      sql.includes('LEFT JOIN culling_decisions') && sql.includes('GROUP BY'))
    expect(pageSql).toContain("json_extract(COALESCE((")
    expect(pageSql).toContain('json_valid(a3.result_json)')
    expect(pageSql).toContain("'$.status') = ?")

    mocks.db.calls.length = 0
    mocks.service.listPage('s', 'filtered', { qualityStatus: 'unanalysed' })
    const unanalysedSql = mocks.db.calls.find(sql =>
      sql.includes('LEFT JOIN culling_decisions') && sql.includes('GROUP BY'))
    expect(unanalysedSql).toContain('NOT EXISTS (')
    // Malformed result_json rows must not count as analysed (JS parity).
    expect(unanalysedSql).toContain('json_valid(a3.result_json)')
  })

  it('uses the group-query first_rowid as the cursor, not the loaded rows', () => {
    const mocks = baseMocks()
    // The pushed-down predicate would only select this group because the
    // preferred RAW matches; mirror that decision here so the JS safety net
    // keeps the asset.
    mocks.cullingRepo.getByPhotoIds.mockReturnValue([
      { photo_id: 'raw', decision: 'keep', rating: 0, color_label: 'None', decision_source: 'manual', revision: 1, updated_at: '' },
    ])
    // JPEG variant (rowid 1) loads alongside the matching RAW (rowid 2). The
    // cursor must stay at the group query's first_rowid (2): recomputing it
    // from the loaded rows would yield 1 and re-select the group on the next
    // page via HAVING MIN(p.rowid) > 1, duplicating the asset.
    const rows = [
      {
        rowid: 1,
        id: 'jpeg',
        session_id: 's',
        filepath: '/shoot/A001.jpg',
        filename: 'A001.jpg',
        status: 'pending',
        asset_id: 'asset-1',
        asset_file_id: 'af2',
        width: 200,
        height: 200,
        created_at: '',
        updated_at: '',
      },
      {
        rowid: 2,
        id: 'raw',
        session_id: 's',
        filepath: '/shoot/A001.NEF',
        filename: 'A001.NEF',
        status: 'pending',
        asset_id: 'asset-1',
        asset_file_id: 'af1',
        width: 100,
        height: 100,
        created_at: '',
        updated_at: '',
      },
    ]
    recordCalls(mocks, sql => {
      if (sql.includes('COUNT(*)') && sql.includes('LEFT JOIN culling_decisions')) {
        return { count: 1 }
      }
      if (sql.includes('GROUP BY') && sql.includes('LEFT JOIN culling_decisions')) {
        return groupRows([{ gid: 'asset-1', first_rowid: 2 }])
      }
      if (sql.includes('COALESCE(p.asset_id, p.id) IN (')) return { rows }
      return undefined
    })

    const page = mocks.service.listPage('s', 'filtered', { pickStates: ['picked'] })

    expect(page.assets).toHaveLength(1)
    expect(page.assets[0].photo.id).toBe('raw')
    expect(page.nextRowId).toBe(2)
  })

  it('keeps RAW/JPEG variants of one asset together on a single page', () => {
    const mocks = baseMocks()
    const variantRows = [
      {
        rowid: 1,
        id: 'raw',
        session_id: 's',
        filepath: '/shoot/A001.NEF',
        filename: 'A001.NEF',
        status: 'pending',
        asset_id: 'asset-1',
        asset_file_id: 'af1',
        width: 100,
        height: 100,
        created_at: '',
        updated_at: '',
      },
      {
        rowid: 2,
        id: 'jpeg',
        session_id: 's',
        filepath: '/shoot/A001.jpg',
        filename: 'A001.jpg',
        status: 'pending',
        asset_id: 'asset-1',
        asset_file_id: 'af2',
        width: 200,
        height: 200,
        created_at: '',
        updated_at: '',
      },
    ]
    // The 'all' scope page comes from the repository; feed it the asset
    // group's two rows directly (already grouped at the asset boundary).
    mocks.photoRepo.getAssetPage.mockReturnValue({ rows: variantRows, cursor: 1 })
    recordCalls(mocks, pageHandler([{ gid: 'asset-1', first_rowid: 1 }], variantRows))

    const page = mocks.service.listPage('s', 'all', undefined, undefined, undefined, 1)

    expect(page.assets).toHaveLength(1)
    const asset = page.assets[0]
    expect(asset.photo.id).toBe('raw')
    expect(asset.photo.variantCount).toBe(2)
    expect(asset.linkedVariantCount).toBe(2)
    expect(asset.photo.variants.map(variant => variant.photoId)).toEqual(['raw', 'jpeg'])
    expect(asset.photo.variants[0].role).toBe('primary')
    // Cursor is the asset group's first rowid, not the last physical row.
    expect(page.nextRowId).toBe(1)
  })
})

describe('CullingService.list after refactor', () => {
  it('still materializes assets from the full session row set', () => {
    const mocks = baseMocks()
    mocks.photoRepo.getBySession.mockReturnValue([{
      id: 'p1',
      session_id: 's',
      filepath: '/shoot/a.jpg',
      filename: 'a.jpg',
      checksum: '',
      checksum_file_size: 0,
      checksum_file_mtime_ms: 0,
      status: 'pending',
      metadata: '{"make":"Nikon"}',
      result: '{}',
      asset_id: null,
      asset_file_id: 'af1',
      width: 100,
      height: 100,
      created_at: '',
      updated_at: '',
    }])

    const assets = mocks.service.list('s', 'all')

    expect(mocks.photoRepo.getBySession).toHaveBeenCalledTimes(1)
    expect(assets).toHaveLength(1)
    expect(assets[0].photo.id).toBe('p1')
    expect(assets[0].photo.metadata).toEqual({ make: 'Nikon' })
    // Session mode keeps the session-wide faces query without an IN clause.
    const faceSql = mocks.db.calls.find(sql => sql.includes('face_observations'))
    expect(faceSql).toContain('WHERE session_id = ?')
    expect(faceSql).not.toContain('IN (')
  })

  it('still filters filtered scope with matchesFilters on the full list', () => {
    const mocks = baseMocks()
    mocks.photoRepo.getBySession.mockReturnValue([{
      id: 'p1',
      session_id: 's',
      filepath: '/shoot/a.jpg',
      filename: 'a.jpg',
      checksum: '',
      checksum_file_size: 0,
      checksum_file_mtime_ms: 0,
      status: 'pending',
      metadata: '{}',
      result: '{}',
      asset_id: null,
      asset_file_id: 'af1',
      width: 100,
      height: 100,
      created_at: '',
      updated_at: '',
    }])
    mocks.cullingRepo.getBySession.mockReturnValue([{
      photo_id: 'p1',
      decision: 'keep',
      rating: 5,
      color_label: 'Red',
      decision_source: 'manual',
      revision: 1,
      updated_at: '',
    }])

    const assets = mocks.service.list('s', 'filtered', { pickStates: ['picked'], ratings: [5] })
    expect(assets).toHaveLength(1)
    expect(assets[0].state.rating).toBe(5)

    const excluded = mocks.service.list('s', 'filtered', { ratings: [3] })
    expect(excluded).toHaveLength(0)
  })
})
