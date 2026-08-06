import { Database } from '../database'
import crypto from 'crypto'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface PhotoRow {
  id: string
  session_id: string
  filepath: string
  filename: string
  checksum: string
  checksum_file_size: number
  checksum_file_mtime_ms: number
  status: string
  metadata: string
  result: string
  asset_id: string | null
  asset_file_id: string | null
  width: number
  height: number
  created_at: string
  updated_at: string
}

/** Light projection of a photo row: every column except the two heavy JSON
 * blobs (metadata/result). Used by analysis/indexing/culling callers that only
 * need identity, file, asset and dimension fields. */
export type PhotoProjectionRow = Omit<PhotoRow, 'metadata' | 'result'>

/** Light projection of a photo row for paginated culling loads: the heavy
 * JSON columns (metadata/result/checksum) are intentionally omitted. */
export interface PhotoPageRow {
  rowid: number
  id: string
  session_id: string
  filepath: string
  filename: string
  status: string
  asset_id: string | null
  asset_file_id: string | null
  width: number
  height: number
  created_at: string
  updated_at: string
  checksum?: string
  metadata?: string
  result?: string
  checksum_file_size?: number
  checksum_file_mtime_ms?: number
}

/** Column list shared by the repository keyset query and the service-side
 * filter-pushdown queries, so both stay in sync. Requires the `p` table alias. */
export const PHOTO_PAGE_COLUMNS = `p.rowid, p.id, p.session_id, p.filepath, p.filename, p.status,
  p.asset_id, p.asset_file_id, p.width, p.height, p.created_at, p.updated_at`

/** RAW file extensions that make a photo the preferred variant of its logical
 * asset (photos sharing an `asset_id`, e.g. RAW+JPEG pairs). Shared by the
 * JS-side `assembleAssets` preference and the SQL preferred-row predicate so
 * the two can never drift apart. */
export const RAW_EXTENSIONS = [
  '.nef', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw',
] as const

/** `LOWER(p2.filename) LIKE '%.nef' OR ...` fragment for the SQL preferred-row
 * predicate; derived from RAW_EXTENSIONS (requires the `p2` table alias). */
export const RAW_EXTENSION_LIKE_SQL = RAW_EXTENSIONS
  .map(extension => `LOWER(p2.filename) LIKE '%${extension}'`)
  .join(' OR ')

@injectable()
export class PhotoRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getBySession(sessionId: string): PhotoRow[] {
    return this.db
      .prepare('SELECT * FROM photos WHERE session_id = ? ORDER BY rowid')
      .all(sessionId) as PhotoRow[]
  }

  /** `getBySession` minus the heavy JSON columns (metadata/result); the
   * remaining columns (checksum/asset_id/asset_file_id/width/height/status/
   * filepath/filename/timestamps) are preserved. Callers that do not need the
   * JSON blobs should use this projection. */
  getBySessionProjection(sessionId: string): PhotoProjectionRow[] {
    return this.db
      .prepare(`
        SELECT id, session_id, filepath, filename, checksum, checksum_file_size,
               checksum_file_mtime_ms, status, asset_id, asset_file_id, width,
               height, created_at, updated_at
        FROM photos WHERE session_id = ? ORDER BY rowid
      `)
      .all(sessionId) as PhotoProjectionRow[]
  }

  /** Keyset-paginated light projection ordered by rowid. Pass the `rowid` of
   * the last row of the previous page as `afterRowId` to fetch the next page.
   * Rows are cut at the physical photo level, so RAW/JPEG variants sharing an
   * `asset_id` can land on different pages; prefer `getAssetPage`. */
  getBySessionPage(
    sessionId: string,
    afterRowId?: number,
    limit = 200,
  ): PhotoPageRow[] {
    const statement = afterRowId === undefined
      ? this.db.prepare(`
          SELECT ${PHOTO_PAGE_COLUMNS}
          FROM photos p
          WHERE p.session_id = ?
          ORDER BY p.rowid
          LIMIT ?
        `)
      : this.db.prepare(`
          SELECT ${PHOTO_PAGE_COLUMNS}
          FROM photos p
          WHERE p.session_id = ? AND p.rowid > ?
          ORDER BY p.rowid
          LIMIT ?
        `)
    return (afterRowId === undefined
      ? statement.all(sessionId, limit)
      : statement.all(sessionId, afterRowId, limit)) as PhotoPageRow[]
  }

  countBySession(sessionId: string): number {
    const row = this.db
      .prepare('SELECT COUNT(*) as count FROM photos WHERE session_id = ?')
      .get(sessionId) as { count: number } | undefined
    return row?.count ?? 0
  }

  /** Keyset-paginated light projection grouped by logical asset: every page
   * contains whole asset groups (all photos sharing the same
   * `COALESCE(asset_id, id)`) ordered by their first rowid, so RAW/JPEG
   * variants never split across pages. Pass the `first_rowid` of the last
   * asset group of the previous page as `afterFirstRowid` to fetch the next
   * page (group first rowids are mutually distinct, so the keyset is strictly
   * ordered without gaps or duplicates). `cursor` is the group-query
   * `first_rowid` of the page's last group — the keyset cursor for the next
   * page (null when no groups were selected). */
  getAssetPage(
    sessionId: string,
    afterFirstRowid?: number,
    limit = 200,
  ): { rows: PhotoPageRow[]; cursor: number | null } {
    const groups = this.db.prepare(`
      SELECT COALESCE(asset_id, id) AS gid, MIN(rowid) AS first_rowid
      FROM photos
      WHERE session_id = ?
      GROUP BY COALESCE(asset_id, id)
      HAVING MIN(rowid) > ?
      ORDER BY first_rowid
      LIMIT ?
    `).all(sessionId, afterFirstRowid ?? 0, limit) as Array<{
      gid: string
      first_rowid: number
    }>
    if (groups.length === 0) return { rows: [], cursor: null }
    const rows: PhotoPageRow[] = []
    for (let index = 0; index < groups.length; index += 800) {
      const chunk = groups.slice(index, index + 800).map(group => group.gid)
      rows.push(...this.db.prepare(`
        SELECT ${PHOTO_PAGE_COLUMNS}
        FROM photos p
        WHERE p.session_id = ? AND COALESCE(p.asset_id, p.id) IN (${chunk.map(() => '?').join(',')})
        ORDER BY p.rowid
      `).all(sessionId, ...chunk) as PhotoPageRow[])
    }
    return { rows, cursor: groups[groups.length - 1].first_rowid }
  }

  /** Number of distinct logical assets in the session — the `total` shown by
   * the culling filmstrip, which counts one entry per asset (not per physical
   * photo row). */
  countAssetsBySession(sessionId: string): number {
    const row = this.db.prepare(`
      SELECT COUNT(*) AS count
      FROM (SELECT COALESCE(asset_id, id) AS gid FROM photos WHERE session_id = ? GROUP BY gid)
    `).get(sessionId) as { count: number } | undefined
    return row?.count ?? 0
  }

  containsFilepath(filepath: string): boolean {
    return Boolean(
      this.db.prepare('SELECT 1 FROM photos WHERE filepath = ? LIMIT 1').get(filepath),
    )
  }

  addPhotos(
    sessionId: string,
    filepaths: Array<{ filepath: string; width: number; height: number }>,
    _source: string,
  ): { added: number; skipped: number } {
    const now = new Date().toISOString()
    let added = 0
    let skipped = 0

    const insertStmt = this.db.prepare(
      `INSERT OR IGNORE INTO photos (id, session_id, filepath, filename, checksum, status, metadata, result, width, height, created_at, updated_at)
       VALUES (?, ?, ?, ?, '', 'pending', '{}', '{}', ?, ?, ?, ?)`,
    )
    const existsStmt = this.db.prepare(
      'SELECT 1 FROM photos WHERE session_id = ? AND filepath = ? LIMIT 1',
    )

    const insertMany = this.db.transaction((paths: Array<{ filepath: string; width: number; height: number }>) => {
      for (const { filepath, width, height } of paths) {
        if (existsStmt.get(sessionId, filepath)) {
          skipped++
          continue
        }
        const filename = filepath.split(/[/\\]/).pop() ?? filepath
        const id = crypto.randomUUID()
        const result = insertStmt.run(id, sessionId, filepath, filename, width, height, now, now)
        if (result.changes > 0) {
          added++
        } else {
          skipped++
        }
      }
    })

    insertMany(filepaths)
    return { added, skipped }
  }

  deleteBySession(sessionId: string): void {
    this.db.prepare('DELETE FROM photos WHERE session_id = ?').run(sessionId)
  }

  updateIndexedFile(
    photoId: string,
    width: number,
    height: number,
    changed: boolean,
  ): void {
    this.db.prepare(`
      UPDATE photos
      SET width = ?, height = ?, status = 'pending',
          checksum = CASE WHEN ? THEN '' ELSE checksum END,
          checksum_file_size = CASE WHEN ? THEN 0 ELSE checksum_file_size END,
          checksum_file_mtime_ms = CASE WHEN ? THEN 0 ELSE checksum_file_mtime_ms END,
          updated_at = ?
      WHERE id = ?
    `).run(
      width,
      height,
      changed ? 1 : 0,
      changed ? 1 : 0,
      changed ? 1 : 0,
      new Date().toISOString(),
      photoId,
    )
  }

  updateChecksum(
    photoId: string,
    checksum: string,
    fileSize: number,
    fileMtimeMs: number,
  ): void {
    this.db.prepare(`
      UPDATE photos
      SET checksum = ?, checksum_file_size = ?, checksum_file_mtime_ms = ?,
          updated_at = ?
      WHERE id = ?
    `).run(checksum, fileSize, fileMtimeMs, new Date().toISOString(), photoId)
  }

  markMissing(photoIds: string[]): void {
    const statement = this.db.prepare(
      "UPDATE photos SET status = 'missing', updated_at = ? WHERE id = ?",
    )
    const updateMany = this.db.transaction((ids: string[]) => {
      const now = new Date().toISOString()
      for (const id of ids) statement.run(now, id)
    })
    updateMany(photoIds)
  }
}
