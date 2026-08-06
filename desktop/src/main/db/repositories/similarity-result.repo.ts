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

// Neighbor-threshold tiers are stored as regular rows (keyed by
// (session_id, param_threshold)) with this marker in stats_json so getLatest
// keeps returning the most recent analysis/recluster row for existing callers
// (culling, writeback preview) without a schema migration.
const PRECOMPUTED_TIER_MARKER = '"precomputed":true'

@injectable()
export class SimilarityResultRepository {
  constructor(@inject(DI_TOKENS.DB) private db: Database) {}

  getLatest(sessionId: string): SimilarityResultRow | undefined {
    return this.db
      .prepare(
        `SELECT * FROM similarity_results
         WHERE session_id = ?
           AND stats_json NOT LIKE ?
         ORDER BY id DESC LIMIT 1`,
      )
      .get(sessionId, `%${PRECOMPUTED_TIER_MARKER}%`) as SimilarityResultRow | undefined
  }

  getByThreshold(sessionId: string, threshold: number): SimilarityResultRow | undefined {
    return this.db
      .prepare(
        `SELECT * FROM similarity_results
         WHERE session_id = ? AND param_threshold = ?
         ORDER BY id DESC LIMIT 1`,
      )
      .get(sessionId, threshold) as SimilarityResultRow | undefined
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
      this.db.prepare('DELETE FROM similarity_results WHERE session_id = ?').run(sessionId)
      resultId = this.insertRow(
        sessionId,
        groupsJson,
        statsJson,
        threshold,
        minGroupSize,
        memberships,
      )
    })
    replaceResult()
    return resultId
  }

  replaceForThreshold(
    sessionId: string,
    groupsJson: string,
    statsJson: string,
    threshold: number,
    minGroupSize: number,
    memberships: Array<{ photoId: string; groupIndex: number }>,
  ): number {
    let resultId = 0
    const replaceResult = this.db.transaction(() => {
      this.db
        .prepare(
          'DELETE FROM similarity_results WHERE session_id = ? AND param_threshold = ?',
        )
        .run(sessionId, threshold)
      resultId = this.insertRow(
        sessionId,
        groupsJson,
        statsJson,
        threshold,
        minGroupSize,
        memberships,
      )
    })
    replaceResult()
    return resultId
  }

  private insertRow(
    sessionId: string,
    groupsJson: string,
    statsJson: string,
    threshold: number,
    minGroupSize: number,
    memberships: Array<{ photoId: string; groupIndex: number }>,
  ): number {
    const inserted = this.db.prepare(
      `INSERT INTO similarity_results (session_id, groups_json, stats_json, param_threshold, param_min_group_size, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
    ).run(sessionId, groupsJson, statsJson, threshold, minGroupSize, new Date().toISOString())
    const resultId = Number(inserted.lastInsertRowid)
    const insertMember = this.db.prepare(`
      INSERT INTO similarity_result_members
        (result_id, session_id, group_index, photo_id)
      VALUES (?, ?, ?, ?)
    `)
    for (const membership of memberships) {
      insertMember.run(resultId, sessionId, membership.groupIndex, membership.photoId)
    }
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

  /** Group membership of a result row assembled from the members table, with
   * photo filepaths joined in. Ordering preserves the write order: groups in
   * ascending group_index and members within each group by the members table's
   * implicit auto-increment rowid (the first row of a group is its
   * representative). Returns null when the row has no member rows — legacy
   * rows written before the members table existed, whose groups_json remains
   * the only source. */
  getGroupMembers(
    sessionId: string,
    resultId: number,
  ): Array<{ groupIndex: number; photoId: string; filepath: string }> | null {
    const rows = this.db.prepare(`
      SELECT m.group_index, m.photo_id, p.filepath
      FROM similarity_result_members m
      JOIN photos p ON p.id = m.photo_id
      WHERE m.result_id = ? AND m.session_id = ?
      ORDER BY m.rowid
    `).all(resultId, sessionId) as Array<{
      group_index: number
      photo_id: string
      filepath: string
    }>
    if (rows.length === 0) return null
    return rows.map(row => ({
      groupIndex: row.group_index,
      photoId: row.photo_id,
      filepath: row.filepath,
    }))
  }
}
