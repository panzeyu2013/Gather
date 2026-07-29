import { Database } from '../database'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'

export interface SimilarityResultRow {
  id: number
  session_id: string
  groups_json: string
  stats_json: string
  param_threshold: number
  param_min_group_size: number
  created_at: string
}

@injectable()
export class SimilarityResultRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getLatest(sessionId: string): SimilarityResultRow | undefined {
    return this.db
      .prepare(
        'SELECT * FROM similarity_results WHERE session_id = ? ORDER BY id DESC LIMIT 1',
      )
      .get(sessionId) as SimilarityResultRow | undefined
  }

  replace(
    sessionId: string,
    groupsJson: string,
    statsJson: string,
    threshold: number,
    minGroupSize: number,
    memberships: Array<{ photoId: string; groupIndex: number }>,
  ): number {
    let resultId = 0
    const replaceResult = this.db.transaction(() => {
      this.db.prepare('DELETE FROM culling_decisions WHERE session_id = ?').run(sessionId)
      this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?').run(sessionId)
      const inserted = this.db.prepare(
        `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
      ).run(sessionId, groupsJson, statsJson, threshold, minGroupSize, new Date().toISOString())
      resultId = Number(inserted.lastInsertRowid)
      const insertMember = this.db.prepare(`
        INSERT INTO similarity_result_members
          (result_id, session_id, group_index, photo_id)
        VALUES (?, ?, ?, ?)
      `)
      for (const membership of memberships) {
        insertMember.run(resultId, sessionId, membership.groupIndex, membership.photoId)
      }
    })
    replaceResult()
    return resultId
  }

  getPhotoGroupMap(sessionId: string, resultId: number): Map<string, string> {
    const rows = this.db.prepare(`
      SELECT photo_id, group_index
      FROM similarity_result_members
      WHERE session_id = ? AND result_id = ?
    `).all(sessionId, resultId) as Array<{ photo_id: string; group_index: number }>
    return new Map(rows.map(row => [row.photo_id, `${resultId}:${row.group_index}`]))
  }
}
