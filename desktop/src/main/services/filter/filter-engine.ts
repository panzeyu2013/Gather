import { Database } from '../../db/database'
import type { FilterGroup, FilterRule, PhotoData, GlobalPhotoResult, FilterSuggestion } from '@gather/shared'
import type { PhotoRow } from '../../db/repositories/photo.repo'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

interface WhereClauseResult {
  sql: string
  params: unknown[]
}

const SIMPLE_FIELDS = new Set(['filename', 'filepath', 'checksum', 'status', 'created_at'])
const METADATA_FIELDS = new Set([
  'date_taken', 'camera_make', 'camera_model', 'lens_model',
  'focal_length', 'f_number', 'exposure_time', 'iso', 'rating',
  'gps_latitude', 'gps_longitude', 'width', 'height', 'file_size', 'file_mtime', 'label',
])

function isFilterRule(condition: FilterRule | FilterGroup): condition is FilterRule {
  return 'field' in condition
}

function escapeLike(value: string): string {
  // Escape LIKE wildcards so directory paths containing % or _ match literally.
  return value.replace(/[\\%_]/g, (ch) => `\\${ch}`)
}

function resolveField(rule: FilterRule): { prefix: string; col: string } {
  if (SIMPLE_FIELDS.has(rule.field)) {
    return { prefix: 'p', col: rule.field }
  }
  if (METADATA_FIELDS.has(rule.field)) {
    return { prefix: 'pmc', col: rule.field }
  }
  throw new Error('Unknown filter field: ' + rule.field)
}

@injectable()
export class FilterEngine {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  filterPhotos(sessionId: string, criteria: FilterGroup, sortBy?: string, sortOrder?: string, limit?: number, offset?: number): PhotoData[] {
    const db = this.db
    const { sql: whereSql, params: whereParams } = this.buildWhereClause(criteria)

    const sessionFilter = sessionId === '__global__' ? '1=1' : 'p.session_id = ?'
    const sql = [
      'SELECT DISTINCT p.id, p.session_id, p.filepath, p.filename, p.checksum, p.status,',
      'p.metadata, p.result, p.created_at, p.updated_at,',
      '(SELECT COUNT(*) FROM face_observations fo WHERE fo.photo_id = p.id AND fo.session_id = p.session_id) as face_count',
      'FROM photos p',
      'LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id',
      `WHERE ${sessionFilter} AND (${whereSql || '1=1'})`,
    ].join(' ')

    const allParams: unknown[] = sessionId === '__global__' ? [...whereParams] : [sessionId, ...whereParams]

    let resolvedSql = sortBy
      ? `${sql} ORDER BY ${this.resolveSortColumn(sortBy)} ${sortOrder === 'asc' ? 'ASC' : 'DESC'}`
      : sql

    if (typeof limit === 'number') {
      resolvedSql += ' LIMIT ?'
      allParams.push(limit)
    }
    if (typeof offset === 'number') {
      resolvedSql += ' OFFSET ?'
      allParams.push(offset)
    }

    const rows = db.prepare(resolvedSql).all(...allParams) as (PhotoRow & { face_count: number })[]
    return rows.map((row) => this.rowToPhotoData(row))
  }

  filterGlobally(
    criteria: FilterGroup,
    sortBy?: string,
    sortOrder?: string,
    limit?: number,
    offset?: number,
    sessionId?: string,
  ): GlobalPhotoResult[] {
    const db = this.db
    const { sql: whereSql, params: whereParams } = this.buildWhereClause(criteria)

    const membershipFilter = sessionId
      ? `AND EXISTS (
          SELECT 1 FROM photos member
          WHERE COALESCE(NULLIF(member.asset_id, ''), member.id) =
            COALESCE(NULLIF(p.asset_id, ''), p.id)
            AND member.session_id = ?
        )`
      : ''
    const sql = [
      'WITH matching AS (',
      'SELECT p.rowid AS photo_rowid, COALESCE(NULLIF(p.asset_id, \'\'), p.id) AS asset_key',
      'FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id',
      `WHERE (${whereSql || '1=1'}) ${membershipFilter}`,
      '), representatives AS (',
      'SELECT asset_key, MIN(photo_rowid) AS photo_rowid FROM matching GROUP BY asset_key',
      ')',
      'SELECT p.id AS photo_id, COALESCE(NULLIF(p.asset_id, \'\'), p.id) AS asset_id,',
      'p.session_id, s.name AS session_name, p.filename, p.filepath, p.status,',
      'COALESCE(pmc.rating, 0) AS rating, COALESCE(pmc.label, \'\') AS label,',
      'COALESCE(pmc.keywords, \'[]\') AS keywords,',
      '(SELECT GROUP_CONCAT(DISTINCT member.session_id) FROM photos member',
      ' WHERE COALESCE(NULLIF(member.asset_id, \'\'), member.id) = representatives.asset_key) AS session_ids,',
      '(SELECT GROUP_CONCAT(DISTINCT member_session.name) FROM photos member',
      ' JOIN sessions member_session ON member_session.id = member.session_id',
      ' WHERE COALESCE(NULLIF(member.asset_id, \'\'), member.id) = representatives.asset_key) AS session_names',
      'FROM representatives JOIN photos p ON p.rowid = representatives.photo_rowid',
      'LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id',
      'JOIN sessions s ON p.session_id = s.id',
      sortBy
        ? `ORDER BY ${this.resolveSortColumn(sortBy)} ${sortOrder === 'asc' ? 'ASC' : 'DESC'}`
        : 'ORDER BY p.rowid',
    ].join(' ')

    const params = [...whereParams, ...(sessionId ? [sessionId] : [])]
    let paginatedSql = sql
    if (typeof limit === 'number') {
      paginatedSql += ' LIMIT ?'
      params.push(Math.max(1, Math.min(500, Math.floor(limit))))
      if (typeof offset === 'number') {
        paginatedSql += ' OFFSET ?'
        params.push(Math.max(0, Math.floor(offset)))
      }
    }
    const rows = db.prepare(paginatedSql).all(...params) as {
      photo_id: string
      asset_id: string
      session_id: string
      session_name: string
      filename: string
      filepath: string
      status: string
      rating: number
      label: string
      keywords: string
      session_ids: string
      session_names: string
    }[]

    return rows.map((r) => ({
      photoId: r.photo_id,
      assetId: r.asset_id,
      sessionId: r.session_id,
      sessionName: r.session_name,
      sessionIds: r.session_ids ? r.session_ids.split(',') : [r.session_id],
      sessionNames: r.session_names ? r.session_names.split(',') : [r.session_name],
      filename: r.filename,
      filepath: r.filepath,
      status: r.status,
      rating: r.rating,
      label: r.label,
      keywords: (() => {
        try {
          const parsed = JSON.parse(r.keywords) as unknown
          return Array.isArray(parsed)
            ? parsed.filter((value): value is string => typeof value === 'string')
            : []
        } catch {
          return []
        }
      })(),
    }))
  }

  countGlobally(criteria: FilterGroup, sessionId?: string): number {
    const { sql: whereSql, params } = this.buildWhereClause(criteria)
    const membershipFilter = sessionId
      ? `AND EXISTS (
          SELECT 1 FROM photos member
          WHERE COALESCE(NULLIF(member.asset_id, ''), member.id) =
            COALESCE(NULLIF(p.asset_id, ''), p.id)
            AND member.session_id = ?
        )`
      : ''
    const row = this.db.prepare(`
      SELECT COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id)) AS count
      FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
      WHERE (${whereSql || '1=1'}) ${membershipFilter}
    `).get(...params, ...(sessionId ? [sessionId] : [])) as { count: number }
    return row.count
  }

  countPhotos(sessionId: string, criteria: FilterGroup): number {
    const { sql: whereSql, params } = this.buildWhereClause(criteria)
    const sessionFilter = sessionId === '__global__' ? '1=1' : 'p.session_id = ?'
    const allParams: unknown[] = sessionId === '__global__' ? params : [sessionId, ...params]
    const countExpression = sessionId === '__global__'
      ? "COUNT(DISTINCT COALESCE(NULLIF(p.asset_id, ''), p.id))"
      : 'COUNT(DISTINCT p.id)'
    const row = this.db.prepare(`
      SELECT ${countExpression} AS count
      FROM photos p LEFT JOIN photo_metadata_cache pmc ON p.id = pmc.photo_id
      WHERE ${sessionFilter} AND (${whereSql || '1=1'})
    `).get(...allParams) as { count: number }
    return row.count
  }

  suggest(_sessionId: string, keyword: string): FilterSuggestion[] {
    if (!keyword || keyword.trim().length < 2) return []
    const db = this.db
    const pattern = `%${keyword}%`
    const cameraRows = db.prepare(
      'SELECT DISTINCT camera_make FROM photo_metadata_cache WHERE camera_make LIKE ? LIMIT 5'
    ).all(pattern) as { camera_make: string }[]
    const result: FilterSuggestion[] = [
      { field: 'camera_make', values: cameraRows.map(r => r.camera_make) },
    ]
    return result
  }

  buildWhereClause(group: FilterGroup): WhereClauseResult {
    const parts: string[] = []
    const params: unknown[] = []

    for (const condition of group.conditions) {
      if (isFilterRule(condition)) {
        const { sql, params: ruleParams } = this.buildConditionSql(condition)
        if (sql) {
          parts.push(sql)
          params.push(...ruleParams)
        }
      } else {
        const sub = this.buildWhereClause(condition)
        if (sub.sql) {
          parts.push(`(${sub.sql})`)
          params.push(...sub.params)
        }
      }
    }

    if (parts.length === 0) {
      return { sql: '', params: [] }
    }

    const joiner = group.logic === 'or' ? ' OR ' : ' AND '
    return { sql: parts.join(joiner), params }
  }

  private buildConditionSql(rule: FilterRule): { sql: string; params: unknown[] } {
    const { field, operator, value } = rule

    if (field === 'has_face') {
      return this.buildHasFaceCondition(operator, value)
    }
    if (field === 'person') {
      return this.buildPersonCondition(operator, value)
    }
    if (field === 'keywords') {
      return this.buildKeywordsCondition(operator, value)
    }
    if (field === 'directory') {
      if (operator !== 'eq' && operator !== 'starts_with') {
        // Previously this silently matched everything, producing misleading
        // "all photos match" results for unsupported operators.
        throw new Error(`Unsupported operator for directory field: ${operator}`)
      }
      return {
        sql: `p.filepath LIKE ? || '%' ESCAPE '\\'`,
        params: [escapeLike(String(value))],
      }
    }
    if (field === 'volume') {
      return {
        sql: `EXISTS (
          SELECT 1 FROM asset_files af
          WHERE af.id = p.asset_file_id AND af.volume_id = ?
        )`,
        params: [String(value)],
      }
    }
    if (field === 'has_duplicates') {
      const existsSql = `EXISTS (
        SELECT 1 FROM duplicate_group_members dgm
        JOIN duplicate_groups dg ON dg.id = dgm.group_id
        WHERE dgm.photo_id = p.id AND dg.member_count > 1
      )`
      return value === false
        ? { sql: `NOT ${existsSql}`, params: [] }
        : { sql: existsSql, params: [] }
    }

    const { prefix, col } = resolveField(rule)
    const fullCol = `${prefix}.${col}`

    switch (operator) {
      case 'eq':
        return { sql: `${fullCol} = ?`, params: [value] }
      case 'neq':
        return { sql: `${fullCol} != ?`, params: [value] }
      case 'gt':
        return { sql: `${fullCol} > ?`, params: [value] }
      case 'lt':
        return { sql: `${fullCol} < ?`, params: [value] }
      case 'gte':
        return { sql: `${fullCol} >= ?`, params: [value] }
      case 'lte':
        return { sql: `${fullCol} <= ?`, params: [value] }
      case 'between': {
        const arr = value as [unknown, unknown]
        return { sql: `${fullCol} BETWEEN ? AND ?`, params: [arr[0], arr[1]] }
      }
      case 'in': {
        const arr = value as unknown[]
        if (!Array.isArray(arr) || arr.length === 0) {
          return { sql: '1=0', params: [] }
        }
        const placeholders = arr.map(() => '?').join(', ')
        return { sql: `${fullCol} IN (${placeholders})`, params: arr }
      }
      case 'contains':
        return { sql: `${fullCol} LIKE '%' || ? || '%'`, params: [String(value)] }
      case 'starts_with':
        return { sql: `${fullCol} LIKE ? || '%'`, params: [String(value)] }
      case 'contains_any': {
        const arr = (Array.isArray(value) ? value : [value]) as string[]
        if (arr.length === 0) return { sql: '1=0', params: [] }
        const orParts = arr.map(() => `${fullCol} LIKE '%' || ? || '%'`)
        return { sql: `(${orParts.join(' OR ')})`, params: arr }
      }
      case 'contains_all': {
        const arr = (Array.isArray(value) ? value : [value]) as string[]
        if (arr.length === 0) return { sql: '1=0', params: [] }
        const andParts = arr.map(() => `${fullCol} LIKE '%' || ? || '%'`)
        return { sql: `(${andParts.join(' AND ')})`, params: arr }
      }
      case 'exists':
        return { sql: `${fullCol} IS NOT NULL`, params: [] }
      default:
        throw new Error(`Unsupported filter operator: ${String(operator)}`)
    }
  }

  private buildKeywordsCondition(operator: string, value: unknown): { sql: string; params: unknown[] } {
    const arr = (Array.isArray(value) ? value : [value]) as string[]
    switch (operator) {
      case 'contains_any': {
        if (arr.length === 0) return { sql: '1=0', params: [] }
        const placeholders = arr.map(() => '?').join(', ')
        return {
          sql: `EXISTS (SELECT 1 FROM json_each(pmc.keywords) WHERE value IN (${placeholders}))`,
          params: arr,
        }
      }
      case 'contains_all': {
        if (arr.length === 0) return { sql: '1=0', params: [] }
        const unique = [...new Set(arr)]
        const placeholders = unique.map(() => '?').join(', ')
        return {
          sql: `(SELECT COUNT(DISTINCT value) FROM json_each(pmc.keywords) WHERE value IN (${placeholders})) = ?`,
          params: [...unique, unique.length],
        }
      }
      case 'exists':
        return { sql: `pmc.keywords IS NOT NULL AND pmc.keywords != '[]'`, params: [] }
      case 'eq': {
        const sorted = [...arr].sort()
        return {
          sql: `(
            SELECT json_group_array(value ORDER BY value) FROM json_each(pmc.keywords)
          ) = (
            SELECT json_group_array(value ORDER BY value) FROM json_each(?)
          )`,
          params: [JSON.stringify(sorted)],
        }
      }
      default:
        return { sql: '1=1', params: [] }
    }
  }

  private buildHasFaceCondition(operator: string, value: unknown): { sql: string; params: unknown[] } {
    const existsSql =
      'EXISTS (SELECT 1 FROM face_observations fo WHERE fo.photo_id = p.id AND fo.session_id = p.session_id)'

    switch (operator) {
      case 'eq':
        return value === true ? { sql: existsSql, params: [] } : { sql: `NOT ${existsSql}`, params: [] }
      case 'neq':
        return value === true ? { sql: `NOT ${existsSql}`, params: [] } : { sql: existsSql, params: [] }
      case 'exists':
        return { sql: existsSql, params: [] }
      default:
        return { sql: existsSql, params: [] }
    }
  }

  private buildPersonCondition(operator: string, value: unknown): { sql: string; params: unknown[] } {
    switch (operator) {
      case 'eq':
        return {
          sql: 'EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)',
          params: [String(value)],
        }
      case 'contains':
        return {
          sql: 'EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name LIKE \'%\' || ? || \'%\')',
          params: [String(value)],
        }
      case 'neq':
        return {
          sql: 'NOT EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)',
          params: [String(value)],
        }
      case 'contains_any': {
        const names = (Array.isArray(value) ? value : [value]) as string[]
        if (names.length === 0) return { sql: '1=0', params: [] }
        const parts = names.map(() => 'per.name LIKE \'%\' || ? || \'%\'')
        return {
          sql: `EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND (${parts.join(' OR ')}))`,
          params: names,
        }
      }
      case 'in': {
        const ids = (Array.isArray(value) ? value : [value]) as string[]
        if (ids.length === 0) return { sql: '1=0', params: [] }
        const placeholders = ids.map(() => '?').join(', ')
        return {
          sql: `EXISTS (SELECT 1 FROM person_photos pp WHERE pp.photo_id = p.id AND pp.person_id IN (${placeholders}))`,
          params: ids,
        }
      }
      default:
        return {
          sql: 'EXISTS (SELECT 1 FROM person_photos pp JOIN persons per ON pp.person_id = per.id WHERE pp.photo_id = p.id AND per.name = ?)',
          params: [String(value)],
        }
    }
  }

  private resolveSortColumn(sortBy: string): string {
    if (SIMPLE_FIELDS.has(sortBy)) return `p.${sortBy}`
    if (METADATA_FIELDS.has(sortBy)) return `pmc.${sortBy}`
    return 'p.filename'
  }

  private rowToPhotoData(row: PhotoRow & { face_count: number }): PhotoData {
    return {
      id: row.id,
      sessionId: row.session_id,
      filepath: row.filepath,
      filename: row.filename,
      checksum: row.checksum,
      hasExistingXmp: false,
      faceCount: row.face_count,
      width: row.width ?? 0,
      height: row.height ?? 0,
      metadata: typeof row.metadata === 'string' ? JSON.parse(row.metadata) : row.metadata,
      result: typeof row.result === 'string' ? JSON.parse(row.result) : row.result,
      status: row.status,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    }
  }
}
