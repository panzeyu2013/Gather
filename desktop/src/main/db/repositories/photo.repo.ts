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

@injectable()
export class PhotoRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getBySession(sessionId: string): PhotoRow[] {
    return this.db
      .prepare('SELECT * FROM photos WHERE session_id = ? ORDER BY rowid')
      .all(sessionId) as PhotoRow[]
  }

  countBySession(sessionId: string): number {
    const row = this.db
      .prepare('SELECT COUNT(*) as count FROM photos WHERE session_id = ?')
      .get(sessionId) as { count: number } | undefined
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
