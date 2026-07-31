import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

@injectable()
export class MetadataKeywordOriginRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  markIntroduced(xmpPath: string, source: string, keywords: string[]): void {
    if (keywords.length === 0) return
    const timestamp = new Date().toISOString()
    const statement = this.db.prepare(`
      INSERT INTO metadata_keyword_origins (
        xmp_path, source, keyword, active, created_at, updated_at
      ) VALUES (?, ?, ?, 1, ?, ?)
      ON CONFLICT(xmp_path, source, keyword) DO UPDATE SET
        active = 1, updated_at = excluded.updated_at
    `)
    this.db.transaction(() => {
      for (const keyword of new Set(keywords)) {
        statement.run(xmpPath, source, keyword, timestamp, timestamp)
      }
    })()
  }

  getActiveIntroduced(xmpPath: string, source: string, keywords: string[]): string[] {
    if (keywords.length === 0) return []
    const placeholders = keywords.map(() => '?').join(', ')
    const rows = this.db.prepare(`
      SELECT keyword FROM metadata_keyword_origins
      WHERE xmp_path = ? AND source = ? AND active = 1
        AND keyword IN (${placeholders})
    `).all(xmpPath, source, ...keywords) as Array<{ keyword: string }>
    return rows.map(row => row.keyword)
  }

  deactivate(xmpPath: string, source: string, keywords: string[]): void {
    if (keywords.length === 0) return
    const placeholders = keywords.map(() => '?').join(', ')
    this.db.prepare(`
      UPDATE metadata_keyword_origins
      SET active = 0, updated_at = ?
      WHERE xmp_path = ? AND source = ?
        AND keyword IN (${placeholders})
    `).run(new Date().toISOString(), xmpPath, source, ...keywords)
  }
}
